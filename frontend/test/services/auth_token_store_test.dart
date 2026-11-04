import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';

class _FakeSecureKv implements SecureKv {
  final Map<String, String> data = {};

  /// Writes "succeed" but persist nothing — the read-back-verified migration
  /// must then refuse to delete the prefs copy.
  bool dropWrites = false;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  /// Fail this many individual reads, then behave — models the transient
  /// plugin faults (Keystore after OS update, early-boot contention) that
  /// the store's retry exists for.
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
  Future<void> write(String key, String value) async {
    if (throwOnWrite) throw Exception('secure storage write refused');
    if (dropWrites) return;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureKv secure;

  AuthTokenStore nativeStore() =>
      AuthTokenStore(secure: secure, useSecureStorage: true);

  AuthTokenStore prefsStore() =>
      AuthTokenStore(secure: secure, useSecureStorage: false);
  setUp(() async {
    secure = _FakeSecureKv();
    SharedPreferences.setMockInitialValues({});
    // The durable diag cache is static — isolate it so dedup/absence
    // assertions never observe records from earlier tests in this file.
    await E2ePersistentDiag.clear();
  });

  group('prefs path (web / non-Android)', () {
    test('write/read/clear round-trip through SharedPreferences', () async {
      final store = prefsStore();
      await store.write(access: 'a1', refresh: 'r1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), 'a1');
      expect(prefs.getString('refresh_token'), 'r1');
      final read = await store.read();
      expect(read.access, 'a1');
      expect(read.refresh, 'r1');
      await store.clear();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
      expect(secure.data, isEmpty, reason: 'never touches secure storage');
    });
  });

  group('native path', () {
    test('write/read/clear round-trip through secure storage', () async {
      final store = nativeStore();
      await store.write(access: 'a1', refresh: 'r1');
      expect(secure.data['jwt_token'], 'a1');
      expect(secure.data['refresh_token'], 'r1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull,
          reason: 'tokens must never land in the plaintext XML');
      final read = await store.read();
      expect(read.access, 'a1');
      expect(read.refresh, 'r1');
      await store.clear();
      expect(secure.data, isEmpty);
    });

    test('migrates a pre-Phase-2 install: copy, verify, then delete prefs',
        () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy-access',
        'refresh_token': 'legacy-refresh',
      });
      final read = await nativeStore().read();
      // Serves the tokens THIS launch (no forced re-login)...
      expect(read.access, 'legacy-access');
      expect(read.refresh, 'legacy-refresh');
      // ...has moved them to secure storage...
      expect(secure.data['jwt_token'], 'legacy-access');
      expect(secure.data['refresh_token'], 'legacy-refresh');
      // ...and only then removed the prefs copies.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('a dropped secure write leaves the prefs copy as the working set',
        () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy-access',
        'refresh_token': 'legacy-refresh',
      });
      secure.dropWrites = true;
      final read = await nativeStore().read();
      // Still logged in off the prefs copy this launch...
      expect(read.access, 'legacy-access');
      // ...and the prefs copy MUST survive: it is the only durable home the
      // tokens have until a secure write can be proven.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), 'legacy-access');
      expect(prefs.getString('refresh_token'), 'legacy-refresh');
    });

    test('a throwing secure store reads as logged out, never crashes',
        () async {
      secure.throwOnRead = true;
      final read = await nativeStore().read();
      expect(read.access, isNull);
      expect(read.refresh, isNull);
    });

    test('clear removes secure AND legacy prefs residue', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'stale-legacy',
      });
      secure.data['jwt_token'] = 'a1';
      await nativeStore().clear();
      expect(secure.data, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
    });

    test('post-migration reads clean stray prefs residue', () async {
      // Tokens already secure; a prefs twin survived (e.g. an old backup of
      // the XML got restored). Reads must not resurrect it — secure wins and
      // the residue goes.
      secure.data['jwt_token'] = 'secure-access';
      secure.data['refresh_token'] = 'secure-refresh';
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'stale-prefs-copy',
      });
      final read = await nativeStore().read();
      expect(read.access, 'secure-access');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
    });
  });

  /// §5.4: a storage ERROR must never read as "logged out". These pin the
  /// tri-state contract — readFailed is a distinct answer, retries recover
  /// transients, and invisible failures now leave durable evidence.
  group('failure honesty (0.1.11)', () {
    test('a read that keeps erroring reports readFailed, never absence',
        () async {
      secure.data['jwt_token'] = 'a1';
      secure.data['refresh_token'] = 'r1';
      secure.throwOnRead = true;

      final read = await nativeStore().read();

      expect(read.readFailed, isTrue);
      expect(read.access, isNull);
      expect(read.refresh, isNull);
      expect(
        secure.data['refresh_token'],
        'r1',
        reason: 'the tokens are intact behind the fault — nothing may '
            'delete or overwrite them',
      );
      expect(
        E2ePersistentDiag.entries.any(
          (e) => e.contains('AUTH_TOKENS_UNREADABLE'),
        ),
        isTrue,
        reason: 'an unreadable store must leave durable evidence',
      );
    });

    test('a transient read error is retried and recovered', () async {
      secure.data['jwt_token'] = 'a1';
      secure.data['refresh_token'] = 'r1';
      secure.failReadsRemaining = 1;

      final read = await nativeStore().read();

      expect(read.readFailed, isFalse);
      expect(read.access, 'a1');
      expect(read.refresh, 'r1');
    });

    test('a persistently refused write records a durable diagnostic',
        () async {
      secure.throwOnWrite = true;

      await nativeStore().write(access: 'a2', refresh: 'r2');

      expect(
        E2ePersistentDiag.entries.any(
          (e) => e.contains('AUTH_TOKEN_WRITE_FAILED'),
        ),
        isTrue,
        reason: '"logged out next boot" must have a paper trail',
      );
    });

    test('repeated unreadable reads are deduped in the durable log',
        () async {
      secure.throwOnRead = true;
      final store = nativeStore();

      await store.read();
      await store.read();
      await store.read();

      expect(
        E2ePersistentDiag.entries
            .where((e) => e.contains('AUTH_TOKENS_UNREADABLE'))
            .length,
        1,
        reason: 'the provider reads up to 3× per failed boot — plain records '
            'from a chronically failing store would churn the 80-entry FIFO '
            'and evict the BOOT_MARKERS wipe forensics',
      );
    });
  });

  // Issue #205: a revoked tab deletes its box queues only when the stored
  // session still names the revoked device; a wrong answer deletes the
  // queues of a sibling tab that adopted a reset session.
  group('readSessionDeviceId', () {
    String jwt(Map<String, Object?> claims) =>
        'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

    test('answers the deviceId claim; a token without one is device 1',
        () async {
      final store = prefsStore();
      await store.write(access: jwt({'sub': 5, 'deviceId': 7}), refresh: 'r');
      expect(await store.readSessionDeviceId(), 7);
      await store.write(access: jwt({'sub': 5}), refresh: 'r');
      expect(await store.readSessionDeviceId(), 1);
    });

    test('answers null for no session or a token that does not parse',
        () async {
      final store = prefsStore();
      expect(await store.readSessionDeviceId(), isNull);
      await store.write(access: 'not-a-jwt', refresh: 'r');
      expect(await store.readSessionDeviceId(), isNull);
      await store.write(access: 'h.%%%.s', refresh: 'r');
      expect(await store.readSessionDeviceId(), isNull);
    });
  });

  // Decision 129 (E129a), web: the push worker cannot read localStorage, so
  // the page leaves it the refresh token and the API origin it asks
  // `/auth/refresh` with while the app is closed. Off web the writer is a
  // no-op; here it is injected.
  group("the push worker's copy of the session", () {
    late List<({String refresh, String api})> written;
    late int cleared;
    var failing = false;

    AuthTokenStore mirrored() => AuthTokenStore(
      secure: secure,
      useSecureStorage: false,
      wakeSessionWriter: ({required refresh, required api}) async {
        if (failing) throw StateError('IndexedDB refused');
        written.add((refresh: refresh, api: api));
      },
      wakeSessionClearer: () async {
        if (failing) throw StateError('IndexedDB refused');
        cleared++;
      },
    );

    setUp(() {
      written = [];
      cleared = 0;
      failing = false;
    });

    test('every token write leaves the refresh token and the API origin; a clear removes them', () async {
      final store = mirrored();

      await store.write(access: 'a1', refresh: 'r1');
      await store.write(access: 'a2', refresh: 'r2');
      expect(written.map((w) => w.refresh), ['r1', 'r2']);
      expect(written.first.api, AppConfig.baseUrl);

      await store.clear();
      expect(cleared, 1);
    });

    test('a session restored by a build that predates the copy gets one on its first read, once', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'a',
        'refresh_token': 'r-old',
      });
      final store = mirrored();

      await store.read();
      await store.read();
      await pumpEventQueue();

      expect(written.map((w) => w.refresh), ['r-old']);
    });

    test('a read that finds no session or cannot read writes nothing', () async {
      await mirrored().read();
      secure.throwOnRead = true;
      await AuthTokenStore(
        secure: secure,
        useSecureStorage: true,
        wakeSessionWriter: ({required refresh, required api}) async {
          written.add((refresh: refresh, api: api));
        },
      ).read();
      await pumpEventQueue();

      expect(written, isEmpty);
    });

    test('a copy that cannot be written never fails the write, the read or the clear', () async {
      failing = true;
      final store = mirrored();

      await store.write(access: 'a1', refresh: 'r1');
      expect((await store.read()).refresh, 'r1');
      await store.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), isNull);
      expect(written, isEmpty);
    });

    test('a refused token write leaves no copy of a token that was not stored', () async {
      final store = AuthTokenStore(
        secure: secure..throwOnWrite = true,
        useSecureStorage: true,
        wakeSessionWriter: ({required refresh, required api}) async {
          written.add((refresh: refresh, api: api));
        },
      );

      await store.write(access: 'a1', refresh: 'r1');

      expect(written, isEmpty);
    });
  });
}
