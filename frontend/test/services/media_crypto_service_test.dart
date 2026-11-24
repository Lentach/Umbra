import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/services/media_crypto_service.dart';

import '../support/native_webcrypto.dart';

/// Needs the native webcrypto library (`dart run webcrypto:setup`; cmake + a C
/// compiler). Without it the round-trip tests are SKIPPED on a dev machine and
/// FAIL in CI (`REQUIRE_NATIVE_WEBCRYPTO=1`, see support/native_webcrypto.dart).
bool? _webcryptoOk;
Object? _webcryptoError;

Future<bool> _ensureWebcryptoAvailable() async {
  if (_webcryptoOk != null) return _webcryptoOk!;
  try {
    await MediaCryptoService().encrypt(Uint8List.fromList([1]));
    _webcryptoOk = true;
  } catch (e) {
    _webcryptoError = e;
    _webcryptoOk = false;
  }
  return _webcryptoOk!;
}

void main() {
  final service = MediaCryptoService();

  group('MediaCryptoService', () {
    test('encrypt produces ciphertext different from input', () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final input = Uint8List.fromList(List.generate(100, (i) => i));
      final result = await service.encrypt(input);
      expect(result.ciphertext, isNot(equals(input)));
      expect(result.keyBase64.isNotEmpty, isTrue);
      expect(result.ivBase64.isNotEmpty, isTrue);
    });

    test('decrypt restores original bytes', () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final encrypted = await service.encrypt(input);
      final decrypted = await service.decrypt(
        encrypted.ciphertext,
        encrypted.keyBase64,
        encrypted.ivBase64,
      );
      expect(decrypted, equals(input));
    });

    test('each encrypt call produces unique key and IV', () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final input = Uint8List.fromList([42, 43, 44]);
      final a = await service.encrypt(input);
      final b = await service.encrypt(input);
      expect(a.keyBase64, isNot(equals(b.keyBase64)));
      expect(a.ivBase64, isNot(equals(b.ivBase64)));
    });

    test('decrypt with wrong key throws', () async {
      if (!await _ensureWebcryptoAvailable()) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final input = Uint8List.fromList([1, 2, 3]);
      final encrypted = await service.encrypt(input);
      final other = await service.encrypt(input);
      await expectLater(
        service.decrypt(
          encrypted.ciphertext,
          other.keyBase64,
          encrypted.ivBase64,
        ),
        throwsA(anything),
      );
    });

    test('throws ArgumentError for input over 20MB', () async {
      // Size check runs before webcrypto; no `webcrypto:setup` required.
      final huge = Uint8List(21 * 1024 * 1024);
      await expectLater(service.encrypt(huge), throwsA(isA<ArgumentError>()));
    });

    test('20MB boundary: maxBytes+1 throws, exactly maxBytes clears the guard',
        () async {
      // Source guard is `bytes.length > maxBytes`. One byte over MUST throw...
      await expectLater(
        service.encrypt(Uint8List(MediaCryptoService.maxBytes + 1)),
        throwsA(isA<ArgumentError>()),
      );
      // ...while exactly maxBytes MUST clear the size guard (catches a `>=`
      // off-by-one). It then proceeds to webcrypto, which either encrypts
      // (native available) or throws a NON-ArgumentError (native missing) —
      // both prove the size guard was passed.
      try {
        await service.encrypt(Uint8List(MediaCryptoService.maxBytes));
      } on ArgumentError {
        fail('exactly maxBytes must pass the size guard (off-by-one: >= vs >)');
      } catch (_) {
        // Non-ArgumentError (e.g. webcrypto native unavailable) is acceptable.
      }
    });
  });
}
