import 'dart:typed_data';

import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Distinct first and last bytes, so a shifted or truncated body shows.
Uint8List _body(int length) => Uint8List(length)
  ..[0] = 0xa1
  ..[length - 1] = 0xb2;

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
    "today's largest file (20 MiB of plaintext + the GCM tag) lands on the "
    '32 MiB rung',
    () {
      final framed = frameMediaToRung(
        Uint8List(MediaCryptoService.maxCiphertextBytes),
      );
      expect(framed.length, 32 * 1024 * 1024);
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
}
