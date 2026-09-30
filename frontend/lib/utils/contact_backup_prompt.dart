/// The one-time "confirm your password to protect your contacts" sheet
/// (metadata-privacy decision 76).
///
/// A contact-backup row is minted only when a password is typed, and a
/// 365-day sliding session never types one, so most accounts had none. The
/// sheet asks once per app open until the row exists, then never again.
/// "Later" (or any dismissal) hides it for [kContactBackupPromptSnooze].
const Duration kContactBackupPromptSnooze = Duration(days: 3);

/// Whether the sheet is due: the server answered that this account has no
/// backup row (never "unknown": a failed GET must not prompt), and the user
/// has not snoozed it less than [kContactBackupPromptSnooze] ago.
bool shouldShowContactBackupPrompt({
  required bool awaitsPassword,
  required DateTime? snoozedAt,
  required DateTime now,
}) {
  if (!awaitsPassword) return false;
  if (snoozedAt == null) return true;
  return now.difference(snoozedAt) >= kContactBackupPromptSnooze;
}

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
