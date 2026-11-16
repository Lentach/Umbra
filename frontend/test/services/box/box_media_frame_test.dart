import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/box_fakes.dart';

/// Distinct first and last bytes, so a shifted or truncated body shows.
Uint8List _body(int length) {
  final body = Uint8List(length);
  if (length > 0) {
    body
      ..[0] = 0xa1
      ..[length - 1] = 0xb2;
  }
  return body;
}

void main() {
  test(
    'every rung takes a body that fills it exactly (4 + len == rung) and '
    'sends one byte more to the next rung (smallest rung >= 4 + len)',
    () {
      for (var i = 0; i < kBoxMediaLadder.length; i++) {
        final rung = kBoxMediaLadder[i];
        final exact = _body(rung - 4);
        final framed = frameMediaToRung(exact);
        expect(framed.length, rung, reason: 'rung $rung, exact fit');
        expect(unframeMedia(framed), exact);

        if (i + 1 < kBoxMediaLadder.length) {
          final over = _body(rung - 3);
          final next = frameMediaToRung(over);
          expect(next.length, kBoxMediaLadder[i + 1], reason: 'rung $rung + 1');
          expect(unframeMedia(next), over);
        }
      }
    },
  );

  test('the frame is uint32be(len) ‖ ciphertext ‖ zeros', () {
    final framed = frameMediaToRung(Uint8List.fromList([9, 8, 7]));
    expect(framed.length, kBoxMediaLadder.first);
    expect(framed.sublist(0, 7), [0, 0, 0, 3, 9, 8, 7]);
    expect(framed.skip(7).every((b) => b == 0), isTrue);
    expect(unframeMedia(frameMediaToRung(Uint8List(0))), isEmpty);
  });

  test(
    "today's largest file (20 MiB) pads to the 32 MiB rung, and its sealed "
    'body is exactly the largest ciphertext a receiver accepts',
    () {
      final padded = padMediaPlaintext(Uint8List(MediaCryptoService.maxBytes));
      final sealedLength = padded.length + kMediaGcmTagBytes;
      expect(sealedLength, MediaCryptoService.maxCiphertextBytes);
      expect(frameMediaToRung(Uint8List(sealedLength)).length, kBoxMediaTopRung);
    },
  );

  test('a body past the top rung is refused', () {
    expect(
      () => frameMediaToRung(Uint8List(kBoxMediaLadder.last - 3)),
      throwsArgumentError,
    );
  });

  test('unframe rejects a size that is not a rung', () {
    final framed = frameMediaToRung(_body(10));
    for (final size in [0, 3, 4, 4095, 4097, 16 * 1024 - 1]) {
      final bad = Uint8List(size);
      if (size >= 4) bad.setRange(0, 4, framed);
      expect(unframeMedia(bad), isNull, reason: 'size $size');
    }
  });

  test('unframe rejects a length prefix that runs past the end', () {
    final framed = frameMediaToRung(_body(10));
    final rung = framed.length;
    // Exactly to the end is a body; one past it is damage.
    framed.buffer.asByteData().setUint32(0, rung - 4);
    expect(unframeMedia(framed)?.length, rung - 4);
    framed.buffer.asByteData().setUint32(0, rung - 3);
    expect(unframeMedia(framed), isNull);
    framed.buffer.asByteData().setUint32(0, 0xffffffff);
    expect(unframeMedia(framed), isNull);
  });

  group('the file size is sealed inside the encryption (plan A1)', () {
    final crypto = MediaCryptoService(cipher: PointyMediaCipher());

    test(
      'every rung: the largest file that fits pads to fill it exactly, one '
      'byte more pads to the next rung',
      () {
        // 4-byte frame prefix + 16-byte GCM tag + 12-byte trailer.
        const overhead = 4 + kMediaGcmTagBytes + kMediaPadTrailerBytes;
        for (var i = 0; i < kBoxMediaLadder.length; i++) {
          final rung = kBoxMediaLadder[i];
          final fits = padMediaPlaintext(_body(rung - overhead));
          expect(fits.length + kMediaGcmTagBytes + 4, rung, reason: '$rung');
          if (i + 1 < kBoxMediaLadder.length) {
            final over = padMediaPlaintext(_body(rung - overhead + 1));
            expect(
              over.length + kMediaGcmTagBytes + 4,
              kBoxMediaLadder[i + 1],
              reason: '$rung + 1',
            );
          }
        }
        expect(
          () => padMediaPlaintext(Uint8List(kBoxMediaTopRung - overhead + 1)),
          throwsArgumentError,
        );
      },
    );

    test(
      'what the server sees: files of different sizes on one rung upload the '
      'same length and the same prefix, rung − 4, with no zeros after the '
      'ciphertext',
      () async {
        final frames = [
          for (final size in [0, 1, 700, 4096 - 32])
            frameMediaToRung((await crypto.encrypt(_body(size))).ciphertext),
        ];
        for (final framed in frames) {
          expect(framed.length, 4096);
          expect(ByteData.sublistView(framed).getUint32(0), 4096 - 4);
        }
      },
    );

    test('decrypt gives back exactly the file, at every size class', () async {
      for (final size in [0, 1, 700, 4096 - 32, 4096 - 31, 70000]) {
        final file = _body(size);
        final sealed = await crypto.encrypt(file);
        final framed = frameMediaToRung(sealed.ciphertext);
        expect(
          await crypto.decrypt(
            unframeMedia(framed)!,
            sealed.keyBase64,
            sealed.ivBase64,
          ),
          file,
          reason: 'size $size',
        );
      }
    });

    test(
      'a file sealed before A1 (an older sender, no padding) still decrypts '
      'to itself',
      () async {
        final cipher = PointyMediaCipher();
        final file = _body(300);
        final old = await cipher.sealFresh(file);
        final decrypted = await MediaCryptoService(cipher: cipher).decrypt(
          old.ciphertext,
          base64.encode(old.key),
          base64.encode(old.iv),
        );
        expect(decrypted, file);
      },
    );

    test(
      'a plaintext is cut only at a well-formed trailer: a length past the '
      'end, or a non-zero byte in the padding, leaves it whole',
      () {
        final padded = padMediaPlaintext(_body(10));
        expect(unpadMediaPlaintext(Uint8List.fromList(padded)), _body(10));

        final nonZeroPad = Uint8List.fromList(padded)..[20] = 1;
        expect(unpadMediaPlaintext(nonZeroPad), nonZeroPad);

        final tooLong = Uint8List.fromList(padded);
        ByteData.sublistView(
          tooLong,
        ).setUint32(tooLong.length - kMediaPadTrailerBytes, tooLong.length);
        expect(unpadMediaPlaintext(tooLong), tooLong);
      },
    );
  });
}
