import 'dart:convert';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/utils/contact_backup_prompt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _validAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjk5OTk5OTk5OTl9.abc';

void main() {
  group('confirmPasswordForContactBackup (decision R76)', () {
    late List<String> calls;

    Future<AuthProvider> restoredSession({required int verifyStatus}) async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      calls = [];
      final mock = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        switch (request.url.path) {
          case '/users/me':
            return http.Response(
              jsonEncode({'id': 1, 'username': 'test', 'tag': '0000'}),
              200,
              headers: {'Content-Type': 'application/json'},
            );
          case '/users/verify-password':
            return http.Response(
              jsonEncode({'ok': true}),
              verifyStatus,
              headers: {'Content-Type': 'application/json'},
            );
          case '/backup/contacts':
            return http.Response('{}', 404);
          default:
            return http.Response('{}', 404);
        }
      });
      final auth = AuthProvider(
        api: ApiService(baseUrl: 'http://t', httpClient: mock),
      );
      for (var i = 0; i < 40 && !auth.isLoggedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await auth.contactBackupReady;
      return auth;
    }

    test('a wrong password mints nothing: the wrap would open for nobody',
        () async {
      final auth = await restoredSession(verifyStatus: 403);
      expect(auth.contactBackupAwaitsPassword, isTrue);

      final result = await auth.confirmPasswordForContactBackup('wrong');

      expect(result, ContactBackupPromptResult.wrongPassword);
      expect(auth.contactBackupAwaitsPassword, isTrue, reason: 'still no row');
      expect(calls, isNot(contains('PUT /backup/contacts')));
    });

    test('an expired token (401) is not a wrong password', () async {
      final auth = await restoredSession(verifyStatus: 401);

      final result = await auth.confirmPasswordForContactBackup('pw');

      expect(result, ContactBackupPromptResult.unavailable);
    });

    test('a failed check is unavailable, not a wrong password', () async {
      final auth = await restoredSession(verifyStatus: 500);

      final result = await auth.confirmPasswordForContactBackup('pw');

      expect(result, ContactBackupPromptResult.unavailable);
      expect(auth.contactBackupAwaitsPassword, isTrue);
    });

    test('listeners hear the resolve settle: the red line needs no rebuild '
        'from elsewhere', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _validAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final mock = MockClient((request) async {
        if (request.url.path == '/users/me') {
          return http.Response(
            jsonEncode({'id': 1, 'username': 'test', 'tag': '0000'}),
            200,
            headers: {'Content-Type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });
      final heard = <bool>[];
      late final AuthProvider auth;
      auth = AuthProvider(
        api: ApiService(baseUrl: 'http://t', httpClient: mock),
      )..addListener(() => heard.add(auth.contactBackupAwaitsPassword));
      for (var i = 0; i < 40 && !auth.isLoggedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await auth.contactBackupReady;
      await Future<void>.delayed(Duration.zero);

      expect(auth.contactBackupAwaitsPassword, isTrue);
      expect(heard.last, isTrue, reason: 'the last notification saw the 404');
    });
  });
}
