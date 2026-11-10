import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';

// exp 1516239022 (expired); exp 9999999999 (valid). Signature not verified client-side.
const _expiredAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjE1MTYyMzkwMjJ9.4Adcj3UFYzPUBaY63_UWOshvRZQZjm7uI9uWGQ8RrXc';
const _validAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjk5OTk5OTk5OTl9.abc';

http.Response _userOk() => http.Response(
      jsonEncode({'id': 1, 'username': 'test', 'tag': '0000', 'profilePictureUrl': null}),
      200,
      headers: {'Content-Type': 'application/json'},
    );

http.Response _tokensOk() => http.Response(
      jsonEncode({'access_token': _validAccessJwt, 'refresh_token': 'rotated'}),
      200,
      headers: {'Content-Type': 'application/json'},
    );

Future<void> _settled(AuthProvider auth, {required bool expectLoggedIn}) async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!auth.isRestoringSession && auth.isLoggedIn == expectLoggedIn) return;
  }
  fail('AuthProvider did not settle '
      '(restoring=${auth.isRestoringSession}, loggedIn=${auth.isLoggedIn}, want=$expectLoggedIn)');
}

void main() {
  const base = 'http://localhost:3999';

  group('AuthProvider boot restore (characterization)', () {
    test(
        'valid saved access -> logged in; boot slides the refresh session '
        'in the background and a slide failure never logs out', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      var refreshCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.path == '/auth/refresh') {
          refreshCalls++;
          return http.Response('{}', 500);
        }
        if (req.url.path == '/users/me') return _userOk();
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: true);

      expect(auth.currentUser?.username, 'test');
      // New contract (0.0.127): a valid-access boot still slides the sliding
      // session in the background (server-visible device health signal). The
      // 500 here must be swallowed — retried transiently, never a logout.
      for (var i = 0; i < 40 && refreshCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(refreshCalls, greaterThan(0),
          reason: 'valid-access boot must slide the session');
      expect(auth.isLoggedIn, isTrue);
    });

    test('expired access + valid refresh + fetchMe OK -> refreshes and logs in',
        () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      var refreshCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.path == '/auth/refresh') {
          refreshCalls++;
          return _tokensOk();
        }
        if (req.url.path == '/users/me') return _userOk();
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: true);

      expect(refreshCalls, 1);
      expect(auth.isLoggedIn, isTrue);
    });

    test('valid access, fetchMe 401 once, refresh recovers -> logged in', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      var meCalls = 0;
      final mock = MockClient((req) async {
        if (req.url.path == '/users/me') {
          meCalls++;
          if (meCalls == 1) {
            return http.Response(jsonEncode({'message': 'unauthorized'}), 401,
                headers: {'Content-Type': 'application/json'});
          }
          return _userOk();
        }
        if (req.url.path == '/auth/refresh') return _tokensOk();
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: true);

      expect(meCalls, 2, reason: 'first fetchMe 401 -> refresh -> second fetchMe');
      expect(auth.currentUser?.username, 'test');
    });

    test('fetchMe 401 + refresh invalid -> clears session with reason', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((req) async {
        if (req.url.path == '/users/me') {
          return http.Response(jsonEncode({'message': 'unauthorized'}), 401,
              headers: {'Content-Type': 'application/json'});
        }
        if (req.url.path == '/auth/refresh') {
          return http.Response(jsonEncode({'message': 'Invalid refresh token'}), 401,
              headers: {'Content-Type': 'application/json'});
        }
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: false);

      expect(auth.lastSessionEndReason, 'refresh_invalid_after_access_401');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
    });

    test('fetchMe 401 + refresh transient -> stays logged in via JWT user', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((req) async {
        if (req.url.path == '/users/me') {
          return http.Response(jsonEncode({'message': 'unauthorized'}), 401,
              headers: {'Content-Type': 'application/json'});
        }
        if (req.url.path == '/auth/refresh') {
          return http.Response(jsonEncode({'message': 'Service unavailable'}), 503,
              headers: {'Content-Type': 'application/json'});
        }
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: true);

      // Transient refresh failure after a 401 keeps the (still-present) access
      // token and rebuilds the user from its JWT claims rather than logging out.
      expect(auth.currentUser?.username, 'test');
    });
  });

  // Issue #234: a device revoked while it was closed starts again online.
  // Its first contact is the boot's REST refresh, which answers
  // `401 {message: 'Device revoked'}` (decision 130's explicit answer): the
  // user must be told why, and the install's queues must go (the widget
  // layer takes the account and asks the connection to retire them).
  group('a refresh answered Device revoked at boot (issue #234)', () {
    http.Response revoked() => http.Response(
      jsonEncode({'message': 'Device revoked', 'statusCode': 401}),
      401,
      headers: {'Content-Type': 'application/json'},
    );

    test('after a 401 on /users/me: signed out with the revoked notice, and '
        'the account is handed over once for its queues', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((req) async {
        if (req.url.path == '/users/me') {
          return http.Response(jsonEncode({'message': 'unauthorized'}), 401,
              headers: {'Content-Type': 'application/json'});
        }
        if (req.url.path == '/auth/refresh') return revoked();
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: false);

      expect(auth.statusCode, AuthStatusCode.deviceRevoked);
      expect(auth.takeRevokedDeviceAccount(), 1);
      expect(auth.takeRevokedDeviceAccount(), isNull, reason: 'taken once');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('with an expired saved access: same notice and hand-over', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((req) async {
        if (req.url.path == '/auth/refresh') return revoked();
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: false);

      expect(auth.statusCode, AuthStatusCode.deviceRevoked);
      expect(auth.takeRevokedDeviceAccount(), 1);
    });

    test('any other refused refresh is a plain sign-out: no notice, no '
        'queue retire', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((req) async {
        if (req.url.path == '/auth/refresh') {
          return http.Response(jsonEncode({'message': 'Invalid refresh token'}),
              401, headers: {'Content-Type': 'application/json'});
        }
        throw Exception('Unexpected ${req.url.path}');
      });

      final auth = AuthProvider(api: ApiService(baseUrl: base, httpClient: mock));
      await _settled(auth, expectLoggedIn: false);

      expect(auth.statusCode, isNull);
      expect(auth.takeRevokedDeviceAccount(), isNull);
    });
  });
}
