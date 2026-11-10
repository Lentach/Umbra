import '../providers/auth_provider.dart';
import 'app_localizations.dart';

/// The words for an [AuthStatusCode], in the user's locale.
///
/// One mapping shared by every credential surface (the front door and the
/// Settings password/delete dialogs) so a refusal reads the same wherever the
/// user meets it, and so a newly added code cannot be localized in one place
/// and left generic in another — this switch is exhaustive, so the analyzer
/// fails the build instead.
String authStatusText(AppLocalizations l10n, AuthStatusCode code) {
  return switch (code) {
    AuthStatusCode.savedSessionUnreadable =>
      l10n.authStatusSavedSessionUnreadable,
    AuthStatusCode.registerSucceeded => l10n.authStatusRegisterSucceeded,
    AuthStatusCode.nicknameTaken => l10n.authStatusNicknameTaken,
    AuthStatusCode.usernameInvalid => l10n.authStatusUsernameInvalid,
    AuthStatusCode.passwordTooWeak => l10n.authStatusPasswordTooWeak,
    AuthStatusCode.invalidCredentials => l10n.authStatusInvalidCredentials,
    AuthStatusCode.wrongPassword => l10n.authStatusWrongPassword,
    AuthStatusCode.tooManyAttempts => l10n.authStatusTooManyAttempts,
    AuthStatusCode.serverError => l10n.authStatusServerError,
    AuthStatusCode.phraseRejected => l10n.authStatusPhraseRejected,
    AuthStatusCode.serverUnreachable => l10n.authStatusServerUnreachable,
    AuthStatusCode.unexpectedError => l10n.authStatusUnexpectedError,
    AuthStatusCode.deviceRevoked => l10n.deviceRevokedNotice,
  };
}
