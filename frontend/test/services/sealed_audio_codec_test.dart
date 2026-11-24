import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fireplace/services/encryption/sealed_audio_codec.dart';

import '../support/native_webcrypto.dart';

/// Real AES-GCM via webcrypto needs the native library (`dart run
/// webcrypto:setup`). Without it these tests are SKIPPED on a dev machine and
/// FAIL in CI (`REQUIRE_NATIVE_WEBCRYPTO=1`, see support/native_webcrypto.dart).
/// Header-only checks (kidOf/isSealed/hasMagic) run everywhere — they do no
/// crypto.
bool? _webcryptoOk;
Object? _webcryptoError;

Future<bool> _ensureWebcryptoAvailable(Uint8List key) async {
  if (_webcryptoOk != null) return _webcryptoOk!;
  try {
    await SealedAudioCodec.seal(
      kid: 'probe',
      keyBytes: key,
      plaintext: Uint8List.fromList([1]),
    );
    _webcryptoOk = true;
  } catch (e) {
    _webcryptoError = e;
    _webcryptoOk = false;
  }
  return _webcryptoOk!;
}

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final otherKey = Uint8List.fromList(List.generate(32, (i) => 200 - i));

  group('header (no crypto)', () {
    test('legacy plain bytes are never mistaken for sealed', () {
      final plain = Uint8List.fromList(utf8.encode('RIFF....not sealed'));
      expect(SealedAudioCodec.isSealed(plain), isFalse);
      expect(SealedAudioCodec.kidOf(plain), isNull);
      expect(SealedAudioCodec.hasMagic(plain), isFalse);
    });

    test('empty and truncated inputs are not sealed', () {
      expect(SealedAudioCodec.isSealed(Uint8List(0)), isFalse);
      expect(SealedAudioCodec.hasMagic(Uint8List(3)), isFalse);
      // Magic + version but a truncated kid/IV region: hasMagic (peek) says
      // yes, the authoritative full header check says no.
      final truncated = Uint8List.fromList([
        ...utf8.encode('FPAE'),
        1,
        5, // claims a 5-byte kid that is not there
      ]);
      expect(SealedAudioCodec.hasMagic(truncated), isTrue);
      expect(SealedAudioCodec.isSealed(truncated), isFalse);
      expect(SealedAudioCodec.kidOf(truncated), isNull);
    });
  });

  group('round-trip (real cipher)', () {
    test('seal/unseal, kid readable without key, multi-byte kid', () async {
      if (!await _ensureWebcryptoAvailable(key)) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final audio = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      final sealed = await SealedAudioCodec.seal(
        kid: 'k17-żółć', // multi-byte UTF-8 kid must survive the length math
        keyBytes: key,
        plaintext: audio,
      );
      expect(SealedAudioCodec.isSealed(sealed), isTrue);
      expect(SealedAudioCodec.hasMagic(sealed), isTrue);
      expect(SealedAudioCodec.kidOf(sealed), 'k17-żółć');
      final plain =
          await SealedAudioCodec.unseal(bytes: sealed, keyBytes: key);
      expect(plain, audio);
    });

    test('wrong key and tampered ciphertext both yield null, never throw',
        () async {
      if (!await _ensureWebcryptoAvailable(key)) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final sealed = await SealedAudioCodec.seal(
        kid: 'k1',
        keyBytes: key,
        plaintext: Uint8List.fromList(utf8.encode('audio')),
      );
      expect(
          await SealedAudioCodec.unseal(bytes: sealed, keyBytes: otherKey),
          isNull);
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 1;
      expect(await SealedAudioCodec.unseal(bytes: tampered, keyBytes: key),
          isNull);
    });

    test('plaintext that itself starts with FPAE still round-trips', () async {
      if (!await _ensureWebcryptoAvailable(key)) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final tricky = Uint8List.fromList([
        ...utf8.encode('FPAE'),
        1,
        2,
        ...List.generate(64, (i) => i),
      ]);
      final sealed = await SealedAudioCodec.seal(
        kid: 'k1',
        keyBytes: key,
        plaintext: tricky,
      );
      expect(
          await SealedAudioCodec.unseal(bytes: sealed, keyBytes: key), tricky);
    });

    test('unseal of legacy plain bytes is null (never garbage audio)',
        () async {
      if (!await _ensureWebcryptoAvailable(key)) {
        skipWithoutNativeWebcrypto(_webcryptoError);
        return;
      }
      final plain = Uint8List.fromList(List.generate(128, (i) => i));
      expect(
          await SealedAudioCodec.unseal(bytes: plain, keyBytes: key), isNull);
    });
  });
}
