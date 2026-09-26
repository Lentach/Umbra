import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/encryption/prekey_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// A request queue is public: anyone who searched the account can seal a
/// frame into it naming our own user id and any device id. Signal's TOFU
/// store accepts any identity key on a PreKey message, so the ONLY thing
/// that tells a sibling (which shares the account identity) from a stranger
/// is the identity key the PreKey message carries.
void main() {
  /// A real PreKey message from [sender] to a fresh recipient bundle.
  Future<String> preKeyFrom(IdentityKeyPair sender) async {
    final recipientIdentity = generateIdentityKeyPair();
    final preKey = generatePreKeys(1, 1).single;
    final signed = generateSignedPreKey(recipientIdentity, 1);
    final store = InMemorySignalProtocolStore(
      sender,
      generateRegistrationId(false),
    );
    const recipient = SignalProtocolAddress('1', 3);
    await SessionBuilder.fromSignalStore(store, recipient).processPreKeyBundle(
      PreKeyBundle(
        generateRegistrationId(false),
        3,
        preKey.id,
        preKey.getKeyPair().publicKey,
        signed.id,
        signed.getKeyPair().publicKey,
        signed.signature,
        recipientIdentity.getPublicKey(),
      ),
    );
    final message = await SessionCipher.fromStore(
      store,
      recipient,
    ).encrypt(Uint8List.fromList(utf8.encode('{"t":"queue_handoff"}')));
    expect(message.getType(), CiphertextMessage.prekeyType);
    return '${message.getType()}:${base64Encode(message.serialize())}';
  }

  String pubOf(IdentityKeyPair pair) =>
      base64Encode(pair.getPublicKey().serialize());

  test('a PreKey message carrying the account identity matches it', () async {
    final account = generateIdentityKeyPair();

    expect(
      ciphertextMatchesIdentity(await preKeyFrom(account), pubOf(account)),
      isTrue,
    );
  });

  test(
    "a stranger's PreKey message naming our account does NOT match, "
    'whatever else it gets right',
    () async {
      final account = generateIdentityKeyPair();
      final stranger = generateIdentityKeyPair();

      expect(
        ciphertextMatchesIdentity(await preKeyFrom(stranger), pubOf(account)),
        isFalse,
      );
    },
  );

  test(
    'a whisper message is left to the decrypt: its MAC is keyed by the '
    'session it names, which only a holder of that session can produce',
    () {
      expect(
        ciphertextMatchesIdentity('2:AQID', pubOf(generateIdentityKeyPair())),
        isTrue,
      );
    },
  );

  test('anything unparseable never matches', () {
    final pub = pubOf(generateIdentityKeyPair());
    for (final junk in [
      '',
      '3',
      '3:',
      '3:AQID',
      '3:!!notbase64',
      'x:AQID',
      '9:AQID',
    ]) {
      expect(ciphertextMatchesIdentity(junk, pub), isFalse, reason: junk);
    }
  });
}
