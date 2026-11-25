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
}
