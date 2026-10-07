/// The "confirm your password to protect your contacts" ask (metadata-privacy
/// decisions R76 and 94).
///
/// A contact-backup row is minted only when a password is typed, and a
/// 365-day sliding session never types one, so most accounts had none. Until
/// the row exists the app asks at every open and keeps a red line on the chat
/// list; the ask can always be dismissed and never blocks the app (decision
/// 94: a user signed in for months may not know the password).
///
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
