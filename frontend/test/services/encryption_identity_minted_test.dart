import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decision B (a): a minted account identity is what makes the box hand every
/// queue again. [EncryptionService.identityMinted] is set where the identity
/// is minted, and [EncryptionProvider.takeIdentityMinted] says so once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('minting an identity sets the flag; the provider reports it once '
      '(N19)', () async {
    final service = EncryptionService();
    expect(service.identityMinted, isFalse, reason: 'nothing minted yet');
    await service.initialize(
      5,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    expect(service.identityMinted, isTrue);

    final provider = EncryptionProvider(service: service);
    expect(provider.takeIdentityMinted(), isTrue);
    expect(provider.takeIdentityMinted(), isFalse, reason: 'asking consumes it');
  });

  test('an identity read from storage mints nothing', () async {
    final first = EncryptionService();
    await first.initialize(
      5,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final again = EncryptionService();
    await again.initialize(
      5,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
    );
    expect(again.identityMinted, isFalse);
  });
}
