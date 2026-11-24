part of '../connection_provider.dart';

/// Local-plaintext maintenance: the purge backlog and expiry sweep at
/// `socketReady`, the in-session sweep timer and the `serverTime` reply.
extension ConnectionPlaintextSweep on ConnectionProvider {
  /// In-session expiry destruction cadence — see [_onPlaintextSweepTick].
  ///
  /// The socketReady sweep only covers reconnects; this timer covers the
  /// session that never reconnects. One minute is cheap (the sweep is a key
  /// scan over an in-memory prefs map) and adds at most a minute on top of the
  /// deliberate `kExpiryPurgeGrace`.
  static const Duration _plaintextSweepInterval = Duration(minutes: 1);

  /// Floor between `getServerTime` requests that never got an answer.
  ///
  /// An older backend without the handler answers NOTHING, so without a floor
  /// a stale clock would re-emit every tick forever. One unanswered request
  /// per this window is bounded waste; the reply handler resets it.
  static const Duration _serverTimeRetryFloor = Duration(minutes: 5);

  /// Drain the purge backlog, then sweep.
  ///
  /// This runs UNAWAITED alongside the other connect work, so it orders
  /// itself against nothing else.
  ///
  /// Order within this method still matters:
  ///   1. the backlog first, so a delete interrupted by a tab close or a
  ///      refused write finishes now instead of leaving plaintext behind for
  ///      good;
  ///   2. the sweep, once the clock is known fresh.
  Future<void> _runLocalPlaintextMaintenance() async {
    final encryption = _encryptionProvider;
    if (encryption == null) return;
    try {
      await encryption.drainPurgeBacklog();
      await encryption.sweepDestroyablePlaintext();
    } catch (_) {
      // Never let maintenance break connect. A failure means the residue
      // survives to the next socketReady, which is the safe direction.
    }
  }

  /// Arm (or re-arm) the in-session expiry sweep.
  ///
  /// Without this, [EncryptionProvider.sweepDestroyablePlaintext] runs ONLY at
  /// socketReady — a message expiring while the app stays connected would keep
  /// its plaintext on disk until the next reconnect, which for a long-lived
  /// PWA is unbounded. The timer makes expiry destruction happen within
  /// `kExpiryPurgeGrace` plus one tick, always.
  void _startPlaintextSweepTimer() {
    _plaintextSweepTimer?.cancel();
    _serverTimeRequestedAt = null;
    _plaintextSweepTimer = Timer.periodic(
      _plaintextSweepInterval,
      (_) => _onPlaintextSweepTick(),
    );
  }

  void _onPlaintextSweepTick() {
    if (!_socketService.isConnected) return;
    final encryption = _encryptionProvider;
    if (encryption == null) return;

    if (ServerClock.instance.estimatedNow == null) {
      // The socketReady observation aged past ServerClock.maxExtrapolation (or
      // never arrived). The sweep would silently no-op forever from here, so
      // ask for a fresh observation; the `serverTime` reply runs the sweep.
      // Floor-limited: an older backend never answers, and one dead request
      // per floor window is bounded waste while staying fail-closed.
      // clock.now() (package:clock), not DateTime.now(): fake_async patches
      // the former, so the retry floor is deterministic under test.
      final requestedAt = _serverTimeRequestedAt;
      final now = clock.now();
      if (requestedAt != null &&
          now.difference(requestedAt) < _serverTimeRetryFloor) {
        return;
      }
      _serverTimeRequestedAt = now;
      _socketService.getServerTime();
      return;
    }
    _sweepPlaintextNow(encryption);
  }

  /// `serverTime` reply — observe, then sweep against the fresh clock.
  ///
  /// A malformed stamp is ignored by [ServerClock.observeIso]; the clock stays
  /// unconfirmed and nothing is destroyed. The retry stamp is cleared only on
  /// a usable answer so garbage cannot silence the re-request path.
  void _onServerTime(dynamic data) {
    _serverResponseCounter++;
    // Issue #206: the server answered on this session, so it still holds it
    // (a revoke closes it there): a box connection waiting since a loss may
    // re-sign the set ([_confirmSessionForBox]).
    if (_accountReady) _box?.accountAnswered();
    ServerClock.instance.observeIso(data is Map ? data['serverTime'] : null);
    if (ServerClock.instance.estimatedNow == null) return;
    _serverTimeRequestedAt = null;
    final encryption = _encryptionProvider;
    if (encryption == null) return;
    _sweepPlaintextNow(encryption);
  }

  void _sweepPlaintextNow(EncryptionProvider encryption) {
    // Fire-and-forget from a timer/socket handler; a failure means the residue
    // survives to the next tick, which is the safe direction.
    unawaited(encryption.sweepDestroyablePlaintext().catchError((Object _) {}));
  }
}
