import 'dart:convert';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_exception.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _validAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjk5OTk5OTk5OTl9.abc';

/// Expired access JWT (exp 1516239022). Signature is not verified client-side.
const _expiredAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjE1MTYyMzkwMjJ9.abc';

/// Account delete (decision 113, E114h, E114i): the password is checked FIRST
/// (a mistyped one must tell nobody goodbye), then the goodbyes
/// (`beforeDelete`), then the delete, then the teardown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every request the fake server saw, and `beforeDelete` when it ran.
  late List<String> calls;

  /// The calls the order is about; the boot's own requests are not.
  const flow = {
    'POST /users/verify-password',
    'beforeDelete',
    'DELETE /users/account',
    'POST /auth/logout',
  };

  List<String> flowSeen() => calls.where(flow.contains).toList();

  setUp(() => calls = []);

  /// A restored session whose server answers [verifyStatus] to the password
  /// check and [deleteStatus] to the delete. [access] is the saved access
  /// token; [refreshWorks] false makes the boot's refresh fail transiently,
  /// which keeps an expired access token in hand.
  Future<AuthProvider> restoredSession({
    int verifyStatus = 201,
    int deleteStatus = 200,
    String access = _validAccessJwt,
    bool Function()? refreshWorks,
    void Function(http.Request request)? onRequest,
  }) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': access,
      'refresh_token': 'opaque_refresh',
    });
    final mock = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      onRequest?.call(request);
      switch ((request.method, request.url.path)) {
        case ('GET', '/users/me'):
          return http.Response(
            jsonEncode({'id': 1, 'username': 'test', 'tag': '0000'}),
            200,
            headers: {'Content-Type': 'application/json'},
          );
        case ('POST', '/auth/refresh'):
          if (!(refreshWorks?.call() ?? true)) {
            return http.Response('{}', 503);
          }
          return http.Response(
            jsonEncode({
              'access_token': _validAccessJwt,
              'refresh_token': 'opaque_refresh',
            }),
            201,
            headers: {'Content-Type': 'application/json'},
          );
        case ('POST', '/users/verify-password'):
          return http.Response('{}', verifyStatus);
        case ('DELETE', '/users/account'):
          return http.Response('{}', deleteStatus);
        case ('POST', '/auth/logout'):
          return http.Response('', 200);
        default:
          return http.Response('{}', 404);
      }
    });
    final auth = AuthProvider(
      api: ApiService(baseUrl: 'http://t', httpClient: mock),
    );
    addTearDown(auth.dispose);
    for (var i = 0; i < 60 && !auth.isLoggedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(auth.isLoggedIn, isTrue, reason: 'boot must restore the session');
    await auth.contactBackupReady;
    return auth;
  }

  // Mutation: skip the verify call (or run beforeDelete before it) -> red.
  test('a wrong password stops everything: no goodbye, no delete, and the '
      'session stays', () async {
    final auth = await restoredSession(verifyStatus: 403);
    var toldFriends = false;

    await expectLater(
      auth.deleteAccount(
        'wrong',
        beforeDelete: () async => toldFriends = true,
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.statusCode,
          'statusCode',
          403,
        ),
      ),
    );

    expect(toldFriends, isFalse, reason: 'a mistyped password tells nobody');
    expect(calls, isNot(contains('DELETE /users/account')));
    expect(auth.isLoggedIn, isTrue, reason: 'nothing happened to the session');
  });

  // Mutation: beforeDelete before the verify, or no logout after -> red.
  test('the right password runs the check, then beforeDelete, then the '
      'delete, then logs out', () async {
    final auth = await restoredSession();

    final deleted = await auth.deleteAccount(
      'right',
      beforeDelete: () async => calls.add('beforeDelete'),
    );

    expect(deleted, isTrue);
    expect(flowSeen(), [
      'POST /users/verify-password',
      'beforeDelete',
      'DELETE /users/account',
      'POST /auth/logout',
    ]);
    expect(auth.token, isNull);
    expect(auth.isLoggedIn, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('jwt_token'), isNull);
    expect(prefs.getString('refresh_token'), isNull);
  });

  // Mutation: let beforeDelete's error out (drop the try, or `on Exception`).
  test('a beforeDelete that throws never holds the delete', () async {
    final auth = await restoredSession();

    final deleted = await auth.deleteAccount(
      'right',
      beforeDelete: () async {
        calls.add('beforeDelete');
        throw StateError('the box is down');
      },
    );

    expect(deleted, isTrue);
    expect(flowSeen(), [
      'POST /users/verify-password',
      'beforeDelete',
      'DELETE /users/account',
      'POST /auth/logout',
    ]);
    expect(auth.isLoggedIn, isFalse);
  });

  // Mutation: swallow the delete's failure, or log out before the delete.
  test('a delete the server refuses after the goodbyes throws and keeps the '
      'session, so a retry can finish it', () async {
    final auth = await restoredSession(deleteStatus: 500);

    await expectLater(
      auth.deleteAccount(
        'right',
        beforeDelete: () async => calls.add('beforeDelete'),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500),
      ),
    );

    expect(flowSeen(), [
      'POST /users/verify-password',
      'beforeDelete',
      'DELETE /users/account',
    ]);
    expect(auth.isLoggedIn, isTrue);
  });

  // Mutation: read the token before ensureSessionReady -> the check 401s.
  test('an expired access token is refreshed before the password is checked, '
      'and the check carries the fresh one', () async {
    var refreshWorks = false;
    String? checkedWith;
    final auth = await restoredSession(
      access: _expiredAccessJwt,
      refreshWorks: () => refreshWorks,
      onRequest: (request) {
        if (request.url.path == '/users/verify-password') {
          checkedWith = request.headers['Authorization'];
        }
      },
    );
    expect(auth.token, _expiredAccessJwt, reason: 'the boot refresh failed');
    refreshWorks = true;

    final deleted = await auth.deleteAccount('right');

    expect(deleted, isTrue);
    expect(checkedWith, 'Bearer $_validAccessJwt');
  });

  test('with no session nothing is called and it throws as it did', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = AuthProvider(
      api: ApiService(
        baseUrl: 'http://t',
        httpClient: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return http.Response('{}', 404);
        }),
      ),
    );
    addTearDown(auth.dispose);
    var toldFriends = false;

    await expectLater(
      auth.deleteAccount('pw', beforeDelete: () async => toldFriends = true),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('Not authenticated'),
        ),
      ),
    );

    expect(toldFriends, isFalse);
    expect(flowSeen(), isEmpty);
  });
}
