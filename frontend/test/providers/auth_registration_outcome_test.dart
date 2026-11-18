import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_exception.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/recovery_phrase.dart';

// exp 9999999999; the client never verifies the signature.
const _accessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoibWEwaSIsInRhZyI6IjUyNjkiLCJleHAiOjk5OTk5OTk5OTl9.abc';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'Content-Type': 'application/json'},
);

AuthProvider _provider(http.Client client) =>
    AuthProvider(api: ApiService(baseUrl: 'http://localhost:3999', httpClient: client));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // What a senior dev hit in production: register → 409 → "Coś poszło nie tak"
  // → he picked a different name. The account was HIS. Every assertion here is
  // about what the surface can now say and offer.
  group('registration outcome is explained, not swallowed', () {
    test('a taken name that opens with these credentials signs the user in',
        () async {
      // The friend's ACTUAL situation: his first register committed the row,
      // its answer was lost, and his retry hit 409. The password he just typed
      // is the account's password, so the retry can simply land him inside.
      final auth = _provider(
        MockClient((req) async => switch (req.url.path) {
              '/auth/register' =>
                _json({'message': 'nickname is already taken'}, 409),
              '/auth/login' =>
                _json({'access_token': _accessJwt, 'refresh_token': 'r'}, 200),
              '/users/me' =>
                _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
              _ => throw StateError('unexpected ${req.url.path}'),
            }),
      );

      expect(await auth.register('ma0i', 'Password1'), isTrue);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.statusCode, isNull);
      expect(auth.recoverableUsername, isNull);
      // (lxxxiii) clause 1 / F42: an EXISTING account is not a fresh one —
      // it may already hold a phrase, so no offer at the door.
      expect(auth.consumeFreshRegistration(), isFalse);
    });

    test("someone else's name is named, and offers the sign-in door",
        () async {
      final auth = _provider(
        MockClient((req) async => switch (req.url.path) {
              '/auth/register' =>
                _json({'message': 'nickname is already taken'}, 409),
              // Not this user's account: the credentials do not open it.
              '/auth/login' => _json({'message': 'Invalid credentials'}, 401),
              _ => throw StateError('unexpected ${req.url.path}'),
            }),
      );

      expect(await auth.register('maoi', 'Password1'), isFalse);
      expect(auth.isLoggedIn, isFalse);
      expect(auth.statusCode, AuthStatusCode.nicknameTaken);
      expect(auth.recoverableUsername, 'maoi');
    });

    test('a successful registration signs the user in, no second step',
        () async {
      final calls = <String>[];
      final auth = _provider(
        MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          return switch (req.url.path) {
            '/auth/register' => _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 201),
            '/auth/login' =>
              _json({'access_token': _accessJwt, 'refresh_token': 'r'}, 200),
            '/users/me' =>
              _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
            _ => throw StateError('unexpected ${req.url.path}'),
          };
        }),
      );

      expect(await auth.register('ma0i', 'Password1'), isTrue);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.username, 'ma0i');
      // Nothing left on screen to interpret: no status, no recovery offer.
      expect(auth.statusCode, isNull);
      expect(auth.recoverableUsername, isNull);
      expect(calls, contains('POST /auth/login'));
      // (lxxxiii) clause 1: the Chats screen offers the phrase exactly once.
      expect(auth.consumeFreshRegistration(), isTrue);
      expect(auth.consumeFreshRegistration(), isFalse);
    });

    test(
        'a created account whose auto sign-in fails still reports success and '
        'hands the username to the login tab', () async {
      final auth = _provider(
        MockClient((req) async => switch (req.url.path) {
              '/auth/register' => _json({'id': 7, 'username': 'nowy'}, 201),
              // e.g. the login throttle after several attempts.
              '/auth/login' => _json({'message': 'ThrottlerException'}, 429),
              _ => throw StateError('unexpected ${req.url.path}'),
            }),
      );

      expect(await auth.register('nowy', 'Password1'), isTrue);
      expect(auth.isLoggedIn, isFalse);
      expect(auth.statusCode, AuthStatusCode.registerSucceeded);
      expect(auth.isError, isFalse);
      expect(auth.recoverableUsername, 'nowy');
    });

    // 2026-09-08, iPhone Safari resumed from the background: the first POST
    // hung on a dead socket, the 15 s timeout fired, and the user read the
    // "account may already exist" paragraph as a server outage. The provider
    // settles that itself now — the user never sees the ambiguity.
    group('a lost register answer is settled by the provider', () {
      test('the lost request DID create the account: sign-in lands inside',
          () async {
        var registers = 0;
        final auth = _provider(
          MockClient((req) async {
            switch (req.url.path) {
              case '/auth/register':
                registers++;
                throw TimeoutException('x');
              case '/auth/login':
                return _json(
                    {'access_token': _accessJwt, 'refresh_token': 'r'}, 200);
              case '/users/me':
                return _json(
                    {'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200);
              default:
                throw StateError('unexpected ${req.url.path}');
            }
          }),
        );

        expect(await auth.register('ma0i', 'Password1'), isTrue);
        expect(auth.isLoggedIn, isTrue);
        expect(auth.statusCode, isNull);
        expect(registers, 1, reason: 'no blind re-register once signed in');
        // (lxxxiii) clause 1: the lost request created it — offer the phrase.
        expect(auth.consumeFreshRegistration(), isTrue);
      });

      test('the lost request did NOT create it: register is retried once',
          () async {
        var registers = 0;
        var logins = 0;
        final auth = _provider(
          MockClient((req) async => switch (req.url.path) {
                '/auth/register' => ++registers == 1
                    ? throw TimeoutException('x')
                    : _json({'id': 7, 'username': 'ma0i'}, 201),
                // First: the settling probe, refused — no such account yet.
                // Second: the sign-in after the retried register.
                '/auth/login' => ++logins == 1
                    ? _json({'message': 'Invalid credentials'}, 401)
                    : _json(
                        {'access_token': _accessJwt, 'refresh_token': 'r'},
                        200),
                '/users/me' =>
                  _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
                _ => throw StateError('unexpected ${req.url.path}'),
              }),
        );

        expect(await auth.register('ma0i', 'Password1'), isTrue);
        expect(auth.isLoggedIn, isTrue);
        expect(auth.statusCode, isNull);
        expect(registers, 2);
      });

      test('a retried register that meets 409 still opens with the credentials',
          () async {
        // The lost request created the row AFTER the settling probe was
        // refused (they raced). The retry's 409 lands in the taken branch,
        // whose sign-in now succeeds.
        var registers = 0;
        var logins = 0;
        final auth = _provider(
          MockClient((req) async => switch (req.url.path) {
                '/auth/register' => ++registers == 1
                    ? throw TimeoutException('x')
                    : _json({'message': 'nickname is already taken'}, 409),
                '/auth/login' => ++logins == 1
                    ? _json({'message': 'Invalid credentials'}, 401)
                    : _json(
                        {'access_token': _accessJwt, 'refresh_token': 'r'},
                        200),
                '/users/me' =>
                  _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
                _ => throw StateError('unexpected ${req.url.path}'),
              }),
        );

        expect(await auth.register('ma0i', 'Password1'), isTrue);
        expect(auth.isLoggedIn, isTrue);
      });

      test('still no answer on the settling sign-in: one line, no paragraph',
          () async {
        var registers = 0;
        final auth = _provider(
          MockClient((req) async {
            if (req.url.path == '/auth/register') registers++;
            throw TimeoutException('no answer');
          }),
        );

        expect(await auth.register('ma0i', 'Password1'), isFalse);
        expect(auth.statusCode, AuthStatusCode.serverUnreachable);
        expect(auth.recoverableUsername, isNull);
        expect(registers, 1,
            reason: 'a dead connection is not probed with a third request');
      });

      test('a second lost answer is reported, not retried forever', () async {
        var registers = 0;
        final auth = _provider(
          MockClient((req) async {
            switch (req.url.path) {
              case '/auth/register':
                registers++;
                throw TimeoutException('x');
              case '/auth/login':
                return _json({'message': 'Invalid credentials'}, 401);
              default:
                throw StateError('unexpected ${req.url.path}');
            }
          }),
        );

        expect(await auth.register('ma0i', 'Password1'), isFalse);
        expect(auth.statusCode, AuthStatusCode.serverUnreachable);
        expect(registers, 2);
      });
    });
  });

  group('sign-in refusals are distinguishable', () {
    test('wrong password is not "something went wrong"', () async {
      final auth = _provider(
        MockClient((req) async => _json({'message': 'Invalid credentials'}, 401)),
      );

      expect(await auth.login('ma0i', 'nope'), isFalse);
      expect(auth.statusCode, AuthStatusCode.invalidCredentials);
    });

    test(
        'a 401 on a password-only door does not name the username field',
        () async {
      // Settings → change password / delete account ask for a password and
      // nothing else, so "wrong username or password" points at a field the
      // user never touched.
      final err = ApiException(
        statusCode: 401,
        message: 'Invalid credentials',
        endpoint: 'POST /users/reset-password',
      );

      expect(
        classifyAuthFailure(err, attempt: AuthAttempt.credentialChange),
        AuthStatusCode.wrongPassword,
      );
      expect(
        classifyAuthFailure(err, attempt: AuthAttempt.login),
        AuthStatusCode.invalidCredentials,
      );
    });

    test('the rate limit says so', () async {
      final auth = _provider(
        MockClient((req) async => _json({'message': 'ThrottlerException'}, 429)),
      );

      expect(await auth.login('ma0i', 'Password1'), isFalse);
      expect(auth.statusCode, AuthStatusCode.tooManyAttempts);
    });

    test('a backend 502 mid-deploy is a server problem, not a user error',
        () async {
      final auth = _provider(
        MockClient((req) async => http.Response('<html>502</html>', 502)),
      );

      expect(await auth.login('ma0i', 'Password1'), isFalse);
      expect(auth.statusCode, AuthStatusCode.serverError);
    });

    test(
        'a WebKit-worded transport failure is reported as a connection problem',
        () async {
      // The wording is the browser engine's, not a library constant
      // (`package:http` re-throws the TypeError text), so classification must
      // be by TYPE — "Load failed" matched none of the old substrings.
      final auth = _provider(
        MockClient((req) async => throw http.ClientException('Load failed')),
      );

      expect(await auth.login('ma0i', 'Password1'), isFalse);
      expect(auth.statusCode, AuthStatusCode.serverUnreachable);
    });

    test('a lost sign-in answer is retried once, silently', () async {
      var logins = 0;
      final auth = _provider(
        MockClient((req) async {
          switch (req.url.path) {
            case '/auth/login':
              if (++logins == 1) throw TimeoutException('x');
              return _json(
                  {'access_token': _accessJwt, 'refresh_token': 'r'}, 200);
            case '/users/me':
              return _json(
                  {'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200);
            default:
              throw StateError('unexpected ${req.url.path}');
          }
        }),
      );

      expect(await auth.login('ma0i', 'Password1'), isTrue);
      expect(auth.statusCode, isNull);
      expect(logins, 2);
    });

    test('a refused sign-in is NOT retried', () async {
      var logins = 0;
      final auth = _provider(
        MockClient((req) async {
          logins++;
          return _json({'message': 'Invalid credentials'}, 401);
        }),
      );

      expect(await auth.login('ma0i', 'nope'), isFalse);
      expect(logins, 1);
    });
  });

  // Amendment (lxxxii) clause 2 — the recovery phrase as a credential.
  group('recover with the phrase', () {
    const phrase =
        'abandon ability able about above absent absorb abstract absurd abuse access accident';

    test('a correct phrase sets the password and lands the user inside', () async {
      final auth = _provider(
        MockClient((req) async => switch (req.url.path) {
              '/auth/recover' =>
                _json({'access_token': _accessJwt, 'refresh_token': 'r'}, 201),
              '/users/me' =>
                _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
              _ => throw StateError('unexpected ${req.url.path}'),
            }),
      );

      expect(await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x'), isTrue);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.statusCode, isNull);
    });

    test('a refused phrase names the phrase, never a password field', () async {
      // (F35) 401 on this door is "name or phrase"; mapping it to
      // invalidCredentials would point at a password the form never asked for.
      final auth = _provider(
        MockClient((req) async => _json({'message': 'Invalid credentials'}, 401)),
      );

      expect(await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x'), isFalse);
      expect(auth.statusCode, AuthStatusCode.phraseRejected);
    });

    // Plan B7: the account's key predates it. 409 on REGISTER means "name
    // taken"; on this door it means the owner must replace the key.
    test('409 legacy_recovery_key names the old key, not a taken nickname',
        () async {
      final auth = _provider(
        MockClient((req) async => _json({'message': 'legacy_recovery_key'}, 409)),
      );

      expect(await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x'), isFalse);
      expect(auth.statusCode, AuthStatusCode.legacyRecoveryKey);
    });

    test('the request body carries authSecret and never the phrase', () async {
      Map<String, dynamic>? body;
      final auth = _provider(
        MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({'message': 'Invalid credentials'}, 401);
        }),
      );

      await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x');

      expect(body, isNotNull);
      expect(body!.containsKey('phrase'), isFalse);
      expect(body!['authSecret'], RecoveryPhrase.deriveAuthSecret(phrase));
      expect(jsonEncode(body), isNot(contains(phrase)));
    });

    test('the lockout (423) reads as too many attempts', () async {
      final auth = _provider(
        MockClient((req) async => _json({'message': 'recovery_locked'}, 423)),
      );

      expect(await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x'), isFalse);
      expect(auth.statusCode, AuthStatusCode.tooManyAttempts);
    });

    test('a lost answer is retried once, then reported', () async {
      var calls = 0;
      final auth = _provider(
        MockClient((req) async {
          calls++;
          throw TimeoutException('x');
        }),
      );

      expect(await auth.recoverPassword('ma0i#5269', phrase, 'NewPass1x'), isFalse);
      expect(auth.statusCode, AuthStatusCode.serverUnreachable);
      expect(calls, 2);
    });
  });

  group('a status describes the attempt in front of the user', () {
    test('a new attempt clears the previous verdict before it runs', () async {
      // First attempt: a name owned by SOMEONE ELSE (the recovery sign-in is
      // refused), so the taken-name verdict stands and must not outlive it.
      var registerCalls = 0;
      final auth = _provider(
        MockClient((req) async {
          if (req.url.path == '/auth/register') {
            registerCalls++;
            return registerCalls == 1
                ? _json({'message': 'nickname is already taken'}, 409)
                : _json({'id': 8, 'username': 'inny'}, 201);
          }
          return switch (req.url.path) {
            // The recovery sign-in after the first 409 is refused; the one
            // after the second (successful) register is not.
            '/auth/login' => registerCalls >= 2
                ? _json({'access_token': _accessJwt, 'refresh_token': 'r'}, 200)
                : _json({'message': 'Invalid credentials'}, 401),
            '/users/me' => _json({'id': 8, 'username': 'inny'}, 200),
            _ => throw StateError('unexpected ${req.url.path}'),
          };
        }),
      );

      await auth.register('maoi', 'Password1');
      expect(auth.statusCode, AuthStatusCode.nicknameTaken);

      await auth.register('inny', 'Password1');
      expect(auth.statusCode, isNull);
      expect(auth.recoverableUsername, isNull);
    });
  });
}
