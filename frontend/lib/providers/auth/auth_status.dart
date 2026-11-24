/// @docImport '../auth_provider.dart';
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import '../../services/api_exception.dart';
import '../../services/contacts/contact_backup_service.dart';

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

  /// The server answered the session refresh `Device revoked` (issue #234):
  /// this device was removed from the account while the app was closed.
  /// The same notice the account socket's `deviceRevoked` shows.
  deviceRevoked,
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
  // The one refusal in the password-change door that is genuinely RETRYABLE:
  // the server-held contact backup could not be re-wrapped, so the change was
  // aborted rather than orphaning the row. `unexpectedError` would render it
  // as a generic fault indistinguishable from a bug; `serverUnreachable`
  // already says the true and actionable thing ("try again when you are
  // online"). Classified before `ApiException` because it is not one.
  if (error is ContactBackupRewrapRefused) {
    return AuthStatusCode.serverUnreachable;
  }
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
