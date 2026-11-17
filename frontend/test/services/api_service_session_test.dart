import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/session_refresh_exception.dart';

void main() {
  group('ApiService session / refresh contract', () {
    const base = 'http://localhost:3999';

    test('login rejects response missing refresh_token (client stays consistent)', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/auth/login');
        return http.Response(
          jsonEncode({'access_token': 'only_access'}),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.login('user#1234', 'pass'),
        throwsA(
          predicate((e) =>
              e.toString().contains('Login response missing tokens')),
        ),
      );
    });

    test('login returns both tokens when server sends them', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'access_token': 'jwt_access',
            'refresh_token': 'opaque_refresh',
          }),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      final data = await api.login('user#1234', 'pass');
      expect(data['access_token'], 'jwt_access');
      expect(data['refresh_token'], 'opaque_refresh');
    });

    test('refreshSession rejects missing tokens in body', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/auth/refresh');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['refresh_token'], 'old_refresh');
        return http.Response(
          jsonEncode({'access_token': 'new_access'}),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('old_refresh'),
        throwsA(
          predicate((e) =>
              e.toString().contains('Refresh response missing tokens')),
        ),
      );
    });

    test('refreshSession returns rotated pair on success, asking to rotate only when told', () async {
      final bodies = <Object?>[];
      final mock = MockClient((request) async {
        bodies.add(jsonDecode(request.body));
        return http.Response(
          jsonEncode({
            'access_token': 'new_access',
            'refresh_token': 'new_refresh_rotated',
          }),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      final data = await api.refreshSession('old_refresh');
      expect(data['access_token'], 'new_access');
      expect(data['refresh_token'], 'new_refresh_rotated');
      await api.refreshSession('old_refresh', rotate: true);
      expect(bodies, [
        {'refresh_token': 'old_refresh'},
        {'refresh_token': 'old_refresh', 'rotate': true},
      ]);
    });

    test('refreshSession throws SessionRefreshInvalidException on 401', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Invalid refresh token'}),
          401,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('bad'),
        throwsA(isA<SessionRefreshInvalidException>()),
      );
    });

    test('refreshSession throws SessionRefreshTransientException on 503', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Service unavailable'}),
          503,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshTransientException>()),
      );
    });

    test('refreshSession 401 with non-JSON body is invalid session', () async {
      final mock = MockClient((request) async {
        return http.Response('<html>Unauthorized</html>', 401);
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshInvalidException>()),
      );
    });

    test('refreshSession 429 is transient', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Too many requests'}),
          429,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshTransientException>()),
      );
    });

    test('refreshSession throws SessionRefreshInvalidException on 403', () async {
      // Source treats 401||403 identically as an invalid session. Dropping 403
      // from the invalid set would force a bad session into an endless
      // transient-retry loop instead of surfacing re-login.
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Forbidden'}),
          403,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshInvalidException>()),
      );
    });

    test('refreshSession 408 is transient', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Request timeout'}),
          408,
          headers: {'Content-Type': 'application/json'},
        );
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshTransientException>()),
      );
    });

    test('refreshSession maps a network drop to transient', () async {
      // A dropped connection (http.ClientException) is retryable, not an
      // invalid session — it must map to the transient class.
      final mock = MockClient((request) async {
        throw http.ClientException('Connection reset by peer');
      });

      final api = ApiService(baseUrl: base, httpClient: mock);
      expect(
        () => api.refreshSession('rt'),
        throwsA(isA<SessionRefreshTransientException>()),
      );
    });
  });
}
