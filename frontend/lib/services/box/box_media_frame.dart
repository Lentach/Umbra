import 'dart:typed_data';

import 'box_wire.dart';

/// `uint32be(len) ‖ ciphertext ‖ zeros` to the smallest [kBoxMediaLadder]
/// rung that holds `4 + len` (E17a) — the `QueueSeal`/contact-backup framing.
/// A body that fills a rung exactly stays on it. Throws [ArgumentError] past
/// the top rung.
///
/// The prefix and the zeros are in the clear, so they hide the file's size
/// only because the ciphertext is sealed from [padMediaPlaintext]'s output,
/// which always fills its rung: the prefix then reads `rung − 4` for every
/// file on that rung, and no zeros follow (plan A1).
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

/// The AES-GCM tag `MediaCryptoService` appends to every sealed file.
const int kMediaGcmTagBytes = 16;

/// `uint32be(file length) ‖ "UmbraPad"`, the end of a padded plaintext.
const int kMediaPadTrailerBytes = 12;

const List<int> _kPadMagic = [0x55, 0x6d, 0x62, 0x72, 0x61, 0x50, 0x61, 0x64];

/// What a box attachment is sealed from (plan A1): `file ‖ zeros ‖
/// uint32be(file length) ‖ "UmbraPad"`, exactly as long as the smallest
/// rung that holds it minus the frame prefix and the GCM tag — so the sealed
/// body fills that rung and the server learns the rung, never the file's
/// size. The length sits INSIDE the encryption; [unpadMediaPlaintext] reads
/// it back after the decrypt. Throws [ArgumentError] past the top rung.
Uint8List padMediaPlaintext(Uint8List file) {
  final padded = Uint8List(
    filledPlaintextLength(file.length + kMediaPadTrailerBytes),
  )..setRange(0, file.length, file);
  final trailer = padded.length - kMediaPadTrailerBytes;
  ByteData.sublistView(padded).setUint32(trailer, file.length);
  return padded..setRange(trailer + 4, padded.length, _kPadMagic);
}

/// How long a plaintext must be for its sealed body to fill the smallest
/// rung that holds [contentLength] bytes: that rung minus the frame prefix
/// and the GCM tag. Throws [ArgumentError] past the top rung.
int filledPlaintextLength(int contentLength) {
  final needed = 4 + contentLength + kMediaGcmTagBytes;
  final rung = kBoxMediaLadder.firstWhere(
    (size) => size >= needed,
    orElse: () => throw ArgumentError.value(
      contentLength,
      'contentLength',
      'too long for the top media rung once sealed',
    ),
  );
  return rung - 4 - kMediaGcmTagBytes;
}

/// Inverse of [padMediaPlaintext]. A plaintext without a well-formed trailer
/// (magic, a length that fits, nothing but zeros between) is returned
/// unchanged: a file sealed before A1, from a sender still on an older build.
Uint8List unpadMediaPlaintext(Uint8List plaintext) {
  final total = plaintext.length;
  if (total < kMediaPadTrailerBytes) return plaintext;
  final magicAt = total - _kPadMagic.length;
  for (var i = 0; i < _kPadMagic.length; i++) {
    if (plaintext[magicAt + i] != _kPadMagic[i]) return plaintext;
  }
  final trailer = total - kMediaPadTrailerBytes;
  final length = ByteData.sublistView(plaintext).getUint32(trailer);
  if (length > trailer) return plaintext;
  for (var i = length; i < trailer; i++) {
    if (plaintext[i] != 0) return plaintext;
  }
  // A copy, so the padding (up to a 32 MiB rung) is not kept alive by it.
  return Uint8List.fromList(Uint8List.sublistView(plaintext, 0, length));
}
