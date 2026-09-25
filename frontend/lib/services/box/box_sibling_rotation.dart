import 'dart:async';

import '../../utils/e2e_diag_log.dart';
import '../../utils/e2e_envelope.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_siblings.dart';
import 'box_wire.dart';
import 'queue_keys.dart';

/// Keeps this device's SELF-queue out of the hands of a device the account
/// revoked (metadata-privacy PR3.1 sibling queues part B, owner decision 27,
/// E6/E7). The own VERIFIED list is the only authority ([liveDevices]).
///
/// Each [run], once the box is ready and the store open:
///  * a sibling entry whose device the list no longer names live is gone
///    (E7). Every device that may hold our self sid has an entry — the swap
///    notes one before its first handoff — so when one goes and a
///    self-queue exists, the self-queue ROTATES (E6): a new queue replaces
///    it in one store write, the old one starts retiring (still subscribed
///    and read), and the new address is handed into every remaining
///    sibling's self-queue; the swap also hands it through the request
///    queues on its next ask, since no sibling has acknowledged it yet;
///  * a retiring queue is deleted from the box once the box TTL has passed
///    since the rotation — never earlier: a sibling may still send into it
///    (a copy built before it learned the new address, a second tab working
///    from an older row), and a `send` to a deleted sid is answered ok (the
///    box has no oracle), so a copy sent there after the delete would be
///    lost without a trace. What the revoked device sends into it meanwhile
///    is finished unread.
///
/// Nothing happens while this device is not live in its own list (it is the
/// revoked one). Idempotent: a run that finds nothing to do does nothing,
/// and a rotation that failed half-way leaves the old self-queue current,
/// so the next run tries again. A rotation another tab of this device made
/// first is refused here; the session follows it on its next read of the
/// self-queue (`BoxSession._currentSelf`).
class BoxSiblingRotation {
  BoxSiblingRotation({
    required BoxClient box,
    required ContactStore store,
    required QueueKeys keys,
    required void Function(ContactQueue next) rotated,
    required Future<bool> Function(
      ContactOutbound sibling,
      Map<String, dynamic> envelope,
    )
    sendToSibling,
    DateTime Function()? now,
  }) : _box = box,
       _store = store,
       _keys = keys,
       _rotated = rotated,
       _sendToSibling = sendToSibling,
       _now = now ?? DateTime.now;

  final BoxClient _box;
  final ContactStore _store;
  final QueueKeys _keys;
  final void Function(ContactQueue next) _rotated;
  final Future<bool> Function(ContactOutbound, Map<String, dynamic>)
  _sendToSibling;
  final DateTime Function() _now;

  /// The own verified list (`MessagingProvider`); nothing is pruned or
  /// rotated until it is wired.
  OwnLiveDevices? liveDevices;

  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// Checks now, or right after a check already running.
  void run() {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    unawaited(_loop());
  }

  void dispose() => _disposed = true;

  Future<void> _loop() async {
    _running = true;
    try {
      do {
        _again = false;
        await _check();
      } while (_again && !_disposed);
    } on Object catch (e) {
      E2ePersistentDiag.record('BOX_SIBLING_ROTATION_FAILED', {
        'error': e.runtimeType.toString(),
      });
    } finally {
      _running = false;
    }
  }

  bool get _usable =>
      !_disposed && _box.state == BoxState.ready && _store.isOpen;

  Future<void> _check() async {
    if (!_usable) return;
    final lookup = liveDevices;
    final own = lookup == null ? null : await lookup();
    if (own != null && own.live.contains(own.self) && _usable) {
      final gone = [
        for (final s in _store.siblings)
          if (!own.live.contains(s.deviceId)) s.deviceId,
      ];
      if (gone.isNotEmpty) await _dropGone(gone, own.live);
    }
    if (_usable) await _retire();
  }

  Future<void> _dropGone(List<int> gone, Set<int> live) async {
    final current = _store.selfQueue;
    if (current == null) {
      // No self-queue to protect: the next one is minted fresh anyway.
      await _store.pruneSiblings(live);
      return;
    }
    final next = await _keys.rotateSelf(current, live: live, now: _now());
    if (_disposed || next == null) return;
    E2eDiagLog.add('BOX_SELF_QUEUE_ROTATED', {'gone': gone});
    _rotated(next);
    final handoff = E2eEnvelope.buildQueueHandoff(
      sid: next.sid,
      sealPub: next.sealPub,
    );
    for (final s in _store.siblings) {
      final (sid, sealPub) = (s.sid, s.sealPub);
      if (_disposed) return;
      if (sid == null || sealPub == null) continue;
      await _sendToSibling(
        ContactOutbound(peerDeviceId: s.deviceId, sid: sid, sealPub: sealPub),
        handoff,
      );
    }
  }

  Future<void> _retire() async {
    final now = _now();
    for (final queue in _store.retiringSelfQueues) {
      if (_disposed) return;
      if (now.difference(queue.since) <= kBoxRedeliveryWindow) continue;
      if (await _keys.retire(queue)) {
        E2eDiagLog.add('BOX_SELF_QUEUE_RETIRED', const <String, Object?>{});
      }
    }
  }
}
