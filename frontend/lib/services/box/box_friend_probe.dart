import 'dart:async';

import '../../utils/e2e_diag_log.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_frame.dart';
import 'box_friend_gate.dart';
import 'box_friend_handoff.dart';
import 'box_wire.dart';
import 'queue_keys.dart';

/// Seals THE probe: the one `queue_handoff` a [ProbePermit] stands for, on
/// the session that exists under the pinned identity (the messaging side
/// implements it, so the box layer stays crypto-free). Null when it cannot
/// now (not ready, device not live, session identity is not the permit's).
typedef FriendProbeEncrypt = Future<BoxFrame?> Function(ProbePermit permit);

/// What asked for a probe: a level check made at one of three moments.
enum ProbeTrigger {
  /// The friend's pinned identity moved (both movers).
  move,

  /// This account connected, or the box, E2E or the journal became ready.
  connect,

  /// A frame authenticated under the pinned identity arrived from the friend.
  heard,
}

/// Re-tag on PROOF (key-change invariant, item 9 and its amendment). A friend
/// whose identity moved but who KEPT its queues never announces anything, so
/// the address held for it stays stale and the messages wait. While an
/// address is stale and unproven, ONE control frame with no user content goes
/// to it: the handoff of a fresh queue Z, minted ONCE per (friend device,
/// stale sid) and persisted on the record ([QueueKeys.ensureProbe]), sealed
/// under the pinned identity. A `queue_handoff_ack` naming Z, authenticated
/// under that identity (`BoxSession.friendAcked`), proves the holder of the
/// address reads under the new key and re-tags it. A dead queue never acks:
/// nothing else happens.
///
/// Level-triggered, never timed: [run] is asked at [ProbeTrigger]s and sends
/// at most once per trigger per session and stale address (a `move` clears
/// the friend's marks, a new connect clears the [ProbeTrigger.connect] ones).
/// No lookup is ever made for it, and the gate's probe clauses
/// ([FriendGate.probeOpen]) hold: no calm hold pending, the journal judged,
/// the permit's identity the pinned one.
class BoxFriendProbe {
  BoxFriendProbe({
    required BoxClient box,
    required ContactStore store,
    required QueueKeys keys,
    required BoxFriendHandoff friends,
    required void Function() queueCreated,
  }) : _box = box,
       _store = store,
       _keys = keys,
       _friends = friends,
       _queueCreated = queueCreated;

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final BoxFriendHandoff _friends;
  final void Function() _queueCreated;

  /// The Signal side of the probe (`MessagingProvider.encryptProbeForFriend`).
  FriendProbeEncrypt? encrypt;

  /// `friend:device:sid:trigger` already sent this session.
  final Set<String> _sent = {};

  /// Friends a run is in flight for, and the triggers asked meanwhile.
  final Map<int, Set<ProbeTrigger>> _queued = {};

  bool _disposed = false;

  void dispose() => _disposed = true;

  /// A new account connect: the connect trigger is due again.
  void connected() =>
      _sent.removeWhere((k) => k.endsWith(':${ProbeTrigger.connect.name}'));

  /// [friend]'s identity moved: every trigger is due again for it.
  void moved(int friend) => _sent.removeWhere((k) => k.startsWith('$friend:'));

  /// Asks the probe of every friend ([ProbeTrigger.connect]).
  void runAll(ProbeTrigger trigger) {
    if (_disposed || !_store.isOpen) return;
    for (final record in _store.all) {
      if (record.state == ContactState.friend) {
        unawaited(run(record.userId, trigger));
      }
    }
  }

  /// One level check for [friend]: every stale address of it that is still
  /// unproven gets THE probe, unless that was already sent for [trigger].
  Future<void> run(int friend, ProbeTrigger trigger) async {
    final queued = _queued[friend];
    if (queued != null) {
      queued.add(trigger);
      return;
    }
    _queued[friend] = {};
    try {
      var next = trigger;
      while (true) {
        await _check(friend, next);
        final more = _queued[friend];
        if (more == null || more.isEmpty) return;
        next = more.first;
        more.remove(next);
      }
    } finally {
      _queued.remove(friend);
    }
  }

  bool _ready() =>
      !_disposed &&
      encrypt != null &&
      _friends.gate != null &&
      _box.state == BoxState.ready &&
      _store.isOpen;

  Future<void> _check(int friend, ProbeTrigger trigger) async {
    final gate = _friends.gate;
    if (!_ready() || gate == null) return;
    final record = _store.byUserId(friend);
    if (record == null || record.state != ContactState.friend) return;
    for (final stale in [...record.outbound]) {
      // An untagged address is "not yet labelled", never probed.
      if (!gate.isForeign(friend, stale)) continue;
      final key = '$friend:${stale.peerDeviceId}:${stale.sid}:${trigger.name}';
      if (_sent.contains(key) || !gate.probeOpen(friend, stale)) continue;
      if (await _send(friend, stale, gate)) {
        _sent.add(key);
        E2eDiagLog.add('BOX_FRIEND_PROBE_SENT', {
          'device': stale.peerDeviceId,
          'trigger': trigger.name,
        });
      }
      if (!_ready()) return;
    }
  }

  /// Mints (once) or finds Z, follows it, then writes its handoff to
  /// [stale]; true only when the box took the frame.
  Future<bool> _send(
    int friend,
    ContactOutbound stale,
    FriendGate gate,
  ) async {
    final seal = encrypt;
    if (seal == null) return false;
    // The lead the friend is handed besides Z must exist: Z never leads.
    if (await _keys.ensureInbound(friend) is! InboundQueueCreated) return false;
    if (!gate.probeOpen(friend, stale) || _disposed) return false;
    final z = await _keys.ensureProbe(
      friend,
      device: stale.peerDeviceId,
      staleSid: stale.sid,
    );
    final auth = z == null ? null : QueueKeys.authOf(z);
    if (z == null || auth == null || _disposed) return false;
    // A queue the box does not follow is never handed: what the device writes
    // there would not be read before the next connect.
    if (!_box.subscribed.any((r) => boxB64(r) == z.rid)) {
      if (await _box.subscribe([auth]) is! BoxOk) return false;
      _queueCreated();
    }
    final permit = gate.probePermitFor(
      friend,
      stale: stale,
      handoffSid: z.sid,
      handoffSealPub: z.sealPub,
    );
    if (permit == null) return false;
    final frame = await seal(permit);
    if (frame == null) return false;
    return await _friends.sendProbe(permit, stale, frame) is BoxOk;
  }
}
