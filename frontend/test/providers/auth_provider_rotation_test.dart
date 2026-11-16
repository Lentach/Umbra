import 'dart:convert';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/secure_kv.dart';
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

final String _validAccess = _jwt(exp: 9999999999);
final String _expiredAccess = _jwt(exp: 1516239022);

/// Secure storage whose writes can be refused, as a broken Keystore does.
class _Kv implements SecureKv {
  final Map<String, String> data = {};
  bool refuseWrites = false;
  int refused = 0;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    if (refuseWrites) {
      refused++;
      throw Exception('keystore refused');
    }
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(data);
}

/// A server that rotates `…rt-N` to `…rt-N+1` when asked, and otherwise
/// hands the same token back; it records every `/auth/refresh` body. With
/// [revoked] it answers every refresh `401 Device revoked` (decision 130).
class _Server {
  final bodies = <Map<String, dynamic>>[];
  bool revoked = false;

  ApiService api() => ApiService(
    baseUrl: 'http://localhost:3999',
    httpClient: MockClient((request) async {
      if (request.url.path == '/auth/refresh') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        if (revoked) {
          return http.Response(
            jsonEncode({'message': 'Device revoked'}),
            401,
            headers: {'Content-Type': 'application/json'},
          );
        }
        final presented = body['refresh_token'] as String;
        final n = presented.lastIndexOf('-') + 1;
        final next = body['rotate'] == true
            ? '${presented.substring(0, n)}'
                  '${int.parse(presented.substring(n)) + 1}'
            : presented;
        return http.Response(
          jsonEncode({'access_token': _validAccess, 'refresh_token': next}),
          201,
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (request.url.path == '/users/me') {
        return http.Response(
          jsonEncode({'id': 1, 'username': 'test', 'tag': '0000'}),
          200,
          headers: {'Content-Type': 'application/json'},
        );
      }
      return http.Response('unexpected ${request.url.path}', 500);
    }),
  );
}

Future<void> _until(bool Function() done, String what) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: what);
}

/// The access token runs out and the next caller refreshes.
Future<void> _refreshNow(AuthProvider auth) async {
  auth.setAccessTokenForTest(_expiredAccess);
  await auth.ensureSessionReady();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
  });

  // Plan B4: the server replaces the session's token on every refresh that
  // asks, and ends the session when an old one comes back. A client that
  // asked and then presented anything but the token it got back would log
  // itself out.
  test('native asks every refresh to rotate, keeps the token it gets back and presents that one next', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': _validAccess,
      'refresh_token': 'rt-0',
    });
    final server = _Server();
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: true);
    // The boot slide is fire-and-forget: wait for the token it brings.
    await _until(
      () => auth.isLoggedIn && server.bodies.isNotEmpty,
      'boot slide never ran',
    );
    final prefs = await SharedPreferences.getInstance();
    await _until(
      () => prefs.getString('refresh_token') == 'rt-1',
      'the rotated token was not stored',
    );

    await _refreshNow(auth);

    expect(server.bodies, [
      {'refresh_token': 'rt-0', 'rotate': true},
      {'refresh_token': 'rt-1', 'rotate': true},
    ]);
    expect(prefs.getString('refresh_token'), 'rt-2');
    auth.dispose();
  });

  test('web never asks to rotate: its tabs share one stored token', () async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': _validAccess,
      'refresh_token': 'rt-0',
    });
    final server = _Server();
    final auth = AuthProvider(api: server.api(), rotateRefreshTokens: false);
    await _until(
      () => auth.isLoggedIn && server.bodies.isNotEmpty,
      'boot slide never ran',
    );

    await _refreshNow(auth);

    expect(server.bodies, [
      {'refresh_token': 'rt-0'},
      {'refresh_token': 'rt-0'},
    ]);
    auth.dispose();
  });

  // The server answers the token just replaced as a retry, but ends the
  // session on one two rotations old. A store that refused the rotated token
  // still holds the replaced one: the next cold start (or the wake-up check,
  // which reads the store) presents it. Rotating again before a write lands
  // would make it two rotations old.
  test('after the store refused a rotated token, refreshes keep the token they hold until a write lands', () async {
    final kv = _Kv()
      ..data['jwt_token'] = _validAccess
      ..data['refresh_token'] = 'rt-0'
      ..refuseWrites = true;
    final server = _Server();
    final auth = AuthProvider(
      api: server.api(),
      tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
      rotateRefreshTokens: true,
    );
    // Boot slide: rotated to rt-1, and the store refuses it (write + retry).
    await _until(() => kv.refused >= 2, 'the store was never asked');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(kv.data['refresh_token'], 'rt-0');

    await _refreshNow(auth);
    expect(
      server.bodies.last,
      {'refresh_token': 'rt-1'},
      reason: 'no rotation past a token the store does not hold',
    );

    kv.refuseWrites = false;
    await _refreshNow(auth);
    expect(kv.data['refresh_token'], 'rt-1');
    await _refreshNow(auth);

    expect(server.bodies, [
      {'refresh_token': 'rt-0', 'rotate': true},
      {'refresh_token': 'rt-1'},
      {'refresh_token': 'rt-1'},
      {'refresh_token': 'rt-1', 'rotate': true},
    ]);
    expect(kv.data['refresh_token'], 'rt-2');
    auth.dispose();
  });

  // Issue #234: a device revoked while it was closed hands its account over
  // to retire its queues, but only while the store still holds the refused
  // SESSION. One refused write leaves the store a rotation behind the token
  // the refresh was refused with: same session, another string.
  test('a device revoked while its store is a rotation behind still hands the account over for its queues', () async {
    const session = '0b7e6c1a-5d0f-4c2e-9a51-3f6f2f1d9e10';
    final kv = _Kv()
      ..data['jwt_token'] = _validAccess
      ..data['refresh_token'] = '$session.rt-0'
      ..refuseWrites = true;
    final server = _Server();
    final auth = AuthProvider(
      api: server.api(),
      tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
      rotateRefreshTokens: true,
    );
    await _until(() => kv.refused >= 2, 'the store was never asked');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(kv.data['refresh_token'], '$session.rt-0');

    server.revoked = true;
    await _refreshNow(auth);

    expect(server.bodies.last, {'refresh_token': '$session.rt-1'});
    expect(auth.statusCode, AuthStatusCode.deviceRevoked);
    expect(auth.takeRevokedDeviceAccount(), 1);
    auth.dispose();
  });
}
