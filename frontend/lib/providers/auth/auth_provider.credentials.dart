part of '../auth_provider.dart';

// The moved bodies call `notifyListeners()`, which is `@protected` on
// `ChangeNotifier`: an extension is outside the class as far as the analyzer
// is concerned, though it is the same library.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Credential doors: the single calls behind `register`, `login` and
/// `recoverPassword`, and the session adoption they end in.
extension AuthCredentialDoors on AuthProvider {
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
    _currentUser = _withOwnAvatar(UserModel.fromJson(userData));

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
      _resolveContactBackup(
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
}
