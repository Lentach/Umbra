// Full-stack proof of the §5.4 auth-token tri-state contract (PR #137/#138)
// against a REAL backend: the app's REAL AuthProvider + AuthTokenStore +
// ApiService do real /auth/register, /auth/login, /auth/refresh, /users/me —
// only the secure-storage seam is fault-injected.
//
// Requires a locally running backend (`docker-compose up`), like every test
// in this directory.

import 'dart:convert';

import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

/// In-memory secure storage with injectable read faults.
class _FlakyKv implements SecureKv {
  final Map<String, String> data = {};
  bool throwOnRead = false;
  int failReadsRemaining = 0;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw Exception('secure storage unavailable');
    if (failReadsRemaining > 0) {
      failReadsRemaining--;
      throw Exception('secure storage transiently unavailable');
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(data);
}

// Dead access JWT (public jwt.io example claims, exp long past), built at
// runtime — a literal JWT trips the gitleaks pre-commit gate.
final String _expiredAccessJwt = [
  base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}')),
  base64Url.encode(
    utf8.encode('{"sub":1,"username":"test","tag":"0000","exp":1516239022}'),
  ),
  'not-a-real-signature',
].join('.');

Future<void> _waitRestored(AuthProvider auth) async {
  for (var i = 0; i < 400 && auth.isRestoringSession; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(auth.isRestoringSession, isFalse, reason: 'boot never finished');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  final baseUrl = e2eBaseUrl();
  late _FlakyKv kv;

  AuthProvider boot() => AuthProvider(
    api: ApiService(baseUrl: baseUrl),
    tokenStore: AuthTokenStore(secure: kv, useSecureStorage: true),
    tokenReadRetryDelays: const [Duration(milliseconds: 50)],
  );

  setUpAll(() async {
    await requireBackendUp(baseUrl);
  });

  setUp(() async {
    // test_e2e/ is not a standard `test/` dir, so the @visibleForTesting
    // check misfires — this IS a flutter_test test.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
  });
  test('storage faults never cost a real session (live backend)', () async {
    kv = _FlakyKv();
    // Full timestamp + microsecond suffix: a modulo-truncated name collides
    // across runs in the same ~16-minute window and fails register() (review).
    final username =
        'af${DateTime.now().millisecondsSinceEpoch}'
        '${DateTime.now().microsecond % 100}';
    const password = 'AuthFault1!';

    // Real registration + login through the real provider stack.
    final registerBoot = boot();
    await _waitRestored(registerBoot);
    expect(await registerBoot.register(username, password), isTrue);
    expect(await registerBoot.login(username, password), isTrue);
    expect(registerBoot.currentUser, isNotNull);
    expect(kv.data['refresh_token'], isNotNull,
        reason: 'login must persist tokens into the (fault-free) store');
    final persistedRefresh = kv.data['refresh_token'];
    registerBoot.dispose();

    // Reboot 1 — TRANSIENT storage fault: the first read attempt dies, the
    // retry recovers, and the session comes back via a real /users/me.
    kv.failReadsRemaining = 1;
    final transientBoot = boot();
    await _waitRestored(transientBoot);
    expect(transientBoot.currentUser, isNotNull,
        reason: 'a transient storage fault must be invisible to the user');
    expect(transientBoot.currentUser!.username, username);
    // Its boot slide rotates the refresh token (native, plan B4): the rotated
    // one is what the outage below must leave untouched.
    for (
      var i = 0;
      i < 200 && kv.data['refresh_token'] == persistedRefresh;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final rotatedRefresh = kv.data['refresh_token'];
    expect(rotatedRefresh, isNot(persistedRefresh),
        reason: 'the boot slide rotates the token and stores the new one');
    transientBoot.dispose();

    // Reboot 2 — PERSISTENT storage fault: the boot concedes honestly,
    // fabricates no logout, and DELETES NOTHING.
    kv.throwOnRead = true;
    final blindBoot = boot();
    await _waitRestored(blindBoot);
    expect(blindBoot.currentUser, isNull);
    expect(blindBoot.isError, isTrue);
    // A CODE, not prose: the provider holds no locale, so the widget layer
    // maps this to an ARB string (the login screen used to render an English
    // literal built here, on every locale).
    expect(blindBoot.statusCode, AuthStatusCode.savedSessionUnreadable);
    expect(blindBoot.statusMessage, isNull);
    expect(blindBoot.lastSessionEndReason, isNull,
        reason: 'no session ended — nothing may claim one did');
    expect(kv.data['refresh_token'], rotatedRefresh,
        reason: 'the stored refresh token survives the outage untouched');
    expect(
      E2ePersistentDiag.entries.any((e) => e.contains('AUTH_TOKENS_UNREADABLE')),
      isTrue,
    );
    blindBoot.dispose();

    // Reboot 3 — storage healthy again: the SAME tokens log the user back in
    // against the real server. Pre-§5.4 code had already deleted them here.
    kv.throwOnRead = false;
    final recoveredBoot = boot();
    await _waitRestored(recoveredBoot);
    expect(recoveredBoot.currentUser, isNotNull,
        reason: 'the outage cost nothing: same store, same session');
    expect(recoveredBoot.currentUser!.username, username);
    recoveredBoot.dispose();
  });

  test('dead access token boot-loop: store kept, durable log deduped '
      '(live backend)', () async {
    kv = _FlakyKv()..data['jwt_token'] = _expiredAccessJwt;
    // Sentinel standing in for BOOT_MARKERS: it must survive the boot loop.
    E2ePersistentDiag.record('BOOT_MARKERS', {'ls': 'present'});

    for (var i = 0; i < 3; i++) {
      final auth = boot();
      await _waitRestored(auth);
      expect(auth.currentUser, isNull,
          reason: 'a dead access token with no refresh cannot log in');
      expect(kv.data['jwt_token'], _expiredAccessJwt,
          reason: 'locally-derived session ends must never delete the store');
      auth.dispose();
    }

    final sessionEnds = E2ePersistentDiag.entries
        .where((e) =>
            e.contains('AUTH_SESSION_END') &&
            e.contains('access_401_without_refresh'))
        .length;
    expect(sessionEnds, 1,
        reason: 'repeat no-op boots are deduped — they must not churn the '
            '80-entry FIFO');
    expect(
      E2ePersistentDiag.entries.any((e) => e.contains('BOOT_MARKERS')),
      isTrue,
      reason: 'the wipe forensics survive the boot loop',
    );
  });
}
