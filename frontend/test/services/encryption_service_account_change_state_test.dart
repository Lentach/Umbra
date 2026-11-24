import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `EncryptionService` is a process singleton reused across logins. Per-account
/// RAM that an account change leaves standing is used under the next account.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> init(EncryptionService s, int userId) => s.initialize(
    userId,
    checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
  );

  group('account change', () {
    test(
      'ledger ids buffered for account A are not written under account B',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final service = EncryptionService();
        await init(service, 61);
        await service.saveDecryptedContent(18801, {'content': 'A secret'});

        await init(service, 62);
        await service.flushDecryptedLedger();

        expect(await service.decryptedLedgerIds(), isNot(contains(18801)));
      },
    );
  });
}
