import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Signal key-value store that can be made unable to list its keys AFTER the
/// account is set up.
class _UnlistableStorage extends DualStorage {
  _UnlistableStorage() : super(const FlutterSecureStorage());

  bool unlistable = false;

  @override
  Future<Map<String, String>> readAll() async {
    if (unlistable) throw StateError('signal store unavailable');
    return super.readAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('a wipe that fails still leaves the provider not ready, and the caller '
      'is told', () async {
    final storage = _UnlistableStorage();
    final service = EncryptionService()..debugSetDualStorage(storage);
    await service.initialize(
      42,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final provider = EncryptionProvider(service: service)
      ..markE2EInitialized();
    expect(provider.isE2EReady, isTrue);
    storage.unlistable = true;

    await expectLater(provider.clearEncryptionKeys(), throwsStateError);

    // The service forgot the account even though the wipe failed; a provider
    // that still says "ready" would send under an account nobody holds.
    expect(service.activeUserId, isNull);
    expect(provider.isE2EReady, isFalse);
  });

  test('a wipe for a named account removes its keys although the service was '
      'never initialized (a device closed while the account was deleted)',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'e2e_7_identity_record_v1': 'x',
      'e2e_7_signed_pre_key_0': 'y',
      'e2e_8_identity_record_v1': 'another-account',
    });
    final service = EncryptionService()
      ..debugSetDualStorage(DualStorage(const FlutterSecureStorage()));
    expect(service.activeUserId, isNull);

    await EncryptionProvider(service: service).clearEncryptionKeys(userId: 7);

    expect(await const FlutterSecureStorage().readAll(), {
      'e2e_8_identity_record_v1': 'another-account',
    });
  });
}
