import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plan B5: past the per-target search budget the server serves a
/// `searchUsers` bundle with `oneTimePreKeyId`/`oneTimePreKeyPublic` null.
/// A first contact built from it must still work end to end (X3DH from the
/// signed pre-key alone), both directions, with real libsignal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;

  test('a first contact from an OTP-less search bundle builds a session '
      'the peer decrypts, and the peer can answer', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final alice = EncryptionService();
    final bob = EncryptionService();
    await alice.initialize(
      aliceId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    await bob.initialize(
      bobId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );

    final upload = bob.getKeysForUpload()!;
    // The exact over-budget wire shape: both OTP fields present and null.
    final bundle = {
      ...(upload['keyBundle'] as Map).cast<String, dynamic>(),
      'oneTimePreKeyId': null,
      'oneTimePreKeyPublic': null,
    };

    await alice.buildSession(bobId, bundle, expectedIdentityBase64: null);
    final hello = await alice.encrypt(bobId, 'hello without an OTP');
    expect(await bob.decrypt(aliceId, hello), 'hello without an OTP');

    final reply = await bob.encrypt(aliceId, 'reply');
    expect(await alice.decrypt(bobId, reply), 'reply');
    expect(await alice.hasAnsweredSession(bobId, deviceId: 1), isTrue);
  });
}
