import 'dart:convert';
import 'dart:typed_data';

import 'profile/profile_photo_codec.dart';

/// The link preview's thumbnail (security hardening C1). The SENDER fetches
/// the page's og:image and scales it into a small JPEG that rides inside the
/// E2E envelope (`linkPreview.img`, base64); a receiver renders only those
/// bytes and never contacts the page's host, so a link cannot reveal its
/// reader's IP or reading time.
abstract final class LinkPreviewThumb {
  /// The longest side this build sends.
  static const int kSide = 320;

  /// The longest side this build accepts.
  static const int kMaxAcceptedSide = 320;

  /// The largest JPEG this build sends: base64 makes it ~8 KiB of the
  /// ~16 KiB box envelope, leaving the text, quote and title their room.
  static const int kMaxBytes = 6 * 1024;

  /// The largest decoded JPEG a receiver keeps (room over [kMaxBytes]).
  static const int kMaxAcceptedBytes = 8 * 1024;

  /// [kMaxAcceptedBytes] as base64 characters: checked before decoding.
  static const int _maxBase64Length = (kMaxAcceptedBytes * 4 ~/ 3) + 4;

  /// The JPEG in [b64], or null when it is absent, not base64, over the
  /// byte cap, or not a sound JPEG within [kMaxAcceptedSide]. Peer data:
  /// null drops only the image, never the message.
  static Uint8List? decode(String? b64) {
    if (b64 == null || b64.isEmpty || b64.length > _maxBase64Length) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } on FormatException {
      return null;
    }
    if (bytes.length > kMaxAcceptedBytes ||
        !ProfilePhotoCodec.isSound(bytes, maxSide: kMaxAcceptedSide)) {
      return null;
    }
    return bytes;
  }

  /// [b64] when [decode] accepts it, else null.
  static String? validated(String? b64) => decode(b64) == null ? null : b64;

  /// [downloaded] (any image the platform decodes) as a base64 JPEG of at
  /// most [kSide] px and [kMaxBytes], stepping quality then size down until
  /// it fits. Null when it cannot be decoded or will not fit.
  static Future<String?> scale(Uint8List downloaded) async {
    for (final (side, quality) in const [
      (kSide, 80),
      (kSide, 60),
      (240, 60),
      (160, 55),
      (120, 45),
    ]) {
      final jpeg = await ProfilePhotoCodec.scale(
        downloaded,
        side: side,
        quality: quality,
      );
      if (jpeg == null) return null;
      if (jpeg.length <= kMaxBytes) return base64Encode(jpeg);
    }
    return null;
  }
}
