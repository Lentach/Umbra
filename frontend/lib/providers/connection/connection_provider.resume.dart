part of '../connection_provider.dart';

/// App resume: the reconnect check with its repeat guard, the account
/// socket's liveness probe and the box's session confirmation.
extension ConnectionResume on ConnectionProvider {
  /// Ensure reconnected if needed (e.g. app resume from background).
  /// Test-only: seed identity so [ensureReconnectIfNeeded]'s guards pass
  /// without a full connect() (which arms the real connect cooldown).
  @visibleForTesting
  void setIdentityForTest(int userId, String token) {
    _currentUserId = userId;
    _reconnectManager.tokenForReconnect = token;
  }

  void ensureReconnectIfNeeded() {
    final claimsConnected = _socketService.isConnected;
    // On web ONE resume reaches this method twice (tab visibility and the app
    // lifecycle). The second run is the same resume: against a dead socket it
    // would queue a second real connect() behind the connect cooldown, against
    // a zombie one it would cost another getServerTime and restart the probe
    // window. Only a repeat that sees the SAME socket claim is dropped: a
    // socket that died since the last run still reconnects at once. On EVERY
    // platform, a genuine second resume within the cooldown whose claim is
    // unchanged is treated as that same resume — the cost is a zombie socket
    // noticed one resume (or socket.io's ping timeout) later.
    // The stamp is written here only, so socket-death reconnects, the probe
    // timeout and connect() are never throttled by it. clock.now()
    // (package:clock), not DateTime.now(): fake_async patches the former.
    final now = clock.now();
    final last = _lastResumeCheckAt;
    if (last != null &&
        _lastResumeCheckClaimed == claimsConnected &&
        now.difference(last) < AppConstants.reconnectConnectCooldown) {
      // Its own marker: RESUME_CHECK must only ever mean a check happened.
      E2eDiagLog.add('RESUME_CHECK_SKIPPED', {
        'socketConnected': claimsConnected,
      });
      return;
    }
    E2eDiagLog.add('RESUME_CHECK', {'socketConnected': claimsConnected});
    if (_currentUserId == null || _reconnectManager.tokenForReconnect == null) {
      return;
    }
    _lastResumeCheckAt = now;
    _lastResumeCheckClaimed = claimsConnected;
    // The box socket is its own transport and gets nothing from the account
    // socket's probe below: suspended in the background (an iOS PWA above
    // all), it can be dead while it still reports connected, until
    // socket.io's ping timeout. Meanwhile every box send waits out its
    // timeout and fails, and the box hands every message stored for us to
    // that dead socket instead of pushing it. Probe it, whatever the account
    // socket claims; only a dead one is replaced (and the replacement waits
    // for the session to be confirmed, issue #206).
    _box?.checkAlive();
    if (!claimsConnected) {
      _reconnectWithStoredCredentials();
      return;
    }
    // Socket CLAIMS connected, but iOS suspends the transport in background
    // and socket.io only notices on ping timeout (zombie socket) — the resume
    // used to do nothing, leaving pushed messages invisible until a full
    // relaunch. Re-sync now and arm a liveness probe: if no server response
    // lands within the window, force a fresh connect (cheap; reconnect
    // preserves state by design).
    _resyncAfterResume();
  }

  static const _kResumeProbeWindow = Duration(seconds: 6);

  void _resyncAfterResume() {
    final activeConvId = _conversationsProvider?.activeConversationId;
    _probeAccountLiveness();
    _conversationsProvider?.repostActiveConversationToSw();
    E2eDiagLog.add('RESUME_RESYNC', {
      'activeConvId': activeConvId ?? -1,
      'socketConnected': _socketService.isConnected,
    });
  }

  /// Asks the server for the time on the account socket and forces a fresh
  /// connect if nothing answers within [_kResumeProbeWindow]: a socket that
  /// claims connected may be dead. The probe's own question is the time: the
  /// server answers it from no table, and a reply is all the probe needs.
  void _probeAccountLiveness() {
    final probeStart = _serverResponseCounter;
    _socketService.getServerTime();
    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = Timer(_kResumeProbeWindow, () {
      if (_serverResponseCounter != probeStart) return; // server replied: alive
      E2eDiagLog.add('RESUME_PROBE_TIMEOUT', {'forcedReconnect': true});
      _reconnectWithStoredCredentials();
    });
  }

  /// Issue #206: a box connection came back after a loss and waits for the
  /// session to be confirmed before it re-signs the set. While the account
  /// socket is not ready its `socketReady` (or `deviceRevoked`) answers;
  /// while it claims ready it may be dead with this device revoked
  /// meanwhile, so the server is asked: `serverTime` releases
  /// ([_onServerTime]), silence forces a reconnect that meets the gate.
  void _confirmSessionForBox() {
    if (_accountReady) _probeAccountLiveness();
  }
}
