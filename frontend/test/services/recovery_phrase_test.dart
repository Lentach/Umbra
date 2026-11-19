import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fireplace/services/recovery_phrase.dart';

/// Recovery phrase generation and local checking (multi-device spec §6.2.1).
///
/// The checksum matters for a practical reason, not a ceremonial one: the
/// server locks the phrase out after five failed presentations, so a typo that
/// reaches it costs the user one of very few chances to get their account back.
void main() {
  group('generate', () {
    test('produces twelve words', () {
      expect(RecoveryPhrase.generate().length, 12);
    });

    test('produces a phrase that validates', () {
      final phrase = RecoveryPhrase.generate().join(' ');
      expect(RecoveryPhrase.isValid(phrase), isTrue);
    });

    test('does not repeat itself', () {
      // 128 bits of entropy: a collision here means the generator is broken,
      // not that the test was unlucky.
      final first = RecoveryPhrase.generate().join(' ');
      final second = RecoveryPhrase.generate().join(' ');
      expect(first, isNot(second));
    });

    test('generated output survives normalize unchanged', () {
      // Enrolment stores a hash of the normalized phrase and verification
      // hashes the normalized input. If normalize ever altered a freshly
      // generated phrase, the two would disagree and the user would burn
      // lockout attempts on words the client had just called valid.
      final joined = RecoveryPhrase.generate().join(' ');
      expect(RecoveryPhrase.normalize(joined), joined);
    });
  });

  group('isValid', () {
    test('accepts a known-good BIP39 phrase', () {
      expect(
        RecoveryPhrase.isValid(
          'legal winner thank year wave sausage worth useful legal winner '
          'thank yellow',
        ),
        isTrue,
      );
    });

    test('tolerates casing and sloppy whitespace', () {
      expect(
        RecoveryPhrase.isValid(
          '  LEGAL winner  thank year wave sausage worth useful legal winner '
          'thank YELLOW ',
        ),
        isTrue,
      );
    });

    test('rejects a phrase whose checksum does not hold', () {
      // Same wordlist, last word swapped — the shape a typo takes.
      expect(
        RecoveryPhrase.isValid(
          'legal winner thank year wave sausage worth useful legal winner '
          'thank zebra',
        ),
        isFalse,
      );
    });

    test('rejects a word that is not in the list', () {
      expect(
        RecoveryPhrase.isValid(
          'legal winner thank year wave sausage worth useful legal winner '
          'thank fireplace',
        ),
        isFalse,
      );
    });
    test('rejects the wrong number of words', () {
      expect(RecoveryPhrase.isValid('legal winner thank year'), isFalse);
      expect(
        RecoveryPhrase.isValid(
          'legal winner thank year wave sausage worth useful legal winner '
          'thank yellow yellow',
        ),
        isFalse,
      );
    });

    test('rejects empty input', () {
      expect(RecoveryPhrase.isValid(''), isFalse);
      expect(RecoveryPhrase.isValid('   '), isFalse);
    });
  });

  group('plan B7 derivations (the phrase never leaves the device)', () {
    const phrase =
        'abandon ability able about above absent absorb abstract absurd abuse '
        'access accident';
    String hex(List<int> b) =>
        b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

    // Known answers computed with an independent RFC-5869 implementation
    // (HMAC-SHA256, salt = 32 zero bytes, one expand block). They pin the
    // labels and the salt-in-info layout: changing any of them silently makes
    // every enrolled account unrecoverable.
    test('authSecret is the pinned HKDF output, base64 of 32 bytes', () {
      final secret = RecoveryPhrase.deriveAuthSecret(phrase);
      expect(base64Decode(secret), hasLength(32));
      expect(secret, matches(RegExp(r'^[A-Za-z0-9+/]{43}=$')));
      expect(
        hex(base64Decode(secret)),
        '25c63d8ac90b91df37079197ed64d7d6f179134bd8aff71ebbe635ce5930762b', // gitleaks:allow
      );
    });

    test('sealKey is the pinned HKDF output for a salt', () {
      final key = RecoveryPhrase.deriveSealKey(
        phrase,
        Uint8List.fromList(List<int>.generate(16, (i) => i)),
      );
      expect(
        hex(key),
        '8be850a63fdb4d147c795bd0eeeac59eb3d3b8a8ff1b4d430bf4cadb8e0bd912', // gitleaks:allow
      );
    });

    test('sealKey and authSecret are unrelated outputs', () {
      final salt = Uint8List(16);
      expect(
        base64Encode(RecoveryPhrase.deriveSealKey(phrase, salt)),
        isNot(RecoveryPhrase.deriveAuthSecret(phrase)),
      );
    });

    test('the seal key follows the blob salt', () {
      final a = RecoveryPhrase.deriveSealKey(phrase, Uint8List(16));
      final b = RecoveryPhrase.deriveSealKey(phrase, Uint8List(16)..[0] = 1);
      expect(a, isNot(b));
    });

    test('derivation normalizes like every other consumer', () {
      expect(
        RecoveryPhrase.deriveAuthSecret('  ${phrase.toUpperCase()}\n'),
        RecoveryPhrase.deriveAuthSecret(phrase),
      );
    });

    test('a different phrase gives a different authSecret', () {
      expect(
        RecoveryPhrase.deriveAuthSecret('$phrase extra'),
        isNot(RecoveryPhrase.deriveAuthSecret(phrase)),
      );
    });
  });
}
