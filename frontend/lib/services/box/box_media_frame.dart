import 'dart:typed_data';

import 'box_wire.dart';

/// `uint32be(len) ‖ ciphertext ‖ zeros` to the smallest [kBoxMediaLadder]
/// rung that holds `4 + len` (E17a) — the `QueueSeal`/contact-backup framing,
/// so the box only ever sees a rung size, never the file's (I5). A body that
/// fills a rung exactly stays on it. Throws [ArgumentError] past the top rung.
Uint8List frameMediaToRung(Uint8List ciphertext) {
  final needed = 4 + ciphertext.length;
  final rung = kBoxMediaLadder.firstWhere(
    (size) => size >= needed,
    orElse: () => throw ArgumentError.value(
      ciphertext.length,
      'ciphertext',
      'longer than the top media rung',
    ),
  );
  final framed = Uint8List(rung);
  framed.buffer.asByteData().setUint32(0, ciphertext.length);
  framed.setRange(4, needed, ciphertext);
  return framed;
}

/// Inverse of [frameMediaToRung]: null unless [framed] is a rung size and its
/// length prefix fits inside it. The padding is not checked — the AES-GCM tag
/// inside the body is what authenticates the file.
Uint8List? unframeMedia(Uint8List framed) {
  if (!kBoxMediaLadder.contains(framed.length)) return null;
  final length = ByteData.sublistView(framed).getUint32(0);
  if (length > framed.length - 4) return null;
  return Uint8List.sublistView(framed, 4, 4 + length);
}
