import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/services/encryption/content_key_manager.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption/native_content_store.dart';
import 'package:fireplace/services/encryption/record_db.dart';

/// Secure storage fake with the failure modes the store defends against:
/// throwing enumeration (transient Keystore unavailability) and writes that
/// silently drop (the armed-gate case).
class _FakeSecureKv implements SecureKv {
  final Map<String, String> data = {};
  bool throwOnReadAll = false;
  bool throwOnRead = false;
  bool dropWrites = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw Exception('secure storage unavailable');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (dropWrites) return; // "succeeds" but persists nothing
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (throwOnReadAll) throw Exception('secure storage unavailable');
    return Map.of(data);
  }
}

/// Deterministic sealer: `[key0, key1] || plaintext`. Wrong key -> null,
/// exactly the contract the state machine depends on. Real-cipher coverage
/// lives in the AesGcmContentSealer group below.
class _MarkerSealer implements ContentSealer {
  int sealCalls = 0;

  /// When set, the NEXT seal parks until it completes — the only way to place
  /// a write mid-flight across a rotation.
  Completer<void>? sealGate;

  /// Models the cipher itself failing (webcrypto throwing), as opposed to a
  /// healthy cipher refusing bytes it did not seal.
  bool cipherDown = false;

  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async {
    sealCalls++;
    final gate = sealGate;
    if (gate != null) {
      sealGate = null;
      await gate.future;
    }
    if (cipherDown) return null;
    return Uint8List.fromList([key[0], key[1], ...plaintext]);
  }

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (cipherDown) return null;
    if (sealed.length < 2 || sealed[0] != key[0] || sealed[1] != key[1]) {
      return null;
    }
    return Uint8List.sublistView(sealed, 2);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryRecordDb db;
  late _FakeSecureKv secure;
  late _MarkerSealer sealer;
  NativeContentStore? store;

  setUp(() {
    db = InMemoryRecordDb();
    secure = _FakeSecureKv();
    sealer = _MarkerSealer();
    store = null;
  });

  tearDown(() async {
    // Timers (rotation debounce/deadline) must never leak out of a test.
    await store?.close();
  });

  Future<NativeContentStore> openStore({
    Map<String, Object> prefs = const {},
    bool audioResealOk = true,
    List<(Map<String, Uint8List>, String)>? resealCalls,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final legacy = await SharedPreferences.getInstance();
    return NativeContentStore.open(
      db: db,
      keys: ContentKeyManager(secure),
      legacyPrefs: legacy,
      sealer: sealer,
      audioResealer: (retiring, newKid, newKey) async {
        resealCalls?.add((retiring, newKid));
        return audioResealOk;
      },
      // Tests drive rotateNow() directly; long timers so nothing fires
      // underneath the test (close() cancels them either way).
      rotationDebounce: const Duration(hours: 1),
      rotationDeadline: const Duration(hours: 2),
    );
  }

  group('arming', () {
    test('fresh open mints a content key, arms it, and seals writes', () async {
      store = await openStore();
      expect(secure.data.keys.where((k) => k.startsWith('fp_content_key_')),
          hasLength(1));

      expect(await store!.setString('e2e_7_decrypted_41', '{"content":"hi"}'),
          isTrue);
      final row = db.rows['e2e_7_decrypted_41']!;
      expect(row.kid, store!.debugActiveKid);
      // The DB bytes must not contain the plaintext.
      expect(utf8.decode(row.sealed!.sublist(2)), '{"content":"hi"}');
      expect(row.text, isNull);
      expect(store!.getString('e2e_7_decrypted_41'), '{"content":"hi"}');
    });

    test('control keys stay cleartext rows; ints carried as ints', () async {
      store = await openStore();
      await store!.setString('e2e_7_purge_pending_v1', '{"ids":[1]}');
      await store!.setInt('e2e_7_retention_epoch_v1', 123);
      expect(db.rows['e2e_7_purge_pending_v1']!.kid, isNull);
      expect(db.rows['e2e_7_purge_pending_v1']!.text, '{"ids":[1]}');
      expect(db.rows['e2e_7_retention_epoch_v1']!.intValue, 123);
      expect(store!.getInt('e2e_7_retention_epoch_v1'), 123);
    });

    test('a write that never persists refuses to arm (armed-gate)', () async {
      secure.dropWrites = true;
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'mint')),
      );
      // Nothing may believe it is sealed: no rows, no active kid.
      expect(db.rows, isEmpty);
      expect(db.meta.containsKey('active_kid'), isFalse);
    });

    test('sealed records survive a reopen', () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"content":"hi"}');
      await store!.close();
      store = await openStore();
      expect(store!.getString('e2e_7_decrypted_41'), '{"content":"hi"}');
    });
  });

  group('key loss', () {
    Future<void> seedSealedRecord() async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"content":"hi"}');
      await store!.setString('e2e_7_decrypt_raw_v1_42', '{"c":"x"}');
      await store!.close();
      store = null;
    }

    test('throwing enumeration retires NOTHING and falls back', () async {
      await seedSealedRecord();
      secure.throwOnReadAll = true;
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'inventory')),
      );
      // Rows untouched, no retired set written.
      expect(db.rows.containsKey('e2e_7_decrypted_41'), isTrue);
      expect(db.rows.containsKey('e2e_7_retired_v1'), isFalse);
    });

    test('empty enumeration with an active kid is unavailability, not loss',
        () async {
      await seedSealedRecord();
      secure.data.clear(); // nothing at all — not even Signal keys
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'empty-enumeration')),
      );
      expect(db.rows.containsKey('e2e_7_decrypted_41'), isTrue);
      expect(db.rows.containsKey('e2e_7_retired_v1'), isFalse);
    });

    test('genuine key loss retires ids eagerly and keeps the rows', () async {
      await seedSealedRecord();
      secure.data.removeWhere((k, _) => k.startsWith('fp_content_key_'));
      secure.data['sig_something'] = 'still-here'; // other entries exist

      store = await openStore();
      // Retired BEFORE any caller could read: both id-bearing families.
      final retired =
          jsonDecode(store!.getString('e2e_7_retired_v1')!) as List;
      expect(retired, containsAll([41, 42]));
      // Also persisted, so the provider's one-shot loadRetiredIds sees it.
      final dbRetired = jsonDecode(db.rows['e2e_7_retired_v1']!.text!) as List;
      expect(dbRetired, containsAll([41, 42]));
      // Rows kept (bytes recoverable if the key ever reappears), but not
      // served.
      expect(db.rows.containsKey('e2e_7_decrypted_41'), isTrue);
      expect(store!.getString('e2e_7_decrypted_41'), isNull);
      // New writes seal under a fresh key.
      expect(await store!.setString('e2e_7_decrypted_43', '{"c":"new"}'),
          isTrue);
      expect(store!.getString('e2e_7_decrypted_43'), '{"c":"new"}');
    });

    test('corrupt sealed row is retired, kept, and skipped', () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"content":"hi"}');
      await store!.close();
      // Tamper: flip the key-marker byte so unseal refuses.
      final row = db.rows['e2e_7_decrypted_41']!;
      final bad = Uint8List.fromList(row.sealed!);
      bad[0] ^= 0xff;
      db.rows['e2e_7_decrypted_41'] =
          RecordRow(k: row.k, kid: row.kid, sealed: bad);

      store = await openStore();
      expect(store!.getString('e2e_7_decrypted_41'), isNull);
      expect(db.rows.containsKey('e2e_7_decrypted_41'), isTrue);
      final retired =
          jsonDecode(store!.getString('e2e_7_retired_v1')!) as List;
      expect(retired, contains(41));
    });
  });

  group('legacy migration drain', () {
    test('seeds, serves, seals, and deletes legacy prefs keys', () async {
      store = await openStore(prefs: {
        'e2e_7_decrypted_41': '{"content":"legacy"}',
        'e2e_7_retention_epoch_v1': 555,
        'theme_mode': 'dark', // non-e2e: never touched
      });
      // Served immediately, before any drain completes.
      expect(store!.getString('e2e_7_decrypted_41'), '{"content":"legacy"}');
      expect(store!.getInt('e2e_7_retention_epoch_v1'), 555);

      await store!.debugDrainNow();
      final legacy = await SharedPreferences.getInstance();
      expect(legacy.containsKey('e2e_7_decrypted_41'), isFalse);
      expect(legacy.containsKey('e2e_7_retention_epoch_v1'), isFalse);
      expect(legacy.getString('theme_mode'), 'dark');
      // Migrated record is SEALED in the DB.
      expect(db.rows['e2e_7_decrypted_41']!.kid, isNotNull);
      expect(store!.debugDrainDone, isTrue);
    });

    test('a refused DB write leaves the prefs key for the next drain',
        () async {
      store = await openStore(prefs: {
        'e2e_7_decrypted_41': '{"content":"legacy"}',
      });
      db.failNextWrites = 1;
      await store!.debugDrainNow();
      final legacy = await SharedPreferences.getInstance();
      // Not migrated, NOT deleted — the value has exactly one durable home.
      expect(legacy.getString('e2e_7_decrypted_41'), '{"content":"legacy"}');
      expect(store!.debugDrainDone, isFalse);

      await store!.debugDrainNow();
      expect(legacy.containsKey('e2e_7_decrypted_41'), isFalse);
      expect(db.rows['e2e_7_decrypted_41']!.kid, isNotNull);
      expect(store!.debugDrainDone, isTrue);
    });

    test('DB value wins over a stale legacy copy', () async {
      db.rows['e2e_7_decrypted_41'] = RecordRow(
        k: 'e2e_7_decrypted_41',
        text: null,
        kid: null,
        intValue: null,
      );
      // Simulate an already-migrated record: sealed row in the DB whose
      // prefs twin survived a dropped remove.
      store = await openStore(prefs: {
        'e2e_7_decrypted_50': '{"content":"stale"}',
      });
      await store!.setString('e2e_7_decrypted_50', '{"content":"fresh"}');
      await store!.debugDrainNow();
      expect(store!.getString('e2e_7_decrypted_50'), '{"content":"fresh"}');
      final legacy = await SharedPreferences.getInstance();
      expect(legacy.containsKey('e2e_7_decrypted_50'), isFalse);
    });
  });

  group('rotation', () {
    test('removing a sealed record stamps a durable obligation', () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      expect(store!.rotationPending, isFalse);
      expect(await store!.remove('e2e_7_decrypted_41'), isTrue);
      expect(store!.rotationPending, isTrue);
      expect(db.meta['shred_gen'], isNotNull); // durable, not in-memory only
    });

    test('removing an unsent box message stamps it too (decision 104)',
        () async {
      store = await openStore();
      const key = 'e2e_7_boxunsent_v1_temp_1760000000000_7';
      await store!.setString(key, '{"content":"unsent words"}');
      expect(await store!.remove(key), isTrue);
      expect(store!.rotationPending, isTrue);
    });

    test('removing a control record does NOT stamp', () async {
      store = await openStore();
      await store!.setInt('e2e_7_retention_epoch_v1', 1);
      await store!.remove('e2e_7_retention_epoch_v1');
      expect(store!.rotationPending, isFalse);
    });

    test(
        'rotation re-seals survivors under a new kid, destroys the old key, '
        'and clears the obligation', () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"survivor"}');
      await store!.setString('e2e_7_decrypted_42', '{"c":"victim"}');
      final oldKid = store!.debugActiveKid;
      await store!.remove('e2e_7_decrypted_42');

      final resealCalls = <(Map<String, Uint8List>, String)>[];
      // openStore already wired the resealer; drive the rotation directly.
      await store!.rotateNow();

      expect(store!.rotationPending, isFalse);
      expect(store!.debugActiveKid, isNot(oldKid));
      expect(secure.data.containsKey('fp_content_key_$oldKid'), isFalse,
          reason: 'old key destroyed = the shred');
      expect(db.rows['e2e_7_decrypted_41']!.kid, store!.debugActiveKid);
      expect(store!.getString('e2e_7_decrypted_41'), '{"c":"survivor"}');
      expect(resealCalls, isEmpty, reason: 'wired at open, not here');
    });

    test('N deletes before the rotation fire O(1) rotations', () async {
      store = await openStore();
      for (var i = 0; i < 8; i++) {
        await store!.setString('e2e_7_decrypted_$i', '{"c":"$i"}');
      }
      final sealsBefore = sealer.sealCalls;
      for (var i = 0; i < 6; i++) {
        await store!.remove('e2e_7_decrypted_$i');
      }
      // Removing never re-seals anything by itself.
      expect(sealer.sealCalls, sealsBefore);
      await store!.rotateNow();
      expect(store!.rotationPending, isFalse);
      // One rotation: exactly the 2 survivors re-sealed.
      expect(sealer.sealCalls, sealsBefore + 2);
    });

    test('audio reseal failure aborts BEFORE any key is destroyed', () async {
      store = await openStore(audioResealOk: false);
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      await store!.setString('e2e_7_decrypted_42', '{"c":"b"}');
      final oldKid = store!.debugActiveKid;
      await store!.remove('e2e_7_decrypted_42');
      await store!.rotateNow();
      expect(store!.rotationPending, isTrue, reason: 'obligation survives');
      expect(secure.data.containsKey('fp_content_key_$oldKid'), isTrue,
          reason: 'no key may die while a file could still need it');
      // The record is still readable regardless of which kid holds it now.
      expect(store!.getString('e2e_7_decrypted_41'), '{"c":"a"}');
    });

    test('a purge landing after a rotation leaves the next one owed',
        () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      await store!.setString('e2e_7_decrypted_42', '{"c":"b"}');
      await store!.remove('e2e_7_decrypted_41');
      await store!.rotateNow();
      expect(store!.rotationPending, isFalse);
      await store!.remove('e2e_7_decrypted_42');
      expect(store!.rotationPending, isTrue);
      await store!.rotateNow();
      expect(store!.rotationPending, isFalse);
    });

    test('pending rotation survives a restart (durable stamp)', () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      await store!.remove('e2e_7_decrypted_41');
      expect(store!.rotationPending, isTrue);
      await store!.close();

      store = await openStore();
      expect(store!.rotationPending, isTrue,
          reason: 'kill between purge and rotation must not lose the shred');
      await store!.rotateNow();
      expect(store!.rotationPending, isFalse);
    });

    test('a write racing a rotation is never stranded under a dead key',
        () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      await store!.remove('e2e_7_decrypted_41'); // owes a rotation

      // Park a sealed write inside seal(), then run the whole rotation on top
      // of it: the row's bytes belong to the retiring key, and its label must
      // agree with them or the reseal pass cannot see it.
      final gate = Completer<void>();
      sealer.sealGate = gate;
      final write = store!.setString('e2e_7_decrypted_99', '{"c":"inflight"}');
      await pumpEventQueue();
      final rotation = store!.rotateNow();
      await pumpEventQueue();
      gate.complete();
      expect(await write, isTrue);
      await rotation;

      // The only honest end state: the record survives a reopen. Either the
      // rotation waited for it, or it deferred the shred — never destroyed the
      // key that record was sealed with.
      await store!.close();
      store = await openStore();
      expect(store!.getString('e2e_7_decrypted_99'), '{"c":"inflight"}');
    });

    test('a cipher failure defers the shred instead of destroying keys',
        () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"survivor"}');
      await store!.setString('e2e_7_decrypted_42', '{"c":"victim"}');
      final oldKid = store!.debugActiveKid;
      await store!.remove('e2e_7_decrypted_42');

      sealer.cipherDown = true; // transient: refuses every unseal AND seal
      await store!.rotateNow();
      expect(secure.data.containsKey('fp_content_key_$oldKid'), isTrue,
          reason: 'an ambiguous decrypt failure is not evidence of corruption');
      expect(store!.rotationPending, isTrue, reason: 'obligation survives');

      sealer.cipherDown = false;
      await store!.rotateNow();
      expect(store!.rotationPending, isFalse);
      expect(secure.data.containsKey('fp_content_key_$oldKid'), isFalse);
      expect(store!.getString('e2e_7_decrypted_41'), '{"c":"survivor"}');
    });

    test('a provably corrupt row is retired, and never blocks the shred',
        () async {
      store = await openStore();
      await store!.setString('e2e_7_decrypted_41', '{"c":"a"}');
      await store!.setString('e2e_7_decrypted_42', '{"c":"b"}');
      final oldKid = store!.debugActiveKid;
      await store!.remove('e2e_7_decrypted_42');
      // Tamper AFTER the view was built, so open-time retirement did not
      // already handle it: the rotation is what must notice.
      final row = db.rows['e2e_7_decrypted_41']!;
      final bad = Uint8List.fromList(row.sealed!);
      bad[0] ^= 0xff;
      db.rows[row.k] = RecordRow(k: row.k, kid: row.kid, sealed: bad);

      await store!.rotateNow();

      expect(store!.rotationPending, isFalse,
          reason: 'corruption cannot block shredding forever');
      expect(secure.data.containsKey('fp_content_key_$oldKid'), isFalse);
      final retired =
          jsonDecode(store!.getString('e2e_7_retired_v1')!) as List;
      expect(retired, contains(41),
          reason: 'renders "no longer stored", never [Decryption failed]');
    });
  });

  group('AesGcmContentSealer (real cipher)', () {
    test('round-trip, wrong key, tamper', () async {
      final cipher = AesGcmContentSealer();
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final other = Uint8List.fromList(List.generate(32, (i) => 99 - i));
      final plain = Uint8List.fromList(utf8.encode('tajna wiadomość 🔥'));

      final Uint8List? sealed;
      try {
        sealed = await cipher.seal(key, plain);
      } catch (_) {
        markTestSkipped('webcrypto native unavailable');
        return;
      }
      if (sealed == null) {
        markTestSkipped('webcrypto native unavailable');
        return;
      }
      expect(utf8.decode((await cipher.unseal(key, sealed))!),
          'tajna wiadomość 🔥');
      expect(await cipher.unseal(other, sealed), isNull);
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 1;
      expect(await cipher.unseal(key, tampered), isNull);
      // IVs must never repeat across seals of the same payload.
      final sealed2 = await cipher.seal(key, plain);
      expect(sealed2!.sublist(0, 12), isNot(sealed.sublist(0, 12)));
    });
  });
}
