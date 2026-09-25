import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../utils/e2e_envelope.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_frame.dart';
import 'box_siblings.dart';
import 'box_wire.dart';
import 'queue_seal.dart';

/// Hands this device's SELF-queue to every sibling that has not
/// acknowledged it (metadata-privacy PR3.1 sibling queues, owner decision
/// 26): through each sibling's REQUEST queue, never the link blob, so ONE
/// mechanism serves devices linked before this release and new links alike.
///
/// Once the account socket is ready (with a confirmed device id), the box is
/// ready, the store is open, E2E is ready and the self-queue exists, it asks
/// the server for the own siblings' request queues (`getOwnRequestQueues`,
/// wire.md) and sends one E2E `queue_handoff` — an account-bearing frame,
/// sealed to that sibling's request key — to each published sibling whose
/// `ackedSelfSid` is not the current self sid. Asked again on every account
/// ready (a reconnect) and whenever the own device list changes, so a
/// handoff is retried until acknowledged; `rate_limited` asks again after
/// `retryAfterMs`, anything else waits for the next connect.
class BoxSiblingSwap {
  BoxSiblingSwap({
    required BoxClient box,
    required ContactStore store,
    required QueueSeal seal,
    required void Function(String event, Object? data) emit,
    required ContactQueue? Function() selfQueue,
  }) : _box = box,
       _store = store,
       _seal = seal,
       _emit = emit,
       _self = selfQueue;

  final BoxClient _box;
  final ContactStore _store;
  final QueueSeal _seal;
  final void Function(String event, Object? data) _emit;
  final ContactQueue? Function() _self;

  /// The Signal side; nothing is asked until it is wired.
  OwnDeviceEncrypt? encrypt;

  bool _accountReady = false;
  bool _e2eReady = false;
  bool _asking = false;
  bool _disposed = false;

  /// The self sid the server last answered for this connect (success or
  /// refusal): nothing is asked again for it until the next account ready,
  /// an own device-list change or a rate limit's `retryAfterMs`. A handoff
  /// that failed is retried then, never in a loop.
  String? _answeredFor;
  Timer? _retry;

  /// The account socket is ready; [deviceId] null = a server that names no
  /// device, which cannot serve the verb either.
  void accountReady(int? deviceId) {
    _accountReady = deviceId != null;
    _asking = false;
    _answeredFor = null;
    run();
  }

  /// The account socket dropped: an answer still owed will never come, and
  /// E2E readiness is per connect (it fires again on the next one).
  void accountLost() {
    _accountReady = false;
    _e2eReady = false;
    _asking = false;
    _retry?.cancel();
  }

  void e2eReady() {
    _e2eReady = true;
    run();
  }

  /// The own verified device list was dropped (a device linked or revoked):
  /// the siblings may have changed.
  void ownDevicesChanged() {
    _answeredFor = null;
    run();
  }

  /// Asks for the siblings' request queues once every gate is open.
  void run() {
    final self = _self();
    if (_disposed ||
        !_accountReady ||
        !_e2eReady ||
        encrypt == null ||
        _box.state != BoxState.ready ||
        !_store.isOpen ||
        self == null ||
        _asking ||
        _answeredFor == self.sid) {
      return;
    }
    _asking = true;
    _emit('getOwnRequestQueues', const <String, Object?>{});
  }

  /// `ownRequestQueues { success, devices?, error?, retryAfterMs? }`.
  Future<void> onOwnRequestQueues(Object? data) async {
    if (!_asking || data is! Map) return;
    // Cleared at once, not after the sends: a reconnect meanwhile asks
    // again, and its answer must not be taken for this one's.
    _asking = false;
    final self = _self();
    _answeredFor = self?.sid;
    if (data['success'] != true) {
      final retryMs = data['retryAfterMs'];
      if (data['error'] == 'rate_limited' && retryMs is int) {
        _retry?.cancel();
        _retry = Timer(Duration(milliseconds: retryMs), () {
          _answeredFor = null;
          run();
        });
      }
      return;
    }
    final devices = data['devices'];
    final own = _store.userId;
    final seal = encrypt;
    if (devices is! List || self == null || own == null || seal == null) {
      return;
    }
    for (final device in devices) {
      if (_disposed) return;
      if (device is! Map) continue;
      final deviceId = device['deviceId'];
      final sid = boxB64Decode(device['requestSid'], kBoxSidBytes);
      final sealPub = boxB64Decode(device['sealPub'], 32);
      if (deviceId is! int) continue;
      // Not published yet: handed off on a later connect.
      if (sid == null || sealPub == null) continue;
      // Our OWN request queue under a sibling's id: the handoff would come
      // straight back to us. A device on the link gate once published its
      // queue under the primary's token (found live, 2026-09-25).
      if (device['requestSid'] == _store.requestQueue?.sid) continue;
      final acked = _store.siblings
          .where((s) => s.deviceId == deviceId)
          .firstOrNull
          ?.ackedSelfSid;
      if (acked == self.sid) continue;
      await _handoff(seal, own, deviceId, sid, sealPub, self);
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }

  /// One `queue_handoff` to sibling [deviceId]'s request queue. A failure is
  /// only recorded: the next connect hands off again.
  Future<void> _handoff(
    OwnDeviceEncrypt encrypt,
    int own,
    int deviceId,
    Uint8List sid,
    Uint8List sealPub,
    ContactQueue self,
  ) async {
    String? failed;
    try {
      final signal = await encrypt(
        deviceId,
        jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: self.sid, sealPub: self.sealPub),
        ),
      );
      if (_disposed) return;
      if (signal == null) {
        failed = 'encrypt';
      } else {
        final body = BoxFrame(
          kind: signal.kind,
          senderDeviceId: signal.senderDeviceId,
          senderUserId: own,
          signal: signal.signal,
        ).encode();
        final blob = await _seal.seal(sealPub, body);
        if (_disposed) return;
        if (blob == null) {
          failed = 'seal';
        } else if (await _box.send(sid, blob) is! BoxOk) {
          failed = 'send';
        }
      }
    } on Object catch (e) {
      failed = e.runtimeType.toString();
    }
    if (failed != null) {
      E2ePersistentDiag.record('BOX_SIBLING_HANDOFF_FAILED', {
        'device': deviceId,
        'stage': failed,
      });
    }
  }
}
