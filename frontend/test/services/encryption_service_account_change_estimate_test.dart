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
      'the cached record-count estimate of account A does not stand for B',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({
          for (var id = 101; id <= 105; id++) 'e2e_62_decrypted_$id': '{}',
        });
        final service = EncryptionService(decryptedContentCacheLimit: 3);
        await init(service, 61);
        await service.saveDecryptedContent(18801, {'content': 'A'});

        await init(service, 62);
        await service.saveDecryptedContent(18802, {'content': 'B'});

        final prefs = await SharedPreferences.getInstance();
        final kept = prefs
            .getKeys()
            .where((k) => k.startsWith('e2e_62_decrypted_'))
            .length;
        expect(kept, lessThanOrEqualTo(3));
      },
    );
  });
}
