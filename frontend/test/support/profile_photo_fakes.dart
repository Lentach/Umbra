import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/profile_photo.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/media_crypto_service.dart';

/// A JPEG's marker stream up to and including its frame header: SOI, an APP0
/// segment, a DQT-shaped segment, then the SOF [marker] claiming [width] x
/// [height]. Enough for the header walk (`ProfilePhotoCodec.isSound`); never
/// decodable. [tail] distinguishes files that share a size.
Uint8List jpegHeader(
  int width,
  int height, {
  int marker = 0xC0,
  List<int> prefix = const [],
  List<int> tail = const [],
}) => Uint8List.fromList([
  0xFF, 0xD8, //
  0xFF, 0xE0, 0x00, 0x10, ...List.filled(14, 0x4A), // APP0, length 16
  0xFF, 0xDB, 0x00, 0x05, 1, 2, 3, // DQT, length 5
  ...prefix,
  0xFF, marker, 0x00, 0x0B, 0x08, // SOF, length 11, 8-bit
  height >> 8, height & 0xFF, width >> 8, width & 0xFF,
  0x01, 0x01, 0x11, 0x00,
  ...tail,
]);

/// A small "photo" the codec vouches for, different for every [seed].
Uint8List fakeJpeg([int seed = 0]) => jpegHeader(64, 64, tail: [seed & 0xFF]);

/// The media id a test names a file by: 32 bytes of [fill], spelled as the
/// box spells it.
String mediaIdOf(int fill) => boxB64(Uint8List(32)..fillRange(0, 32, fill));

/// A media crypto that runs without the native library. A "ciphertext" is the
/// plaintext reversed plus a 16-byte tag derived from key AND nonce, so a
/// wrong key, a wrong nonce or a flipped tag byte fails to open the way an
/// AES-GCM tag would; every call is counted.
class TagMediaCrypto extends MediaCryptoService {
  int encrypts = 0;
  int decrypts = 0;
  final List<Uint8List> encrypted = [];

  static Uint8List _tag(String keyB64, String ivB64) {
    final key = base64.decode(keyB64);
    final iv = base64.decode(ivB64);
    return Uint8List.fromList(List.filled(16, key[0] ^ iv[0] ^ key[31]));
  }

  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async {
    encrypted.add(bytes);
    final n = ++encrypts;
    final key = base64.encode([for (var i = 0; i < 32; i++) (n + i) & 0xFF]);
    final iv = base64.encode(List.filled(12, (n * 3) & 0xFF));
    return EncryptedMedia(
      ciphertext: Uint8List.fromList([...bytes.reversed, ..._tag(key, iv)]),
      keyBase64: key,
      ivBase64: iv,
    );
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    String keyB64,
    String ivB64,
  ) async {
    decrypts++;
    if (ciphertext.length < 16) throw const FormatException('short');
    final tag = _tag(keyB64, ivB64);
    final body = ciphertext.length - 16;
    for (var i = 0; i < 16; i++) {
      if (ciphertext[body + i] != tag[i]) {
        throw const FormatException('bad tag');
      }
    }
    return Uint8List.fromList(ciphertext.sublist(0, body).reversed.toList());
  }
}

/// A photo [plain] sealed by [crypto] the way a sender does: the reference
/// naming it (media id from [idFill], counter [rev]) and the file the box
/// would hold.
Future<({ProfilePhotoRef ref, Uint8List ciphertext})> sealPhoto(
  TagMediaCrypto crypto,
  Uint8List plain, {
  int rev = 1,
  int idFill = 1,
}) async {
  final sealed = await crypto.encrypt(plain);
  return (
    ref: ProfilePhotoRef(
      rev: rev,
      mediaId: mediaIdOf(idFill),
      key: sealed.keyBase64,
      iv: sealed.ivBase64,
    ),
    ciphertext: sealed.ciphertext,
  );
}
