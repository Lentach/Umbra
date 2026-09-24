import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:fireplace/services/encryption/content_key_manager.dart';
import 'package:fireplace/services/encryption/content_key_wrap.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption/content_kv_opener_stub.dart'
    as web_opener;
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/encryption/sealed_web_content_kv.dart';
import 'package:fireplace/services/encryption/sealed_web_envelope.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';

/// Guards of `docs/design/web-content-sealing.md` §5. The one unforgivable
/// failure class: any path that lets a transient seal/key/enumeration error
/// read as "record absent" — the ledger gate retires PERMANENTLY on
/// `recordExists == false`, so that misreading destroys real history (the
/// 2026-08-02 incident shape). Everything here pins the tri-state chain, the
/// locked proven-loss fold, and the verify-before-overwrite drain.

/// Deterministic [ContentSealer]: `12-byte counter IV | keyTag | body`.
/// Key-dependent (wrong key refuses), reversible, and switchable into the
/// failure modes the store defends against.
class _FakeSealer implements ContentSealer {
  bool failSeal = false;

  /// Seals a body that does NOT round-trip to the plaintext — the drain's
  /// verify-before-overwrite must catch this while the plaintext still
  /// exists.
  bool corruptRoundTrip = false;

  /// One-shot: awaited INSIDE the next [seal] call before it completes —
  /// the D1 interleave point where a foreground edit/purge can land while
  /// the drain is suspended on its crypto awaits.
  Future<void> Function()? beforeSealCompletes;

  int _counter = 0;

  static int _keyTag(Uint8List key) =>
      key.fold<int>(0, (a, b) => (a + b) & 0xff);

  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async {
    final hook = beforeSealCompletes;
    beforeSealCompletes = null;
    if (hook != null) await hook();
    if (failSeal) return null;
    _counter++;
    final iv = Uint8List(12)
      ..[0] = _counter & 0xff
      ..[1] = (_counter >> 8) & 0xff;
    final body = corruptRoundTrip
        ? Uint8List.fromList(plaintext.reversed.toList())
        : plaintext;
    return Uint8List.fromList([...iv, _keyTag(key), ...body]);
  }

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (sealed.length < 13) return null;
    if (sealed[12] != _keyTag(key)) return null;
    return Uint8List.sublistView(sealed, 13);
  }
}

/// Secure-storage fake with the failure modes proven loss must never be
/// inferred from: throwing enumeration, an enumeration override (stale
/// snapshot / post-mint miss), and dropped writes.
class _FakeSecureKv implements SecureKv {
  final Map<String, String> store = {};

  bool throwReadAll = false;
  bool dropWrites = false;

  /// Served by the NEXT readAll call only, then cleared.
  Map<String, String>? readAllOverrideOnce;

  /// Runs inside the NEXT readAll, after the snapshot is taken and before it
  /// is returned — the C1 interleave: another engine mints and seals while
  /// this engine holds a stale inventory.
  Future<void> Function()? onNextReadAll;

  /// Scripted enumerations, consumed FIFO; a null entry serves the live map.
  /// Lets a test target the SECOND readAll (the post-mint arm read).
  List<Map<String, String>?>? readAllScript;

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async {
    if (dropWrites) return;
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (throwReadAll) throw Exception('secure storage unavailable');
    Map<String, String>? override;
    final script = readAllScript;
    if (script != null && script.isNotEmpty) {
      override = script.removeAt(0);
    } else {
      override = readAllOverrideOnce;
      readAllOverrideOnce = null;
    }
    final snapshot = override ?? Map<String, String>.of(store);
    final hook = onNextReadAll;
    onNextReadAll = null;
    if (hook != null) await hook();
    return snapshot;
  }
}

/// Serializing cross-context lock double that also records which lock was
/// held while store internals ran — pins that inventory and the proven-loss
/// fold happen INSIDE the content-keys lock.
class _RecordingLock {
  final List<String> active = [];
  Future<void> _tail = Future.value();

  Future<T> run<T>(String name, Future<T> Function() action) {
    final prev = _tail;
    final result = prev.then((_) async {
      active.add(name);
      try {
        return await action();
      } finally {
        active.remove(name);
      }
    });
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// Backing prefs store that can refuse commits and observe writes.
class _ObservableStore extends SharedPreferencesStorePlatform {
  _ObservableStore() : _inner = InMemorySharedPreferencesStore.empty();

  final InMemorySharedPreferencesStore _inner;

  String? refusePrefix;
  bool throwGetAll = false;
  void Function(String key)? onSetValue;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    onSetValue?.call(key);
    final refuse = refusePrefix;
    if (refuse != null && key.contains(refuse)) return Future.value(false);
    return _inner.setValue(valueType, key, value);
  }

  @override
  Future<bool> clear() => _inner.clear();

  @override
  Future<Map<String, Object>> getAll() {
    if (throwGetAll) throw Exception('enumeration failed');
    return _inner.getAll();
  }

  @override
  Future<bool> remove(String key) => _inner.remove(key);

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      _inner.clearWithPrefix(prefix);

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _inner.clearWithParameters(parameters);

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      _inner.getAllWithPrefix(prefix);

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => _inner.getAllWithParameters(parameters);
}

const _hexA = // 32 bytes of 0x01
    '0101010101010101010101010101010101010101010101010101010101010101';
const _hexB = // 32 bytes of 0x02
    '0202020202020202020202020202020202020202020202020202020202020202';

Uint8List _bytesOf(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ObservableStore store;
  late _FakeSealer sealer;
  late _FakeSecureKv secure;
  late SharedPreferences prefs;

  Future<SealedWebContentKv> openStore({
    Future<T> Function<T>(String, Future<T> Function())? lock,
  }) => SealedWebContentKv.open(
    prefs: prefs,
    keys: ContentKeyManager(secure),
    sealer: sealer,
    lock: lock,
  );

  // Phase 2: a passcode-wrapped content key whose vault is locked. The
  // plaintext fallback in `content_kv_opener_stub.dart` is correct for a
  // genuinely unavailable store, but taking it while LOCKED would write the
  // decrypted-message cache in cleartext with the app still locked — so the
  // exception has to say "locked" and the opener has to refuse to fall back.
  Future<SealedWebContentKv> openStoreLocked() => SealedWebContentKv.open(
    prefs: prefs,
    keys: ContentKeyManager(
      secure,
      wrap: ContentKeyWrap(sealer: sealer),
    ),
    sealer: sealer,
    lock: null,
  );

  group('passcode-wrapped keys (Phase 2)', () {
    test('a locked key is unavailable-and-locked, never a plaintext fallback',
        () async {
      secure.store['fp_content_key_kidA'] = 'fpwk1:kek1:AQIDBA==';

      await expectLater(
        openStoreLocked(),
        throwsA(
          isA<ContentStoreUnavailable>()
              .having((e) => e.stage, 'stage', 'locked')
              .having((e) => e.locked, 'locked', isTrue),
        ),
      );
    });

    test('revoke drops the keys AND the decrypted view, keeping rows PRESENT',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      prefs.setString('e2e_7_decrypted_1', 'seed');
      final kv = await openStore();
      expect(await kv.setString('e2e_7_decrypted_1', 'hello'), isTrue);
      expect(kv.getString('e2e_7_decrypted_1'), 'hello');

      kv.revoke();

      // The row is still PRESENT — served as its raw envelope, never null and
      // never plaintext. A null here is what retires history permanently.
      final held = kv.getString('e2e_7_decrypted_1');
      expect(held, isNotNull);
      expect(held, isNot('hello'));
      expect(SealedWebEnvelope.isEnvelope(held!), isTrue);
      // And the plaintext is gone from RAM, not merely unreachable through
      // this getter: a reload cannot bring it back either.
      await kv.reload();
      expect(kv.getString('e2e_7_decrypted_1'), isNot('hello'));
    });

    test('a revoked store REFUSES sealed writes instead of sealing blind',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      final kv = await openStore();
      kv.revoke();

      expect(await kv.setString('e2e_7_decrypted_9', 'after lock'), isFalse);
      // Nothing was persisted, in any form.
      expect(prefs.getString('e2e_7_decrypted_9'), isNull);
      // Control records are not key material and must still be writable, or
      // the retired set and the ledger freeze mid-session.
      expect(await kv.setString('e2e_7_retired_v1', '[1]'), isTrue);
    });

    test('authoritativeSnapshot stays TOTAL after a revoke', () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      final kv = await openStore();
      await kv.setString('e2e_7_decrypted_1', 'hello');

      kv.revoke();

      final snapshot = await kv.authoritativeSnapshot();
      // Present, undecodable — the tri-state `recordExists` depends on.
      expect(snapshot, isNotNull);
      expect(snapshot!.containsKey('e2e_7_decrypted_1'), isTrue);
      expect(snapshot['e2e_7_decrypted_1'], isNot('hello'));
    });
  });

  Future<String> envelopeOf(
    String kid,
    Uint8List key,
    String plaintext, {
    int? cid,
  }) async {
    final sealed = await sealer.seal(
      key,
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return SealedWebEnvelope(kid: kid, cid: cid, bytes: sealed!).encode();
  }

  /// A well-formed envelope whose bytes no key can unseal (tag 0xFF).
  String corruptEnvelope(String kid, {int? cid}) => SealedWebEnvelope(
    kid: kid,
    cid: cid,
    bytes: Uint8List(20)..[12] = 0xff,
  ).encode();

  Set<int> retiredOf(int uid) {
    final raw = prefs.getString('e2e_${uid}_retired_v1');
    if (raw == null) return <int>{};
    return (jsonDecode(raw) as List).whereType<int>().toSet();
  }

  setUp(() async {
    store = _ObservableStore();
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    prefs = await SharedPreferences.getInstance();
    sealer = _FakeSealer();
    secure = _FakeSecureKv();
    E2eDiagLog.clear();
  });

  group('envelope codec', () {
    test('round-trips kid, cid and bytes', () {
      final env = SealedWebEnvelope(
        kid: 'k17',
        cid: 75,
        bytes: Uint8List.fromList(List.generate(20, (i) => i)),
      );
      final parsed = SealedWebEnvelope.tryParse(env.encode())!;
      expect(parsed.kid, 'k17');
      expect(parsed.cid, 75);
      expect(parsed.bytes, env.bytes);
      final noCid = SealedWebEnvelope(
        kid: 'k17',
        cid: null,
        bytes: Uint8List(13),
      );
      expect(SealedWebEnvelope.tryParse(noCid.encode())!.cid, isNull);
    });

    test('refuses malformed values instead of classifying them', () {
      expect(SealedWebEnvelope.tryParse('{"_cid":75}'), isNull);
      expect(SealedWebEnvelope.tryParse('fps1:'), isNull);
      expect(SealedWebEnvelope.tryParse('fps1:kid:notacid:AAAA'), isNull);
      expect(SealedWebEnvelope.tryParse('fps1:kid:-:@@@'), isNull);
      // 12 bytes cannot hold IV + tag: not a real seal.
      expect(
        SealedWebEnvelope.tryParse('fps1:kid:-:${base64Encode(Uint8List(12))}'),
        isNull,
      );
    });
  });

  group('open and key custody', () {
    test('cold store mints, arms and seals new writes', () async {
      final kv = await openStore();
      expect(kv.debugActiveKid, isNotEmpty);
      expect(secure.store['fp_content_key_${kv.debugActiveKid}'], isNotNull);
      expect(prefs.getString(SealedWebContentKv.activeKidKey),
          kv.debugActiveKid);

      expect(await kv.setString('e2e_37_decrypted_9', '{"_cid":75,"c":"hi"}'),
          isTrue);
      final raw = prefs.getString('e2e_37_decrypted_9')!;
      expect(SealedWebEnvelope.isEnvelope(raw), isTrue);
      expect(SealedWebEnvelope.tryParse(raw)!.cid, 75);
      expect(kv.getString('e2e_37_decrypted_9'), '{"_cid":75,"c":"hi"}');
    });

    test('null inventory changes NOTHING: open throws, zero retirements',
        () async {
      await prefs.setString(
        'e2e_37_decrypted_11',
        await envelopeOf('kidA', _bytesOf(1), 'x'),
      );
      secure.throwReadAll = true;
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'inventory')),
      );
      expect(retiredOf(37), isEmpty);
      expect(prefs.getString('e2e_37_decrypted_11'), isNotNull);
    });

    test('empty enumeration with sealed rows = unavailable, not wiped',
        () async {
      await prefs.setString(
        'e2e_37_decrypted_12',
        await envelopeOf('kidA', _bytesOf(1), 'x'),
      );
      // Successful enumeration, no content keys at all.
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'empty-enumeration')),
      );
      expect(retiredOf(37), isEmpty);
    });

    test('armed gate: a mint whose read-back misses never seals', () async {
      secure.dropWrites = true;
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'mint')),
      );
      // Mint's own write+read-back succeeds, but the post-mint ARMING
      // inventory cannot see the key: still refused, nothing ever sealed.
      secure.dropWrites = false;
      secure.readAllScript = [null, <String, String>{}];
      await expectLater(
        openStore(),
        throwsA(isA<ContentStoreUnavailable>()
            .having((e) => e.stage, 'stage', 'arm')),
      );
      expect(prefs.getString(SealedWebContentKv.activeKidKey), isNull);
    });

    test('proven kid loss retires that kid only — and never deletes',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      final live = await envelopeOf('kidA', _bytesOf(1), '{"c":"kept"}');
      final lost1 = await envelopeOf('kidGone', _bytesOf(9), 'x', cid: 75);
      final lost2 = await envelopeOf('kidGone', _bytesOf(9), 'y');
      await prefs.setString('e2e_37_decrypted_21', live);
      await prefs.setString('e2e_37_decrypted_22', lost1);
      await prefs.setString('e2e_37_decrypt_raw_v1_23', lost2);

      final kv = await openStore();
      expect(retiredOf(37), {22, 23});
      // Rows are NEVER deleted: the key may come back.
      expect(prefs.getString('e2e_37_decrypted_22'), lost1);
      expect(prefs.getString('e2e_37_decrypt_raw_v1_23'), lost2);
      // The surviving kid's rows are served.
      expect(kv.getString('e2e_37_decrypted_21'), '{"c":"kept"}');
      // The lost rows read PRESENT (their raw envelope), never absent.
      expect(kv.getString('e2e_37_decrypted_22'), lost1);
    });

    test(
        'a lost-kid id with a READABLE sibling source is NOT retired '
        '(review finding D2: the fold must be no more aggressive than the '
        'runtime gate\'s recordExists && rawReplayExists conjunction)',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      // 201: decrypted_ lost, but the raw replay cache still serves it.
      await prefs.setString(
        'e2e_37_decrypted_201',
        await envelopeOf('kidGone', _bytesOf(9), 'x'),
      );
      await prefs.setString(
        'e2e_37_decrypt_raw_v1_201',
        await envelopeOf('kidA', _bytesOf(1), '{"raw":"replayable"}'),
      );
      // 202: decrypted_ lost with no sibling — genuinely unservable.
      await prefs.setString(
        'e2e_37_decrypted_202',
        await envelopeOf('kidGone', _bytesOf(9), 'y'),
      );
      // 203: raw cache lost, but the decrypted record is legacy plaintext.
      await prefs.setString(
        'e2e_37_decrypt_raw_v1_203',
        await envelopeOf('kidGone', _bytesOf(9), 'z'),
      );
      await prefs.setString('e2e_37_decrypted_203', '{"c":"readable"}');

      await openStore();
      expect(retiredOf(37), {202},
          reason: '201 and 203 are still servable from a surviving source; '
              'retiring them would over-destroy');
    });

    test('marker pointing at a missing kid falls back to a surviving key',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      await prefs.setString(SealedWebContentKv.activeKidKey, 'kidVanished');
      final kv = await openStore();
      expect(kv.debugActiveKid, 'kidA');
      expect(prefs.getString(SealedWebContentKv.activeKidKey), 'kidA');
    });
  });

  group('tri-state: unseal failure is UNDETERMINED, never absent', () {
    test('unsealable row with its key PRESENT reads present-but-unreadable',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      final corrupt = corruptEnvelope('kidA');
      await prefs.setString('e2e_37_decrypted_31', corrupt);

      final kv = await openStore();
      // Served as its raw envelope: non-null (present), undecodable.
      expect(kv.getString('e2e_37_decrypted_31'), corrupt);
      // Never retired: corruption is not proven key loss.
      expect(retiredOf(37), isEmpty);
      // The snapshot NEVER omits it (omission == absent == retire).
      final snapshot = await kv.authoritativeSnapshot();
      expect(snapshot!['e2e_37_decrypted_31'], corrupt);
    });

    test('recordExists answers true for an unsealable row through the service',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      await prefs.setString('e2e_37_decrypted_32', corruptEnvelope('kidA'));
      final kv = await openStore();

      FlutterSecureStorage.setMockInitialValues({});
      final service = EncryptionService();
      await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      service.debugSetContentKv(kv);

      expect(await service.recordExists(32), isTrue);
    });

    test(
        'snapshot totality: enumeration failure THROWS and recordExists '
        'answers null, never false', () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      await prefs.setString(
        'e2e_37_decrypted_33',
        await envelopeOf('kidA', _bytesOf(1), '{"c":"x"}'),
      );
      final kv = await openStore();

      FlutterSecureStorage.setMockInitialValues({});
      final service = EncryptionService();
      await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      service.debugSetContentKv(kv);

      store.throwGetAll = true;
      await expectLater(kv.authoritativeSnapshot(), throwsA(anything));
      // The catch in recordExists turns the throw into UNDETERMINED.
      expect(await service.recordExists(33), isNull);
      expect(await service.recordExists(99999), isNull);
    });
  });

  group('write path', () {
    test('a refused seal refuses the write and touches nothing', () async {
      final kv = await openStore();
      await kv.setString('e2e_37_decrypted_41', '{"c":"old"}');
      final before = prefs.getString('e2e_37_decrypted_41');

      sealer.failSeal = true;
      expect(await kv.setString('e2e_37_decrypted_41', '{"c":"new"}'),
          isFalse);
      expect(prefs.getString('e2e_37_decrypted_41'), before);
      expect(kv.getString('e2e_37_decrypted_41'), '{"c":"old"}');
    });

    test('a refused commit reports false and never persists', () async {
      final kv = await openStore();
      store.refusePrefix = 'e2e_37_decrypted_42';
      expect(await kv.setString('e2e_37_decrypted_42', '{"c":"x"}'), isFalse);
      // The plugin CACHE keeps the refused value (the documented quota trap);
      // the durable truth is the platform store, and it must be empty. The
      // caller's retry policy owns what happens next.
      expect(kv.getString('e2e_37_decrypted_42'), isNot('{"c":"x"}'));
      final backing = await store.getAll();
      expect(backing.containsKey('flutter.e2e_37_decrypted_42'), isFalse);
    });

    test('control records pass through CLEARTEXT', () async {
      final kv = await openStore();
      await kv.setString('e2e_37_retired_v1', '[1,2]');
      await kv.setString('e2e_37_decrypt_ledger_v1', '[3]');
      await kv.setInt('e2e_37_retention_epoch_v1', 123);
      expect(prefs.getString('e2e_37_retired_v1'), '[1,2]');
      expect(prefs.getString('e2e_37_decrypt_ledger_v1'), '[3]');
      expect(prefs.getInt('e2e_37_retention_epoch_v1'), 123);
    });

    test("this device's request-queue keys are sealed, never cleartext",
        () async {
      // The row holds the queue's private auth + seal halves (PR3.1).
      final kv = await openStore();
      await kv.setString('e2e_37_boxreq_v1', '{"v":1,"queue":{}}');
      expect(
        SealedWebEnvelope.isEnvelope(prefs.getString('e2e_37_boxreq_v1')!),
        isTrue,
      );
      expect(kv.getString('e2e_37_boxreq_v1'), '{"v":1,"queue":{}}');
    });

    test('remove drops the row and the view', () async {
      final kv = await openStore();
      await kv.setString('e2e_37_decrypted_43', '{"c":"x"}');
      expect(await kv.remove('e2e_37_decrypted_43'), isTrue);
      expect(kv.getString('e2e_37_decrypted_43'), isNull);
      expect(prefs.getString('e2e_37_decrypted_43'), isNull);
    });
  });

  group('read-both and the drain', () {
    test('legacy plaintext is served verbatim and sealed by the drain',
        () async {
      await prefs.setString('e2e_37_decrypted_51', '{"_cid":75,"c":"legacy"}');
      await prefs.setString('e2e_37_pendsend_v1_ct1', '{"p":"send"}');
      final kv = await openStore();

      // Read-both: correctness never depends on the drain finishing.
      expect(kv.getString('e2e_37_decrypted_51'), '{"_cid":75,"c":"legacy"}');

      await kv.debugDrainNow();
      expect(kv.debugLegacyResidue, isEmpty);
      final raw = prefs.getString('e2e_37_decrypted_51')!;
      expect(SealedWebEnvelope.isEnvelope(raw), isTrue);
      expect(SealedWebEnvelope.tryParse(raw)!.cid, 75);
      expect(
        SealedWebEnvelope.isEnvelope(
          prefs.getString('e2e_37_pendsend_v1_ct1')!,
        ),
        isTrue,
      );
      // Still served after sealing.
      expect(kv.getString('e2e_37_decrypted_51'), '{"_cid":75,"c":"legacy"}');
      expect(
        E2eDiagLog.entries.any((e) => e.contains('WEB_SEAL_DRAIN_DONE')),
        isTrue,
      );
    });

    test(
        'drain never overwrites unverified: a non-round-tripping envelope '
        'leaves the plaintext UNTOUCHED', () async {
      await prefs.setString('e2e_37_decrypted_52', '{"c":"only copy"}');
      // Corrupt BEFORE open: the open-scheduled auto-drain must hit the
      // failing sealer too, not race the flag.
      sealer.corruptRoundTrip = true;
      final kv = await openStore();
      await kv.debugDrainNow();
      // Verify happens IN RAM before the destructive write: plaintext intact.
      expect(prefs.getString('e2e_37_decrypted_52'), '{"c":"only copy"}');
      expect(kv.debugLegacyResidue, contains('e2e_37_decrypted_52'));

      // Resume: the next healthy pass finishes the migration with no loss.
      sealer.corruptRoundTrip = false;
      await kv.debugDrainNow();
      expect(kv.debugLegacyResidue, isEmpty);
      expect(
        SealedWebEnvelope.isEnvelope(prefs.getString('e2e_37_decrypted_52')!),
        isTrue,
      );
      expect(kv.getString('e2e_37_decrypted_52'), '{"c":"only copy"}');
    });

    test('a refused drain commit keeps the plaintext durable and retries '
        'later', () async {
      await prefs.setString('e2e_37_decrypted_53', '{"c":"kept"}');
      // Refuse BEFORE open so the open-scheduled auto-drain cannot race the
      // flag and seal the row first.
      store.refusePrefix = 'e2e_37_decrypted_53';
      final kv = await openStore();
      await kv.debugDrainNow();
      // Cache may hold the refused envelope; the DURABLE copy is still the
      // plaintext, and the row stays in the residue for the next session.
      final backing = await store.getAll();
      expect(backing['flutter.e2e_37_decrypted_53'], '{"c":"kept"}');
      expect(kv.debugLegacyResidue, contains('e2e_37_decrypted_53'));
    });

    test('control records stay cleartext after a full drain', () async {
      await prefs.setString('e2e_37_retired_v1', '[7]');
      await prefs.setString('e2e_37_decrypted_54', '{"c":"x"}');
      final kv = await openStore();
      await kv.debugDrainNow();
      expect(prefs.getString('e2e_37_retired_v1'), '[7]');
    });
  });

  group('drain concurrency (review finding D1)', () {
    test('an edit landing mid-drain is never clobbered by the stale re-seal',
        () async {
      await prefs.setString('e2e_37_decrypted_55', '{"c":"v1"}');
      late SealedWebContentKv kv;
      final opened = Completer<void>();
      // Fires inside the drain's seal await: the foreground edit replaces
      // the value while the drain holds a stale plaintext.
      sealer.beforeSealCompletes = () async {
        await opened.future;
        await kv.setString('e2e_37_decrypted_55', '{"c":"v2 edited"}');
      };
      kv = await openStore();
      opened.complete();
      await kv.debugDrainNow();
      // The newer value survives — on disk AND in the view.
      expect(kv.getString('e2e_37_decrypted_55'), '{"c":"v2 edited"}');
      final raw = prefs.getString('e2e_37_decrypted_55')!;
      expect(SealedWebEnvelope.isEnvelope(raw), isTrue);
      expect(kv.debugLegacyResidue, isEmpty);
    });

    test('a purge landing mid-drain is never resurrected by the re-seal',
        () async {
      await prefs.setString('e2e_37_decrypted_56', '{"c":"destroy me"}');
      late SealedWebContentKv kv;
      final opened = Completer<void>();
      sealer.beforeSealCompletes = () async {
        await opened.future;
        await kv.remove('e2e_37_decrypted_56');
      };
      kv = await openStore();
      opened.complete();
      await kv.debugDrainNow();
      // The user asked for this plaintext to be gone: it STAYS gone.
      expect(prefs.getString('e2e_37_decrypted_56'), isNull);
      expect(kv.getString('e2e_37_decrypted_56'), isNull);
      expect(kv.debugLegacyResidue, isEmpty);
    });
  });

  group('cross-engine coherence', () {
    test('a row sealed by another engine appears after reload', () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      final kv = await openStore();

      // "Another engine": writes through the shared backing store.
      await prefs.setString(
        'e2e_37_decrypted_61',
        await envelopeOf('kidA', _bytesOf(1), '{"c":"peer"}'),
      );
      await kv.reload();
      expect(kv.getString('e2e_37_decrypted_61'), '{"c":"peer"}');

      await prefs.remove('e2e_37_decrypted_61');
      await kv.reload();
      expect(kv.getString('e2e_37_decrypted_61'), isNull);
    });

    test(
        'a kid minted by another engine mid-session is unsealed after an '
        'inventory refresh — and NEVER retired', () async {
      final kv = await openStore();

      // Peer engine mints kidB and seals a row under it.
      secure.store['fp_content_key_kidB'] = _hexB;
      await prefs.setString(
        'e2e_37_decrypted_62',
        await envelopeOf('kidB', _bytesOf(2), '{"c":"minted later"}'),
      );
      await kv.reload();
      expect(kv.getString('e2e_37_decrypted_62'), '{"c":"minted later"}');
      expect(retiredOf(37), isEmpty);
    });

    test('an envelope under a kid nobody has reads present, not retired',
        () async {
      final kv = await openStore();
      final orphan = await envelopeOf('kidNobody', _bytesOf(7), 'x');
      await prefs.setString('e2e_37_decrypted_63', orphan);
      await kv.reload();
      // Mid-session skew never retires; the row waits for the next LOCKED
      // open to prove anything.
      expect(kv.getString('e2e_37_decrypted_63'), orphan);
      expect(retiredOf(37), isEmpty);
    });
  });

  group('the open lock (design §3.2a, review finding C1)', () {
    test(
        'HAZARD (documents why the lock exists): an UNSERIALIZED open whose '
        'inventory predates a peer mint retires readable rows', () async {
      secure.store['fp_content_key_kidOld'] = _hexA;
      await prefs.setString(
        'e2e_37_decrypted_71',
        await envelopeOf('kidOld', _bytesOf(1), '{"c":"old"}'),
      );
      // The stale snapshot this engine's inventory will see.
      secure.readAllOverrideOnce = Map<String, String>.of(secure.store);
      // The peer's mint+seal lands between that inventory and the row scan.
      secure.onNextReadAll = () async {
        secure.store['fp_content_key_kidA'] = _hexB;
        await prefs.setString(
          'e2e_37_decrypted_72',
          await envelopeOf('kidA', _bytesOf(2), '{"c":"fresh"}'),
        );
      };

      await openStore(); // default lock on the VM is a passthrough
      // The fresh, fully readable row was retired: the forbidden outcome the
      // lock prevents (rows survive — retirement never deletes).
      expect(retiredOf(37), {72});
      expect(prefs.getString('e2e_37_decrypted_72'), isNotNull);
    });

    test('inventory and the proven-loss fold run INSIDE the content-keys lock',
        () async {
      secure.store['fp_content_key_kidA'] = _hexA;
      await prefs.setString(
        'e2e_37_decrypted_73',
        await envelopeOf('kidGone', _bytesOf(9), 'x'),
      );
      final lock = _RecordingLock();
      var readAllUnderLock = false;
      var foldUnderLock = false;
      secure.onNextReadAll = () async {
        readAllUnderLock =
            lock.active.contains(SealedWebContentKv.lockName);
      };
      store.onSetValue = (key) {
        if (key.contains('retired_v1')) {
          foldUnderLock = lock.active.contains(SealedWebContentKv.lockName);
        }
      };

      await openStore(lock: lock.run);
      expect(readAllUnderLock, isTrue,
          reason: 'inventory outside the lock re-arms the C1 race');
      expect(foldUnderLock, isTrue,
          reason: 'retiring outside the lock re-arms the C1 race');
      expect(retiredOf(37), {73});
    });

    test('a serialized second open sees the first open\'s mint: no retirement',
        () async {
      final lock = _RecordingLock();
      final first = await openStore(lock: lock.run);
      await first.setString('e2e_37_decrypted_74', '{"c":"mine"}');

      // Second engine, same lock domain: its locked section starts after the
      // first one's, so its fresh inventory contains the first mint.
      final second = await openStore(lock: lock.run);
      expect(retiredOf(37), isEmpty);
      expect(second.getString('e2e_37_decrypted_74'), '{"c":"mine"}');
    });
  });

  group('erasure completeness (advisory finding)', () {
    late EncryptionService service;

    setUp(() async {
      PrefsContentKv.debugForceAuthoritative = true;
      addTearDown(() => PrefsContentKv.debugForceAuthoritative = false);
      FlutterSecureStorage.setMockInitialValues({});
      service = EncryptionService();
      await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      // A FALLBACK session: plain prefs backend over a store that already
      // holds sealed envelopes (the drain ran in a sealed session earlier).
      service.debugSetContentKv(PrefsContentKv(prefs));
    });

    test(
        'user-requested deletion selects sealed rows via envelope cid in a '
        'session that cannot unseal them', () async {
      await prefs.setString(
        'e2e_37_decrypted_81',
        corruptEnvelope('kidX', cid: 75),
      );
      await prefs.setString(
        'e2e_37_decrypted_82',
        corruptEnvelope('kidX', cid: 76),
      );
      await prefs.setString('e2e_37_decrypted_83', '{"_cid":75,"c":"plain"}');
      // Pre-`_cid` sealed legacy: no conversation, must never be selected.
      await prefs.setString('e2e_37_decrypted_84', corruptEnvelope('kidX'));

      final ids = await service.messageIdsForConversations({75});
      expect(ids, {81, 83},
          reason: 'the sealed row for conv 75 must be selected; the sealed '
              'row for conv 76 and the cid-less row must NOT be');
    });

    test('automatic destruction still SKIPS envelopes it cannot read',
        () async {
      await prefs.setString(
        'e2e_37_decrypted_85',
        corruptEnvelope('kidX', cid: 75),
      );
      final result = await service.destroyableMessageIds(
        serverNow: DateTime.now().toUtc().add(const Duration(days: 365)),
        expiryGrace: Duration.zero,
      );
      expect(result.expired, isEmpty,
          reason: 'an unreadable row must never satisfy an expiry rule');
      expect(result.retired, isEmpty,
          reason: 'an unreadable row must never age out via the epoch '
              'fallback — over-retention is the recoverable direction');
    });
  });

  group('web opener', () {
    setUp(web_opener.debugResetPlatformContentKv);
    tearDown(web_opener.debugResetPlatformContentKv);

    test('falls back to prefs, loudly and STICKILY, when arming fails',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      // Sealed rows exist but the (successful) enumeration has no content
      // key: unavailable-not-wiped.
      await prefs.setString(
        'e2e_37_decrypted_91',
        corruptEnvelope('kidX'),
      );
      final first = await web_opener.openPlatformContentKv();
      expect(first, isA<PrefsContentKv>());
      expect(
        E2eDiagLog.entries.any((e) =>
            e.contains('CONTENT_STORE_FALLBACK') &&
            e.contains('web-empty-enumeration')),
        isTrue,
      );
      // Memoized: the session never flips backends.
      final second = await web_opener.openPlatformContentKv();
      expect(identical(first, second), isTrue);
    });

    test('opens the sealed backend when arming succeeds', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final kv = await web_opener.openPlatformContentKv();
      expect(kv, isA<SealedWebContentKv>());
    });
  });
}
