/// The "confirm your password to protect your contacts" ask (metadata-privacy
/// decisions R76 and 94).
///
/// A contact-backup row is minted only when a password is typed, and a
/// 365-day sliding session never types one, so most accounts had none. Until
/// the row exists the app asks at every open and keeps a red line on the chat
/// list; the ask can always be dismissed and never blocks the app (decision
/// 94: a user signed in for months may not know the password). After
/// [kContactBackupLaterLimit] dismissals on this install both stop (decision
/// 95); a password login still mints the row.
const int kContactBackupLaterLimit = 5;

/// Whether the sheet and the red line are due: the server answered that this
/// account has no backup row (a failed GET never asks), and this install has
/// counted fewer than [kContactBackupLaterLimit] "Later"s (null = not loaded
/// yet, not due).
bool shouldAskForContactBackup({
  required bool awaitsPassword,
  required int? laters,
}) => awaitsPassword && laters != null && laters < kContactBackupLaterLimit;

/// What confirming the password came to.
enum ContactBackupPromptResult {
  /// The row exists and this device's contacts are on the server.
  saved,

  /// The server refused the password; nothing was minted.
  wrongPassword,

  /// The check or the upload did not complete (offline, throttled, an older
  /// server without the route); nothing the user typed was wrong.
  unavailable,
}
