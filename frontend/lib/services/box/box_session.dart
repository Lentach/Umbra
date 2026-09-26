import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_envelope.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_inbox.dart';
import 'box_notifiers.dart';
import 'box_outbox.dart';
import 'box_sibling_rotation.dart';
import 'box_sibling_swap.dart';
import 'box_siblings.dart';
import 'box_wire.dart';
import 'queue_keys.dart';
import 'queue_seal.dart';

/// One account session's link to the box (metadata-privacy PR3.1 slice (a)):
/// owns the [BoxClient] and keeps this device's REQUEST queue published on
/// the account socket (`setRequestQueue`, wire.md "First contact").
///
/// Two independent connections meet here — the box socket (no account on
/// its path, I1) and the account socket (JWT) — so publishing waits for
/// both: the queue exists only once the box has answered, and the server
/// files it under the device the account socket's JWT names.
///
/// Published at most once per (device id, sid) per SESSION — the dedupe
/// lives in RAM, so every launch, tab and reload publishes again (the
/// server overwrites the same value; the event is throttled at 30 / 15 min).
/// A new device id — a §6.2 reset re-homes the account — or a replaced queue
/// publishes again; a refused or unanswered publish is re-sent on the next
/// ready, a rate-limited one after `retryAfterMs`.
///
/// It also RECEIVES (slice (b)): once the box is ready and the store is
/// open, every contact's inbound queue is subscribed, and its [BoxInbox]
/// journals, acks and offers each delivery to [consumer].
///
/// And it SENDS (slice (c)): as the [BoxOutbox], it hands the messaging send
/// path a friend's addresses and seals each frame into its queue.
///
/// And it links this account's OWN devices (sibling queues, owner decisions
/// 26–29): it keeps this device's SELF-queue (`QueueKeys.ensureSelf`) beside
/// the request queue, drives the address swap ([BoxSiblingSwap]) and the
/// rotation on revoke ([BoxSiblingRotation]), hands the send path the
/// siblings' self-queues ([siblingAddresses], part B) and, as the
/// [BoxSiblingLink], stores what the messaging reader learns from a sibling.
///
/// And it registers box push (E9): with a [BoxPushSource], every contact
/// queue gets a notifier ([BoxNotifiers]) once the box is ready and the
/// store open, and again whenever the push target changes.
class BoxSession implements BoxOutbox, BoxSiblingLink {
  BoxSession({
    required BoxClient box,
    required ContactStore store,
    required void Function(String event, Object? data) emit,
    QueueSeal? seal,
    BoxPushSource? push,
    DateTime Function()? now,
  }) : _box = box,
       _store = store,
       _keys = QueueKeys(box: box, store: store),
       _seal = seal ?? QueueSeal(),
       _emit = emit,
       _now = now ?? DateTime.now {
    _inbox = BoxInbox(box: box, store: store, seal: _seal, now: now);
    _notifiers = push == null
        ? null
        : BoxNotifiers(box: box, store: store, push: push);
    _swap = BoxSiblingSwap(
      box: box,
      store: store,
      seal: _seal,
      emit: emit,
      selfQueue: _currentSelf,
    );
    _rotation = BoxSiblingRotation(
      box: box,
      store: store,
      keys: _keys,
      now: now,
      rotated: (next) {
        _self = next;
        _swap.run();
      },
      sendToSibling: _sendToSibling,
    );
  }

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final QueueSeal _seal;
  late final BoxInbox _inbox;
  late final BoxSiblingSwap _swap;
  late final BoxSiblingRotation _rotation;
  late final BoxNotifiers? _notifiers;

  /// Siblings re-keyed this session ([rekeySibling]): once each.
  final Set<int> _rekeyed = {};

  /// When this device built a re-key's handoff for a sibling it has not
  /// read since ([awaitingRekeyFrom], decision 37).
  final Map<int, DateTime> _rekeyAsked = {};
  final DateTime Function() _now;
  final void Function(String event, Object? data) _emit;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  ContactQueue? _request;
  bool _ensuring = false;

  /// This device's self-queue once ensured (and subscribed) this session.
  /// Read through [_currentSelf], never directly.
  ContactQueue? _self;
  bool _ensuringSelf = false;

  /// The self-queue to hand a sibling: the one the ROW holds, once this
  /// session ensured one. Any write re-reads the row, and another tab of
  /// this device may have rotated it meanwhile (E6): that queue is followed
  /// — subscribed here too — and the one this session ensured, now
  /// retiring, is never handed out again.
  ContactQueue? _currentSelf() {
    final ensured = _self;
    final current = _store.selfQueue;
    if (ensured == null || current == null || current.rid == ensured.rid) {
      return ensured;
    }
    final owned = QueueKeys.authOf(current);
    if (owned == null) return ensured;
    _self = current;
    unawaited(_box.subscribe([owned]));
    return current;
  }

  /// Null until the account socket is ready; the device id it names (null
  /// from a server that predates the field — the server still files it).
  ({int? deviceId})? _account;

  /// E2E became ready on THIS account connect (it fires once per connect).
  /// Nothing is published before it: a device still on the link gate holds
  /// no identity, and its token names the PRIMARY's device, so a publish
  /// would overwrite the primary's request queue (found live, 2026-09-25).
  /// Cleared with the connect, so a link rebind — identity adopted on the
  /// old token — publishes only under the new one.
  bool _e2eReady = false;
  String? _published;
  String? _inFlight;
  Timer? _retry;
  bool _disposed = false;

  /// The app's reader of box deliveries (`MessagingProvider`). Wiring one
  /// offers it everything that landed in the journal meanwhile.
  BoxInboxConsumer? get consumer => _inbox.consumer;

  set consumer(BoxInboxConsumer? read) {
    _inbox.consumer = read;
    if (read != null) unawaited(_inbox.drain());
  }

  /// Offers the journal again — the reader may be able to read what it
  /// refused (E2E just became ready).
  void drainInbox() {
    if (!_disposed) unawaited(_inbox.drain());
  }

  /// The Signal side of the sibling swap (`MessagingProvider`).
  OwnDeviceEncrypt? get encryptForOwnDevice => _swap.encrypt;

  set encryptForOwnDevice(OwnDeviceEncrypt? encrypt) {
    _swap
      ..encrypt = encrypt
      ..run();
  }

  /// The own verified list, for the rotation on revoke (`MessagingProvider`).
  OwnLiveDevices? get ownLiveDevices => _rotation.liveDevices;

  set ownLiveDevices(OwnLiveDevices? lookup) {
    _rotation
      ..liveDevices = lookup
      ..run();
  }

  /// E2E is ready on this connect: the request queue may be published, a
  /// handoff encrypted and the own list read now.
  void e2eReady() {
    if (_disposed) return;
    _e2eReady = true;
    _publish();
    _swap.e2eReady();
    _rotation.run();
  }

  /// The own verified device list was dropped (a device linked or revoked).
  void ownDevicesChanged() {
    if (_disposed) return;
    _swap.ownDevicesChanged();
    _rotation.run();
  }

  /// `ownRequestQueues { success, devices?, error?, retryAfterMs? }`.
  void onOwnRequestQueues(Object? data) {
    if (!_disposed) unawaited(_swap.onOwnRequestQueues(data));
  }

  /// Connects the box and starts following it.
  void start() {
    _inbox.start();
    _notifiers?.start();
    _subscriptions
      ..add(
        _box.states.listen((state) {
          if (state != BoxState.ready) return;
          if (_request == null) unawaited(_ensure());
          if (_self == null) unawaited(_ensureSelf());
          unawaited(_receive());
          _swap.run();
          _rotation.run();
          _notifiers?.run();
        }),
      )
      ..add(_box.lostQueues.listen(_onLost));
    _box.connect();
  }

  /// Reconnects the box after [close] (the account reconnected).
  void resume() {
    if (!_disposed) _box.connect();
  }

  /// Drops the box connection; [resume] brings it back.
  void close() => _box.close();

  /// The account socket is ready (`socketReady`) as [deviceId].
  void accountReady(int? deviceId) {
    _account = (deviceId: deviceId);
    _inFlight = null;
    if (_request == null) {
      unawaited(_ensure());
    } else {
      _publish();
    }
    _swap.accountReady(deviceId);
    // `socketReady` is what confirms this device's id for the own list.
    _rotation.run();
  }

  /// The contact store (re)opened — a web vault that booted locked was just
  /// unlocked, or a slow open landed after the budget. Every earlier attempt
  /// found it closed, and neither socket will say "ready" again on its own.
  void storeOpened() {
    if (_request == null) unawaited(_ensure());
    if (_self == null) unawaited(_ensureSelf());
    unawaited(_receive());
    _swap.run();
    _rotation.run();
    _notifiers?.run();
  }

  /// The account socket dropped: an answer still owed will never come.
  void accountLost() {
    _account = null;
    _e2eReady = false;
    _inFlight = null;
    _retry?.cancel();
    _swap.accountLost();
  }

  /// `requestQueueSet { success, error?, retryAfterMs? }`.
  void onRequestQueueSet(Object? data) {
    final sent = _inFlight;
    _inFlight = null;
    if (sent == null || data is! Map) return;
    if (data['success'] == true) {
      _published = sent;
      return;
    }
    final retryMs = data['retryAfterMs'];
    if (data['error'] == 'rate_limited' && retryMs is int) {
      _retry?.cancel();
      _retry = Timer(Duration(milliseconds: retryMs), _publish);
    }
  }

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) {
    // Answered whatever the box's state: a peer the box covers must FAIL a
    // send while it is down (decision 19), never fall back to the old path
    // and leave a server row naming the pair (decision 15). A closed store
    // holds no records, so `byUserId` answers null below.
    if (_disposed) return const {};
    final peer = _store.byUserId(peerUserId);
    if (peer == null || peer.state != ContactState.friend) return const {};
    return {for (final to in peer.outbound) to.peerDeviceId: to};
  }

  @override
  Map<int, ContactOutbound> siblingAddresses() {
    if (_disposed) return const {};
    return {
      for (final s in _store.siblings)
        if ((s.sid, s.sealPub) case (final String sid, final String sealPub))
          s.deviceId: ContactOutbound(
            peerDeviceId: s.deviceId,
            sid: sid,
            sealPub: sealPub,
          ),
    };
  }

  @override
  Iterable<int> coveredPeers() => _disposed
      ? const []
      : [
          for (final peer in _store.all)
            if (peer.state == ContactState.friend && peer.outbound.isNotEmpty)
              peer.userId,
        ];

  @override
  Future<bool> deliver(ContactOutbound to, Uint8List body) async {
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    final sealPub = boxB64Decode(to.sealPub, 32);
    if (_disposed || sid == null || sealPub == null) return false;
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return false;
    return await _box.send(sid, blob) is BoxOk;
  }

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    // Refused here, never thrown: the client throws on both, and the send
    // path fails the row on any refusal (E17b).
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    if (sid == null) return const BoxRefused(BoxCode.invalidPayload);
    if (!kBoxMediaLadder.contains(framed.length)) {
      return const BoxRefused(BoxCode.badSize);
    }
    return _box.uploadMedia(sid, framed);
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    if (id.length != kBoxMediaIdBytes) {
      return const BoxRefused(BoxCode.invalidPayload);
    }
    return _box.downloadMedia(id);
  }

  @override
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async {
    if (_disposed) return SiblingWrite.retryLater;
    final stored = await _store.learnSibling(
      deviceId,
      sid: sid,
      sealPub: sealPub,
    );
    if (stored != SiblingWrite.stored) return stored;
    final selfQueue = ContactOutbound(
      peerDeviceId: deviceId,
      sid: sid,
      sealPub: sealPub,
    );
    final ack = E2eEnvelope.buildQueueHandoffAck(sid: sid);
    final acked = await _sendToSibling(selfQueue, ack);
    final self = _store.selfQueue;
    final owed =
        self != null &&
        _store.siblings
                .where((s) => s.deviceId == deviceId)
                .firstOrNull
                ?.ackedSelfSid !=
            self.sid;
    final handedBack =
        owed &&
        await _sendToSibling(
          selfQueue,
          E2eEnvelope.buildQueueHandoff(sid: self.sid, sealPub: self.sealPub),
        );
    E2eDiagLog.add('BOX_SIBLING_HANDOFF', {
      'device': deviceId,
      'acked': acked,
      if (owed) 'handedBack': handedBack,
    });
    if (kDebugMode) {
      debugPrint(
        '[E2E-FLOW] BOX_SIBLING_HANDOFF | {device: $deviceId, acked: $acked'
        '${owed ? ', handedBack: $handedBack' : ''}}',
      );
    }
    return SiblingWrite.stored;
  }

  /// Encrypts [envelope] for sibling [to] and seals it into its self-queue
  /// as a normal frame; true only when the box took it.
  Future<bool> _sendToSibling(
    ContactOutbound to,
    Map<String, dynamic> envelope,
  ) async {
    final encrypt = _swap.encrypt;
    if (_disposed || encrypt == null) return false;
    final frame = await encrypt(to.peerDeviceId, jsonEncode(envelope));
    return frame != null && await deliver(to, frame.encode());
  }

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async {
    if (_disposed) return SiblingWrite.retryLater;
    final written = await _store.markSiblingAcked(deviceId, sid);
    return written == SiblingWrite.refused
        ? _staleAck(deviceId, sid)
        : written;
  }

  /// Sibling [deviceId] acked [sid], which is not our current self-queue: it
  /// learned an older handoff after the newer one (they travel through
  /// different queues, which the box does not order), and would send into a
  /// queue that is retiring or gone. Its ack is forgotten, so the
  /// swap hands it the current queue — asked again now, and on every
  /// connect until it acks. The re-hand leaves only after the stale handoff
  /// was read, so it cannot be overtaken by it.
  Future<SiblingWrite> _staleAck(int deviceId, String sid) async {
    final self = _store.selfQueue;
    if (self == null || self.sid == sid || _store.siblingsUnsupported) {
      return SiblingWrite.refused;
    }
    final forgot = await _store.forgetSiblingAck(deviceId);
    if (forgot != SiblingWrite.stored) return forgot;
    E2eDiagLog.add('BOX_SIBLING_STALE_ACK', {'device': deviceId});
    _swap.handAgain();
    return SiblingWrite.stored;
  }

  @override
  ContactRecord? contactOf(int userId) =>
      _disposed ? null : _store.byUserId(userId);

  @override
  Future<void> rekeySibling(int deviceId) async {
    final self = _store.selfQueue;
    final to = siblingAddresses()[deviceId];
    final encrypt = _swap.encrypt;
    if (self == null || to == null || !_rekeyed.add(deviceId)) return;
    final handoff = E2eEnvelope.buildQueueHandoff(
      sid: self.sid,
      sealPub: self.sealPub,
    );
    final frame = _disposed || encrypt == null
        ? null
        : await encrypt(deviceId, jsonEncode(handoff), fresh: true);
    // Marked before the send: our session with it is already the fresh one,
    // so a replacing PreKey from it is an answer even if this send is lost.
    if (frame != null) _rekeyAsked[deviceId] = _now();
    final sent = frame != null && await deliver(to, frame.encode());
    E2eDiagLog.add('BOX_SIBLING_REKEYED', {'device': deviceId, 'sent': sent});
  }

  @override
  bool awaitingRekeyFrom(int deviceId) {
    final at = _rekeyAsked[deviceId];
    if (at == null) return false;
    if (_now().difference(at) <= kSiblingRekeyWindow) return true;
    _rekeyAsked.remove(deviceId);
    return false;
  }

  @override
  void rekeyAnswered(int deviceId) => _rekeyAsked.remove(deviceId);

  @override
  Future<int?> nextLocalId() => _store.allocateLocalId();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _swap.dispose();
    _rotation.dispose();
    _notifiers?.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _inbox.dispose();
    _box.dispose();
  }

  /// Subscribes every contact queue the box is not already following, then
  /// offers what the journal holds. The box keeps the set and re-signs it on
  /// every reconnect, so each queue is subscribed here once per session.
  Future<void> _receive() async {
    if (_disposed || _box.state != BoxState.ready || !_store.isOpen) return;
    final following = {for (final rid in _box.subscribed) boxB64(rid)};
    final missing = [
      for (final queue in _keys.inbound())
        if (!following.contains(boxB64(queue.rid))) queue,
    ];
    if (missing.isNotEmpty) await _box.subscribe(missing);
    if (!_disposed) await _inbox.drain();
  }

  Future<void> _ensure() async {
    if (_ensuring || _disposed || _box.state != BoxState.ready) return;
    _ensuring = true;
    try {
      final queue = await _keys.ensureRequest();
      if (_disposed || queue == null) return;
      _request = queue;
      _publish();
    } finally {
      _ensuring = false;
    }
  }

  Future<void> _ensureSelf() async {
    if (_ensuringSelf || _disposed || _box.state != BoxState.ready) return;
    _ensuringSelf = true;
    try {
      final queue = await _keys.ensureSelf();
      if (_disposed || queue == null) return;
      // A rotation that landed while this ran is followed on the next read
      // ([_currentSelf]).
      _self = queue;
      _swap.run();
    } finally {
      _ensuringSelf = false;
    }
  }

  /// A reconnect's subscribe refused the request queue or the self-queue:
  /// it is gone for good. Forgotten here; the `ready` that follows the
  /// resubscribe ensures it again, which sees the same refusal, drops the
  /// stored row and creates a replacement.
  void _onLost(BoxRefusal refusal) {
    final rid = boxB64(refusal.rid);
    if (rid == _request?.rid) _request = null;
    if (rid == _self?.rid) _self = null;
  }

  void _publish() {
    final account = _account;
    final queue = _request;
    if (_disposed || !_e2eReady || account == null || queue == null) return;
    final key = '${account.deviceId}:${queue.sid}';
    if (key == _published || key == _inFlight) return;
    _inFlight = key;
    _emit('setRequestQueue', {'sid': queue.sid, 'sealPub': queue.sealPub});
  }
}
