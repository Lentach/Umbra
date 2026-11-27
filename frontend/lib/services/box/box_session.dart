import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_envelope.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_first_contact.dart';
import 'box_friend_gate.dart';
import 'box_friend_handoff.dart';
import 'box_friend_probe.dart';
import 'box_friends.dart';
import 'box_inbox.dart';
import 'box_notifiers.dart';
import 'box_outbox.dart';
import 'box_push_nids.dart';
import 'box_sibling_rotation.dart';
import 'box_sibling_swap.dart';
import 'box_siblings.dart';
import 'box_signer.dart' show BoxAuthKey;
import 'box_wire.dart';
import 'queue_keys.dart';
import 'queue_seal.dart';

part 'box_session_connection.dart';
part 'box_session_deliver.dart';
part 'box_session_queues.dart';
part 'box_session_retire.dart';
part 'box_session_wiring.dart';

/// How long a request-queue publish the server failed waits before it is
/// sent again. The event is throttled at 30 / 15 min.
const Duration kRequestQueueRetry = Duration(minutes: 1);

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
/// ready, a rate-limited one after `retryAfterMs`, one the server failed
/// after [kRequestQueueRetry].
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
    implements
        BoxOutbox,
        BoxFriendGateOutbox,
        BoxSiblingLink,
        BoxFriendLink,
        BoxFirstContactLink {
  BoxSession({
    required BoxClient box,
    required ContactStore store,
    required void Function(String event, Object? data) emit,
    QueueSeal? seal,
    BoxPushSource? push,
    DateTime Function()? now,
    String? Function(int peerId)? anchorOf,
  }) : _box = box,
       _store = store,
       _keys = QueueKeys(box: box, store: store),
       _seal = seal ?? QueueSeal(),
       _emit = emit,
       _now = now ?? DateTime.now,
       _anchorOf = anchorOf {
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
    _gate = FriendGate(
      addressesOf: _friendAddresses,
      anchorOf: anchorOf,
      journalJudged: () => _journalJudged,
      labelled: () => _labelled,
    );
    _friends.gate = _gate;
    _probe = BoxFriendProbe(
      box: box,
      store: store,
      keys: _keys,
      friends: _friends,
      queueCreated: _registerPush,
    );
    _inbox
      ..judgeable = (() => _e2eReady && _inbox.consumer != null)
      ..onJudged = (() {
        final first = !_journalJudged;
        _journalJudged = true;
        if (first) {
          onJournalJudged?.call();
          // The last clause of the probe's gate opened: level check.
          _probe.runAll(ProbeTrigger.connect);
        }
      });
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
  late final BoxFriendProbe _probe;
  late final BoxFriendHandoff _friends;
  late final FriendGate _gate;

  /// The journal was judged once this session: the end of the first
  /// [BoxInbox.drain] after E2E ready with the reader wired (the friend
  /// write gate's start-up clause; an empty journal counts).
  bool _journalJudged = false;

  /// The one labelling of untagged addresses ([ContactStore.
  /// tagUntaggedAddresses]) completed on an OPEN store in this process. Until
  /// then the gate is closed for messages and nothing is probed: a missing
  /// tag is "not yet labelled", a different state from a foreign tag.
  bool _labelled = false;
  Future<void>? _labelling;

  /// What the friend write gate calls a friend's address: the stored one per
  /// device and the request addresses already served.
  Iterable<ContactOutbound> _friendAddresses(int friend) => _disposed
      ? const []
      : [
          ...?_store.byUserId(friend)?.outbound,
          ..._friends.requestAddresses(friend),
        ];

  /// The friend whose address [sid] is, or null: a sibling or own self-queue
  /// is no friend address, and its writes are never gated.
  int? _friendOfSid(String sid) {
    for (final peer in _store.all) {
      if (peer.outbound.any((o) => o.sid == sid) ||
          (peer.boxOrigin?.addresses.any((a) => a.sid == sid) ?? false) ||
          _friends.requestAddresses(peer.userId).any((a) => a.sid == sid)) {
        return peer.userId;
      }
    }
    return null;
  }

  /// Whether [sid] is positively OUR lane: our own self queue, our own
  /// request queue or a known sibling's self queue. The only targets a write
  /// or an upload may reach with no permit (decision item 13); every other
  /// sid with no permit is refused.
  bool _isOwnLaneSid(String sid) =>
      _store.selfQueue?.sid == sid ||
      _store.requestQueue?.sid == sid ||
      _store.siblings.any((s) => s.sid == sid);

  /// Whether a calm hold is pending for a friend (`MessagingProvider`);
  /// only a calm hold closes the gate on its own.
  bool Function(int friend)? get calmHeld => _gate.calmHeld;

  set calmHeld(bool Function(int friend)? check) => _gate.calmHeld = check;

  @override
  FriendPermit? permitFor(
    int friend, {
    Iterable<ContactOutbound> to = const [],
    bool goodbye = false,
  }) => _disposed ? null : _gate.permitFor(friend, to: to, goodbye: goodbye);

  /// The pinned account identity (base64) of a friend, answered without an
  /// await from the Signal store's trusted memo; null when none is pinned
  /// (or no mirror is wired). What a handoff must have been learned under
  /// ([_takeHandoff]) and what the migration tags untagged addresses with
  /// ([ContactStore.tagUntaggedAddresses]).
  final String? Function(int peerId)? _anchorOf;

  /// Friend devices re-keyed this session ([rekeyFriend]), as `user:device`:
  /// once each, whether or not the re-key left (decision 70: a forged frame
  /// times one bundle fetch per friend device per session). Only a re-key
  /// that had no queue to hand, so fetched nothing, is not kept.
  final Set<String> _friendRekeyed = {};

  /// When this device started a session with a friend's device it has not
  /// read since ([friendSessionStarted], [awaitingFriendRekeyFrom]), by
  /// `user:device`.
  final Map<String, DateTime> _friendRekeyAsked = {};

  /// Called when this device first counts as on the box ([onBox]): its
  /// request queue was published. The composer notice (decision 48) reads it.
  void Function()? onBoxReady;

  /// Called when the journal was judged for the first time this session (the
  /// last clause of the friend write gate): what the gate refused may go now.
  void Function()? onJournalJudged;

  /// Called when the labelling of untagged addresses completed for the first
  /// time in this process ([_label]): the gate it kept closed may be open.
  void Function()? onAddressesLabelled;

  /// Friend devices whose request queue was asked for by handle this session
  /// ([rekeyFriend]), as `user:device`: once each, so a device the lookup
  /// names no address for is given up, never looped on.
  final Set<String> _friendAddressAsked = {};

  /// Siblings re-keyed this account connect ([rekeySibling]): once each; a
  /// re-key that did not leave over the self-queue is not kept.
  final Set<int> _rekeyed = {};

  /// What each friend device last said about relaying (`rl`, decision 101
  /// A, E101b) this session: a handoff stored after the frame keeps it
  /// ([friendRelays]).
  final Map<(int, int), bool> _friendRelays = {};

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

  /// [start] ran: the box is followed. A device that cannot do E2E duty
  /// under its session — the link gate — never starts it (issue #205).
  bool _started = false;

  /// This device was revoked ([retireRevokedDevice]): no queue is followed,
  /// made or registered again.
  bool _revoked = false;

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
    final permit = _friends.gate?.permitFor(userId, to: [target.to]);
    if (permit == null) return false;
    final frame = await encrypt(
      userId,
      deviceId,
      jsonEncode(E2eEnvelope.buildListUpdate(auth)),
      permit: permit,
    );
    return frame != null &&
        await _friends.send(target, frame, permit: permit) is BoxOk;
  }

  @override
  Future<bool> announceOwnList(Map<String, dynamic> auth) =>
      _disposed ? Future.value(false) : _friends.announceOwnList(auth);

  /// How long [retireRevokedDevice] waits by default before recording what
  /// is left as owed (`boxgone_v1`).
  static const Duration kRetireWait = Duration(seconds: 15);

  /// The server revoked this device (`deviceRevoked`, issue #205), or the
  /// install is about to become a new device (issue #208, a fresh device
  /// life): nobody can read what reaches its queues any more, and while they
  /// exist a friend holding an old list keeps filling them. Deletes every
  /// queue this device holds — it alone holds their keys; no other device or
  /// the server may (decision 29) — taking and subscribing none, then closes
  /// the box. Best effort: whatever is not confirmed deleted within [wait]
  /// of the call — box reached or not, a delete in flight included — is
  /// recorded as owed in the store (`boxgone_v1`, issue #208), which the
  /// install's next ready box deletes. Deletes nothing when [proceed]
  /// answers false (another tab of this install adopted a newer session and
  /// shares these queues). The diag keeps its #205 name,
  /// `BOX_REVOKED_QUEUES_RETIRED`.
  Future<void> retireRevokedDevice({
    required Future<bool> proceed,
    Duration wait = kRetireWait,
  }) async {
    if (_disposed || _revoked) return;
    _revoked = true;
    _retry?.cancel();
    final deadline = _now().add(wait);
    // Nothing more is taken, and a (re)connection re-signs no queue: what
    // reaches them now goes with them. Issue #206: the subscribes are held
    // until a session confirmation this device will never get; with the set
    // empty, releasing them (and no longer holding on a lost connection)
    // subscribes nothing and lets a connection turn ready for the deletes.
    _inbox.dispose();
    _box
      ..forgetAll()
      ..holdOnLoss = false
      ..releaseSubscribes();
    // The store this device's queue keys live in. The logout that follows
    // may let another account open the same store object before the delete
    // is done (a sign-in within [wait]): its queues are never touched.
    final owner = _store.userId;
    bool keepGoing() =>
        !_disposed &&
        _store.isOpen &&
        _store.userId == owner &&
        _now().isBefore(deadline);
    try {
      if (owner == null) return;
      if (!await proceed) {
        E2eDiagLog.add('BOX_REVOKED_QUEUES_KEPT', const {});
        return;
      }
      if (_box.state != BoxState.ready) {
        final ready = _box.states.firstWhere((s) => s == BoxState.ready);
        _box.connect();
        try {
          await ready.timeout(deadline.difference(_now()));
        } on TimeoutException {
          // Nothing can be deleted now: every queue is owed.
        }
        // `ready` completes from inside the box's synchronous state
        // dispatch; closing the box there throws. Leave it first.
        await Future<void>.delayed(Duration.zero);
      }
      final reached = _box.state == BoxState.ready;
      final retired = await _retireQueues(
        () => reached && keepGoing(),
        deadline: deadline,
      );
      // Issue #208: what the box did not confirm is deleted by the next
      // life's box, never left to the reaper — unless another account took
      // the store meanwhile.
      if (_store.isOpen && _store.userId == owner) {
        await _oweDeletes(retired.owed);
      }
      E2eDiagLog.add('BOX_REVOKED_QUEUES_RETIRED', {
        'held': retired.held,
        'owed': retired.owed.length,
      });
    } on Object catch (e) {
      E2eDiagLog.add('BOX_REVOKED_RETIRE_FAILED', {
        'error': e.runtimeType.toString(),
      });
    } finally {
      dispose();
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
            // A sibling's self-queue is no friend address: no identity.
            idk: null,
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
  }) => deliverFriend(to, body, mode: mode);

  @override
  Future<BoxSendOutcome> deliverFriend(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
    FriendPermit? permit,
  }) async => switch (await _sealAndSend(to, body, mode, permit: permit)) {
    BoxOk() => BoxSendOutcome.taken,
    BoxRefused(code: BoxCode.queueFull) => BoxSendOutcome.full,
    BoxRefused() || BoxUnknown() || null => BoxSendOutcome.failed,
  };

  @override
  Future<BoxRequestSend> deliverRequest(
    ContactOutbound to,
    Uint8List body,
  ) async => switch (await _sealAndSend(to, body, null, request: true)) {
    BoxOk() => BoxRequestSend.taken,
    BoxRefused(code: BoxCode.quotaExceeded) => BoxRequestSend.busy,
    BoxRefused() || BoxUnknown() || null => BoxRequestSend.failed,
  };

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) => uploadMediaFriend(to, framed);

  @override
  Future<BoxResult<BoxMediaRef>> uploadMediaFriend(
    ContactOutbound to,
    Uint8List framed, {
    FriendPermit? permit,
  }) async {
    // Refused here, never thrown: the client throws on both, and the send
    // path fails the row on any refusal (E17b).
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    if (sid == null) return const BoxRefused(BoxCode.invalidPayload);
    if (!kBoxMediaLadder.contains(framed.length)) {
      return const BoxRefused(BoxCode.badSize);
    }
    // Friend lane: one that carries a permit, or targets a friend's address,
    // is a friend write (the address it was sealed for may be gone). With no
    // permit the target must positively be OUR lane (own self queue, own
    // request queue, a known sibling); any other sid is refused. No await
    // sits between this check and the upload.
    final friend = permit != null || _friendOfSid(to.sid) != null;
    final refused = friend
        ? _gate.refusalOf(permit, to.sid) != null
        : !_isOwnLaneSid(to.sid);
    if (refused) {
      if (!friend) {
        E2eDiagLog.add('BOX_FRIEND_WRITE_REFUSED', {
          'why': 'no_permit_unknown_sid',
        });
      }
      return const BoxRefused(BoxCode.invalidPayload);
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
  Future<BoxResult<void>> deleteMedia(Uint8List id, Uint8List secret) async {
    if (id.length != kBoxMediaIdBytes ||
        secret.length != kBoxMediaDeleteSecretBytes) {
      return const BoxRefused(BoxCode.invalidPayload);
    }
    return _box.deleteMedia(id, secret);
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
      idk: null,
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

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async {
    if (_disposed) return SiblingWrite.retryLater;
    final written = await _store.markSiblingAcked(deviceId, sid);
    return written == SiblingWrite.refused ? _staleAck(deviceId, sid) : written;
  }

  @override
  ContactRecord? contactOf(int userId) =>
      _disposed ? null : _store.byUserId(userId);

  @override
  Future<void> rekeySibling(int deviceId) async {
    final self = _store.selfQueue;
    final to = siblingAddresses()[deviceId];
    final encrypt = _swap.encrypt;
    if (self == null || !_rekeyed.add(deviceId)) return;
    if (to == null) {
      // No self-queue address for it yet (crossing first sessions): the
      // re-key goes through its request queue instead, or neither side
      // could ever answer the other's refused handoff.
      final route = await _swap.rekeyViaRequest(deviceId);
      if (route == SiblingRekeyRoute.sent) _rekeyAsked[deviceId] = _now();
      // Owed stays latched: the answer that names the address hands off.
      if (route == SiblingRekeyRoute.failed) _rekeyed.remove(deviceId);
      E2eDiagLog.add('BOX_SIBLING_REKEYED', {
        'device': deviceId,
        'sent': route == SiblingRekeyRoute.sent,
        'via': 'request',
      });
      return;
    }
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
    // A re-key that did not leave is owed still: the next loss makes it
    // again.
    if (!sent) _rekeyed.remove(deviceId);
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
    required String? learnedUnder,
  }) => _takeHandoff(
    userId,
    deviceId,
    sid: sid,
    sealPub: sealPub,
    learnedUnder: learnedUnder,
  );

  @override
  Future<FriendWrite> acceptFirstContact(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
    required E2eProfile profile,
    required String? learnedUnder,
  }) => _takeHandoff(
    userId,
    deviceId,
    sid: sid,
    sealPub: sealPub,
    learnedUnder: learnedUnder,
    profile: profile,
  );

  @override
  Future<FriendWrite> friendAcked(
    int userId,
    int deviceId,
    String sid, {
    required String? learnedUnder,
  }) async {
    if (_disposed) return FriendWrite.retryLater;
    var matched = false;
    var proven = false;
    var tookLead = false;
    final anchor = _anchorOf?.call(userId);
    final committed = await _store.update(userId, (current) {
      if (current == null) return null;
      final i = current.queues.indexWhere((q) => q.sid == sid);
      if (i < 0) return null;
      matched = true;
      final queue = current.queues[i];
      var next = current;
      final staleSid = queue.probeSid;
      if (staleSid == null) {
        tookLead = true;
      } else if (queue.retiredAt == null &&
          queue.probeDevice == deviceId &&
          anchor != null &&
          learnedUnder == anchor) {
        // PROOF: the holder of the stale address read the probe and answered
        // under the pinned identity, so it reads under the new key.
        final held = current.outbound
            .where((o) => o.peerDeviceId == deviceId && o.sid == staleSid)
            .firstOrNull;
        if (held != null && held.idk != anchor) {
          proven = true;
          next = next.copyWith(
            outbound: [
              for (final o in current.outbound)
                if (identical(o, held)) o.copyWith(idk: anchor) else o,
            ],
          );
        }
      }
      if (!queue.ackedBy.contains(deviceId)) {
        next = next.copyWith(
          queues: [...next.queues]..[i] = queue.withAck(deviceId),
        );
      }
      return identical(next, current) ? null : next;
    });
    if (!committed) return FriendWrite.retryLater;
    if (proven) {
      E2eDiagLog.add('BOX_FRIEND_PROBE_PROVEN', {'device': deviceId});
      // The address is current now: our lead is handed to it by the pass.
      _friends.friendChanged(userId);
    }
    // The device took our own queue AND its address is current: what it
    // wrote to its probe queue Z is all that will ever arrive there, so Z
    // stops being handed and goes with the box TTL (until then still read).
    // While its address is still stale Z is kept: it is the ONE probe.
    final held = _store
        .byUserId(userId)
        ?.outbound
        .where((o) => o.peerDeviceId == deviceId)
        .firstOrNull;
    if (tookLead && (held == null || !_gate.isStale(userId, held))) {
      await _keys.softRetireProbes(userId, deviceId, now: _now());
    }
    return matched ? FriendWrite.stored : FriendWrite.refused;
  }

  @override
  void friendAuthenticated(int userId) {
    if (!_disposed) unawaited(_probe.run(userId, ProbeTrigger.heard));
  }

  @override
  Future<void> rekeyFriend(int userId, int deviceId) async {
    final key = '$userId:$deviceId';
    final encrypt = _friends.encrypt;
    if (_disposed || encrypt == null || _friendRekeyed.contains(key)) return;
    var target = _friends.targetOf(userId, deviceId);
    if (target == null) {
      // No address held for that device (it published a request queue after
      // our last lookup, or this process never looked): ask by handle, once
      // per device per session (E114d), and re-key from what it names. None
      // named: given up for the session, never looped on.
      if (!_friendAddressAsked.add(key)) return;
      // A device not ready to ask yet spent nothing: left to the next call.
      if (!await _friends.lookupAddresses(userId)) {
        _friendAddressAsked.remove(key);
      }
      if (_disposed) return;
      target = _friends.targetOf(userId, deviceId);
      if (target == null) return;
    }
    // The gate is checked BEFORE the once-per-session mark: a closed gate
    // gives the re-key up for now, not for the session.
    if (_friends.gate?.permitFor(userId, to: [target.to]) == null) return;
    _friendRekeyed.add(key);
    final ensured = await _keys.ensureInbound(userId);
    if (ensured is! InboundQueueCreated || _disposed) {
      // No queue to hand, and no bundle was fetched yet (decision 70's
      // bound is intact): the next loss asks again.
      _friendRekeyed.remove(key);
      return;
    }
    final queue = ensured.queue;
    // The fresh session counts as asked (`friendSessionStarted`, set by the
    // encrypt side): two devices that re-key each other at once read each
    // other's re-key (decision 49).
    final permit = _friends.gate?.permitFor(userId, to: [target.to]);
    if (permit == null) {
      _friendRekeyed.remove(key);
      return;
    }
    final frame = await encrypt(
      userId,
      deviceId,
      jsonEncode(
        E2eEnvelope.buildQueueHandoff(sid: queue.sid, sealPub: queue.sealPub),
      ),
      fresh: true,
      permit: permit,
    );
    final sent =
        frame != null &&
        await _friends.send(target, frame, permit: permit) is BoxOk;
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
  Future<void> friendRelays(
    int userId,
    int deviceId, {
    required bool relays,
  }) async {
    if (_disposed) return;
    _friendRelays[(userId, deviceId)] = relays;
    final held = _store
        .byUserId(userId)
        ?.outbound
        .where((o) => o.peerDeviceId == deviceId)
        .firstOrNull;
    if (held == null || held.relays == relays) return;
    await _store.update(userId, (current) {
      if (current == null || current.state != ContactState.friend) return null;
      final now = current.outbound
          .where((o) => o.peerDeviceId == deviceId)
          .firstOrNull;
      if (now == null || now.relays == relays) return null;
      return current.copyWith(
        outbound: [
          for (final o in current.outbound)
            if (o.peerDeviceId != deviceId)
              o
            else
              o.copyWith(relays: relays),
        ],
      );
    });
  }

  @override
  void handOffTo(int userId) {
    if (!_disposed) _friends.friendChanged(userId);
  }

  /// Friend [friend]'s pinned identity moved (the acknowledge and the stale
  /// anchor replacement both end here): our handoff to that friend is due
  /// again ([BoxFriendHandoff.anchorMoved]).
  Future<void> anchorMoved(int friend) async {
    if (_disposed) return;
    _probe.moved(friend);
    await _friends.anchorMoved(friend);
    // Level trigger: the address held for a device is stale now and unproven.
    unawaited(_probe.run(friend, ProbeTrigger.move));
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
      if (_store.byUserId(userId) != null) await _store.remove(userId);
      return;
    }
    await _store.update(userId, (current) {
      if (current == null) return null;
      final origin = current.boxOrigin;
      // Nothing the friendship held stays but an undeleted queue: no
      // address, no chat, no request kept. The origin mark keeps a box-made
      // record out of every server list's sweep (E15g); a friendship from
      // before the box has none (the server lists its block), and a queue
      // left on it keeps it out of the sweep (`onBoxRoute`). An unfriend
      // that left a queue is `former` until the queue is gone.
      return ContactRecord(
        userId: userId,
        username: current.username,
        tag: current.tag,
        avatarUrl: current.avatarUrl,
        avatar: current.avatar,
        state: block ? ContactState.blocked : ContactState.former,
        queues: current.queues,
        boxOrigin: origin == null ? null : ContactBoxOrigin(at: origin.at),
      );
    });
  }

  @override
  void takeServedAddresses(int userId, List<ContactOutbound> addresses) {
    if (!_disposed) _friends.takeServedAddresses(userId, addresses);
  }

  @override
  Future<void> retireAccountQueues() async {
    if (_disposed) return;
    // Best effort (decision 113, E114i): a queue the box does not confirm
    // deleted stays for its reaper, and the account is going either way.
    await _retireQueues(() => !_disposed);
  }

  bool _deletingOwed = false;

  /// Called when a box-made record changed outside the messaging reader —
  /// a pending request expired (E15i) — so the lists and chats re-read the
  /// store. Wired by `ConnectionProvider`.
  void Function()? onFirstContactsChanged;

  DateTime? _expiryRanAt;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _swap.dispose();
    _rotation.dispose();
    _friends.dispose();
    _probe.dispose();
    _notifiers?.dispose();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _inbox.dispose();
    _box.dispose();
  }
}
