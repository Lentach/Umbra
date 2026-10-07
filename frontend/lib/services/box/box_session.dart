import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_envelope.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_first_contact.dart';
import 'box_friend_handoff.dart';
import 'box_friends.dart';
import 'box_inbox.dart';
import 'box_notifiers.dart';
import 'box_outbox.dart';
import 'box_push_nids.dart';
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
/// And it moves existing friendships onto the box (item 5, decision 47): it
/// hands this device's queue for each friend to that friend's devices
/// ([BoxFriendHandoff]) and, as the [BoxFriendLink], stores what the
/// messaging reader learns from a friend's handoff.
///
/// And first contact (slice (f), decisions 52–55): as the
/// [BoxFirstContactLink] it holds the records a request makes
/// ([BoxFirstContact]) and the queue our request offers.
///
/// And it registers box push (E9): with a [BoxPushSource], every contact
/// queue gets a notifier ([BoxNotifiers]) once the box is ready and the
/// store open, and again whenever the push target changes.
class BoxSession
    implements BoxOutbox, BoxSiblingLink, BoxFriendLink, BoxFirstContactLink {
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
    _nids = push == null ? null : BoxPushNids(store: store);
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
    _friends = BoxFriendHandoff(
      now: _now,
      box: box,
      store: store,
      keys: _keys,
      seal: _seal,
      queueCreated: _registerPush,
    );
    firstContact = BoxFirstContact(store: store, now: now);
  }

  @override
  late final BoxFirstContact firstContact;

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final QueueSeal _seal;
  late final BoxInbox _inbox;
  late final BoxSiblingSwap _swap;
  late final BoxSiblingRotation _rotation;
  late final BoxNotifiers? _notifiers;
  late final BoxPushNids? _nids;
  late final BoxFriendHandoff _friends;

  /// Friend devices re-keyed this session ([rekeyFriend]), as `user:device`:
  /// once each.
  final Set<String> _friendRekeyed = {};

  /// When this device started a session with a friend's device it has not
  /// read since ([friendSessionStarted], [awaitingFriendRekeyFrom]), by
  /// `user:device`.
  final Map<String, DateTime> _friendRekeyAsked = {};

  /// Called when this device first counts as on the box ([onBox]): its
  /// request queue was published. The composer notice (decision 48) reads it.
  void Function()? onBoxReady;

  /// Re-keys owed to friend devices this device had no address for, whether
  /// a fresh friends list was asked for them, and the devices one was asked
  /// for this session: once each, so a device the next list still names no
  /// address for is given up, never looped on ([rekeyFriend]).
  final Set<(int, int)> _rekeyOwed = {};
  final Set<String> _friendAddressAsked = {};
  bool _askedFriends = false;

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

  /// Called when the inbox has read everything queued so far (slice (g),
  /// E61d: one delivered receipt per drain).
  void Function()? get onReadsIdle => _inbox.onReadsIdle;

  set onReadsIdle(void Function()? idle) => _inbox.onReadsIdle = idle;

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

  /// The Signal side of the friend handoff (`MessagingProvider`).
  FriendEncrypt? get encryptForFriend => _friends.encrypt;

  set encryptForFriend(FriendEncrypt? encrypt) {
    _friends
      ..encrypt = encrypt
      ..run();
  }

  /// Friends' verified lists, for the friend handoff (`MessagingProvider`).
  FriendLiveDevices? get friendLiveDevices => _friends.liveDevices;

  set friendLiveDevices(FriendLiveDevices? lookup) {
    _friends
      ..liveDevices = lookup
      ..run();
  }

  /// This account's device list, carried on request-queue frames to
  /// friends (slice (e), decision 50; `MessagingProvider`).
  Future<Map<String, dynamic>?> Function()? get ownDeviceList =>
      _friends.ownDeviceList;

  set ownDeviceList(Future<Map<String, dynamic>?> Function()? lookup) {
    _friends.ownDeviceList = lookup;
  }

  /// The devices friends' verified lists name revoked, for the rotation
  /// (slice (e), E50e; `MessagingProvider`).
  Future<Set<int>?> Function(int userId)? get friendRevokedDevices =>
      _friends.revokedDevices;

  set friendRevokedDevices(Future<Set<int>?> Function(int userId)? lookup) {
    _friends.revokedDevices = lookup;
  }

  /// E2E is ready on this connect: the request queue may be published, a
  /// handoff encrypted and the own list read now.
  void e2eReady() {
    if (_disposed) return;
    _e2eReady = true;
    _publish();
    _swap.e2eReady();
    _rotation.run();
    _friends.e2eReady();
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

  /// `friendsList`: each friend device's request queue, where the friend
  /// handoff goes until that device hands us its own queue (item 5). A
  /// re-key that was owed for want of an address goes out once the store
  /// holds what the list wrote ([rekeyFriend]).
  void onFriendsList(Object? data) {
    if (_disposed) return;
    _friends.takeFriendsList(data);
    _askedFriends = false;
    if (_rekeyOwed.isEmpty) return;
    final owed = List.of(_rekeyOwed);
    _rekeyOwed.clear();
    unawaited(
      _store.settled.then((_) async {
        for (final (user, device) in owed) {
          await rekeyFriend(user, device);
        }
      }),
    );
  }

  /// Friend [userId]'s verified device list was dropped or moved (a device
  /// linked or revoked): its devices may have changed, so the handoff runs
  /// again — and rotates our queue away from a revoked one (E50e).
  @override
  void friendDevicesChanged(int userId) {
    if (!_disposed) _friends.friendChanged(userId);
  }

  @override
  Future<bool> sendListUpdate(
    int userId,
    int deviceId,
    Map<String, dynamic> auth,
  ) async {
    final target = _friends.targetOf(userId, deviceId);
    final encrypt = _friends.encrypt;
    if (_disposed || encrypt == null || target == null || target.viaRequest) {
      return false;
    }
    final frame = await encrypt(
      userId,
      deviceId,
      jsonEncode(E2eEnvelope.buildListUpdate(auth)),
    );
    return frame != null && await _friends.send(target, frame) is BoxOk;
  }

  @override
  Future<bool> announceOwnList(Map<String, dynamic> auth) =>
      _disposed ? Future.value(false) : _friends.announceOwnList(auth);

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
          _registerPush();
          _friends.run();
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
    if (deviceId != null) _friends.accountReady();
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
    _registerPush();
    _friends.run();
  }

  /// A queue appeared, or the box is ready: every contact queue gets its
  /// push notifier (E9), and the push worker its nid → chat table (decision
  /// 77) — the worker has no other way to name the chat a wake-up is for.
  void _registerPush() {
    _nids?.sync();
    _notifiers?.run();
  }

  /// The account socket dropped: an answer still owed will never come.
  void accountLost() {
    _account = null;
    _e2eReady = false;
    _inFlight = null;
    _retry?.cancel();
    _swap.accountLost();
    _friends.accountLost();
  }

  /// `requestQueueSet { success, error?, retryAfterMs? }`.
  void onRequestQueueSet(Object? data) {
    final sent = _inFlight;
    _inFlight = null;
    if (sent == null || data is! Map) return;
    if (data['success'] == true) {
      final first = _published == null;
      _published = sent;
      if (first) onBoxReady?.call();
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
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    final sealPub = boxB64Decode(to.sealPub, 32);
    if (_disposed || sid == null || sealPub == null) {
      return BoxSendOutcome.failed;
    }
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return BoxSendOutcome.failed;
    return switch (await _box.send(sid, blob, mode: mode)) {
      BoxOk() => BoxSendOutcome.taken,
      BoxRefused(code: BoxCode.queueFull) => BoxSendOutcome.full,
      BoxRefused() || BoxUnknown() => BoxSendOutcome.failed,
    };
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
    return frame != null &&
        await deliver(to, frame.encode()) == BoxSendOutcome.taken;
  }

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async {
    if (_disposed) return SiblingWrite.retryLater;
    final written = await _store.markSiblingAcked(deviceId, sid);
    return written == SiblingWrite.refused ? _staleAck(deviceId, sid) : written;
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
    final sent =
        frame != null &&
        await deliver(to, frame.encode()) == BoxSendOutcome.taken;
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

  @override
  bool get onBox => !_disposed && _published != null;

  @override
  Future<FriendWrite> takeFriendHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
  }) => _takeHandoff(userId, deviceId, sid: sid, sealPub: sealPub);

  @override
  Future<FriendWrite> acceptFirstContact(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
    required E2eProfile profile,
  }) => _takeHandoff(
    userId,
    deviceId,
    sid: sid,
    sealPub: sealPub,
    profile: profile,
  );

  /// Store → ack → hand-back (item 5): [userId]'s [deviceId] address, on a
  /// record already `friend`; our hand-back carries [profile] when this is
  /// the accept of a first contact (slice (f), decision 55).
  Future<FriendWrite> _takeHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
    E2eProfile? profile,
  }) async {
    if (_disposed) return FriendWrite.retryLater;
    final address = ContactOutbound(
      peerDeviceId: deviceId,
      sid: sid,
      sealPub: sealPub,
    );
    var friend = false;
    final committed = await _store.update(userId, (current) {
      if (current == null || current.state != ContactState.friend) return null;
      friend = true;
      final held = current.outbound
          .where((o) => o.peerDeviceId == deviceId)
          .firstOrNull;
      if (held?.sid == sid && held?.sealPub == sealPub) return null;
      return current.copyWith(
        outbound: [
          for (final o in current.outbound)
            if (o.peerDeviceId != deviceId) o,
          address,
        ],
      );
    });
    if (!committed) return FriendWrite.retryLater;
    if (!friend) return FriendWrite.refused;
    final acked = await _sendToFriend(
      userId,
      deviceId,
      E2eEnvelope.buildQueueHandoffAck(sid: sid),
    );
    final ours = _store.byUserId(userId)?.queues.firstOrNull;
    bool? handedBack;
    if (ours == null || !ours.ackedBy.contains(deviceId)) {
      handedBack = false;
      final ensured = await _keys.ensureInbound(userId);
      if (ensured case InboundQueueCreated(:final queue)) {
        if (ours == null) _registerPush();
        handedBack = await _sendToFriend(
          userId,
          deviceId,
          E2eEnvelope.buildQueueHandoff(
            sid: queue.sid,
            sealPub: queue.sealPub,
            profile: profile,
          ),
        );
        if (handedBack) _friends.noteHanded(userId, deviceId, queue.sid);
      }
    }
    E2eDiagLog.add('BOX_FRIEND_HANDOFF', {
      'device': deviceId,
      'acked': acked,
      'handedBack': ?handedBack,
      if (profile != null) 'accept': true,
    });
    return FriendWrite.stored;
  }

  /// Encrypts [envelope] for [userId]'s [deviceId] and sends it to where
  /// that device takes it (the queue it handed us, else its request queue);
  /// true only when the box took it.
  Future<bool> _sendToFriend(
    int userId,
    int deviceId,
    Map<String, dynamic> envelope,
  ) async {
    final encrypt = _friends.encrypt;
    final target = _friends.targetOf(userId, deviceId);
    if (_disposed || encrypt == null || target == null) return false;
    final frame = await encrypt(userId, deviceId, jsonEncode(envelope));
    return frame != null && await _friends.send(target, frame) is BoxOk;
  }

  @override
  Future<FriendWrite> friendAcked(int userId, int deviceId, String sid) async {
    if (_disposed) return FriendWrite.retryLater;
    var matched = false;
    final committed = await _store.update(userId, (current) {
      if (current == null) return null;
      final i = current.queues.indexWhere((q) => q.sid == sid);
      if (i < 0) return null;
      matched = true;
      final queue = current.queues[i];
      if (queue.ackedBy.contains(deviceId)) return null;
      return current.copyWith(
        queues: [...current.queues]..[i] = queue.withAck(deviceId),
      );
    });
    if (!committed) return FriendWrite.retryLater;
    return matched ? FriendWrite.stored : FriendWrite.refused;
  }

  @override
  Future<void> rekeyFriend(int userId, int deviceId) async {
    final key = '$userId:$deviceId';
    final encrypt = _friends.encrypt;
    if (_disposed || encrypt == null || _friendRekeyed.contains(key)) return;
    final target = _friends.targetOf(userId, deviceId);
    if (target == null) {
      // Our friends list predates that device's app update (it named no
      // request queue then): ask for a fresh one, once per device per
      // session, and re-key when it arrives ([onFriendsList]).
      if (!_friendAddressAsked.add(key)) return;
      _rekeyOwed.add((userId, deviceId));
      if (!_askedFriends) {
        _askedFriends = true;
        _emit('getFriends', null);
      }
      return;
    }
    _friendRekeyed.add(key);
    final ensured = await _keys.ensureInbound(userId);
    if (ensured is! InboundQueueCreated || _disposed) return;
    final queue = ensured.queue;
    // The fresh session counts as asked (`friendSessionStarted`, set by the
    // encrypt side): two devices that re-key each other at once read each
    // other's re-key (decision 49).
    final frame = await encrypt(
      userId,
      deviceId,
      jsonEncode(
        E2eEnvelope.buildQueueHandoff(sid: queue.sid, sealPub: queue.sealPub),
      ),
      fresh: true,
    );
    final sent = frame != null && await _friends.send(target, frame) is BoxOk;
    if (sent) _friends.noteHanded(userId, deviceId, queue.sid);
    E2eDiagLog.add('BOX_FRIEND_REKEYED', {'device': deviceId, 'sent': sent});
  }

  @override
  void friendSessionStarted(int userId, int deviceId) {
    if (!_disposed) _friendRekeyAsked['$userId:$deviceId'] = _now();
  }

  @override
  bool awaitingFriendRekeyFrom(int userId, int deviceId) {
    final key = '$userId:$deviceId';
    final at = _friendRekeyAsked[key];
    if (at == null) return false;
    if (_now().difference(at) <= kFriendRekeyWindow) return true;
    _friendRekeyAsked.remove(key);
    return false;
  }

  @override
  void friendRekeyAnswered(int userId, int deviceId) =>
      _friendRekeyAsked.remove('$userId:$deviceId');

  @override
  void friendHeard(int userId, int deviceId) {
    if (!_disposed) _friends.friendHeard(userId, deviceId);
  }

  @override
  void handOffTo(int userId) {
    if (!_disposed) _friends.friendChanged(userId);
  }

  @override
  Future<ContactQueue?> firstContactQueue(int userId) async {
    if (_disposed) return null;
    switch (await _keys.ensureInbound(userId)) {
      case InboundQueueCreated(:final queue):
        // A new contact queue gets its push notifier (E9) like any other.
        _registerPush();
        return queue;
      case InboundQueueNotCreated():
      case InboundQueueNotStored():
        return null;
    }
  }

  @override
  void firstContactFriend(int userId) {
    if (!_disposed) _friends.friendChanged(userId);
  }

  @override
  Future<void> retireFirstContact(int userId) async {
    if (_disposed) return;
    var deleted = true;
    for (final queue in [...?_store.byUserId(userId)?.queues]) {
      deleted = await _keys.retireInbound(userId, queue) && deleted;
    }
    // A queue the box did not delete keeps its record — the record is the
    // only holder of that queue's auth key — hidden, and the next expiry
    // pass deletes it.
    if (deleted) {
      await firstContact.forget([userId]);
    } else {
      await firstContact.drop([userId]);
    }
  }

  @override
  Future<void> endBoxFriendship(int userId, {required bool block}) async {
    if (_disposed) return;
    // Each queue the box confirmed deleted leaves the record
    // (`retireInbound`); one it did not stays, since the record holds its
    // only auth key, and the next expiry pass deletes it (review).
    for (final queue in [...?_store.byUserId(userId)?.queues]) {
      await _keys.retireInbound(userId, queue);
    }
    if (!block && (_store.byUserId(userId)?.queues.isEmpty ?? true)) {
      if (_store.byUserId(userId)?.boxOrigin != null) {
        await _store.remove(userId);
      }
      return;
    }
    await _store.update(userId, (current) {
      final origin = current?.boxOrigin;
      if (current == null || origin == null) return null;
      // Nothing the friendship held stays but an undeleted queue: no
      // address, no chat, no request kept. The origin mark keeps the record
      // out of every server list's sweep (E15g); an unfriend that left a
      // queue is `former` until the queue is gone.
      return ContactRecord(
        userId: userId,
        username: current.username,
        tag: current.tag,
        avatarUrl: current.avatarUrl,
        state: block ? ContactState.blocked : ContactState.former,
        queues: current.queues,
        boxOrigin: ContactBoxOrigin(at: origin.at),
      );
    });
  }

  /// Called when a box-made record changed outside the messaging reader —
  /// a pending request expired (E15i) — so the lists and chats re-read the
  /// store. Wired by `ConnectionProvider`.
  void Function()? onFirstContactsChanged;

  DateTime? _expiryRanAt;

  /// E15i, whenever the box and the store are ready and at most once a day
  /// (a long-lived tab outlives a request's lifetime): every pending box
  /// request older than [BoxFirstContact.lifetime] retires.
  Future<void> _expireFirstContacts() async {
    final last = _expiryRanAt;
    if (last != null && _now().difference(last) < const Duration(days: 1)) {
      return;
    }
    _expiryRanAt = _now();
    final expired = await firstContact.expired();
    for (final userId in expired) {
      if (_disposed) return;
      await retireFirstContact(userId);
    }
    if (expired.isNotEmpty && !_disposed) onFirstContactsChanged?.call();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _swap.dispose();
    _rotation.dispose();
    _friends.dispose();
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
    if (!_disposed) await _expireFirstContacts();
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
