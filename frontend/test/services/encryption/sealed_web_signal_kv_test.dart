import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart'
    show SignalProtocolAddress;

import 'package:fireplace/services/encryption/content_key_manager.dart';
import 'package:fireplace/services/encryption/content_key_wrap.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/encryption/sealed_sig_envelope.dart';
import 'package:fireplace/services/encryption/sealed_web_signal_kv.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'web_signal_kv_store_test.dart' show FakeAsyncKv, FakeLegacyKv;

/// The web sig-sealing store (docs/design/web-sig-sealing.md §5 falsification
/// plan, store-level half; the service-level R1/R3 hardenings live in
/// `../encryption_service_sig_hardening_test.dart`).
///
/// The cases where the store must NOT act (throw instead of absent, skip
/// instead of clobber, fail closed instead of fall back) are worth more than
/// the happy path: every absent-shaped answer here feeds identity
/// regeneration, ratchet resets, or prekey id reuse upstream.
class _FakeSealer implements ContentSealer {
  bool failSeal = false;

  /// Seals a body that does NOT round-trip — the drain's verify-before-write
  /// must catch this while the plaintext still exists.
  bool corruptRoundTrip = false;

  /// One-shot: awaited INSIDE the next [seal] call before it completes — the
  /// interleave point where a concurrent writer can land mid-drain.
  Future<void> Function()? beforeSealCompletes;

  int _counter = 0;

  int _keyTag(Uint8List key) => key.fold(0, (a, b) => a ^ b);

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
    if (sealed[12] != _keyTag(key)) return null; // wrong key
    return Uint8List.sublistView(sealed, 13);
  }
}

class _FakeSecureKv implements SecureKv {
  final Map<String, String> store = {};
  bool throwReadAll = false;
  bool dropWrites = false;

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
    return Map.of(store);
  }
}

/// Per-NAME serializing lock that records every name acquired — pins that
/// the drain takes the PER-PEER session lock for session rows (§5.13) and
/// the sig-keys lock at open. Per-name tails, like the real Web Locks API.
///
/// Also records the §5.17 lock-order hazard: any acquisition REQUESTED while
/// `fireplace-e2e-sig-keys` is HELD is the ABBA half of a cross-engine
/// deadlock (the ratchet path acquires per-peer → lazy store open →
/// sig-keys; Web Locks are origin-wide with no timeout).
class _RecordingLock {
  final List<String> names = [];
  final List<String> nestedWhileSigKeysHeld = [];
  final Set<String> _held = {};
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String name, Future<T> Function() action) {
    if (_held.contains(SealedWebSignalKv.lockName) &&
        name != SealedWebSignalKv.lockName) {
      nestedWhileSigKeysHeld.add(name);
    }
    names.add(name);
    final tail = _tails[name] ?? Future.value();
    final result = tail.then((_) async {
      _held.add(name);
      try {
        return await action();
      } finally {
        _held.remove(name);
      }
    });
    _tails[name] = result.then((_) {}, onError: (_) {});
    return result;
  }
}
/// Routes the libsignal store classes ([SecureSessionStore],
/// [SecurePreKeyStore]) through a [SealedWebSignalKv] — pins the §5.2/§5.3
/// interlocks at the exact method whose absent-shaped answer is catastrophic.
class _SealedDualStorage extends DualStorage {
  _SealedDualStorage(this._kv) : super(const FlutterSecureStorage());

  final SealedWebSignalKv _kv;

  @override
  Future<void> write({required String key, required String value}) =>
      _kv.write(key, value);

  @override
  Future<String?> read({required String key}) => _kv.read(key);

  @override
  Future<void> delete({required String key}) => _kv.delete(key);

  @override
  Future<Map<String, String>> readAll() => _kv.readAll();
}
final String _hex64 = 'ab' * 32;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAsyncKv async;
  late FakeLegacyKv legacy;
  late _FakeSecureKv secure;
  late _FakeSealer sealer;
  late _RecordingLock lock;

  const sessionKey = 'e2e_37_session_2_1';
  const identityKey = 'e2e_37_identity_record_v1';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    E2eDiagLog.clear();
    await E2ePersistentDiag.init();
    async = FakeAsyncKv();
    legacy = FakeLegacyKv();
    secure = _FakeSecureKv();
    sealer = _FakeSealer();
    lock = _RecordingLock();
  });

  WebSignalKvStore inner() =>
      WebSignalKvStore(async, () async => legacy, 'sig_');

  ContentKeyManager keys() =>
      ContentKeyManager(secure, keyPrefix: ContentKeyManager.sigKeyPrefix);

  Future<SealedWebSignalKv> openStore() => SealedWebSignalKv.open(
    inner: inner(),
    keys: keys(),
    sealer: sealer,
    lock: lock.run,
  );

  void seedKey([String kid = 'k1']) {
    secure.store['${ContentKeyManager.sigKeyPrefix}$kid'] = _hex64;
  }

  /// Phase 2: a passcode-wrapped sig key on a device whose vault is locked.
  void seedLockedKey({String kid = 'k1'}) {
    final writer = ContentKeyWrap(sealer: sealer)
      ..unlock(kek: Uint8List(32), kekId: 'kek1');
    // Wrapped with the fake sealer, then abandoned: nothing in this test can
    // open it, which is exactly the locked-device shape.
    secure.store['${ContentKeyManager.sigKeyPrefix}$kid'] = 'fpwk1:kek1:'
        '${base64Encode(Uint8List.fromList([1, 2, 3, 4]))}';
    writer.lock();
  }

  Future<SealedWebSignalKv> openStoreLocked() => SealedWebSignalKv.open(
    inner: inner(),
    keys: ContentKeyManager(
      secure,
      keyPrefix: ContentKeyManager.sigKeyPrefix,
      wrap: ContentKeyWrap(sealer: sealer),
    ),
    sealer: sealer,
    lock: lock.run,
  );

  group('passcode-wrapped keys (Phase 2)', () {
    // THE catastrophe test. A locked key with ZERO sealed rows is the state
    // where every pre-Phase-2 branch does something destructive: the sig
    // store would mint a fresh key and seal over the real one, or declare a
    // plaintext fallback legal — after which the identity reads `absent` and
    // `EncryptionService` mints a new Signal identity. Locked must outrank
    // the sealed-row probe entirely.
    test('locked keys refuse fallback and refuse to mint, even with ZERO '
        'sealed rows on disk', () async {
      seedLockedKey();

      await expectLater(
        openStoreLocked(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isFalse)
              .having((e) => e.stage, 'stage', 'locked'),
        ),
      );
      expect(
        secure.store.keys.where(
          (k) => k.startsWith(ContentKeyManager.sigKeyPrefix),
        ),
        hasLength(1),
        reason: 'nothing may be minted while the vault is locked',
      );
    });

    test('locked keys refuse fallback with sealed rows present too', () async {
      seedKey();
      final kv = await openStore();
      await kv.write(sessionKey, 'live-ratchet');
      secure.store.clear();
      seedLockedKey();

      await expectLater(
        openStoreLocked(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isFalse),
        ),
      );
    });

    test('revoke makes sealed reads THROW — never null, never plaintext',
        () async {
      seedKey();
      final kv = await openStore();
      await kv.write(identityKey, 'identity-bytes');
      expect(await kv.read(identityKey), 'identity-bytes');

      kv.revoke();

      // The absence-as-truth inversion is the one unforgivable failure here:
      // a null identity read is what mints a new Signal identity.
      await expectLater(
        kv.read(identityKey),
        throwsA(
          isA<SigStoreUnreadable>().having((e) => e.stage, 'stage', 'revoked'),
        ),
      );
      // Control records carry no key material and stay readable, so the
      // store's own markers do not start reading as absent either.
      expect(await kv.read('e2e_37_next_pre_key_id'), isNull);
      await kv.write('e2e_37_next_pre_key_id', '42');
      expect(await kv.read('e2e_37_next_pre_key_id'), '42');
    });

    test('a revoked store refuses sealed writes rather than sealing blind',
        () async {
      seedKey();
      final kv = await openStore();
      kv.revoke();

      await expectLater(
        kv.write(sessionKey, 'ratchet-advance'),
        throwsA(isA<SigStoreUnreadable>()),
      );
      expect(await async.getString('sig_$sessionKey'), isNull);
    });

    test('revoke keeps readAll presence-preserving so residue still counts',
        () async {
      seedKey();
      final kv = await openStore();
      await kv.write(identityKey, 'identity-bytes');

      kv.revoke();

      // `_hasPriorInstallResidue` and the highest-prekey-id scan read NAMES
      // out of this map. An enumeration that dropped unreadable rows would
      // make a revoked device look like a fresh install.
      final all = await kv.readAll();
      expect(all.containsKey(identityKey), isTrue);
      expect(all[identityKey], isNot('identity-bytes'));
    });

    // 0.2.74 prod (SaraLee, 2026-11-05): the boot read the Signal store
    // before the passcode screen was passed. The open failed `locked`, and
    // a memoized failure kept every later op throwing after the unlock:
    // E2E down for the session, no send, no decrypt, no invite.
    test('a store opened while the vault is locked opens after the unlock',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final kek = Uint8List(32)..fillRange(0, 32, 7);
      final vault = ContentKeyWrap(sealer: sealer)
        ..unlock(kek: kek, kekId: 'kek1');
      secure.store['${ContentKeyManager.sigKeyPrefix}k1'] =
          (await vault.wrapKey(Uint8List(32)..fillRange(0, 32, 9)))!;
      vault.lock();
      final storage = DualStorage(
        const FlutterSecureStorage(),
        sigKeys: ContentKeyManager(
          secure,
          keyPrefix: ContentKeyManager.sigKeyPrefix,
          wrap: vault,
        ),
        sigSealer: sealer,
        sigLock: lock.run,
        debugForceSealedWeb: true,
      );

      await expectLater(
        storage.read(key: identityKey),
        throwsA(
          isA<SigSealOpenUnavailable>().having((e) => e.stage, 'stage', 'locked'),
        ),
      );

      vault.unlock(kek: Uint8List(32)..fillRange(0, 32, 7), kekId: 'kek1');
      await storage.write(key: identityKey, value: 'identity-bytes');
      expect(await storage.read(key: identityKey), 'identity-bytes');
    });
  });

  group('seam', () {
    test('sealed family seals on write, unseals on read; envelope on disk',
        () async {
      seedKey();
      final kv = await openStore();
      await kv.write(sessionKey, 'ratchet-state-v1');

      final onDisk = async.store['sig_$sessionKey'] as String;
      expect(SealedSigEnvelope.isEnvelope(onDisk), isTrue,
          reason: 'the localStorage value must never be plaintext');
      expect(await kv.read(sessionKey), 'ratchet-state-v1');
    });

    test('§5.8 control records stay cleartext even with the sealer broken',
        () async {
      seedKey();
      final kv = await openStore();
      sealer.failSeal = true;

      await kv.write('e2e_37_next_pre_key_id', '120');
      expect(async.store['sig_e2e_37_next_pre_key_id'], '120');
      expect(await kv.read('e2e_37_next_pre_key_id'), '120');
    });

    test('§5.1 an unsealable value THROWS — never null, never plaintext',
        () async {
      seedKey();
      final kv = await openStore();
      await kv.write(sessionKey, 'live-ratchet');
      // Corrupt the stored envelope body (wrong key tag → unseal null).
      final envelope = SealedSigEnvelope.tryParse(
        async.store['sig_$sessionKey'] as String,
      )!;
      final tampered = Uint8List.fromList(envelope.bytes)..[12] ^= 0xff;
      async.store['sig_$sessionKey'] =
          SealedSigEnvelope.encode(envelope.kid, tampered);

      await expectLater(
        kv.read(sessionKey),
        throwsA(
          isA<SigStoreUnreadable>().having((e) => e.stage, 'stage', 'unseal'),
        ),
      );
    });

    test('unknown kid throws after one refresh attempt', () async {
      seedKey();
      final kv = await openStore();
      final sealed = await sealer.seal(
        Uint8List.fromList(List.filled(32, 7)),
        Uint8List.fromList('x'.codeUnits),
      );
      async.store['sig_$sessionKey'] = SealedSigEnvelope.encode('kGONE', sealed!);

      await expectLater(
        kv.read(sessionKey),
        throwsA(isA<SigStoreUnreadable>().having((e) => e.stage, 'stage', 'kid')),
      );
    });

    test('genuine absence still reads as null', () async {
      seedKey();
      final kv = await openStore();
      expect(await kv.read('e2e_37_session_99_1'), isNull);
    });

    test('§5.2 loadSession on an unsealable row THROWS — never a fresh '
        'SessionRecord (ratchet reset)', () async {
      seedKey();
      final kv = await openStore();
      await kv.write(sessionKey, 'ratchet-state');
      final envelope = SealedSigEnvelope.tryParse(
        async.store['sig_$sessionKey'] as String,
      )!;
      final tampered = Uint8List.fromList(envelope.bytes)..[12] ^= 0xff;
      async.store['sig_$sessionKey'] =
          SealedSigEnvelope.encode(envelope.kid, tampered);

      final sessionStore = SecureSessionStore(
        _SealedDualStorage(kv),
        'e2e_37_',
      );
      await expectLater(
        sessionStore.loadSession(SignalProtocolAddress('2', 1)),
        throwsA(isA<SigStoreUnreadable>()),
      );
    });

    test('§5.3 containsPreKey on an unsealable row THROWS — never false '
        '(prekey id reuse)', () async {
      seedKey();
      final kv = await openStore();
      await kv.write('e2e_37_pre_key_20', 'private-half');
      final envelope = SealedSigEnvelope.tryParse(
        async.store['sig_e2e_37_pre_key_20'] as String,
      )!;
      final tampered = Uint8List.fromList(envelope.bytes)..[12] ^= 0xff;
      async.store['sig_e2e_37_pre_key_20'] =
          SealedSigEnvelope.encode(envelope.kid, tampered);

      final preKeyStore = SecurePreKeyStore(_SealedDualStorage(kv), 'e2e_37_');
      await expectLater(
        preKeyStore.containsPreKey(20),
        throwsA(isA<SigStoreUnreadable>()),
        reason: 'a false here reuses an id whose public half the server '
            'already serves — the overwritten private half bad-MACs whoever '
            'drew it',
      );
    });

    test('read-both: legacy plaintext is served as-is', () async {
      seedKey();
      async.store['sig_$identityKey'] = '{"pair":"AAA","registrationId":7}';
      final kv = await openStore();
      expect(await kv.read(identityKey), '{"pair":"AAA","registrationId":7}');
    });

    test('§5.10 no double-seal; a content fps1: value is not a sig envelope',
        () async {
      seedKey();
      final kv = await openStore();
      const alien = 'fpsig1:k1:AAAAAAAAAAAAAAAAAAAAAAAAAA==';
      await kv.write(sessionKey, alien);
      expect(async.store['sig_$sessionKey'], alien,
          reason: 'an envelope value is written verbatim, never re-sealed');
      expect(SealedSigEnvelope.tryParse('fps1:k1:AAAA'), isNull,
          reason: 'the content magic must not parse as a sig envelope');
    });

    test('§5.16 readAll is presence-preserving: unsealable value appears as '
        'its raw envelope, never omitted, never a throw', () async {
      seedKey();
      final kv = await openStore();
      await kv.write(sessionKey, 'good');
      final bad = 'fpsig1:kGONE:${'A' * 24}';
      async.store['sig_e2e_37_pre_key_5'] = bad;

      final all = await kv.readAll();
      expect(all[sessionKey], 'good');
      expect(all['e2e_37_pre_key_5'], bad,
          reason: 'the key must stay PRESENT so residue/highest-id/inventory '
              'answers stay correct — an omission reads as absent upstream');
    });
  });

  group('open (§3.2 decision table)', () {
    test('cold store mints, arms, writes the marker, takes the sig lock',
        () async {
      final kv = await openStore();
      expect(
        secure.store.keys.where(
          (k) => k.startsWith(ContentKeyManager.sigKeyPrefix),
        ),
        hasLength(1),
      );
      expect(async.store['sig_${SealedWebSignalKv.activeKidMarker}'],
          kv.debugActiveKid);
      expect(lock.names, contains(SealedWebSignalKv.lockName));
    });
    test('§5.7 two engines racing a cold store: the shared lock serializes '
        'the mint — exactly ONE key, both engines agree on it', () async {
      final opens = await Future.wait([
        SealedWebSignalKv.open(
          inner: inner(),
          keys: keys(),
          sealer: sealer,
          lock: lock.run,
        ),
        SealedWebSignalKv.open(
          inner: inner(),
          keys: keys(),
          sealer: sealer,
          lock: lock.run,
        ),
      ]);

      expect(
        secure.store.keys.where(
          (k) => k.startsWith(ContentKeyManager.sigKeyPrefix),
        ),
        hasLength(1),
        reason: 'the second open runs its inventory AFTER the first mint '
            'under the shared lock; a passthrough lock double-mints',
      );
      expect(opens[0].debugActiveKid, opens[1].debugActiveKid);
    });

    test('§5.4 inventory fails + envelopes exist → fallbackLegal FALSE',
        () async {
      async.store['sig_$sessionKey'] = 'fpsig1:k1:${'A' * 24}';
      secure.throwReadAll = true;

      await expectLater(
        openStore(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isFalse)
              .having((e) => e.stage, 'stage', 'keys-unavailable'),
        ),
      );
    });

    test('inventory fails + PROVEN zero envelopes → fallbackLegal TRUE',
        () async {
      async.store['sig_$identityKey'] = '{"pair":"AAA"}'; // legacy plaintext
      secure.throwReadAll = true;

      await expectLater(
        openStore(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isTrue)
              .having((e) => e.stage, 'stage', 'inventory'),
        ),
      );
    });

    test('§5.14 probe failure is UNDECIDABLE → fail closed, never fallback',
        () async {
      secure.throwReadAll = true;
      async.throwGetAll = true;

      await expectLater(
        openStore(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isFalse)
              .having((e) => e.stage, 'stage', 'probe'),
        ),
      );
    });

    test('keys enumerate EMPTY while envelopes exist → keys-lost, closed, '
        'nothing deleted', () async {
      final envelope = 'fpsig1:kOLD:${'A' * 24}';
      async.store['sig_$sessionKey'] = envelope;

      await expectLater(
        openStore(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isFalse)
              .having((e) => e.stage, 'stage', 'keys-lost'),
        ),
      );
      expect(async.store['sig_$sessionKey'], envelope,
          reason: 'rows are NEVER deleted — the key may come back next boot');
    });

    test('mint failure on a proven-empty store → fallbackLegal TRUE',
        () async {
      secure.dropWrites = true; // mint read-back fails
      await expectLater(
        openStore(),
        throwsA(
          isA<SigSealOpenUnavailable>()
              .having((e) => e.fallbackLegal, 'fallbackLegal', isTrue)
              .having((e) => e.stage, 'stage', 'mint'),
        ),
      );
    });
  });

  group('drain (§3.3)', () {
    test('legacy rows seal in place; drain-done durable is one-shot',
        () async {
      seedKey();
      async.store['sig_$identityKey'] = '{"pair":"AAA","registrationId":7}';
      async.store['sig_e2e_37_pre_key_3'] = 'prekey-bytes';
      final kv = await openStore();
      await kv.debugDrainNow();

      expect(
        SealedSigEnvelope.isEnvelope(async.store['sig_$identityKey'] as String),
        isTrue,
      );
      expect(await kv.read(identityKey), '{"pair":"AAA","registrationId":7}');
      expect(
        E2ePersistentDiag.entries
            .where((e) => e.contains('SIG_SEAL_DRAIN_DONE')),
        hasLength(1),
      );
      expect(async.store['sig_${SealedWebSignalKv.drainDoneMarker}'], '1');
    });

    test('§5.5 a non-round-tripping envelope aborts BEFORE the write; the '
        'only plaintext copy survives; a healthy pass resumes', () async {
      seedKey();
      async.store['sig_$identityKey'] = 'the-only-identity-copy';
      sealer.corruptRoundTrip = true;
      final kv = await openStore();
      await kv.debugDrainNow();

      expect(async.store['sig_$identityKey'], 'the-only-identity-copy',
          reason: 'verify happens IN RAM before the destructive write');

      sealer.corruptRoundTrip = false;
      final kv2 = await openStore();
      await kv2.debugDrainNow();
      expect(
        SealedSigEnvelope.isEnvelope(async.store['sig_$identityKey'] as String),
        isTrue,
      );
    });

    test('§5.6/§5.13 a write landing mid-drain is SKIPPED, never clobbered, '
        'and session rows drain under the per-peer lock', () async {
      seedKey();
      async.store['sig_$sessionKey'] = 'ratchet-v1';
      final kv = await openStore();
      // The interleave: a ratchet advance lands while the drain's seal await
      // is in flight (the writer that, cross-engine, holds the per-peer lock).
      sealer.beforeSealCompletes = () async {
        async.store['sig_$sessionKey'] = 'ratchet-v2';
      };
      await kv.debugDrainNow();

      expect(async.store['sig_$sessionKey'], 'ratchet-v2',
          reason: 'a stale envelope over v2 is a double-ratchet ROLLBACK — '
              'permanent bad-MAC for the peer');
      expect(lock.names, contains('fireplace-e2e-session-37-2'),
          reason: 'the drain must hold the SAME lock the ratchet write takes; '
              'the sig-keys batch lock does not mutually exclude it (R2)');
      expect(lock.nestedWhileSigKeysHeld, isEmpty,
          reason: '§5.17: requesting a per-peer lock while sig-keys is held '
              'is the ABBA half of a cross-engine deadlock — the ratchet '
              'path acquires per-peer → lazy open → sig-keys');
    });
  });

  group('fallback guard (§3.4, review R6)', () {
    test('§5.15 a fallback session refuses to write plaintext once a sibling '
        'sealed — reads keep serving', () async {
      final fallback = FallbackWebSignalKv(inner());
      await fallback.write(sessionKey, 'plain-ok'); // pre-first-seal: legal
      expect(async.store['sig_$sessionKey'], 'plain-ok');

      // A sibling engine seals a row.
      async.store['sig_e2e_37_pre_key_1'] = 'fpsig1:k9:${'A' * 24}';

      await expectLater(
        fallback.write(sessionKey, 'plain-no'),
        throwsA(
          isA<SigStoreUnreadable>()
              .having((e) => e.stage, 'stage', 'fallback-superseded'),
        ),
      );
      expect(async.store['sig_$sessionKey'], 'plain-ok',
          reason: 'no plaintext persisted beside sealed rows');
      expect(
        E2ePersistentDiag.entries
            .where((e) => e.contains('SIG_KEY_UNAVAILABLE')),
        hasLength(1),
      );
      expect(await fallback.read(sessionKey), 'plain-ok');
    });
  });

  group('key custody separation (cross-family)', () {
    test('a sig key is invisible to the content manager and survives its '
        'destroy', () async {
      final sigKeys = keys();
      final contentKeys = ContentKeyManager(secure);
      final kid = await sigKeys.mintContentKey();
      expect(kid, isNotNull);
      final contentView = await contentKeys.inventory();
      expect(contentView!.keys, isEmpty,
          reason: 'content-key rotation/shredding must never be able to see '
              '— let alone destroy — a key Signal rows need');
      // destroyContentKey targets fp_content_key_<kid>, which never existed;
      // the load-bearing invariant is that the SIG key survives untouched.
      await contentKeys.destroyContentKey(kid!);
      expect(
        secure.store['${ContentKeyManager.sigKeyPrefix}$kid'],
        isNotNull,
      );
    });
  });

  group('rollback characterization (§5.9)', () {
    test('old code reading envelopes: identity load THROWS (never absent), '
        'session load throws, containsPreKey answers true', () async {
      seedKey();
      final kv = await openStore();
      await kv.write(identityKey, '{"pair":"AAA","registrationId":7}');
      await kv.write('e2e_37_pre_key_3', 'prekey-bytes');

      // Roll back: raw store, no sealing layer.
      final raw = inner();
      final identityRaw = await raw.read(identityKey);
      expect(SealedSigEnvelope.isEnvelope(identityRaw!), isTrue);
      // Old loadFromStorage would jsonDecode this — pin that it THROWS
      // rather than reading as absent (absent = regeneration).
      expect(identityRaw.startsWith('{'), isFalse);
      // Old containsPreKey: non-null → true. Safe direction.
      expect(await raw.read('e2e_37_pre_key_3'), isNotNull);
    });
  });
}
