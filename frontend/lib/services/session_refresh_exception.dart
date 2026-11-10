/// Refresh failed because the opaque refresh token is invalid, expired, or revoked.
class SessionRefreshInvalidException implements Exception {
  SessionRefreshInvalidException([
    this.message = 'Invalid or expired refresh token',
  ]) : deviceRevoked = false;

  /// The server answered `401 {message: 'Device revoked'}` (decision 130).
  SessionRefreshInvalidException.revokedDevice()
    : message = 'Device revoked',
      deviceRevoked = true;

  final String message;

  /// THIS device was revoked. The only refusal that means it; every other
  /// one is a plain end of the session (logout, password change, expiry).
  final bool deviceRevoked;

  @override
  String toString() => message;
}

/// Refresh failed due to network, timeout, or server errors — session may still be valid.
class SessionRefreshTransientException implements Exception {
  SessionRefreshTransientException([this.message = 'Transient session refresh failure']);

  final String message;

  @override
  String toString() => message;
}
