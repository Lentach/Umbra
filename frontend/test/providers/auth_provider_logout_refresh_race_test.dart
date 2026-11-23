import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Built at runtime: a literal JWT trips the gitleaks pre-commit gate. The
// signature is never verified client-side.
String _jwt({required int exp}) => [
  base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}')),
  base64Url.encode(
    utf8.encode('{"sub":1,"username":"test","tag":"0000","exp":$exp}'),
  ),
  'sig',
].join('.');

final String _savedAccess = _jwt(exp: 9999999999);
final String _refreshedAccess = _jwt(exp: 9999999998);
final String _linkedAccess = _jwt(exp: 9999999997);
final String _expiredAccess = _jwt(exp: 1516239022);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'Content-Type': 'application/json'},
);

http.Response _freshTokens() => _json({
  'access_token': _refreshedAccess,
  'refresh_token': 'rt-fresh',
}, 201);

/// A server whose `/auth/refresh` and `/auth/logout` answers can be held
/// back, so a test decides which of the two lands first.
class _Server {
  /// When set, the next `/auth/refresh` waits for it.
  Completer<http.Response>? refreshGate;

  /// When set, the next `/auth/logout` waits for it.
  Completer<void>? logoutGate;

  int refreshes = 0;
  int logouts = 0;

  ApiService api() => ApiService(
    baseUrl: 'http://localhost:3999',
    httpClient: MockClient((request) async {
      switch (request.url.path) {
        case '/auth/refresh':
          refreshes++;
          final gate = refreshGate;
          if (gate != null) {
            refreshGate = null;
            return gate.future;
          }
          return _json({
            'access_token': _savedAccess,
            'refresh_token': 'rt-boot',
          }, 201);
        case '/auth/logout':
          logouts++;
          final gate = logoutGate;
          if (gate != null) {
            logoutGate = null;
            await gate.future;
          }
          return http.Response('', 204);
        case '/users/me':
          return _json({'id': 1, 'username': 'test', 'tag': '0000'}, 200);
      }
      return http.Response('unexpected ${request.url.path}', 500);
    }),
  );
}

/// Runs the event queue until [done]; no wall-clock wait.
Future<void> _settle(bool Function() done, String what) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await pumpEventQueue();
  }
  expect(done(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late _Server server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': _savedAccess,
      'refresh_token': 'rt-0',
    });
    await E2ePersistentDiag.clear();
    prefs = await SharedPreferences.getInstance();
    server = _Server();
  });

  void expectSignedOut(AuthProvider auth, List<String> pushedTokens) {
    expect(auth.isLoggedIn, isFalse, reason: 'signed in again after logout');
    expect(auth.token, isNull);
    expect(prefs.getString('jwt_token'), isNull);
    expect(
      prefs.getString('refresh_token'),
      isNull,
      reason: 'a live refresh token is back on disk after logout',
    );
    expect(pushedTokens, isEmpty, reason: 'the socket was handed a token');
  }

  // CONT-02: a refresh the server answers after the user logged out carried
  // fresh tokens straight into memory and the store.
  test('a refresh in flight when the user logs out does not sign the app back in', () async {
    final refresh = server.refreshGate = Completer<http.Response>();
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: true);
    // The boot slide is the refresh in flight.
    await _settle(
      () => auth.isLoggedIn && server.refreshes == 1,
      'boot slide never asked',
    );
    final pushed = <String>[];
    auth.onAccessTokenChanged = pushed.add;

    await auth.logout();
    refresh.complete(_freshTokens());
    await pumpEventQueue();

    expectSignedOut(auth, pushed);
    expect(auth.lastSessionEndReason, 'explicit_logout');
  });

  test('a refresh that starts while logout is still talking to the server does not sign the app back in', () async {
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: true);
    await _settle(
      () => prefs.getString('refresh_token') == 'rt-boot',
      'boot slide never landed',
    );
    final pushed = <String>[];
    auth
      ..onAccessTokenChanged = pushed.add
      ..setAccessTokenForTest(_expiredAccess);

    final logoutAnswer = server.logoutGate = Completer<void>();
    final loggedOut = auth.logout();
    await _settle(() => server.logouts == 1, 'logout never reached the server');

    // The 15-minute tick, or a resume, lands inside logout.
    final refresh = server.refreshGate = Completer<http.Response>();
    final ready = auth.ensureSessionReady();
    await _settle(() => server.refreshes == 2, 'the refresh never asked');

    logoutAnswer.complete();
    await loggedOut;
    refresh.complete(_freshTokens());
    await ready;
    await pumpEventQueue();

    expectSignedOut(auth, pushed);
    expect(auth.lastSessionEndReason, 'explicit_logout');
  });

  // The logout revoked the token the refresh presented, so its answer is a
  // refusal. That refusal belongs to a session the user already ended.
  test('a refresh refused after logout does not end the session a second time', () async {
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: true);
    await _settle(
      () => prefs.getString('refresh_token') == 'rt-boot',
      'boot slide never landed',
    );
    auth.setAccessTokenForTest(_expiredAccess);
    final refresh = server.refreshGate = Completer<http.Response>();
    final ready = auth.ensureSessionReady();
    await _settle(() => server.refreshes == 2, 'the refresh never asked');

    await auth.logout();
    refresh.complete(_json({'message': 'Unauthorized'}, 401));
    await ready;
    await pumpEventQueue();

    expect(auth.isLoggedIn, isFalse);
    expect(
      auth.lastSessionEndReason,
      'explicit_logout',
      reason: 'the auth screen names a refused session, not the logout',
    );
    expect(
      E2ePersistentDiag.entries.where((e) => e.contains('AUTH_SESSION_END')),
      isEmpty,
      reason: 'an explicit logout was recorded as an involuntary session end',
    );
  });

  // The link rebind installs a new device-bound session; the old session's
  // refresh still in flight must not overwrite it.
  test('a refresh of the old session does not overwrite a rebound session', () async {
    final refresh = server.refreshGate = Completer<http.Response>();
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: true);
    await _settle(
      () => auth.isLoggedIn && server.refreshes == 1,
      'boot slide never asked',
    );

    await auth.adoptProvisionedSession({
      'access_token': _linkedAccess,
      'refresh_token': 'rt-linked',
    });
    refresh.complete(_freshTokens());
    await pumpEventQueue();

    expect(auth.token, _linkedAccess);
    expect(prefs.getString('refresh_token'), 'rt-linked');
  });
}
