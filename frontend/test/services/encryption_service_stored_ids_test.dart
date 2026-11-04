import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('EncryptionService.storedMessageIds', () {
    test(
      'covers both id-keyed stores, including unstamped legacy records',
      () async {
        SharedPreferences.setMockInitialValues({
          // A record from before the metadata stamps existed: no _cid, no
          // _savedAt. Invisible to every other purge rule.
          'e2e_42_decrypted_7': '{"content":"legacy"}',
          'e2e_42_decrypt_raw_v1_8': '{"plaintext":"raw","ciphertext":"c"}',
          // Other keys in the same namespace must not be read as message ids.
          'e2e_42_retired_v1': '[1,2]',
          'e2e_42_purge_pending_v1': '{"ids":[],"cts":[]}',
          'e2e_42_retention_epoch_v1': 1,
          // Another account's record.
          'e2e_43_decrypted_9': '{"content":"not mine"}',
        });
        final scanner = EncryptionService();
        await scanner.initialize(
          42,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );

        expect(await scanner.storedMessageIds(), {7, 8});
      },
    );
  });
}
