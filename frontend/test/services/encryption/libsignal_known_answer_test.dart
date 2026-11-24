// `convert` and `optional` are dependencies of the vendored package, not ours:
// hex decoding, and the parameter classes cannot be built without `optional`.
// ignore_for_file: depend_on_referenced_packages

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:libsignal_protocol_dart/src/kdf/hkdf.dart';
import 'package:libsignal_protocol_dart/src/ratchet/alice_signal_protocol_parameters.dart';
import 'package:libsignal_protocol_dart/src/ratchet/bob_signal_protocol_parameters.dart';
import 'package:libsignal_protocol_dart/src/ratchet/chain_key.dart';
import 'package:libsignal_protocol_dart/src/ratchet/ratcheting_session.dart';
import 'package:libsignal_protocol_dart/src/ratchet/root_key.dart';
import 'package:optional/optional.dart';

/// Known-answer tests: the vendored Dart port
/// (`frontend/third_party/libsignal_protocol_dart`) against the reference
/// implementation of the classic Signal protocol.
///
/// Inputs and expected values are copied from the unit tests of
/// `signalapp/libsignal-protocol-java` at commit `fde96d22` (directory
/// `tests/src/test/java/org/whispersystems/libsignal/`); each group names its
/// file and method. The X3DH and Double Ratchet specifications publish no test
/// vectors, and libsignal dropped the classic protocol in v0.75.0.
///
/// Two of the Java tests use private keys that are not clamped (RFC 7748 §5),
/// and the Java library multiplied by them as given. The port clamps every
/// scalar before use, and so does libsignal: its own copy of the Alice test
/// (v0.74.1, `rust/protocol/tests/ratchet.rs`) expects another value, which
/// the port gives unaided. The two Java cases run with the Java arithmetic
/// plugged in ([_x25519AsGiven]); the last group pins the difference itself.
/// For a clamped key, which is every key the port generates, all three agree.
/// Provenance and what these tests do NOT cover:
/// `frontend/third_party/libsignal_protocol_dart/PATCHES.md`.
Uint8List _h(String hexString) => Uint8List.fromList(hex.decode(hexString));

/// X25519 (RFC 7748 §5 ladder) that uses [scalar] exactly as given: no
/// clamping. This is the arithmetic the Java vectors were produced with.
Uint8List _x25519AsGiven(Uint8List scalar, Uint8List point) {
  BigInt le(Uint8List bytes) => bytes.reversed.fold(
    BigInt.zero,
    (value, byte) => (value << 8) | BigInt.from(byte),
  );
  final p = (BigInt.one << 255) - BigInt.from(19);
  final a24 = BigInt.from(121665);
  final k = le(scalar);
  final x1 = le(point) & ((BigInt.one << 255) - BigInt.one);
  var x2 = BigInt.one;
  var z2 = BigInt.zero;
  var x3 = x1;
  var z3 = BigInt.one;
  var swap = false;
  for (var t = 254; t >= 0; t--) {
    final bit = (k >> t).isOdd;
    if (swap != bit) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    swap = bit;
    final a = (x2 + z2) % p;
    final aa = a * a % p;
    final b = (x2 - z2) % p;
    final bb = b * b % p;
    final e = (aa - bb) % p;
    final c = (x3 + z3) % p;
    final d = (x3 - z3) % p;
    final da = d * a % p;
    final cb = c * b % p;
    x3 = (da + cb) * (da + cb) % p;
    z3 = x1 * ((da - cb) * (da - cb) % p) % p;
    x2 = aa * bb % p;
    z2 = e * (aa + a24 * e) % p;
  }
  if (swap) {
    (x2, x3) = (x3, x2);
    (z2, z3) = (z3, z2);
  }
  var result = x2 * z2.modPow(p - BigInt.two, p) % p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (result & BigInt.from(0xff)).toInt();
    result >>= 8;
  }
  return out;
}

/// The reference's agreement for one test; the port's own is restored after.
void _useReferenceAgreement() {
  Curve.agreementCalculator = _x25519AsGiven;
  addTearDown(() => Curve.agreementCalculator = null);
}

void main() {
  group('HKDF (kdf/HKDFTest.java)', () {
    // testVectorV3 and testVectorLongV3 are RFC 5869 test cases 1 and 2.
    test('testVectorV3', () {
      final okm = HKDF.createFor(3).deriveSecrets4(
        _h('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        _h('000102030405060708090a0b0c'),
        _h('f0f1f2f3f4f5f6f7f8f9'),
        42,
      );
      expect(
        hex.encode(okm),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('testVectorLongV3', () {
      final okm = HKDF.createFor(3).deriveSecrets4(
        _h(
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
          '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f'
          '404142434445464748494a4b4c4d4e4f',
        ),
        _h(
          '606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f'
          '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f'
          'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
        ),
        _h(
          'b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf'
          'd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef'
          'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff',
        ),
        82,
      );
      expect(
        hex.encode(okm),
        'b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
        '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
        'cc30c58179ec3e87c14c01d5c1f3434f1d87',
      );
    });

    test('testVectorV2', () {
      final okm = HKDF.createFor(2).deriveSecrets4(
        _h('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        _h('000102030405060708090a0b0c'),
        _h('f0f1f2f3f4f5f6f7f8f9'),
        64,
      );
      expect(
        hex.encode(okm),
        '6ec2556d5d7b1d81dee4222ad7483695ddc98f4f5fabc0e0205dc2ef8752d41e'
        '04e2e21101c68ff09394b8ad0bdcb9609cd4ee82ac13199b4aa9fda899daebec',
      );
    });
  });

  group('symmetric ratchet step (ratchet/ChainKeyTest.java)', () {
    const seed =
        '8ab72d6f4cc5ac0d387eaf463378ddb28edd07385b1cb01250c715982e7ad48f';
    const nextChainKey =
        '28e8f8fee54b801eef7c5cfb2f17f32c7b334485bbb70fac6ec10342a246d15d';

    void check(int version, {required String messageKey, required String macKey}) {
      final chainKey = ChainKey(HKDF.createFor(version), _h(seed), 0);
      final messageKeys = chainKey.getMessageKeys();
      final next = chainKey.getNextChainKey();

      expect(hex.encode(chainKey.key), seed);
      expect(hex.encode(messageKeys.getCipherKey()), messageKey);
      expect(hex.encode(messageKeys.getMacKey()), macKey);
      expect(hex.encode(next.key), nextChainKey);
      expect(chainKey.index, 0);
      expect(messageKeys.getCounter(), 0);
      expect(next.index, 1);
      expect(next.getMessageKeys().getCounter(), 1);
    }

    test('testChainKeyDerivationV2', () {
      check(
        2,
        messageKey:
            '02a9aa6c7dbd64f9d3aa92f92a277bf54609dadf0b00828acfc61e3c724b84a7',
        macKey:
            'bfbe5efb603030526742e3ee89c7024e884e440f1ff376bb2317b2d64deb7c83',
      );
    });

    test('testChainKeyDerivationV3', () {
      check(
        3,
        messageKey:
            'bf51e9d75e0e31031051f82a2491ffc084fa298b7793bd9db620056febf45217',
        macKey:
            'c6c77d6a73a354337a56435e34607dfe48e3ace14e77314dc6abc172e7a7030b',
      );
    });
  });

  group('DH ratchet step (ratchet/RootKeyTest.java)', () {
    // `alicePrivate` is not clamped.
    test('testRootKeyDerivationV2', () {
      _useReferenceAgreement();
      const rootKeySeed =
          '7ba6debc2bc1bbf91abbc1367404176ca623095b7ec66b45f602d93538942dcc';
      final aliceKeyPair = ECKeyPair(
        Curve.decodePoint(
          _h(
            '05ee4fa6cdc030df49ecd0ba6cfcffb233d365a27fadbeff77e963fcb16222e1'
            '3a',
          ),
          0,
        ),
        Curve.decodePrivatePoint(
          _h('216822ec67eb38049ebae7b939baeaebb151bbb32db80fd389245ac37a948e50'),
        ),
      );
      final bobPublicKey = Curve.decodePoint(
        _h(
          '05abb8eb29cc80b47109a2265abe9798485406e32da268934a9555e84757708a'
          '30',
        ),
        0,
      );
      final rootKey = RootKey(HKDF.createFor(2), _h(rootKeySeed));

      final (nextRootKey, nextChainKey) = rootKey.createChain(
        bobPublicKey,
        aliceKeyPair,
      );

      expect(hex.encode(rootKey.getKeyBytes()), rootKeySeed);
      expect(
        hex.encode(nextRootKey.getKeyBytes()),
        'b114f5de28011985e6eba25d50e7ec41a9b02f5693c5c788a63a06d212a2f731',
      );
      expect(
        hex.encode(nextChainKey.key),
        '9d7d2469bc9ae53ee9805aa3264d2499a3ace80f4ccae2da13430c5c55b5ca5f',
      );
    });
  });

  group('session setup from an X3DH key set '
      '(ratchet/RatchetingSessionTest.java)', () {
    // Both tests use one key set; the Java file repeats the public halves.
    const bobRatchetPublic =
        '052cb49776b8770205745a3a6e24f579cdb4ba7a89041005928ebbadc9c05ad4'
        '58';
    const bobIdentityPublic =
        '05f1f43874f6966956c2dd473f8fa15adeb71d1cb991b2341692324cefb1c5e6'
        '26';
    const bobSignedPreKeyPublic =
        '05ac248a8f263be6863576eb0362e28c828f0107a3379d34bab1586bf8c770cd'
        '67';
    const aliceBasePublic =
        '05472d1fb1a9862c3af6beaca8920277e2b26f4a79213ec7c906aeb35e03cf89'
        '50';
    const aliceIdentityPublic =
        '05b4a8455660ada65b401007f615e654041746432e3339c6875149bceefcb42b'
        '4a';
    // `senderChain` in the Bob test and `receiverChain` in the Alice test.
    const firstChainKey =
        '9797caca53c989bbe229a40ca7727010eb2604fc14945d77958a0aeda088b44d';
    // libsignal v0.74.1 `test_ratcheting_session_as_alice`: same keys, clamped.
    const firstChainKeyLibsignal =
        'ab9be50e5cb22a925446ab90ee5670545f4fd32902459ec274b6ad0ae5d6031a';

    test('testRatchetingSessionAsBob', () {
      final bobIdentityKey = IdentityKeyPair(
        IdentityKey.fromBytes(_h(bobIdentityPublic), 0),
        Curve.decodePrivatePoint(
          _h('4875cc69ddf8ea0719ec947d61081135868d5fd801f02c0225e516df2156605e'),
        ),
      );
      final bobRatchetKey = ECKeyPair(
        Curve.decodePoint(_h(bobRatchetPublic), 0),
        Curve.decodePrivatePoint(
          _h('a1cab48f7c893fafa9880a28c3b4999d28d6329562d27a4ea4e22e9ff1bdd65a'),
        ),
      );
      final bobSignedPreKey = ECKeyPair(
        Curve.decodePoint(_h(bobSignedPreKeyPublic), 0),
        Curve.decodePrivatePoint(
          _h('583900131fb727998b7803fe6ac22cc591f342e4e42a8c8d5d78194209b8d253'),
        ),
      );
      final aliceIdentityKey = IdentityKey.fromBytes(
        _h(aliceIdentityPublic),
        0,
      );
      final session = SessionState();

      RatchetingSession.initializeSessionBob(
        session,
        BobSignalProtocolParameters(
          ourIdentityKey: bobIdentityKey,
          ourSignedPreKey: bobSignedPreKey,
          ourRatchetKey: bobRatchetKey,
          ourOneTimePreKey: const Optional<ECKeyPair>.empty(),
          theirIdentityKey: aliceIdentityKey,
          theirBaseKey: Curve.decodePoint(_h(aliceBasePublic), 0),
        ),
      );

      expect(session.getLocalIdentityKey(), bobIdentityKey.getPublicKey());
      expect(session.getRemoteIdentityKey(), aliceIdentityKey);
      expect(hex.encode(session.getSenderChainKey().key), firstChainKey);
    });

    void checkAlice({required String receiverChain}) {
      final bobRatchetPublicKey = Curve.decodePoint(_h(bobRatchetPublic), 0);
      final bobIdentityKey = IdentityKey.fromBytes(_h(bobIdentityPublic), 0);
      final aliceIdentityKey = IdentityKeyPair(
        IdentityKey.fromBytes(_h(aliceIdentityPublic), 0),
        Curve.decodePrivatePoint(
          _h('9040f0d4e09cf38f6dc7c13779c908c015a1da4fa78737a080eb0a6f4f5f8f58'),
        ),
      );
      final aliceBaseKey = ECKeyPair(
        Curve.decodePoint(_h(aliceBasePublic), 0),
        Curve.decodePrivatePoint(
          _h('11ae7c64d1e61cd596b76a0db5012673391cae66edbfcf073b4da80516a47449'),
        ),
      );
      final session = SessionState();

      RatchetingSession.initializeSessionAlice(
        session,
        AliceSignalProtocolParameters(
          ourIdentityKey: aliceIdentityKey,
          ourBaseKey: aliceBaseKey,
          theirIdentityKey: bobIdentityKey,
          theirSignedPreKey: Curve.decodePoint(_h(bobSignedPreKeyPublic), 0),
          theirRatchetKey: bobRatchetPublicKey,
          theirOneTimePreKey: const Optional<ECPublicKey>.empty(),
        ),
      );

      expect(session.getLocalIdentityKey(), aliceIdentityKey.getPublicKey());
      expect(session.getRemoteIdentityKey(), bobIdentityKey);
      expect(
        hex.encode(session.getReceiverChainKey(bobRatchetPublicKey)!.key),
        receiverChain,
      );
    }

    // `aliceBasePrivate` is not clamped.
    test('testRatchetingSessionAsAlice', () {
      _useReferenceAgreement();
      checkAlice(receiverChain: firstChainKey);
    });

    test('test_ratcheting_session_as_alice (libsignal v0.74.1), with the '
        "port's own agreement", () {
      checkAlice(receiverChain: firstChainKeyLibsignal);
    });
  });

  group('curve (ecc/Curve25519Test.java)', () {
    test('testAgreement', () {
      final alicePublicKey = Curve.decodePoint(
        _h(
          '051bb75966f2e93a3691dfff942bb2a466a1c08b8d78ca3f4d6df8b8bfa2e4ee'
          '28',
        ),
        0,
      );
      final alicePrivateKey = Curve.decodePrivatePoint(
        _h('c806439dc9d2c476ffed8f2580c0888d58ab406bf7ae3698879021b96bb4bf59'),
      );
      final bobPublicKey = Curve.decodePoint(
        _h(
          '05653614993d2b15ee9e5fd3d86ce719ef4ec1daae1886a87b3f5fa9565a27a2'
          '2f',
        ),
        0,
      );
      final bobPrivateKey = Curve.decodePrivatePoint(
        _h('b03b34c33a1c44f225b662d2bf4859b8135411fa7b0386d45fb75dc5b91b4466'),
      );
      const shared =
          '325f239328941ced6e673b86ba41017448e99b649a9c3806c1dd7ca4c477e629';

      expect(
        hex.encode(Curve.calculateAgreement(alicePublicKey, bobPrivateKey)),
        shared,
      );
      expect(
        hex.encode(Curve.calculateAgreement(bobPublicKey, alicePrivateKey)),
        shared,
      );
    });

    // The Java test declares `aliceIdentityPrivate` and never uses it: the
    // reference checks verification only, so this does too.
    test('testSignature', () {
      final alicePublicKey = Curve.decodePoint(
        _h(
          '05ab7e717d4a163b7d9a1d8071dfe9dcf8cdcd1cea3339b6356be84d887e322c'
          '64',
        ),
        0,
      );
      final message = Curve.decodePoint(
        _h(
          '05edce9d9c415ca78cb7252e72c2c4a554d3eb29485a0e1d503118d1a82d99fb'
          '4a',
        ),
        0,
      ).serialize();
      final signature = _h(
        '5de88ca9a89b4a115da79109c67c9c7464a3e4180274f1cb8c63c2984e286dfb'
        'ede82deb9dcd9fae0bfbb821569b3d9001bd8130cd11d486cef047bd60b86e88',
      );

      expect(Curve.verifySignature(alicePublicKey, message, signature), isTrue);

      for (var i = 0; i < signature.length; i++) {
        final modified = Uint8List.fromList(signature);
        modified[i] ^= 0x01;
        expect(
          Curve.verifySignature(alicePublicKey, message, modified),
          isFalse,
          reason: 'signature byte $i flipped',
        );
      }
    });
  });

  group('where the port differs from the reference', () {
    // RootKeyTest.java's pair: `alicePrivate` starts 0x21, so its low bits are
    // set and clamping changes it.
    final unclamped = _h(
      '216822ec67eb38049ebae7b939baeaebb151bbb32db80fd389245ac37a948e50',
    );
    final point = _h(
      'abb8eb29cc80b47109a2265abe9798485406e32da268934a9555e84757708a30',
    );

    test('the port clamps a private key before the agreement', () {
      final clamped = Uint8List.fromList(unclamped);
      clamped[0] &= 248;
      clamped[31] &= 127;
      clamped[31] |= 64;
      expect(clamped, isNot(unclamped));

      final port = Curve.calculateAgreement(
        DjbECPublicKey(point),
        Curve.decodePrivatePoint(unclamped),
      );

      expect(port, _x25519AsGiven(clamped, point));
      expect(port, isNot(_x25519AsGiven(unclamped, point)));
    });
  });
}
