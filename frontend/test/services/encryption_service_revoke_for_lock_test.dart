// A3-SVC-D-04: `EncryptionService.revokeForPasscodeLock` is the web re-lock
// teardown. Only its callers were faked anywhere, so deleting any one of its
// three revocations left the suite green while a re-locked web tab kept
// plaintext and the Signal identity in memory. One test per effect.
import 'dart:typed_data';

import 'package:fireplace/services/encryption/content_key_manager.dart';
import 'package:fireplace/services/encryption/content_key_wrap.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/encryption/sealed_sig_envelope.dart';
import 'package:fireplace/services/encryption/sealed_web_content_kv.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/secure_kv.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The VM has no WebCrypto: a reversible tagged stand-in, as the sibling
/// sealed-store tests use.
class _FakeSealer implements ContentSealer {
  static int _tag(Uint8List key) => key.fold<int>(0, (a, b) => (a + b) & 0xff);

  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async =>
      Uint8List.fromList([...Uint8List(12), _tag(key), ...plaintext]);

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (sealed.length < 13 || sealed[12] != _tag(key)) return null;
    return Uint8List.sublistView(sealed, 13);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 37;
  const secureKv = FlutterSecureStorageKv(FlutterSecureStorage());
  const identityRecord = 'e2e_${userId}_identity_record_v1';

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await E2ePersistentDiag.clear();
    await E2ePersistentDiag.init();
  });

  test('revokes the open content store (prefs.revoke)', () async {
    final prefs = await SharedPreferences.getInstance();
    final kv = await SealedWebContentKv.open(
      prefs: prefs,
      keys: ContentKeyManager(secureKv),
      sealer: _FakeSealer(),
      lock: <T>(name, action) => action(),
    );
    expect(kv.debugRevoked, isFalse);
    final service = EncryptionService()..debugSetContentKv(kv);

    await service.revokeForPasscodeLock();

    expect(
      kv.debugRevoked,
      isTrue,
      reason: 'the re-locked tab must not keep the content keys or plaintext',
    );
  });

  test('revokes the web Signal session (revokeWebSession)', () async {
    // A wrapped sig key and an unlocked vault: the store opens and its keys
    // sit in RAM, exactly the state a re-lock has to end.
    final sealer = _FakeSealer();
    final vault = ContentKeyWrap(sealer: sealer)
      ..unlock(kek: Uint8List(32)..fillRange(0, 32, 7), kekId: 'kek1');
    await secureKv.write(
      '${ContentKeyManager.sigKeyPrefix}k1',
      (await vault.wrapKey(Uint8List(32)..fillRange(0, 32, 9)))!,
    );
    final storage = DualStorage(
      const FlutterSecureStorage(),
      sigKeys: ContentKeyManager(
        secureKv,
        keyPrefix: ContentKeyManager.sigKeyPrefix,
        wrap: vault,
      ),
      sigSealer: sealer,
      sigLock: <T>(name, action) => action(),
      debugForceSealedWeb: true,
    );
    final service = EncryptionService()..debugSetDualStorage(storage);
    await storage.write(key: identityRecord, value: 'x');
    expect(await storage.read(key: identityRecord), 'x');

    await service.revokeForPasscodeLock();
    vault.lock();

    await expectLater(
      storage.read(key: identityRecord),
      throwsA(
        isA<SigSealOpenUnavailable>().having((e) => e.stage, 'stage', 'locked'),
      ),
      reason: 'a live memoized store would still answer from its RAM keys',
    );
  });

  test('forgets the in-RAM identity (forgetInMemoryIdentity)', () async {
    final service = EncryptionService();
    await service.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final store = service.debugIdentityStore;
    expect(await store.getIdentityKeyPair(), isNotNull);

    await service.revokeForPasscodeLock();

    await expectLater(store.getIdentityKeyPair(), throwsA(anything));
    expect(await service.getIdentityFingerprint(), isNull);
  });
}
