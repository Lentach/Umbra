part of '../connection_provider.dart';

// Extension methods on ConnectionProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The account socket's life: transport connect, the `socketReady` watchdog
/// and work, the stored-credentials reconnect, token refresh and disconnect.
extension ConnectionLifecycle on ConnectionProvider {
  /// A transport connect that never reaches `socketReady` is invisible: the
  /// socket stays "connected", so no `disconnect` event fires and no reconnect
  /// is ever scheduled, while every authenticated fetch is gated behind ready.
  /// Result is an authenticated-looking empty shell until the user force-quits.
  static const Duration _kSocketReadyWindow = Duration(seconds: 10);

  /// Connects with the account and token this provider holds for a reconnect;
  /// nothing when either is gone (a logout cleared them).
  void _reconnectWithStoredCredentials() {
    final userId = _currentUserId;
    final token = _reconnectManager.tokenForReconnect;
    if (userId == null || token == null) return;
    connect(userId, token, AppConfig.baseUrl);
  }

  void _onSocketTransportConnect(int userId) {
    E2eDiagLog.add('SOCKET_CONNECT', {'userId': userId});
    _intentionalDisconnect = false;
    _isConnected = true;
    notifyListeners();
    _armSocketReadyWatchdog();

    if (!_pushInitialized) {
      _pushInitialized = true;
      void onNavigateToConversation(int conversationId) {
        _conversationsProvider?.requestNavigateToConversationFromNotification(
          conversationId,
        );
      }

      _pushService
          .initialize(onNavigateToConversation: onNavigateToConversation)
          .catchError((_) {});

      // Seed cold-start id from URL param (set once; subsequent reconnects skip it).
      _pushService.coldStartConversationId ??= _coldStartConversationId;
      _coldStartConversationId = null;

      // Drain cold-start notification deep-link (web: URL param; Android: handled by FCM path)
      final coldConvId = _pushService.coldStartConversationId;
      if (coldConvId != null) {
        _pushService.coldStartConversationId = null;
        onNavigateToConversation(coldConvId);
      }
    }
  }

  /// Arms the [_kSocketReadyWindow] guard for the connect attempt that has just
  /// completed its transport handshake. Cancelled by [_onSocketReady].
  void _armSocketReadyWatchdog() {
    _socketReadyWatchdog?.cancel();
    final armedAt = _serverResponseCounter;
    _socketReadyWatchdog = Timer(_kSocketReadyWindow, () {
      _socketReadyWatchdog = null;
      // Any server response since arming means the link works and ready was
      // merely slow — the same liveness signal the resume probe uses.
      if (_serverResponseCounter != armedAt) return;
      if (_intentionalDisconnect || !_isConnected) return;
      E2eDiagLog.add('SOCKET_READY_TIMEOUT', {
        'windowMs': _kSocketReadyWindow.inMilliseconds,
      });
      // Drop the transport instead of calling connect() directly: the resulting
      // `disconnect` event routes through ChatReconnectManager, so the retry
      // inherits its bounded backoff rather than looping every window.
      _socketService.disconnect();
    });
  }

  /// The socket ended before it turned ready: ask the owner of the auth
  /// session whether the account still exists ([onSessionRejected]). Rate
  /// limited, single-flight, and never throws: the probe is a question, and
  /// a failing answer must not disturb the reconnect that is already queued.
  void _probeRejectedSession() {
    final probe = onSessionRejected;
    if (probe == null || _sessionProbeRunning) return;
    final now = clock.now();
    final last = _lastSessionProbeAt;
    if (last != null &&
        now.difference(last) < ConnectionProvider.kSessionProbeSpacing) {
      return;
    }
    _lastSessionProbeAt = now;
    _sessionProbeRunning = true;
    unawaited(
      probe()
          .catchError((Object _) {})
          .whenComplete(() => _sessionProbeRunning = false),
    );
  }

  /// After JWT auth completes on the server (`socketReady` event).
  void _onSocketReady() {
    _socketReadyWatchdog?.cancel();
    _socketReadyWatchdog = null;
    final activeConvId = _conversationsProvider?.activeConversationId;
    E2eDiagLog.add('SOCKET_READY', {
      'activeConvId': activeConvId ?? -1,
      'socketConnected': _socketService.isConnected,
    });
    _reconnectManager.resetAttempts();

    // Local-plaintext maintenance, ordered deliberately. Runs HERE because the
    // socketReady listener has just observed the server clock, and the sweep
    // refuses to destroy anything without a fresh one.
    unawaited(_runLocalPlaintextMaintenance());
    _startPlaintextSweepTimer();

    // Phase 0b: the ceremony countdown and its cancel button are in-memory
    // only, so every connect re-asks who is trying to replace this account's
    // keys. A session that was closed when the request landed opens straight
    // into the banner instead of a silent, un-cancellable delay.
    _encryptionProvider?.refreshOwnAccountStatus();
    // (lxviii) clause 1: a devices screen that is open across a reconnect —
    // above all its own ceremony's rebind — re-reads the list on the socket
    // that can actually answer.
    _provisioningSink?.onSessionReady();

    // A push worker the browser restarted holds no open chat: say it again.
    _conversationsProvider?.repostActiveConversationToSw();
  }

  /// Updates reconnect + messaging token after AuthProvider refreshes JWT (no socket reconnect).
  void applyRefreshedAccessToken(String newAccessToken) {
    _reconnectManager.tokenForReconnect = newAccessToken;
    _messagingProvider?.setToken(newAccessToken);
  }

  // ---------- Disconnect ----------

  void disconnect({bool isLogout = false}) {
    // A connect() parked on an await must not resume into a closed session.
    _connectGeneration++;
    _intentionalDisconnect = true;
    _lastResumeCheckAt = null;
    _debouncedConnectTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _socketReadyWatchdog?.cancel();
    _socketReadyWatchdog = null;
    _plaintextSweepTimer?.cancel();
    _plaintextSweepTimer = null;
    _reconnectManager.cancel();

    // Notify sub-providers
    _encryptionProvider?.onDisconnect();
    _messagingProvider?.onDisconnect();

    // Socket cleanup
    _socketService.disconnect();
    _box?.close();
    _isConnected = false;
    _errorMessage = null;

    if (isLogout) {
      _pushInitialized = false;
      _currentUserId = null;
      _reconnectManager.tokenForReconnect = null;
      _encryptionProvider
        ?..clearAll()
        // Issue #208: the next session may name another device.
        ..forgetPreviousDeviceLife();
      // A revoked device's box may still be deleting its queues (issue
      // #205): the store holds their keys, so it closes after that — unless
      // a new session opened it meanwhile.
      unawaited(_releaseAccountState(mayClose: () => _currentUserId == null));
    }

    notifyListeners();
  }
}
