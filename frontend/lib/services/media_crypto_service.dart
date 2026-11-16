import 'dart:convert';
import 'dart:typed_data';

import 'package:webcrypto/webcrypto.dart';

import 'box/box_media_frame.dart';
import 'box/box_wire.dart';

class EncryptedMedia {
  final Uint8List ciphertext;
  final String keyBase64;
  final String ivBase64;

  const EncryptedMedia({
    required this.ciphertext,
    required this.keyBase64,
    required this.ivBase64,
  });
}

/// The AES-256-GCM primitive under [MediaCryptoService]: webcrypto in the
/// app. An interface so the padding around it runs under `flutter test` on
/// hosts where webcrypto's native library is not set up (traps.md, Tests).
abstract interface class MediaCipher {
  /// [plaintext] sealed under a fresh random 32-byte key and 12-byte IV.
  Future<({Uint8List key, Uint8List iv, Uint8List ciphertext})> sealFresh(
    Uint8List plaintext,
  );

  /// Inverse of [sealFresh]; throws on a wrong key or tampered bytes.
  Future<Uint8List> open(Uint8List key, Uint8List iv, Uint8List ciphertext);
}

class WebCryptoMediaCipher implements MediaCipher {
  const WebCryptoMediaCipher();

  @override
  Future<({Uint8List key, Uint8List iv, Uint8List ciphertext})> sealFresh(
    Uint8List plaintext,
  ) async {
    final keyBytes = Uint8List(32);
    fillRandomBytes(keyBytes);
    final iv = Uint8List(12);
    fillRandomBytes(iv);
    final key = await AesGcmSecretKey.importRawKey(keyBytes);
    final ciphertext = await key.encryptBytes(plaintext, iv);
    return (key: keyBytes, iv: iv, ciphertext: ciphertext);
  }

  @override
  Future<Uint8List> open(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) async {
    final imported = await AesGcmSecretKey.importRawKey(key);
    return imported.decryptBytes(ciphertext, iv);
  }
}

class MediaCryptoService {
  MediaCryptoService({MediaCipher cipher = const WebCryptoMediaCipher()})
    : _cipher = cipher;

  final MediaCipher _cipher;

  static const int maxBytes = 20 * 1024 * 1024;

  /// The longest ciphertext a receiver accepts: a [maxBytes] file is padded
  /// to the 32 MiB rung before sealing (plan A1), so its ciphertext is the
  /// rung minus the frame's 4-byte prefix. A file sealed before A1 is its
  /// plaintext + the 16-byte GCM tag, well under this.
  static const int maxCiphertextBytes = kBoxMediaTopRung - 4;

  /// Client video-length policy, in seconds. Enforced by the composer with a
  /// toast and re-checked in `sendVideoMessage` as a backstop.
  ///
  /// Sized against the real constraint, which is bytes rather than seconds:
  /// iOS HTML Media Capture downsamples to ~360x480 and measures ~103 KB/s in
  /// production, so 180 s lands near 18.5 MB — inside [maxBytes] and inside
  /// nginx's `client_max_body_size`. A full-quality gallery clip is an order
  /// of magnitude denser and will hit [maxBytes] long before this cap; that
  /// asymmetry only disappears with on-device transcoding.
  static const int maxVideoDurationSeconds = 180;

  /// [bytes] padded to fill its box media rung ([padMediaPlaintext]), then
  /// sealed: the ciphertext's length names the rung, never the file.
  Future<EncryptedMedia> encrypt(Uint8List bytes) async {
    if (bytes.length > maxBytes) {
      throw ArgumentError('File exceeds 20MB limit');
    }
    final sealed = await _cipher.sealFresh(padMediaPlaintext(bytes));
    return EncryptedMedia(
      ciphertext: sealed.ciphertext,
      keyBase64: base64.encode(sealed.key),
      ivBase64: base64.encode(sealed.iv),
    );
  }

  /// [filled] sealed as it is: its caller already padded it to fill a rung
  /// with bytes its own readers ignore ([filledPlaintextLength]), as a
  /// catch-up blob does so a 0.2.82 sibling still reads it. Throws
  /// [ArgumentError] unless it fills a rung exactly.
  Future<EncryptedMedia> encryptFilled(Uint8List filled) async {
    if (!kBoxMediaLadder.contains(filled.length + 4 + kMediaGcmTagBytes)) {
      throw ArgumentError.value(
        filled.length,
        'filled',
        'does not fill a media rung',
      );
    }
    final sealed = await _cipher.sealFresh(filled);
    return EncryptedMedia(
      ciphertext: sealed.ciphertext,
      keyBase64: base64.encode(sealed.key),
      ivBase64: base64.encode(sealed.iv),
    );
  }

  /// The file [ciphertext] holds, its padding removed; a file sealed before
  /// A1 (no padding) comes back as it was.
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    String keyB64,
    String ivB64,
  ) async {
    final plaintext = await _cipher.open(
      Uint8List.fromList(base64.decode(keyB64)),
      Uint8List.fromList(base64.decode(ivB64)),
      ciphertext,
    );
    return unpadMediaPlaintext(plaintext);
  }
}
