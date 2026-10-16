part of '../messaging_provider.dart';

/// A sibling the primary asks to unlink (decision 101 B), named as the
/// Devices screen names it.
typedef SiblingToUnlink = ({int deviceId, String name});

/// Decisions 101 B and 103: every device sends each live own sibling a quiet
/// `alive` at most once a day when it connects; every device keeps when it
/// last heard each sibling (any authenticated frame on its self-queue); the
/// primary asks to unlink one silent for 30 days.
extension MessagingBoxAlive on MessagingProvider {
  /// When own sibling [deviceId] was last heard on this device's self-queue,
  /// or first known on this install; null when unknown or the store is shut.
  DateTime? siblingLastHeardAt(int deviceId) => boxAlive?.heardAt(deviceId);

  /// The live own sibling this device — only when it is the account's
  /// primary — should ask to unlink now, or null. Read from the own VERIFIED
  /// list held now; a dropped list asks nothing until it is verified again.
  SiblingToUnlink? get siblingToUnlink {
    final alive = boxAlive;
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (alive == null || enc == null || own == null) return null;
    if (!enc.isE2EReady || !enc.ownDeviceIdConfirmed) return null;
    final list = enc.cachedDeviceList(own);
    if (list == null || !list.enrolled) return null;
    final id = alive.unlinkDue(self: enc.ownDeviceId, live: list.liveDeviceIds);
    if (id == null) return null;
    final entry = list.devices.firstWhere((d) => d.deviceId == id);
    return (
      deviceId: id,
      name: entry.name ?? '${entry.platform} · #${entry.deviceId}',
    );
  }

  /// The user chose "Keep" for sibling [deviceId]: not asked again for
  /// [kSiblingKeepFor].
  Future<void> keepSibling(int deviceId) async {
    final alive = boxAlive;
    if (alive == null) return;
    await alive.keep(deviceId);
    if (!_isDisposed) notifyListeners();
  }

  /// An authenticated frame from own sibling [deviceId] was read from our
  /// self-queue. A sibling the line was asking about stops being asked.
  void _heardFromSibling(int deviceId) {
    final alive = boxAlive;
    if (alive == null) return;
    final asked = siblingToUnlink?.deviceId == deviceId;
    unawaited(
      alive.heard(deviceId).then((moved) {
        if (moved && asked && !_isDisposed) notifyListeners();
      }),
    );
  }

  /// Own sibling [deviceId] sent a frame only a build that reads `relay`
  /// sends (E101b).
  void _siblingReadsRelays(int deviceId) {
    final alive = boxAlive;
    if (alive == null) return;
    if (alive.allReadRelays([deviceId])) return;
    alive.readsRelays(deviceId).ignore();
  }

  /// Whether this device tells friends it relays (`rl`, decision 101 A):
  /// only while every live own sibling in the verified list is known to
  /// read `relay` (E101b). A friend that trusts `rl` stops addressing the
  /// devices it cannot reach, so a sibling on an older build would finish
  /// the relayed copy unread and lose that message for good.
  bool get _vouchesRelay {
    final alive = boxAlive;
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (alive == null || enc == null || own == null) return false;
    if (!enc.ownDeviceIdConfirmed) return false;
    final list = enc.cachedDeviceList(own);
    if (list == null) return false;
    final self = enc.ownDeviceId;
    return alive.allReadRelays([
      for (final d in list.liveDeviceIds)
        if (d != self) d,
    ]);
  }

  /// One pass per connect (and per own-list change): every live sibling is
  /// known, and each one owed an `alive` that has a self-queue address and a
  /// usable session gets one, quiet. Best effort: a frame not taken is owed
  /// again on the next pass. Never builds a session (E38b's rule for a box
  /// frame): a sibling with none waits for the connect's pre-build.
  Future<void> _siblingAlivePass() async {
    final alive = boxAlive;
    final outbox = boxOutbox;
    final own = _currentUserId;
    final enc = _encryptionProvider;
    if (alive == null || outbox == null || own == null || enc == null) return;
    if (!alive.beginPass()) return;
    final before = siblingToUnlink;
    try {
      // This connect's own lookup, when the refresh runs one: never a second.
      try {
        await _boxLists.readyFor(own);
      } on Object {
        // Looked up below, or the pass ends there.
      }
      final mine = await ownLiveDevices();
      if (mine == null || _isDisposed) return;
      final siblings = {
        for (final d in mine.live)
          if (d != mine.self) d,
      };
      if (!await alive.known(siblings)) return;
      final addresses = outbox.siblingAddresses();
      final json = jsonEncode(E2eEnvelope.buildAlive());
      for (final device in alive.aliveDue(siblings)) {
        final to = addresses[device];
        if (to == null || _isDisposed) continue;
        // A paused sibling (E93a) is not read; an `alive` is never worth its
        // probe: sealing it would move that chain for nothing (2000-step cap).
        if (_boxPaused.isPaused(own, device)) continue;
        try {
          if (!await _hasUsableBoxSession(enc, own, device)) continue;
          final frame = await encryptForOwnDevice(device, json);
          if (frame == null) continue;
          final outcome = await outbox.deliver(
            to,
            frame.encode(),
            mode: BoxSendMode.quiet,
          );
          _e2eFlowLog('BOX_SIBLING_ALIVE', {
            'device': device,
            'outcome': outcome.name,
          });
          _noteBoxAnswer(own, device, outcome);
          // A full queue is owed nothing more today: the pause is RAM only,
          // and a retry at every connect would seal one step each time.
          if (outcome != BoxSendOutcome.failed) await alive.aliveSent(device);
        } on Object catch (e) {
          _e2eFlowLog('BOX_SIBLING_ALIVE_FAILED', {
            'device': device,
            'error': e.runtimeType.toString(),
          });
        }
      }
    } finally {
      alive.endPass();
      if (!_isDisposed && siblingToUnlink != before) notifyListeners();
    }
  }
}
