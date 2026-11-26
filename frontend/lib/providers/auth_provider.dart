import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jwt_decoder/jwt_decoder.dart';
import '../models/profile_photo.dart';
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
import '../utils/contact_backup_prompt.dart';
import '../utils/download_utils_web.dart'
    if (dart.library.io) '../utils/download_utils_io.dart'
    as download_utils;
import '../utils/e2e_persistent_diag.dart';
import '../widgets/emoji/recent_emoji.dart';
import 'auth/auth_status.dart';

export 'auth/auth_status.dart';

part 'auth/auth_provider.credentials.dart';
part 'auth/auth_provider.session.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider({
    ApiService? api,
    AuthTokenStore? tokenStore,
    List<Duration>? tokenReadRetryDelays,
    ContactBackupService? contactBackup,
    bool? rotateRefreshTokens,
  }) : _api = api ?? ApiService(baseUrl: AppConfig.baseUrl),
       _tokenReadRetryDelays =
           tokenReadRetryDelays ??
           const [Duration(seconds: 2), Duration(seconds: 5)],
       _tokens = tokenStore ?? AuthTokenStore(),
       _rotateRefreshTokens = rotateRefreshTokens ?? !kIsWeb {
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
  final PushService _pushService = PushService();

  /// Native asks every refresh to rotate the refresh token (plan B4). Web
  /// does not: its tabs each hold the token in memory and would race each
  /// other's rotations, and the PWA is frozen (plan section 0).
  final bool _rotateRefreshTokens;

  /// Whether the store holds [_refreshToken]. A refused write leaves the
  /// previous token there, and the server ends a session whose token is two
  /// rotations old: so until a write lands again, refreshes keep the token
  /// they hold (no rotation) instead of moving further past the stored one.
  bool _refreshPersisted = true;

  /// The server-held contact backup (metadata-privacy PR2.4). It lives here
  /// and nowhere else because the account PASSWORD is its door, and the
  /// password exists for exactly the duration of one credential call — this
  /// provider's methods are the only place it is ever in hand.
  late final ContactBackupService _contactBackup;

  /// Handed to `ConnectionProvider.setProviders`, which owns the contact
  /// store the backup mirrors.
  ContactBackupService get contactBackup => _contactBackup;

  bool _disposed = false;

  /// Resolves the backup row, then tells listeners: the chat list's red line
  /// reads [contactBackupAwaitsPassword] (decision 94). Never throws.
  Future<void> _resolveContactBackup({
    required int userId,
    required String token,
    String? password,
    String? phrase,
  }) async {
    await _contactBackup.onSession(
      userId: userId,
      token: token,
      password: password,
      phrase: phrase,
    );
    if (!_disposed) notifyListeners();
  }

  String? _token;
  String? _refreshToken;
  UserModel? _currentUser;

  /// This account's own end-to-end photo (decision 138). The server never
  /// states it, so it is held here apart from [_currentUser]: every profile
  /// re-fetch rebuilds that from `/users/me`, and the photo must survive it.
  /// Told by the contact store that holds it ([adoptOwnAvatar]).
  ProfilePhotoRef? _ownAvatar;
  String? _statusMessage;
  AuthStatusCode? _statusCode;
  bool _isError = false;
  Timer? _sessionRefreshTimer;
  Future<void>? _sessionRefreshInFlight;
  int _sessionRefreshInFlightEpoch = 0;

  /// Bumped when a session ends ([logout] start, [_clearLocalAuthState]). A
  /// refresh that began under an older value belongs to a session the user
  /// or the server already ended: its answer is dropped, never persisted.
  int _sessionEpoch = 0;
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

  /// Issue #234: the account whose session the server refused as
  /// `Device revoked` on THIS install; set only while the install's stored
  /// session was still the refused one. Its queues (keys in this install's
  /// contact store) must go; only the widget layer can reach the connection
  /// that deletes them, so it takes this once.
  int? _revokedDeviceAccount;

  /// Takes the account set by a `Device revoked` refresh answer, once.
  int? takeRevokedDeviceAccount() {
    final userId = _revokedDeviceAccount;
    _revokedDeviceAccount = null;
    return userId;
  }

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

  /// Installs the deviceId-bound session a §5.1 provisioning ceremony
  /// returned in `provisioningCompleted` (spec §12 item (iii)). Same storage
  /// path as login/refresh — a second token path would drift.
  Future<void> adoptProvisionedSession(Map<String, dynamic> tokens) {
    // The old session's refresh still in flight must not overwrite it.
    _sessionEpoch++;
    return _persistTokens(tokens);
  }

  /// The server revoked THIS device (multi-device spec §5.5 + amendment
  /// (xxvi)): end the session and say why.
  ///
  /// Logout semantics, deliberately not a wipe: the local plaintext store and
  /// the Signal key material are untouched — remote wipe of a revoked
  /// device's data is an explicit non-goal (spec §1). Stored tokens DO go,
  /// because the server already deleted that device's refresh sessions;
  /// keeping them would only produce a doomed refresh on the next cold boot.
  /// The files the user saved out of chats are deleted too, as on every other
  /// session end that wipes the token store (A3-MSG-A-04): they are plaintext
  /// outside every store.
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

  Future<void> logout() async {
    _sessionEpoch++;
    _cancelSessionRefreshTimer();
    if (_token != null) {
      await _pushService.unregister();
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

  /// The contact store told us this account's own photo reference (a photo,
  /// the cleared state, or none): what every screen that shows "me" reads
  /// from [currentUser]. A reference alone never leaves the device.
  void adoptOwnAvatar(ProfilePhotoRef? avatar) {
    if (_ownAvatar == avatar) return;
    _ownAvatar = avatar;
    final user = _currentUser;
    if (user != null) {
      _currentUser = avatar == null
          ? user.copyWith(clearAvatar: true)
          : user.copyWith(avatar: avatar);
    }
    if (!_disposed) notifyListeners();
  }

  UserModel _withOwnAvatar(UserModel user) =>
      _ownAvatar == null ? user : user.copyWith(avatar: _ownAvatar);

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

  /// Decision R76: the server answered that this account has no contact
  /// backup and this session cannot mint one without a password.
  bool get contactBackupAwaitsPassword => _contactBackup.awaitsPasswordToMint;

  /// Settles when the login-time backup resolve is done.
  Future<void> get contactBackupReady => _contactBackup.ready;

  /// Decision R76: verifies [password] against the account WITHOUT a session
  /// (a wrap made from a mistyped string would lock the backup for good),
  /// then mints the backup row under it and uploads this device's contacts.
  Future<ContactBackupPromptResult> confirmPasswordForContactBackup(
    String password,
  ) async {
    await ensureSessionReady();
    final token = _token;
    if (token == null) return ContactBackupPromptResult.unavailable;
    try {
      await _api.verifyPassword(token, password);
    } on ApiException catch (e) {
      // 403 = wrong password; 401 is an expired token, not the user's mistake.
      return e.statusCode == 403
          ? ContactBackupPromptResult.wrongPassword
          : ContactBackupPromptResult.unavailable;
    } on Object {
      return ContactBackupPromptResult.unavailable;
    }
    final saved = await _contactBackup.mintFromPassword(password);
    if (!_disposed) notifyListeners();
    return saved
        ? ContactBackupPromptResult.saved
        : ContactBackupPromptResult.unavailable;
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
    // new one at its next login.
    //
    // A REFUSED re-wrap is not cosmetic. Once the server accepts the new
    // password the old one is gone, and no later session can then produce a
    // wrap that opens the existing row: the backup would be locked forever
    // and the next storage loss would take the graph with it. So the change
    // is ABORTED — but only when there is something to lose, or when we do
    // not KNOW. With no row (the server answered 404), or a row this session
    // could not open anyway, the password change takes nothing away, and
    // holding a security action hostage to a backup that does not exist would
    // be the worse bug. A GET that FAILED is the third case and was missed
    // until the G2 review (M1, 2026-09-21): it is ignorance, not absence, so
    // it aborts too — otherwise one transient 502 at login plus a password
    // change in the same session locks the account's backup permanently,
    // because `_clearLocalAuthState` then destroys the cached content key.
    final rewrapped = await _contactBackup.addWrap(
      kind: ContactWrapKind.password,
      secret: newPassword,
    );
    if (!rewrapped &&
        (_contactBackup.holdsOpenableBackup ||
            _contactBackup.rowStatusUnknown)) {
      throw ContactBackupRewrapRefused();
    }
    try {
      await _api.resetPassword(_token!, oldPassword, newPassword);
    } on Object {
      // The server refused — almost always a wrong OLD password. The wrap we
      // just published is derived from a string the server never accepted as
      // this account's password, and leaving it live is a second door to the
      // content key made of whatever the user typed. Retract it; a failure
      // here changes nothing, because the next successful password login
      // prunes every wrap that password does not open.
      await _contactBackup.retractWrap(kind: ContactWrapKind.password);
      rethrow;
    }
    await _clearLocalAuthState('password_changed', source: 'resetPassword');
  }

  /// Deletes the account and logs out, in this order (decision 113, E114h):
  ///
  /// 1. The session is made ready and [password] is checked FIRST, with
  ///    `POST /users/verify-password` (no side effect). The server checks it
  ///    again only at `DELETE /users/account`, so anything that tells other
  ///    people before this would tell every friend goodbye on a mistyped
  ///    password. A wrong one throws that [ApiException] unchanged and
  ///    NOTHING else happens: no [beforeDelete], no delete.
  /// 2. [beforeDelete] — the goodbyes over the box and the retired queues
  ///    (`MessagingProvider.goodbyeToBoxFriends`). Best effort: whatever it
  ///    throws is swallowed, so it can never hold the delete (E114i). It runs
  ///    BEFORE the delete because after it the app tears itself down
  ///    (`logout`, `clearEncryptionKeys`, `disconnect`) and the box work
  ///    could not follow.
  /// 3. `DELETE /users/account` with the token held NOW (the check, or a
  ///    refresh during [beforeDelete], may have replaced it).
  /// 4. [logout].
  ///
  /// Failures of 1 and 3 propagate unwrapped, same reason as
  /// [resetPassword]. A delete that fails after [beforeDelete] leaves the
  /// friends told and this device's queues retired: a retry finishes it.
  Future<bool> deleteAccount(
    String password, {
    Future<void> Function()? beforeDelete,
  }) async {
    await ensureSessionReady();
    final checked = _token;
    if (checked == null) {
      throw Exception('Not authenticated');
    }
    await _api.verifyPassword(checked, password);
    if (beforeDelete != null) {
      try {
        await beforeDelete();
      } on Object {
        // Best effort (E114i): a box that is down or a friend that cannot be
        // told must never keep the account from being deleted.
      }
    }
    final token = _token;
    if (token == null) {
      throw Exception('Not authenticated');
    }
    await _api.deleteAccount(token, password);
    await logout();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSessionRefreshTimer();
    super.dispose();
  }
}
