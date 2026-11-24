import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/services/passcode_kdf.dart';

import '../support/native_webcrypto.dart';

/// Real PBKDF2 needs the native webcrypto library (`dart run webcrypto:setup`;
/// cmake + a C compiler). Without it these tests are SKIPPED on a dev machine
/// and FAIL in CI (`REQUIRE_NATIVE_WEBCRYPTO=1`, see
/// support/native_webcrypto.dart); the on-device acceptance run also covers
/// the real primitive.
bool? _webcryptoOk;
Object? _webcryptoError;

Future<bool> _ensureWebcryptoAvailable() async {
  if (_webcryptoOk != null) return _webcryptoOk!;
  try {
    await const Pbkdf2PasscodeKdf().derive(
      passcode: 'probe',
      salt: Uint8List.fromList(const [1, 2, 3, 4]),
      iterations: 1,
    );
    _webcryptoOk = true;
  } catch (e) {
    _webcryptoError = e;
    _webcryptoOk = false;
  }
  return _webcryptoOk!;
}

void main() {
  group('constantTimeBytesEqual', () {
    test('accepts identical byte strings', () {
      expect(
        constantTimeBytesEqual(
          Uint8List.fromList(const [1, 2, 3]),
          Uint8List.fromList(const [1, 2, 3]),
        ),
        isTrue,
      );
    });

    test('rejects a single differing byte at the end', () {
      expect(
        constantTimeBytesEqual(
          Uint8List.fromList(const [1, 2, 3]),
          Uint8List.fromList(const [1, 2, 4]),
        ),
        isFalse,
      );
    });

    test('rejects a differing length without indexing out of range', () {
      expect(
        constantTimeBytesEqual(
          Uint8List.fromList(const [1, 2, 3]),
          Uint8List.fromList(const [1, 2]),
        ),
        isFalse,
      );
    });
  });

  group('generatePasscodeSalt', () {
    test('is 16 bytes and does not repeat across calls', () {
      final a = generatePasscodeSalt();
      final b = generatePasscodeSalt();
      expect(a, hasLength(16));
      expect(b, hasLength(16));
      expect(constantTimeBytesEqual(a, b), isFalse);
    });
  });

  group('Pbkdf2PasscodeKdf', () {
    test('matches the published PBKDF2-HMAC-SHA256 test vector', () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      // Independent source of truth (widely published SHA-256 PBKDF2 vector):
      // P = "password", S = "salt", c = 1, dkLen = 32.
      final out = await const Pbkdf2PasscodeKdf().derive(
        passcode: 'password',
        salt: Uint8List.fromList(utf8.encode('salt')),
        iterations: 1,
      );
      expect(
        out
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('is deterministic for the same passcode, salt and iterations',
        () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final salt = generatePasscodeSalt();
      final a = await const Pbkdf2PasscodeKdf()
          .derive(passcode: '1234', salt: salt, iterations: 1000);
      final b = await const Pbkdf2PasscodeKdf()
          .derive(passcode: '1234', salt: salt, iterations: 1000);
      expect(constantTimeBytesEqual(a, b), isTrue);
    });

    test('a different passcode under the same salt derives different bytes',
        () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final salt = generatePasscodeSalt();
      final a = await const Pbkdf2PasscodeKdf()
          .derive(passcode: '1234', salt: salt, iterations: 1000);
      final b = await const Pbkdf2PasscodeKdf()
          .derive(passcode: '1235', salt: salt, iterations: 1000);
      expect(constantTimeBytesEqual(a, b), isFalse);
    });

    test('the same passcode under a different salt derives different bytes',
        () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final a = await const Pbkdf2PasscodeKdf().derive(
        passcode: '1234',
        salt: generatePasscodeSalt(),
        iterations: 1000,
      );
      final b = await const Pbkdf2PasscodeKdf().derive(
        passcode: '1234',
        salt: generatePasscodeSalt(),
        iterations: 1000,
      );
      expect(constantTimeBytesEqual(a, b), isFalse);
    });
  });

  group('kPasscodeKdfIterations', () {
    test('is at least the 600k OWASP floor for PBKDF2-HMAC-SHA256', () {
      expect(kPasscodeKdfIterations, greaterThanOrEqualTo(600000));
    });
  });
}
