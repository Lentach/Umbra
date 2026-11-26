import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';

/// Expired access JWT (exp 1516239022). Signature is not verified client-side.
const _expiredAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjE1MTYyMzkwMjJ9.4Adcj3UFYzPUBaY63_UWOshvRZQZjm7uI9uWGQ8RrXc';

const _validAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjk5OTk5OTk5OTl9.abc';

/// Valid access JWT for a DIFFERENT account (sub=2). Used to prove an account
/// switch does not carry the previous user's hydrated profile over.
const _otherUserAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjIsInVzZXJuYW1lIjoib3RoZXIiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTk5fQ.sig';

Future<void> _waitForAuthSettled(
  AuthProvider auth, {
  required bool expectLoggedIn,
}) async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!auth.isRestoringSession && auth.isLoggedIn == expectLoggedIn) return;
  }
  fail(
    'AuthProvider did not settle (isRestoringSession=${auth.isRestoringSession}, isLoggedIn=${auth.isLoggedIn}, expected=$expectLoggedIn)',
  );
}

// Built at runtime (not a literal): it is the public jwt.io example token —
// zero secret value — but a literal JWT trips the gitleaks pre-commit gate.
final String _builtExpiredAccessJwt = [
  base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}')),
  base64Url.encode(
    utf8.encode('{"sub":1,"username":"test","tag":"0000","exp":1516239022}'),
  ),
  'not-a-real-signature',
].join('.');

class _ThrowingKv implements SecureKv {
  final Map<String, String> data = {};
  bool throwOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw Exception('secure storage unavailable');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(data);
}

ApiService _apiWith(http.Response Function(http.Request) handler) =>
    ApiService(
      baseUrl: 'http://localhost:3999',
      httpClient: MockClient((request) async => handler(request)),
    );

Future<void> _waitRestored(AuthProvider auth) async {
  for (var i = 0; i < 200 && auth.isRestoringSession; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(auth.isRestoringSession, isFalse, reason: 'boot never finished');
}

void main() {
  group('AuthProvider session refresh', () {
    const base = 'http://localhost:3999';

    test('refresh 401 clears auth and stored tokens', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });

      final mock = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(
            jsonEncode({'message': 'Invalid refresh token'}),
            401,
            headers: {'Content-Type': 'application/json'},
          );
        }
        throw Exception('Unexpected ${request.url.path}');
      });

      final auth = AuthProvider(
        api: ApiService(baseUrl: base, httpClient: mock),
      );
      await _waitForAuthSettled(auth, expectLoggedIn: false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
      expect(auth.lastSessionEndReason, 'refresh_invalid');
    });

    test('refresh network error keeps auth with JWT user', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });

      final mock = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(
            jsonEncode({'message': 'Service unavailable'}),
            503,
            headers: {'Content-Type': 'application/json'},
          );
        }
        if (request.url.path == '/users/me') {
          return http.Response(
            jsonEncode({
              'id': 1,
              'username': 'test',
              'tag': '0000',
              'profilePictureUrl': null,
            }),
            200,
            headers: {'Content-Type': 'application/json'},
          );
        }
        throw Exception('Unexpected ${request.url.path}');
      });

      final auth = AuthProvider(
        api: ApiService(baseUrl: base, httpClient: mock),
      );
      await _waitForAuthSettled(auth, expectLoggedIn: true);

      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.username, 'test');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), 'opaque_refresh');
      expect(prefs.getString('jwt_token'), _expiredAccessJwt);
    });
    test(
      'boot with valid access proactively slides refresh session '
      '(with X-App-Commit header) and keeps the user logged in',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        var refreshCalls = 0;
        String? commitHeader;
        final mock = MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshCalls++;
            commitHeader = request.headers['X-App-Commit'] ??
                request.headers['x-app-commit'];
            return http.Response(
              jsonEncode({
                'access_token': _validAccessJwt,
                'refresh_token': 'opaque_refresh',
              }),
              201,
              headers: {'Content-Type': 'application/json'},
            );
          }
          if (request.url.path == '/users/me') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': null,
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          throw Exception('Unexpected ${request.url.path}');
        });

        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: mock),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);
        // The slide is fire-and-forget; give it a beat to land.
        for (var i = 0; i < 20 && refreshCalls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(refreshCalls, 1,
            reason: 'valid-access boot must still slide the sliding session');
        expect(commitHeader, isNotNull,
            reason: 'auth calls must carry build telemetry');
        expect(auth.isLoggedIn, isTrue);
      },
    );

    test(
      'background slide failure (401) NEVER logs out a valid session',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        var refreshServed = 0;
        final mock = MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshServed++;
            return http.Response(
              jsonEncode({'message': 'Invalid refresh token'}),
              401,
              headers: {'Content-Type': 'application/json'},
            );
          }
          if (request.url.path == '/users/me') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': null,
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          throw Exception('Unexpected ${request.url.path}');
        });

        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: mock),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);
        // The slide is fire-and-forget: gate on the mock actually serving the
        // 401 before asserting, or this regression test passes vacuously.
        for (var i = 0; i < 40 && refreshServed == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(refreshServed, greaterThan(0),
            reason: 'boot slide never fired — test setup broken');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(auth.isLoggedIn, isTrue,
            reason: 'revoked-row/transient blip at boot must keep the '
                'still-valid session; only the expiry path may clear it');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('refresh_token'), 'opaque_refresh');
      },
    );

    test('parallel ensureSessionReady performs single refresh call', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });

      var refreshCalls = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return http.Response(
            jsonEncode({
              'access_token': _validAccessJwt,
              'refresh_token': 'rotated_refresh',
            }),
            200,
            headers: {'Content-Type': 'application/json'},
          );
        }
        if (request.url.path == '/users/me') {
          return http.Response(
            jsonEncode({
              'id': 1,
              'username': 'test',
              'tag': '0000',
              'profilePictureUrl': null,
            }),
            200,
            headers: {'Content-Type': 'application/json'},
          );
        }
        throw Exception('Unexpected ${request.url.path}');
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      final auth = AuthProvider(api: api);
      await _waitForAuthSettled(auth, expectLoggedIn: true);
      // Boot performs a proactive background slide when the saved access is
      // valid; wait for its COMPLETION (rotated token persisted), not merely
      // the request being served — resetting mid-flight makes the batch below
      // share the in-flight future and count zero calls.
      for (var i = 0; i < 40; i++) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('refresh_token') == 'rotated_refresh') break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      auth.setAccessTokenForTest(_expiredAccessJwt);
      refreshCalls = 0;
      await Future.wait([
        auth.ensureSessionReady(),
        auth.ensureSessionReady(),
        auth.ensureSessionReady(),
      ]);

      expect(refreshCalls, 1);
      expect(auth.isLoggedIn, isTrue);
    });

    test(
      'startup load and ensureSessionReady share single refresh call',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _expiredAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        var refreshCalls = 0;
        final mock = MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return http.Response(
              jsonEncode({
                'access_token': _validAccessJwt,
                'refresh_token': 'rotated_refresh',
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          if (request.url.path == '/users/me') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': null,
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          throw Exception('Unexpected ${request.url.path}');
        });

        final api = ApiService(baseUrl: base, httpClient: mock);
        final auth = AuthProvider(api: api);
        await Future<void>.delayed(Duration.zero);
        await Future.wait([
          auth.ensureSessionReady(),
          auth.ensureSessionReady(),
        ]);
        await _waitForAuthSettled(auth, expectLoggedIn: true);

        expect(refreshCalls, 1);
      },
    );

    test(
      'password reset clears invalidated local session with reason',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        final mock = MockClient((request) async {
          if (request.url.path == '/users/me') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': null,
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          // This account has no contact backup. Modelled explicitly: an
          // unanswered GET here means "row status UNKNOWN", and a password
          // change then aborts rather than orphaning a row it never saw
          // (`rowStatusUnknown`, G2 review M1). A 404 is the server saying
          // there is nothing to lose, which is what this session test means.
          if (request.url.path == '/backup/contacts') {
            return http.Response('{}', 404);
          }
          if (request.url.path == '/users/reset-password') {
            expect(request.headers['Authorization'], 'Bearer $_validAccessJwt');
            return http.Response('{}', 200);
          }
          throw Exception('Unexpected ${request.url.path}');
        });

        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: mock),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);

        await auth.resetPassword('old-password', 'new-password');

        final prefs = await SharedPreferences.getInstance();
        expect(auth.isLoggedIn, isFalse);
        expect(auth.lastSessionEndReason, 'password_changed');
        expect(prefs.getString('jwt_token'), isNull);
        expect(prefs.getString('refresh_token'), isNull);
      },
    );

    // Mirror image of the test above, and the reason the M1 guard exists
    // (G2 review, 2026-09-21). A FAILED contact-backup GET means the session
    // does not know whether a row exists. Going ahead would let the server
    // accept the new password while the stored row stays wrapped under the
    // old one, which no later session can reproduce — the backup would be
    // locked for good. So the change is ABORTED and the session survives.
    test(
      'password reset is refused while the contact backup is unreachable',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        var resetCalls = 0;
        final mock = MockClient((request) async {
          if (request.url.path == '/users/me') {
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': null,
              }),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          }
          // The server is there but cannot answer: NOT a 404.
          if (request.url.path == '/backup/contacts') {
            return http.Response('{"message":"bad gateway"}', 502);
          }
          if (request.url.path == '/users/reset-password') {
            resetCalls++;
            return http.Response('{}', 200);
          }
          throw Exception('Unexpected ${request.url.path}');
        });

        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: mock),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);

        await expectLater(
          auth.resetPassword('old-password', 'new-password'),
          throwsA(isA<ContactBackupRewrapRefused>()),
        );

        expect(
          resetCalls,
          0,
          reason: 'the password must never reach the server here',
        );
        expect(
          auth.isLoggedIn,
          isTrue,
          reason: 'an aborted change must not end the session',
        );
        expect(
          classifyAuthFailure(
            ContactBackupRewrapRefused(),
            attempt: AuthAttempt.credentialChange,
          ),
          AuthStatusCode.serverUnreachable,
          reason: 'the user is told to retry, not shown a generic fault',
        );
      },
    );

    MockClient meMock() => MockClient((request) async {
      if (request.url.path == '/auth/refresh') {
        return http.Response(
          jsonEncode({
            'access_token': _validAccessJwt,
            'refresh_token': 'opaque_refresh',
          }),
          201,
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (request.url.path == '/users/me') {
        return http.Response(
          jsonEncode({
            'id': 1,
            'username': 'test',
            'tag': '0000',
            'profilePictureUrl': 'https://cdn/p1.jpg',
            'about': 'hello world',
          }),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      }
      throw Exception('Unexpected ${request.url.path}');
    });

    final photo = ProfilePhotoRef(
      rev: 5,
      mediaId: '${'A' * 42}E',
      key: base64Encode(List.filled(32, 1)),
      iv: base64Encode(List.filled(12, 1)),
    );

    test(
      'same-user token restore preserves the hydrated about, the legacy photo '
      'path and the own end-to-end avatar',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });
        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: meMock()),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);
        auth.adoptOwnAvatar(photo);
        expect(auth.currentUser?.avatar, photo);

        // A silent 15-min token refresh re-runs _restoreUserFromAccessJwt for
        // the SAME account; it must not drop about or the photo.
        auth.setAccessTokenForTest(_validAccessJwt);

        expect(auth.currentUser?.id, 1);
        expect(auth.currentUser?.about, 'hello world');
        expect(auth.currentUser?.profilePictureUrl, 'https://cdn/p1.jpg');
        expect(auth.currentUser?.avatar, photo);
      },
    );

    test(
      'a removed own avatar clears from the profile everything shows',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });
        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: meMock()),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);
        expect(auth.currentUser?.avatar, isNull);
        auth.adoptOwnAvatar(photo);
        auth.adoptOwnAvatar(null);
        expect(auth.currentUser?.avatar, isNull);
      },
    );

    test(
      'different-user token restore does not carry over the previous '
      "account's about",
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });
        final auth = AuthProvider(
          api: ApiService(baseUrl: base, httpClient: meMock()),
        );
        await _waitForAuthSettled(auth, expectLoggedIn: true);
        auth.adoptOwnAvatar(photo);

        // Account switch: a JWT for a different user id must NOT inherit the
        // previous account's about.
        auth.setAccessTokenForTest(_otherUserAccessJwt);

        expect(auth.currentUser?.id, 2);
        expect(auth.currentUser?.username, 'other');
        expect(auth.currentUser?.about, isNull);
      },
    );
  });

  // The kicked device's own behaviour (multi-device spec §5.5 + §12 amendment
  // (xxvi)).
  //
  // Logout semantics, deliberately NOT a wipe: remote wipe of a revoked
  // device's local data is an explicit §1 non-goal, and the whole reason the
  // server tells the device before dropping it is so the user reads "this
  // device was removed" instead of a generic connection error.
  group('AuthProvider device revoked', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const base = 'http://localhost:3000';
    const notice = 'This device was removed from your account.';

    /// A far-future access JWT, so boot restores a session without a refresh.
    String validAccessJwt() {
      String seg(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final exp = DateTime.now().add(const Duration(hours: 12));
      return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${seg({'sub': 1, 'exp': exp.millisecondsSinceEpoch ~/ 1000})}.sig';
    }

    MockClient client() => MockClient((req) async {
      if (req.url.path == '/users/me') {
        return http.Response(
          jsonEncode({'id': 1, 'username': 'test', 'tag': '0001'}),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (req.url.path == '/auth/refresh') {
        return http.Response('{}', 500);
      }
      throw Exception('Unexpected ${req.url.path}');
    });

    Future<AuthProvider> loggedIn() async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': validAccessJwt(),
        'refresh_token': 'opaque_refresh',
      });
      final auth = AuthProvider(
        api: ApiService(baseUrl: base, httpClient: client()),
      );
      for (var i = 0; i < 60 && !auth.isLoggedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(auth.isLoggedIn, isTrue, reason: 'boot must restore the session');
      return auth;
    }

    test('ends the session and states the reason', () async {
      final auth = await loggedIn();

      await auth.logoutBecauseDeviceRevoked(notice);

      expect(auth.isLoggedIn, isFalse);
      // The reason survives the clear — the auth screen renders it, and it is
      // the only place the user ever learns WHY the session ended.
      expect(auth.statusMessage, notice);
      expect(auth.isError, isTrue);
    });

    // A3-CMP-09: the picker keeps its recent emoji in SharedPreferences, device
    // wide; the next account on this device must not see them.
    test('a session end that wipes the store clears the recent emoji', () async {
      final auth = await loggedIn();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'recent',
        jsonEncode([
          {'emoji': {'emoji': '😀'}, 'counter': 3},
        ]),
      );

      await auth.logout();

      expect(prefs.getString('recent') ?? '[]', '[]');
    });

    test('is a no-op when no session is held', () async {
      SharedPreferences.setMockInitialValues({});
      final auth = AuthProvider(
        api: ApiService(baseUrl: base, httpClient: client()),
      );

      await auth.logoutBecauseDeviceRevoked(notice);

      // A `deviceRevoked` arriving on a socket that is already logged out must
      // not plant an alarming message on a fresh login screen.
      expect(auth.statusMessage, isNull);
      expect(auth.isError, isFalse);
    });
  });

  // §5.4 provider contract: the auth provider must never convert a storage
  // fault into a logout, and must never let a LOCALLY-derived session end
  // delete the persisted tokens (the manufactured-permanent-logout path —
  // user 54's refresh row was valid to 2027 while he sat on a login screen).
  group('AuthProvider unreadable token store', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // The durable diag cache is static — isolate it or dedup assertions
      // observe records from earlier tests in this group.
      await E2ePersistentDiag.clear();
    });

    test('an unreadable token store concedes the boot WITHOUT a fake logout',
        () async {
      final kv = _ThrowingKv()
        ..data['jwt_token'] = 'intact'
        ..data['refresh_token'] = 'intact'
        ..throwOnRead = true;
      final auth = AuthProvider(
        api: _apiWith((_) => http.Response('unexpected', 500)),
        tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
        tokenReadRetryDelays: const [Duration(milliseconds: 10)],
      );
      await _waitRestored(auth);

      expect(auth.currentUser, isNull);
      expect(auth.isError, isTrue);
      expect(
        auth.statusCode,
        AuthStatusCode.savedSessionUnreadable,
        reason: 'the user is told the truth, not shown a silent login screen',
      );
      expect(
        auth.statusMessage,
        isNull,
        reason:
            'the provider has no locale, so it must never build the prose — the '
            'widget layer maps the code to an ARB string',
      );
      expect(
        kv.data['refresh_token'],
        'intact',
        reason: 'the store is left untouched for the next boot to recover',
      );
      expect(
        auth.lastSessionEndReason,
        isNull,
        reason: 'no session ended — nothing may claim one did',
      );
      auth.dispose();
    });

    test(
        'expired access without refresh clears the SESSION but never the STORE',
        () async {
      final kv = _ThrowingKv()..data['jwt_token'] = _builtExpiredAccessJwt;
      final auth = AuthProvider(
        // fetchMe answers 401: with no refresh token this lands on the
        // locally-derived `access_401_without_refresh` branch.
        api: _apiWith(
          (req) => req.url.path == '/users/me'
              ? http.Response(jsonEncode({'message': 'unauthorized'}), 401)
              : http.Response('unexpected ${req.url.path}', 500),
        ),
        tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
        tokenReadRetryDelays: const [],
      );
      await _waitRestored(auth);

      expect(auth.currentUser, isNull, reason: 'the dead session is cleared');
      expect(
        kv.data['jwt_token'],
        _builtExpiredAccessJwt,
        reason: 'a LOCALLY-derived session end must never delete stored '
            'tokens — only server-authoritative refresh_invalid may',
      );
      expect(
        E2ePersistentDiag.entries.any(
          (e) => e.contains('access_401_without_refresh'),
        ),
        isTrue,
        reason: 'the involuntary session end is still recorded durably',
      );
      auth.dispose();
    });

    test('repeated no-op session ends are deduped in the durable log',
        () async {
      // The §5.4 keep-the-store tradeoff makes this boot repeat forever for a
      // user holding only a dead access token. The durable log is an 80-entry
      // FIFO: without dedup, ~80 boots evict the BOOT_MARKERS forensics that
      // 0.1.10 planted to diagnose the next storage wipe.
      final kv = _ThrowingKv()..data['jwt_token'] = _builtExpiredAccessJwt;
      ApiService api() => _apiWith(
            (req) => req.url.path == '/users/me'
                ? http.Response(jsonEncode({'message': 'unauthorized'}), 401)
                : http.Response('unexpected ${req.url.path}', 500),
          );
      for (var boot = 0; boot < 3; boot++) {
        final auth = AuthProvider(
          api: api(),
          tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
          tokenReadRetryDelays: const [],
        );
        await _waitRestored(auth);
        auth.dispose();
      }

      final durable = E2ePersistentDiag.entries
          .where(
            (e) =>
                e.contains('AUTH_SESSION_END') &&
                e.contains('access_401_without_refresh'),
          )
          .length;
      expect(
        durable,
        1,
        reason: 'boot-loop repeats must not churn the FIFO; eviction re-arms '
            'the event so recurrence is never permanently lost',
      );
    });
  });

  // X3: an account deleted elsewhere. The server pushes nothing to this
  // device; the only thing it can say is a bare 401 on an authenticated call
  // made with an access token that has not expired, and a refused refresh.
  group('AuthProvider account gone (endSessionIfAccountGone)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const base = 'http://localhost:3000';
    late int meStatus;
    late String meMessage;
    var refreshMessage = 'Invalid refresh token';
    late int refreshStatus;
    late int meCalls;
    late int refreshCalls;
    Completer<void>? deleteGate;
    var deleteReached = false;

    String freshAccessJwt() {
      String seg(Map<String, dynamic> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      final exp = DateTime.now().add(const Duration(hours: 12));
      return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${seg({'sub': 1, 'exp': exp.millisecondsSinceEpoch ~/ 1000})}.sig';
    }

    Future<AuthProvider> loggedIn({String? access}) async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': access ?? freshAccessJwt(),
        'refresh_token': 'opaque_refresh',
      });
      meStatus = 200;
      meMessage = '';
      refreshMessage = 'Invalid refresh token';
      refreshStatus = 201;
      meCalls = 0;
      refreshCalls = 0;
      deleteGate = null;
      deleteReached = false;
      final auth = AuthProvider(
        api: ApiService(
          baseUrl: base,
          httpClient: MockClient((req) async {
            if (req.url.path == '/users/me') {
              meCalls++;
              return meStatus == 200
                  ? http.Response(
                      jsonEncode({'id': 1, 'username': 'test', 'tag': '0001'}),
                      200,
                    )
                  : http.Response(
                      jsonEncode({'message': meMessage, 'statusCode': meStatus}),
                      meStatus,
                    );
            }
            if (req.url.path == '/auth/refresh') {
              refreshCalls++;
              return refreshStatus == 201
                  ? http.Response(
                      jsonEncode({
                        'access_token': freshAccessJwt(),
                        'refresh_token': 'opaque_refresh',
                      }),
                      201,
                    )
                  : http.Response(
                      jsonEncode({'message': refreshMessage}),
                      refreshStatus,
                    );
            }
            if (req.url.path == '/users/verify-password') {
              return http.Response('{}', 201);
            }
            if (req.method == 'DELETE' && req.url.path == '/users/account') {
              deleteReached = true;
              await deleteGate?.future;
              return http.Response('{}', 200);
            }
            if (req.url.path == '/auth/logout') return http.Response('', 200);
            throw Exception('Unexpected ${req.url.path}');
          }),
        ),
      );
      await _waitForAuthSettled(auth, expectLoggedIn: true);
      // The boot's background slide is fire-and-forget; let it land first.
      for (var i = 0; i < 20 && refreshCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Past the slide's own answer; the test sets what the server says next.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      meCalls = 0;
      refreshCalls = 0;
      return auth;
    }

    test('a bare 401 on a live access token and a refused refresh end the '
        'session and wipe the stored tokens', () async {
      final auth = await loggedIn();
      meStatus = 401;
      meMessage = 'Account not found';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isTrue);

      expect(auth.isLoggedIn, isFalse);
      expect(auth.lastSessionEndReason, 'account_gone');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('a password change elsewhere is not an account that is gone', () async {
      final auth = await loggedIn();
      meStatus = 401;
      meMessage = 'Token invalidated by password change';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(auth.isLoggedIn, isTrue);
      expect(refreshCalls, 0);
    });

    test('a refused access token whose refresh still works keeps the '
        'session', () async {
      final auth = await loggedIn();
      meStatus = 401;
      meMessage = 'Account not found';
      refreshStatus = 201;

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(auth.isLoggedIn, isTrue);
    });

    test('a bare Unauthorized (bad signature, clock skew) never signs out', () async {
      final auth = await loggedIn();
      meStatus = 401;
      meMessage = 'Unauthorized';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(auth.isLoggedIn, isTrue);
      expect(refreshCalls, 0);
    });

    test('a missing account whose refresh answers Device revoked is the '
        'revoke path, not an account that is gone', () async {
      final auth = await loggedIn();
      meStatus = 401;
      meMessage = 'Account not found';
      refreshStatus = 401;
      refreshMessage = 'Device revoked';

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(auth.isLoggedIn, isTrue);
    });

    test('a server or network failure never ends the session', () async {
      final auth = await loggedIn();
      meStatus = 503;
      meMessage = 'Service Unavailable';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(auth.isLoggedIn, isTrue);
      expect(refreshCalls, 0);
    });

    test('an expired access token proves nothing: no call, no sign-out', () async {
      final auth = await loggedIn();
      auth.setAccessTokenForTest(_expiredAccessJwt);
      meStatus = 401;
      meMessage = 'Unauthorized';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isFalse);

      expect(meCalls, 0);
      expect(auth.isLoggedIn, isTrue);
    });

    test('while this device deletes the account, the probe stands down', () async {
      final auth = await loggedIn();
      final gate = deleteGate = Completer<void>();

      final deleting = auth.deleteAccount('pw');
      for (var i = 0; i < 50 && !deleteReached; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(deleteReached, isTrue);
      // The delete just removed the row: the probe would see exactly this.
      meStatus = 401;
      meMessage = 'Account not found';
      refreshStatus = 401;

      expect(await auth.endSessionIfAccountGone(), isFalse);
      expect(auth.isLoggedIn, isTrue, reason: 'the delete flow logs out');

      gate.complete();
      await deleting;
      expect(auth.isLoggedIn, isFalse);
    });
  });
}
