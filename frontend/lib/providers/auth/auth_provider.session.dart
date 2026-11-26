part of '../auth_provider.dart';

// The moved bodies call `notifyListeners()`, which is `@protected` on
// `ChangeNotifier`: an extension is outside the class as far as the analyzer
// is concerned, though it is the same library.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Session lifecycle: the saved-token boot and its two phases, the silent
/// refresh with its single in-flight lock, the 15-minute timer, and the ways
/// a session ends locally.
extension AuthSessionLifecycle on AuthProvider {
  bool _isAccessExpired(String jwt) {
    try {
      return JwtDecoder.isExpired(jwt);
    } catch (_) {
      // Undecodable token → treat as expired (fail closed): forces a refresh
      // attempt instead of trusting garbage; recovers or lands on login.
      return true;
    }
  }

  void _restoreUserFromAccessJwt(String accessJwt) {
    try {
      final payload = JwtDecoder.decode(accessJwt);
      final id = (payload['sub'] as num).toInt();
      final username = payload['username'] as String;
      final tag = payload['tag'] as String? ?? '0000';
      final existing = _currentUser;
      if (existing != null && existing.id == id) {
        // Same account (e.g. silent 15-min token refresh): keep the fully
        // hydrated profile (about, profilePictureUrl, the photo, ...) and
        // only refresh the identity fields the JWT actually carries. Rebuilding
        // from claims alone would drop about.
        _currentUser = existing.copyWith(id: id, username: username, tag: tag);
      } else {
        // Cold start or account switch: no fully-hydrated prior profile to
        // trust, so rebuild from claims (preserving prior behavior exactly).
        _currentUser = UserModel(
          id: id,
          username: username,
          tag: tag,
          profilePictureUrl: existing?.profilePictureUrl,
          avatar: _ownAvatar,
        );
      }
    } catch (_) {}
  }

  Future<void> _persistTokens(Map<String, dynamic> body) async {
    final access = body['access_token'] as String?;
    final refresh = body['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw StateError('Auth response missing tokens');
    }
    _token = access;
    _refreshToken = refresh;
    _refreshPersisted = await _tokens.write(access: access, refresh: refresh);
    _restoreUserFromAccessJwt(access);
    onAccessTokenChanged?.call(access);
    // A fresher token for the SAME account: enough to flush an upload a 401
    // parked. A new account arrives through `_adoptSession`, which resolves
    // the row from scratch.
    _contactBackup.onToken(access);
    notifyListeners();
  }

  Future<void> _silentRefresh() async {
    final r = _refreshToken;
    if (r == null) {
      throw SessionRefreshInvalidException('No refresh token');
    }

    // Decided once: every retry of [r] has to ask the same way, or a retry
    // of a token the server already replaced reads as reuse.
    final rotate = _rotateRefreshTokens && _refreshPersisted;
    final epoch = _sessionEpoch;
    Object? lastTransient;
    for (var attempt = 0; attempt < AuthProvider._refreshMaxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(AuthProvider._refreshRetryBaseDelay * attempt);
        if (epoch != _sessionEpoch) return;
      }
      try {
        final body = await _api.refreshSession(r, rotate: rotate);
        if (epoch != _sessionEpoch) return;
        await _persistTokens(body);
        return;
      } on SessionRefreshInvalidException {
        // A refusal of a session that already ended is not a second ending.
        if (epoch != _sessionEpoch) return;
        rethrow;
      } on SessionRefreshTransientException catch (e) {
        lastTransient = e;
      } catch (e) {
        lastTransient = e;
      }
    }

    throw SessionRefreshTransientException(
      lastTransient?.toString() ?? 'Session refresh failed after retries',
    );
  }

  /// Single in-flight refresh for startup, resume, and parallel [ensureSessionReady].
  Future<void> _refreshSessionLocked() async {
    // A flight begun under an older session is dropped when it lands: a
    // caller of this session must not wait on it.
    if (_sessionRefreshInFlight != null &&
        _sessionRefreshInFlightEpoch == _sessionEpoch) {
      return _sessionRefreshInFlight!;
    }

    final future = _silentRefresh();
    _sessionRefreshInFlight = future;
    _sessionRefreshInFlightEpoch = _sessionEpoch;
    try {
      await future;
    } finally {
      if (identical(_sessionRefreshInFlight, future)) {
        _sessionRefreshInFlight = null;
      }
    }
  }

  void _logSessionEnd(String reason, {required String source, Object? error}) {
    _lastSessionEndReason = reason;
    final access = _token;
    final userId = _currentUser?.id;
    final accessExpired = access == null ? null : _isAccessExpired(access);
    debugPrint(
      '[auth-session-end] reason=$reason source=$source '
      'hasAccess=${access != null} hasRefresh=${_refreshToken != null} '
      'accessExpired=$accessExpired userId=$userId '
      'errorType=${error.runtimeType}',
    );
    // Involuntary session ends are failure-class field evidence (the 2026-07
    // logout incident was undiagnosable client-side); explicit logout is not.
    if (reason != 'explicit_logout') {
      final payload = {
        'reason': reason,
        'source': source,
        'hasRefresh': _refreshToken != null,
        'accessExpired': accessExpired,
      };
      // The locally-derived reasons fire on EVERY boot while a dead access
      // token lingers in storage (the §5.4 keep-the-store tradeoff), and the
      // durable log is an 80-entry FIFO — plain records would churn out the
      // BOOT_MARKERS forensics planted to diagnose the next storage wipe.
      // Dedup them; eviction re-arms, so recurrence is never lost for good.
      const repeatProne = {
        'expired_access_without_refresh',
        'access_401_without_refresh',
      };
      if (repeatProne.contains(reason)) {
        E2ePersistentDiag.recordDeduped(
          'AUTH_SESSION_END',
          payload,
          matchAll: ['reason: $reason,'],
        );
      } else {
        E2ePersistentDiag.record('AUTH_SESSION_END', payload);
      }
    }
  }

  void _finishRestoringSession() {
    if (!_isRestoringSession) return;
    _isRestoringSession = false;
    notifyListeners();
  }

  void _restoreSavedAccessToken(String savedToken) {
    _token = savedToken;
    _restoreUserFromAccessJwt(savedToken);
    notifyListeners();
  }

  /// [wipeStoredTokens]: only SERVER-AUTHORITATIVE reasons (`refresh_invalid*`,
  /// explicit logout, password change) may delete the persisted tokens. The
  /// locally-derived reasons (`expired_access_without_refresh`,
  /// `access_401_without_refresh`) are inferred from in-memory ABSENCE — if
  /// that absence was ever an artifact (a glitched read, a lost hydration),
  /// wiping storage here converts a transient fault into a permanent logout,
  /// destroying a refresh token the server still honors (user 54's row was
  /// valid to 2027 while he sat on a login screen). They clear the SESSION,
  /// never the STORE; the next cold boot re-reads storage and recovers.
  Future<void> _clearLocalAuthState(
    String reason, {
    required String source,
    Object? error,
    bool wipeStoredTokens = true,
  }) async {
    _sessionEpoch++;
    _logSessionEnd(reason, source: source, error: error);
    _cancelSessionRefreshTimer();
    _isRestoringSession = false;
    _token = null;
    _refreshToken = null;
    _currentUser = null;
    _ownAvatar = null;
    _statusMessage = null;
    _statusCode = null;
    _isError = false;
    if (wipeStoredTokens) {
      // A logout that wipes the store wipes the content key with it, by
      // design: the next password login unwraps it again from the server
      // row. A TRANSIENT session drop (`wipeStoredTokens: false`) leaves
      // both alone — the store is intact and the next boot reuses them.
      // The files the user saved out of chats are plaintext outside every
      // store, so they end with the session (A3-MSG-A-04). First, so a
      // failing step below cannot leave them behind; best effort.
      if (!await download_utils.deleteSavedDownloads()) {
        E2ePersistentDiag.record('SAVED_COPIES_DELETE_FAILED', {});
      }
      await _contactBackup.clear();
      await _tokens.clear();
    }
    await clearPwaAppBadgeOnLogout();
    notifyListeners();
  }

  /// A refresh the server refused ends the session. Refused as `Device
  /// revoked` (issue #234: a device revoked while it was closed meets that
  /// answer before any socket), it ends with the same notice the account
  /// socket's `deviceRevoked` gives, and hands the account over for its
  /// queues ([takeRevokedDeviceAccount]) — only while the install's stored
  /// session is still the refused one (its stored token may be one rotation
  /// behind, plan B4): another tab that signed in meanwhile holds a newer
  /// session, and the queues are no longer this decision's.
  /// [access] names the account when no user is held yet (an expired saved
  /// access at boot).
  Future<void> _endRefusedSession(
    SessionRefreshInvalidException error, {
    required String reason,
    required String source,
    String? access,
  }) async {
    if (!error.deviceRevoked) {
      await _clearLocalAuthState(reason, source: source, error: error);
      return;
    }
    final userId = _currentUser?.id ?? _accessUserId(access ?? _token);
    final refused = _refreshToken;
    final stored = await _tokens.read();
    await _clearLocalAuthState('device_revoked', source: source, error: error);
    // After the clear, which resets the status surface.
    _statusCode = AuthStatusCode.deviceRevoked;
    _isError = true;
    final storedRefresh = stored.refresh;
    if (userId != null &&
        refused != null &&
        storedRefresh != null &&
        AuthTokenStore.refreshSessionOf(storedRefresh) ==
            AuthTokenStore.refreshSessionOf(refused)) {
      _revokedDeviceAccount = userId;
    }
    notifyListeners();
  }

  /// The account an access JWT names (`sub`), expired or not; null when it
  /// does not decode.
  static int? _accessUserId(String? access) {
    if (access == null) return null;
    try {
      final sub = JwtDecoder.decode(access)['sub'];
      return sub is num ? sub.toInt() : null;
    } on Object {
      return null;
    }
  }

  Future<void> _ensureSessionReadyBody() async {
    if (_refreshToken == null) {
      if (_token != null && _isAccessExpired(_token!)) {
        await _clearLocalAuthState(
          'expired_access_without_refresh',
          source: 'ensureSessionReady',
          wipeStoredTokens: false,
        );
      }
      return;
    }
    if (_token != null && !_isAccessExpired(_token!)) return;

    try {
      await _refreshSessionLocked();
    } on SessionRefreshInvalidException catch (e) {
      await _endRefusedSession(
        e,
        reason: 'refresh_invalid',
        source: 'ensureSessionReady',
      );
    } on SessionRefreshTransientException {
      if (_token != null) {
        _restoreUserFromAccessJwt(_token!);
      }
      notifyListeners();
    }
  }

  void _cancelSessionRefreshTimer() {
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
  }

  void _startSessionRefreshTimer() {
    _cancelSessionRefreshTimer();
    _sessionRefreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      ensureSessionReady();
    });
  }

  Future<void> _loadSavedToken() async {
    try {
      var saved = await _tokens.read();
      // Bounded retry-before-decide: a read that ERRORS is not a logout —
      // the tokens may be sitting intact behind a transient plugin fault
      // (handoff §5.4). The store already retried fast; these are the slow
      // second chances before we concede the boot.
      for (
        var i = 0;
        saved.readFailed && i < _tokenReadRetryDelays.length;
        i++
      ) {
        await Future<void>.delayed(_tokenReadRetryDelays[i]);
        saved = await _tokens.read();
      }
      if (saved.readFailed) {
        // Storage answered with errors on every attempt. Concede the boot to
        // the login screen but LEAVE THE STORE UNTOUCHED — the next launch
        // re-reads it — and say what happened instead of feigning a logout.
        // Durable AUTH_TOKENS_UNREADABLE was recorded by the store.
        _statusCode = AuthStatusCode.savedSessionUnreadable;
        _isError = true;
        return;
      }
      final savedToken = saved.access;
      final savedRefresh = saved.refresh;
      _refreshToken = savedRefresh;

      if (savedToken == null && savedRefresh == null) return;

      // Whether the SAVED access alone was usable — i.e. boot phase 1 will
      // restore it without refreshing. Decides the proactive slide below.
      final savedAccessUsable =
          savedToken != null && !_isAccessExpired(savedToken);

      // Phase 1: get a usable access token (refresh if missing/expired).
      if (await _restoreAccessOnBoot(savedToken)) return;
      if (_token == null) return;

      // Phase 2: hydrate the current user (one refresh retry on a 401).
      if (await _hydrateCurrentUserOnBoot()) return;

      // PR2.4: no password on this door, so this resolve can only succeed
      // through the CACHED content key — which is the point. It costs one
      // GET and no derivation, and it is what keeps uploads alive across
      // every cold start that never touches a credential form.
      final restored = _currentUser;
      if (restored != null) {
        unawaited(_resolveContactBackup(userId: restored.id, token: _token!));
      }
      _startSessionRefreshTimer();
      if (savedAccessUsable) {
        _scheduleBackgroundSessionSlide();
      }
      notifyListeners();
    } finally {
      _finishRestoringSession();
    }
  }

  /// Proactively slides the sliding refresh session (on native it also
  /// rotates its token, plan B4) once per cold boot even
  /// while the access JWT is still valid. Purpose: (1) the server-side
  /// `refresh_tokens.expires_at` becomes a daily per-device health signal
  /// (a device that stops sliding = storage loss/stale bundle candidate);
  /// (2) the access token in hand is almost always fresh, so a later offline
  /// reopen inside 24h still works. MUST route around [ensureSessionReady]
  /// (it no-ops on a valid access) and MUST swallow every failure including
  /// [SessionRefreshInvalidException]: a revoked-row or transient blip during
  /// boot must never log the user out of a still-valid session — the regular
  /// expiry path deals with truly dead sessions.
  void _scheduleBackgroundSessionSlide() {
    if (_refreshToken == null) return;
    unawaited(
      _refreshSessionLocked().catchError((Object e) {
        debugPrint(
          '[auth-session-slide] background slide failed (kept session): '
          '${e.runtimeType}',
        );
      }),
    );
  }

  /// Boot phase 1: ensure [_token] holds a usable access JWT. When a refresh
  /// token exists and the saved access is missing/expired, refresh; otherwise
  /// restore the saved access. Returns true if the session was cleared and the
  /// caller must abort. [savedToken] is the persisted (possibly expired) access.
  Future<bool> _restoreAccessOnBoot(String? savedToken) async {
    if (_refreshToken != null &&
        (savedToken == null || _isAccessExpired(savedToken))) {
      try {
        await _refreshSessionLocked();
      } on SessionRefreshInvalidException catch (e) {
        await _endRefusedSession(
          e,
          reason: 'refresh_invalid',
          source: 'boot',
          access: savedToken,
        );
        return true;
      } on SessionRefreshTransientException {
        if (savedToken != null) {
          _restoreSavedAccessToken(savedToken);
        }
      } catch (e) {
        if (savedToken != null) {
          _restoreSavedAccessToken(savedToken);
        } else {
          debugPrint(
            '[auth-session-restore] source=boot outcome=transient_without_access '
            'hasRefresh=true errorType=${e.runtimeType}',
          );
        }
      }
    } else if (savedToken != null) {
      _restoreSavedAccessToken(savedToken);
    }
    return false;
  }

  /// Boot phase 2: fetch the current user for the restored [_token]. On a 401,
  /// try exactly one refresh + refetch; a transient failure falls back to the
  /// JWT claims. Returns true if the session was cleared and the caller must abort.
  Future<bool> _hydrateCurrentUserOnBoot() async {
    try {
      final userData = await _api.fetchMe(_token!);
      _currentUser = _withOwnAvatar(UserModel.fromJson(userData));
    } on Exception catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        if (_refreshToken != null) {
          try {
            await _refreshSessionLocked();
            if (_token != null) {
              final userData = await _api.fetchMe(_token!);
              _currentUser = _withOwnAvatar(UserModel.fromJson(userData));
            }
          } on SessionRefreshInvalidException catch (refreshError) {
            await _endRefusedSession(
              refreshError,
              reason: 'refresh_invalid_after_access_401',
              source: 'boot_fetch_me',
            );
            return true;
          } on SessionRefreshTransientException {
            if (_token != null) {
              _restoreUserFromAccessJwt(_token!);
            }
          } catch (_) {
            if (_token != null) {
              _restoreUserFromAccessJwt(_token!);
            }
          }
        } else {
          await _clearLocalAuthState(
            'access_401_without_refresh',
            source: 'boot_fetch_me',
            error: e,
            wipeStoredTokens: false,
          );
          return true;
        }
      }
    }
    return false;
  }
}
