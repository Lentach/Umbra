import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Box messages live under LOCAL ids (≥ 2^48). The id-ordered caches assumed
/// "ids ascend with age"; a local id is always higher than any server id, so
/// without care it crowds every server entry out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;

  Map<String, dynamic> flatBundleFrom(EncryptionService peer) {
    final upload = peer.getKeysForUpload()!;
    final keyBundle = (upload['keyBundle'] as Map).cast<String, dynamic>();
    final otp = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>()
        .first;
    return {
      ...keyBundle,
      'oneTimePreKeyId': otp['keyId'],
      'oneTimePreKeyPublic': otp['publicKey'],
    };
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'box decrypts never push a server message out of the replay cache, and a '
    "box message's replay row can be dropped once its record is stored",
    () async {
      final alice = EncryptionService();
      final bob = EncryptionService();
      await alice.initialize(
        aliceId,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      await bob.initialize(
        bobId,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      await alice.buildSession(
        bobId,
        flatBundleFrom(bob),
        expectedIdentityBase64: null,
      );

      // A server-path message first, then more box messages than the cache
      // holds (40).
      const serverId = 7;
      final serverWire = await alice.encrypt(bobId, 'over the server');
      await bob.decrypt(aliceId, serverWire, messageId: serverId);
      for (var i = 0; i < 45; i++) {
        final wire = await alice.encrypt(bobId, 'box $i');
        await bob.decrypt(
          aliceId,
          wire,
          messageId: kFirstLocalMessageId + i,
        );
      }

      // The server row's replay entry still answers — no second ratchet use.
      expect(await bob.rawReplayExists(serverId), isTrue);
      expect(
        await bob.decrypt(aliceId, serverWire, messageId: serverId),
        'over the server',
      );

      // Local rows hold plaintext: they are capped on their own (40), the
      // oldest going first, and one can be dropped once its record is stored.
      expect(await bob.rawReplayExists(kFirstLocalMessageId), isFalse);
      expect(await bob.rawReplayExists(kFirstLocalMessageId + 5), isTrue);
      await bob.removeRawReplay(kFirstLocalMessageId + 44);
      expect(await bob.rawReplayExists(kFirstLocalMessageId + 44), isFalse);
      expect(await bob.rawReplayExists(kFirstLocalMessageId + 43), isTrue);
    },
  );
}
