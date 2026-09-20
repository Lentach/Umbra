import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../services/auth_token_store.dart';
import '../services/api_service.dart';
import '../services/api_exception.dart';
import '../services/contacts/contact_backup.dart';
import '../services/contacts/contact_backup_service.dart';
import '../services/pwa_app_badge_clear.dart';
import '../services/push_service.dart';
import '../services/session_refresh_exception.dart';
import '../config/app_config.dart';
import '../utils/e2e_persistent_diag.dart';

/// What the auth surface should TELL the user, without deciding the words.
///
/// The provider has no locale, so it must never build user-facing prose. It
/// used to, and the login screen rendered the result verbatim: Polish users saw
/// English on the app's front door, one branch told them to run
/// `docker-compose up`, and the fallback returned the raw exception string.
/// The widget layer maps these to ARB strings — the same split already used for
/// [AuthProvider.logoutBecauseDeviceRevoked] and for backend reason codes on
/// the invitations surface.
enum AuthStatusCode {
  /// Token storage errored on every read attempt. The store was left intact, so
  /// the session may still be there on the next launch.
  savedSessionUnreadable,

  /// Registration succeeded but the automatic sign-in that follows it did not,
  /// so the credentials still work and the user only has to sign in.
  registerSucceeded,

  /// The username is taken. The account may well be the user's OWN from a
  /// previous attempt, so the surface must offer signing in, never just
  /// "pick another name" — that is the advice that strands someone whose
  /// registration succeeded on a request whose response never arrived.
  nicknameTaken,

  /// The server rejected the username's shape (3-20 chars, letters/digits/`_`).
  usernameInvalid,

  /// The server rejected the password's shape (8+ chars, upper+lower+digit).
  passwordTooWeak,

  /// Wrong username or password on SIGN-IN, where both fields are in play.
  invalidCredentials,

  /// The wrong password on a surface that only asked for a password — the
  /// Settings password change and the account-deletion confirmation. Naming
  /// the username there points at a field the user never touched.
  wrongPassword,

  /// The recover door refused: unknown name, wrong phrase, or no phrase
  /// enrolled — one wording by design (no enumeration). Naming a password
  /// here would point at the NEW-password field, which is not what failed.
  phraseRejected,

  /// The endpoint's rate limit refused this attempt (HTTP 429).
  tooManyAttempts,

  /// The server answered, but with a failure of its own (HTTP 5xx, including a
  /// gateway error while the backend is being deployed).
  serverError,

  /// The backend could not be reached at all, or the answer never arrived
  /// (timeout / dropped connection — an iOS tab resumed from the background
  /// is enough). Only reported after [AuthProvider] has already retried on its
  /// own; for a register that includes settling whether the lost request
  /// created the account (see [AuthProvider.register]).
  serverUnreachable,

  /// Anything else. Deliberately generic: the previous behaviour leaked the
  /// exception text, which was untranslated and told the user nothing they
  /// could act on.
  unexpectedError,
}

/// Which credential call failed. The same HTTP status means different things
/// per door: a 400 on register is almost always the USERNAME rule (the form
/// already enforces the password rule before sending), while a 400 on a
/// password change is the new password.
enum AuthAttempt { register, login, credentialChange, recover }

/// Maps a failed credential call to what the user should be TOLD.
///
/// Driven by the HTTP STATUS, never by matching the server's prose: the text is
/// untranslated, unversioned backend English. The one place prose is consulted
/// is choosing between the two shapes a 400 can carry, and it defaults to the
/// attempt's more likely rule when the hint is absent.
///
/// Transport failures are classified by TYPE. Matching on message substrings
/// (`'Failed to fetch'`, `'SocketException'`) was engine-specific: `package:http`
/// re-throws the browser's own `TypeError` text (`browser_client.dart`
/// `_toClientException`), so those literals only ever matched Chromium and
/// `dart:io`, and every WebKit network failure — plus every timeout — fell
/// through to [AuthStatusCode.unexpectedError].
AuthStatusCode classifyAuthFailure(
  Object error, {
  required AuthAttempt attempt,
}) {
  if (error is ApiException) {
    final looksLikePassword = error.message.toLowerCase().contains('password');
    return switch (error.statusCode) {
      400 || 422 =>
        (attempt == AuthAttempt.register && !looksLikePassword)
            ? AuthStatusCode.usernameInvalid
            : AuthStatusCode.passwordTooWeak,
      401 || 403 => switch (attempt) {
        AuthAttempt.credentialChange => AuthStatusCode.wrongPassword,
        AuthAttempt.recover => AuthStatusCode.phraseRejected,
        _ => AuthStatusCode.invalidCredentials,
      },
      // 423: the recovery-phrase lockout (5 wrong phrases → 1 h).
      423 => AuthStatusCode.tooManyAttempts,
      409 => AuthStatusCode.nicknameTaken,
      429 => AuthStatusCode.tooManyAttempts,
      >= 500 => AuthStatusCode.serverError,
      _ => AuthStatusCode.unexpectedError,
    };
  }

  final lost =
      error is TimeoutException ||
      error is http.ClientException ||
      // dart:io socket errors cannot be type-checked from web-safe code.
      error.toString().contains('SocketException');
  if (lost) return AuthStatusCode.serverUnreachable;
  return AuthStatusCode.unexpectedError;
}

class AuthProvider extends ChangeNotifier {
  AuthProvider({
    ApiService? api,
    AuthTokenStore? tokenStore,
    List<Duration>? tokenReadRetryDelays,
    ContactBackupService? contactBackup,
  }) : _api = api ?? ApiService(baseUrl: AppConfig.baseUrl),
       _tokenReadRetryDelays =
           tokenReadRetryDelays ??
           const [Duration(seconds: 2), Duration(seconds: 5)],
       _tokens = tokenStore ?? AuthTokenStore() {
    _pushService = PushService(_api);
    _contactBackup =
        contactBackup ??
        ContactBackupService(api: _api, tokens: _tokens);
    _loadSavedToken();
  }

  /// Slow second-chance delays when the token store reports `readFailed` at
  /// boot. Injectable so tests need not wait real seconds.
  final List<Duration> _tokenReadRetryDelays;

  final ApiService _api;
  final AuthTokenStore _tokens;
  late final PushService _pushService;

  /// The server-held contact backup (metadata-privacy PR2.4). It lives here
  /// and nowhere else because the account PASSWORD is its door, and the
  /// password exists for exactly the duration of one credential call — this
  /// provider's methods are the only place it is ever in hand.
  late final ContactBackupService _contactBackup;

  /// Handed to `ConnectionProvider.setProviders`, which owns the contact
  /// store the backup mirrors.
  ContactBackupService get contactBackup => _contactBackup;

  String? _token;
  String? _refreshToken;
  UserModel? _currentUser;
  String? _statusMessage;
  AuthStatusCode? _statusCode;
  bool _isError = false;
  Timer? _sessionRefreshTimer;
  Future<void>? _sessionRefreshInFlight;
  bool _isRestoringSession = true;
  String? _lastSessionEndReason;
  String? _recoverableUsername;
  bool _freshRegistration = false;

  static const int _refreshMaxAttempts = 3;
  static const Duration _refreshRetryBaseDelay = Duration(milliseconds: 250);

  /// Wired from [MainShell] so socket/media use refreshed JWT without restart.
  void Function(String accessToken)? onAccessTokenChanged;

  String? get token => _token;
  UserModel? get currentUser => _currentUser;
  String? get statusMessage => _statusMessage;

  /// The status to display, when it is one the provider raised itself.
  /// Localized by the widget layer; takes precedence over [statusMessage].
  AuthStatusCode? get statusCode => _statusCode;
  bool get isError => _isError;
  bool get isRestoringSession => _isRestoringSession;
  bool get isLoggedIn => _token != null && _currentUser != null;

  /// Why the last session ended (e.g. `refresh_invalid`,
  /// `expired_access_without_refresh`). Shown on the auth screen so a victim
  /// screenshot names the exact logout path; null on a clean cold start —
  /// which itself is a signal (wiped storage leaves nothing to clear).
  String? get lastSessionEndReason => _lastSessionEndReason;

  /// The username a failed REGISTER should offer to sign in with, because the
  /// account may already exist under it ([AuthStatusCode.nicknameTaken]) or
  /// does and only the follow-up sign-in failed
  /// ([AuthStatusCode.registerSucceeded]). Null whenever no such offer
  /// applies. The screen uses it to prefill the sign-in tab.
  String? get recoverableUsername => _recoverableUsername;

  /// (lxxxiii) clause 1: true once after [register] ended SIGNED IN with an
  /// account these credentials just created. The Chats screen consumes it to
  /// offer the recovery phrase at the door. Reset by [clearStatus] (the start
  /// of every attempt); the "taken → my credentials opened it" path never
  /// sets it — that is an existing account, which may already hold a phrase.
  bool consumeFreshRegistration() {
    final fresh = _freshRegistration;
    _freshRegistration = false;
    return fresh;
  }

  void setOnAccessTokenChanged(void Function(String)? cb) {
    onAccessTokenChanged = cb;
  }

  /// Test-only: force an expired access JWT while keeping refresh token in memory.
  @visibleForTesting
  void setAccessTokenForTest(String token) {
    _token = token;
    _restoreUserFromAccessJwt(token);
    notifyListeners();
  }

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
        // hydrated profile (profilePhotos, about, profilePictureUrl, ...) and
        // only refresh the identity fields the JWT actually carries. Rebuilding
        // from claims alone would collapse profilePhotos to [] and drop about.
        _currentUser = existing.copyWith(id: id, username: username, tag: tag);
      } else {
        // Cold start or account switch: no fully-hydrated prior profile to
        // trust, so rebuild from claims (preserving prior behavior exactly).
        _currentUser = UserModel(
          id: id,
          username: username,
          tag: tag,
          profilePictureUrl: existing?.profilePictureUrl,
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
    await _tokens.write(access: access, refresh: refresh);
    _restoreUserFromAccessJwt(access);
    onAccessTokenChanged?.call(access);
    // A fresher token for the SAME account: enough to flush an upload a 401
    // parked. A new account arrives through `_adoptSession`, which resolves
    // the row from scratch.
    _contactBackup.onToken(access);
    notifyListeners();
  }

  /// Installs the deviceId-bound session a §5.1 provisioning ceremony
  /// returned in `provisioningCompleted` (spec §12 item (iii)). Same storage
  /// path as login/refresh — a second token path would drift.
  Future<void> adoptProvisionedSession(Map<String, dynamic> tokens) =>
      _persistTokens(tokens);

  Future<void> _silentRefresh() async {
    final r = _refreshToken;
    if (r == null) {
      throw SessionRefreshInvalidException('No refresh token');
    }

    Object? lastTransient;
    for (var attempt = 0; attempt < _refreshMaxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_refreshRetryBaseDelay * attempt);
      }
      try {
        final body = await _api.refreshSession(r);
        await _persistTokens(body);
        return;
      } on SessionRefreshInvalidException {
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
    if (_sessionRefreshInFlight != null) {
      return _sessionRefreshInFlight!;
    }

    final future = _silentRefresh();
    _sessionRefreshInFlight = future;
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
    _logSessionEnd(reason, source: source, error: error);
    _cancelSessionRefreshTimer();
    _isRestoringSession = false;
    _token = null;
    _refreshToken = null;
    _currentUser = null;
    _statusMessage = null;
    _statusCode = null;
    _isError = false;
    if (wipeStoredTokens) {
      // A logout that wipes the store wipes the content key with it, by
      // design: the next password login unwraps it again from the server
      // row. A TRANSIENT session drop (`wipeStoredTokens: false`) leaves
      // both alone — the store is intact and the next boot reuses them.
      await _contactBackup.clear();
      await _tokens.clear();
    }
    await clearPwaAppBadgeOnLogout();
    notifyListeners();
  }

  /// The server revoked THIS device (multi-device spec §5.5 + amendment
  /// (xxvi)): end the session and say why.
  ///
  /// Logout semantics, deliberately not a wipe: the local plaintext store and
  /// the Signal key material are untouched, exactly as on every other logout
  /// path — remote wipe of a revoked device's data is an explicit non-goal
  /// (spec §1). Stored tokens DO go, because the server already deleted that
  /// device's refresh sessions; keeping them would only produce a doomed
  /// refresh on the next cold boot.
  ///
  /// [notice] is the localized explanation, passed in because only the widget
  /// layer holds the locale.
  Future<void> logoutBecauseDeviceRevoked(String notice) async {
    if (_token == null && _currentUser == null) return;
    await _clearLocalAuthState('device_revoked', source: 'deviceRevoked');
    // After the clear, which resets the status surface.
    _statusMessage = notice;
    _statusCode = null;
    _isError = true;
    notifyListeners();
  }

  /// Keeps access JWT valid using the opaque refresh token (messenger-style session).
  Future<void> ensureSessionReady() async {
    await _ensureSessionReadyBody();
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
      await _clearLocalAuthState(
        'refresh_invalid',
        source: 'ensureSessionReady',
        error: e,
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
        unawaited(
          _contactBackup.onSession(userId: restored.id, token: _token!),
        );
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

  /// Proactively slides the sliding refresh session once per cold boot even
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
        await _clearLocalAuthState('refresh_invalid', source: 'boot', error: e);
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
      _currentUser = UserModel.fromJson(userData);
    } on Exception catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        if (_refreshToken != null) {
          try {
            await _refreshSessionLocked();
            if (_token != null) {
              final userData = await _api.fetchMe(_token!);
              _currentUser = UserModel.fromJson(userData);
            }
          } on SessionRefreshInvalidException catch (refreshError) {
            await _clearLocalAuthState(
              'refresh_invalid_after_access_401',
              source: 'boot_fetch_me',
              error: refreshError,
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

  /// Creates the account and SIGNS THE USER IN when it can.
  ///
  /// One tap ends in one of two states: a session, or a one-line reason with
  /// the field to fix. The provider settles every ambiguous outcome itself
  /// instead of describing it to the user:
  ///
  /// - 201 → sign in with the same credentials.
  /// - 409 → sign in with the same credentials (a taken name is the SHAPE of
  ///   an earlier lost answer: that request still created the account). Only
  ///   when that sign-in is refused is the name reported as taken.
  /// - answer lost → sign in with the same credentials, which settles whether
  ///   the lost request created the account (`Future.timeout` cannot abort it,
  ///   so the row can be committed while the client saw only a failure). A
  ///   refused sign-in means the server is back and the account is not ours,
  ///   so the register is retried ONCE — a 409 there lands in the branch
  ///   above. Only a second lost answer is reported, as
  ///   [AuthStatusCode.serverUnreachable].
  ///
  /// Production shape this replaces (2026-09-08, iPhone Safari): the first
  /// POST after resuming the tab hung on a dead socket, the 15 s timeout fired
  /// and the user read a paragraph about the account "maybe existing" as a
  /// server outage. The retry he then made succeeded on its own.
  ///
  /// Returns true when the account now exists AND belongs to these credentials,
  /// including the case where the follow-up sign-in failed
  /// ([AuthStatusCode.registerSucceeded]); the caller checks [isLoggedIn] to
  /// know whether it also has a session.
  Future<bool> register(String username, String password) async {
    clearStatus();
    var code = await _register(username, password);

    if (code == AuthStatusCode.serverUnreachable) {
      // The lost request is the one that created the account in every case
      // seen in the field (2026-09-08); a pre-existing account with the same
      // credentials is caught downstream by `hasIdentityBackup`.
      _freshRegistration = true;
      final signIn = await _signIn(username, password);
      if (signIn == null) return true;
      _freshRegistration = false;
      if (signIn == AuthStatusCode.serverUnreachable) {
        _report(signIn);
        return false;
      }
      code = await _register(username, password);
    }

    // One ordinary login attempt, on the same throttle as the login form —
    // not a new oracle. If it opens the account, it was ours.
    if (code == AuthStatusCode.nicknameTaken &&
        await _signIn(username, password) == null) {
      return true;
    }

    if (code != null) {
      _recoverableUsername = code == AuthStatusCode.nicknameTaken
          ? username
          : null;
      _report(code);
      return false;
    }

    // The account exists from here on: never report a failure for it.
    _freshRegistration = true;
    if (await _signIn(username, password) != null) {
      _recoverableUsername = username;
      _statusCode = AuthStatusCode.registerSucceeded;
      _isError = false;
      notifyListeners();
    }
    return true;
  }

  /// Signs in; a lost answer is retried ONCE before being reported, because
  /// the request is idempotent and the first request after a resumed tab is
  /// the one that hangs.
  Future<bool> login(String identifier, String password) async {
    clearStatus();
    var code = await _signIn(identifier, password);
    if (code == AuthStatusCode.serverUnreachable) {
      code = await _signIn(identifier, password);
    }
    if (code == null) return true;
    _report(code);
    return false;
  }

  /// The recovery phrase as a credential (spec (lxxxii) clause 2): sets a new
  /// password and signs in with the session the server answers with. A lost
  /// answer is retried ONCE: the call is idempotent in effect — the same new
  /// password set twice, sessions dropped twice — and the retry spends one of
  /// the 5 / 15 min attempts, which a lost answer already cost.
  Future<bool> recoverPassword(
    String identifier,
    String phrase,
    String newPassword,
  ) async {
    clearStatus();
    var code = await _recover(identifier, phrase, newPassword);
    if (code == AuthStatusCode.serverUnreachable) {
      code = await _recover(identifier, phrase, newPassword);
    }
    if (code == null) return true;
    _report(code);
    return false;
  }

  Future<AuthStatusCode?> _recover(
    String identifier,
    String phrase,
    String newPassword,
  ) async {
    try {
      await _adoptSession(
        await _api.recoverPassword(identifier, phrase, newPassword),
        password: newPassword,
        phrase: phrase,
      );
      return null;
    } catch (e) {
      return classifyAuthFailure(e, attempt: AuthAttempt.recover);
    }
  }

  /// Null when the account was created, else why not.
  Future<AuthStatusCode?> _register(String username, String password) async {
    try {
      await _api.register(username, password);
      return null;
    } catch (e) {
      return classifyAuthFailure(e, attempt: AuthAttempt.register);
    }
  }

  /// Null when signed in (session persisted, user loaded), else why not.
  Future<AuthStatusCode?> _signIn(String identifier, String password) async {
    try {
      await _adoptSession(
        await _api.login(identifier, password),
        password: password,
      );
      return null;
    } catch (e) {
      return classifyAuthFailure(e, attempt: AuthAttempt.login);
    }
  }

  /// Persists the tokens a credential door answered with, loads the user, and
  /// clears every status: from here the shell takes over.
  Future<void> _adoptSession(
    Map<String, dynamic> body, {
    String? password,
    String? phrase,
  }) async {
    await _persistTokens(body);
    final userData = await _api.fetchMe(_token!);
    _currentUser = UserModel.fromJson(userData);

    _statusMessage = null;
    _statusCode = null;
    _recoverableUsername = null;
    _isError = false;
    _startSessionRefreshTimer();
    // PR2.4: the ONLY moment the account password exists in this process.
    // Deliberately not awaited — PBKDF2-600k is 1-2 s on a phone and the
    // shell must not wait for it; `ConnectionProvider.connect()` awaits
    // `ContactBackupService.ready` inside its own budget before the socket.
    unawaited(
      _contactBackup.onSession(
        userId: _currentUser!.id,
        token: _token!,
        password: password,
        phrase: phrase,
      ),
    );
    notifyListeners();
  }

  void _report(AuthStatusCode code) {
    _statusCode = code;
    _isError = true;
    notifyListeners();
  }

  Future<void> logout() async {
    if (_token != null) {
      await _pushService.unregister(_token!);
    }

    final rt = _refreshToken;
    if (rt != null) {
      try {
        await _api.logoutRefresh(rt);
      } catch (_) {}
    }

    await _clearLocalAuthState('explicit_logout', source: 'logout');
  }

  void clearStatus() {
    _statusMessage = null;
    _statusCode = null;
    _recoverableUsername = null;
    _freshRegistration = false;
    _isError = false;
    notifyListeners();
  }

  Future<void> updateProfilePicture(XFile imageFile) async {
    if (_token == null) {
      throw Exception('Not authenticated');
    }

    try {
      await _api.uploadProfilePicture(_token!, imageFile);

      final userData = await _api.fetchMe(_token!);
      _currentUser = UserModel.fromJson(userData);
      notifyListeners();
    } catch (e) {
      throw Exception(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> setPrimaryProfilePhoto(int photoId) async {
    if (_token == null || _currentUser == null) {
      throw Exception('Not authenticated');
    }
    final photos = await _api.setPrimaryProfilePhoto(_token!, photoId);
    final primary = photos.firstWhere((photo) => photo.isPrimary);
    _currentUser = _currentUser!.copyWith(
      profilePhotos: photos,
      profilePictureUrl: primary.url,
    );
    notifyListeners();
  }

  /// Persists an explicit photo order; the first id becomes the primary
  /// photo (backend contract for POST /users/profile-photos/order).
  Future<void> reorderProfilePhotos(List<int> orderedIds) async {
    if (_token == null || _currentUser == null) {
      throw Exception('Not authenticated');
    }
    final photos = await _api.reorderProfilePhotos(_token!, orderedIds);
    final primary = photos.firstWhere((photo) => photo.isPrimary);
    _currentUser = _currentUser!.copyWith(
      profilePhotos: photos,
      profilePictureUrl: primary.url,
    );
    notifyListeners();
  }

  Future<void> deleteProfilePhoto(int photoId) async {
    if (_token == null || _currentUser == null) {
      throw Exception('Not authenticated');
    }
    final photos = await _api.deleteProfilePhoto(_token!, photoId);
    final primary = photos.where((photo) => photo.isPrimary).firstOrNull;
    _currentUser = _currentUser!.copyWith(
      profilePhotos: photos,
      profilePictureUrl: primary?.url,
      clearProfilePicture: primary == null,
    );
    notifyListeners();
  }

  Future<void> updateProfileAbout(String? about) async {
    if (_token == null || _currentUser == null) {
      throw Exception('Not authenticated');
    }
    final savedAbout = await _api.updateProfileAbout(_token!, about);
    _currentUser = _currentUser!.copyWith(
      about: savedAbout,
      clearAbout: savedAbout == null,
    );
    notifyListeners();
  }

  /// Changes the password and ends the session. Failures propagate UNWRAPPED —
  /// re-wrapping them as `Exception(text)` (what this did until 2026-09-06)
  /// destroyed the [ApiException] status, and the Settings surface could then
  /// only print the raw string after "Password reset failed".
  Future<void> resetPassword(String oldPassword, String newPassword) async {
    if (_token == null) {
      throw Exception('Not authenticated');
    }
    // PR2.4, and the ORDER is the whole point: `setPassword` revokes every
    // token server-side, so a wrap uploaded after it would have no session
    // to ride. Additive — the old wrap stays until each device proves the
    // new one at its next login — and a refusal only costs the backup one
    // password change, never the graph.
    await _contactBackup.addWrap(
      kind: ContactWrapKind.password,
      secret: newPassword,
    );
    await _api.resetPassword(_token!, oldPassword, newPassword);
    await _clearLocalAuthState('password_changed', source: 'resetPassword');
  }

  /// Deletes the account and logs out. Failures propagate unwrapped, same
  /// reason as [resetPassword].
  Future<bool> deleteAccount(String password) async {
    if (_token == null) {
      throw Exception('Not authenticated');
    }
    await _api.deleteAccount(_token!, password);
    await logout();
    return true;
  }

  @override
  void dispose() {
    _cancelSessionRefreshTimer();
    super.dispose();
  }
}
