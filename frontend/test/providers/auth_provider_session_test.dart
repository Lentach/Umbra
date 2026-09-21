import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';

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

    test(
      'same-user token restore preserves hydrated profilePhotos and about',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        final mock = MockClient((request) async {
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
            // Server hydrates the self profile with a full gallery + about.
            return http.Response(
              jsonEncode({
                'id': 1,
                'username': 'test',
                'tag': '0000',
                'profilePictureUrl': 'https://cdn/p1.jpg',
                'about': 'hello world',
                'profilePhotos': [
                  {
                    'id': 1,
                    'url': 'https://cdn/p1.jpg',
                    'isPrimary': true,
                    'createdAt': '2026-01-01T00:00:00.000Z',
                  },
                  {
                    'id': 2,
                    'url': 'https://cdn/p2.jpg',
                    'isPrimary': false,
                    'createdAt': '2026-01-02T00:00:00.000Z',
                  },
                  {
                    'id': 3,
                    'url': 'https://cdn/p3.jpg',
                    'isPrimary': false,
                    'createdAt': '2026-01-03T00:00:00.000Z',
                  },
                ],
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
        expect(auth.currentUser?.profilePhotos.length, 3,
            reason: 'seed precondition: gallery must be hydrated from /users/me');

        // A silent 15-min token refresh re-runs _restoreUserFromAccessJwt for
        // the SAME account; it must not collapse the gallery or drop about.
        auth.setAccessTokenForTest(_validAccessJwt);

        expect(auth.currentUser?.id, 1);
        expect(auth.currentUser?.profilePhotos.length, 3);
        expect(
          auth.currentUser?.profilePhotos.map((p) => p.id).toList(),
          [1, 2, 3],
        );
        expect(auth.currentUser?.about, 'hello world');
        expect(auth.currentUser?.profilePictureUrl, 'https://cdn/p1.jpg');
      },
    );

    test(
      'different-user token restore does not carry over stale profilePhotos',
      () async {
        SharedPreferences.setMockInitialValues({
          'jwt_token': _validAccessJwt,
          'refresh_token': 'opaque_refresh',
        });

        final mock = MockClient((request) async {
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
                'profilePhotos': [
                  {
                    'id': 1,
                    'url': 'https://cdn/p1.jpg',
                    'isPrimary': true,
                    'createdAt': '2026-01-01T00:00:00.000Z',
                  },
                  {
                    'id': 2,
                    'url': 'https://cdn/p2.jpg',
                    'isPrimary': false,
                    'createdAt': '2026-01-02T00:00:00.000Z',
                  },
                  {
                    'id': 3,
                    'url': 'https://cdn/p3.jpg',
                    'isPrimary': false,
                    'createdAt': '2026-01-03T00:00:00.000Z',
                  },
                ],
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
        expect(auth.currentUser?.profilePhotos.length, 3);

        // Account switch: a JWT for a different user id must NOT inherit the
        // previous account's gallery/about.
        auth.setAccessTokenForTest(_otherUserAccessJwt);

        expect(auth.currentUser?.id, 2);
        expect(auth.currentUser?.username, 'other');
        expect(auth.currentUser?.profilePhotos, isEmpty);
        expect(auth.currentUser?.about, isNull);
      },
    );
  });
}
