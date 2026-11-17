// SERVICE-LAYER DEMONSTRATION. The fix lands in `_readBox`, so the test that
// turns green with it is in test/providers/messaging_provider_box_test.dart
// ('B3: a normal-queue PreKey frame ...'). This one shows what the Signal
// layer does with such a frame and is not expected to flip.
//
// B3 (docs/plans/2026-11-17-b3-impersonation.md): a server that saw a
// user's login password can speak AS that user to their friends.
//
// The password opens the contact backup; its `outbound` rows are the sid +
// seal key of every friend's queue for that user. A frame sealed there is
// attributed by the friend's inbox to the user (box_inbox.dart `_ownerOf`),
// and the friend's receive path (`_readBox`) hands it straight to
// `EncryptionService.decrypt`. Unlike a request or sibling queue, nothing
// before the decrypt compares the PreKey message's identity key with the
// identity already pinned for that friend, and the identity store is TOFU:
// it returns true for any key, so the attacker's session REPLACES the real
// one.
//
// This test drives the friend's real [EncryptionService] (the layer
// `_readBox` calls) with a PreKey message an attacker built, under an
// identity key it controls, against the friend's public bundle (which the
// server serves). The seal and the inbox attribution are not exercised:
// they need only the sid + sealPub from the backup and add no check of the
// sender's identity.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _skip = 'B3 red test: fails until the friend-identity check lands';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const victimId = 17; // the friend who is lied to
  const userId = 42; // the account whose password the server saw

  late EncryptionService victim;
  late PreKeyBundle victimBundle;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    victim = EncryptionService();
    await victim.initialize(
      victimId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    // What the server serves to anyone who asks for the victim's keys.
    final b = (await victim.getKeyBundleForReupload())!;
    victimBundle = PreKeyBundle(
      b['registrationId'] as int,
      1,
      null,
      null,
      b['signedPreKeyId'] as int,
      Curve.decodePoint(base64Decode(b['signedPreKeyPublic'] as String), 0),
      base64Decode(b['signedPreKeySignature'] as String),
      IdentityKey.fromBytes(base64Decode(b['identityPublicKey'] as String), 0),
    );
  });

  /// A first ("PreKey") message to the victim from a holder of [identity],
  /// in the `"{type}:{base64}"` wire shape a box frame carries.
  Future<String> firstMessageFrom(IdentityKeyPair identity, String text) async {
    final store = InMemorySignalProtocolStore(
      identity,
      generateRegistrationId(false),
    );
    const to = SignalProtocolAddress('$victimId', 1);
    await SessionBuilder.fromSignalStore(
      store,
      to,
    ).processPreKeyBundle(victimBundle);
    final m = await SessionCipher.fromStore(
      store,
      to,
    ).encrypt(Uint8List.fromList(utf8.encode(text)));
    expect(m.getType(), CiphertextMessage.prekeyType);
    return '${m.getType()}:${base64Encode(m.serialize())}';
  }

  /// The friendship as it stands: the real user wrote once, the victim read
  /// it and pinned the user's identity.
  Future<IdentityKeyPair> establishedFriend() async {
    final real = generateIdentityKeyPair();
    final hello = await firstMessageFrom(real, 'hi, it is really me');
    expect(
      await victim.decrypt(userId, hello, messageId: 1),
      'hi, it is really me',
    );
    expect(
      await victim.peerTofuIdentityBase64(userId),
      base64Encode(real.getPublicKey().serialize()),
    );
    return real;
  }

  test(
    'a normal-queue PreKey frame under an identity the friend never had is '
    'refused, not read as from the friend',
    () async {
      await establishedFriend();
      final attacker = generateIdentityKeyPair();
      final forged = await firstMessageFrom(
        attacker,
        'new number, send the code here',
      );

      // Today: decrypt returns the forged text, and `_readBox` would store
      // and display it in the user's chat.
      await expectLater(
        victim.decrypt(userId, forged, messageId: 2),
        throwsA(isA<Exception>()),
      );
    },
    skip: _skip,
  );

  test(
    "the attacker's identity never becomes the friend's pinned identity "
    'without a human acknowledging it',
    () async {
      final real = await establishedFriend();
      final forged = await firstMessageFrom(generateIdentityKeyPair(), 'x');
      try {
        await victim.decrypt(
          userId,
          forged,
          messageId: 2,
        );
      } on Object {
        // A refusal is the fix; the pin check below is the point.
      }
      // Today, with key-change warnings at their default (muted, (lxxix)),
      // the change is auto-acknowledged and the anchor moves to the attacker.
      expect(
        await victim.peerTofuIdentityBase64(userId),
        base64Encode(real.getPublicKey().serialize()),
      );
    },
    skip: _skip,
  );
}
