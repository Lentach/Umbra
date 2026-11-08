import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// The profile photo file (decision 138): a JPEG of at most [kSide]×[kSide]
/// pixels. What a device SENDS is made by [scale]; what it RECEIVES is
/// vouched for by [isSound] before anything decodes it — the sender is a
/// friend's device, and an image whose header claims a billion pixels must
/// not reach the codec.
abstract final class ProfilePhotoCodec {
  /// The longest side of a photo this build sends.
  static const int kSide = 256;

  /// The longest side of a photo this build accepts: room for a later build
  /// to send more, none for a decompression bomb.
  static const int kMaxAcceptedSide = 1024;

  /// The longest encrypted file this build keeps (the 256 KiB box rung):
  /// ours is about 20-40 KiB.
  static const int kMaxCiphertextBytes = 256 * 1024;

  static const int _jpegQuality = 85;

  /// [picked] — whatever image the user chose — scaled down to fit
  /// [kSide]×[kSide] (never up) and encoded as a JPEG, flattened on white
  /// when it had transparency. Null when [picked] is not an image the
  /// platform decodes.
  static Future<Uint8List?> scale(Uint8List picked) async {
    ui.Codec? sourceCodec;
    ui.Image? source;
    ui.Codec? scaledCodec;
    ui.Image? scaled;
    try {
      sourceCodec = await ui.instantiateImageCodec(picked);
      source = (await sourceCodec.getNextFrame()).image;
      final width = source.width;
      final height = source.height;
      if (width <= 0 || height <= 0) return null;
      final ratio = math.min(1, kSide / math.max(width, height));
      final targetWidth = math.max(1, (width * ratio).round());
      final targetHeight = math.max(1, (height * ratio).round());
      // Decoded straight to the target size by the platform, so a 12 MP
      // photo is never held at full size in Dart.
      scaledCodec = await ui.instantiateImageCodec(
        picked,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        allowUpscaling: false,
      );
      scaled = (await scaledCodec.getNextFrame()).image;
      final rgba = await scaled.toByteData();
      if (rgba == null) return null;
      final pixels = rgba.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      final rgb = Uint8List(scaled.width * scaled.height * 3);
      for (var i = 0, o = 0; i < pixels.length; i += 4, o += 3) {
        final a = pixels[i + 3];
        // Over white: a JPEG has no alpha, and black behind a transparent
        // logo is the worse default.
        rgb[o] = _overWhite(pixels[i], a);
        rgb[o + 1] = _overWhite(pixels[i + 1], a);
        rgb[o + 2] = _overWhite(pixels[i + 2], a);
      }
      final image = img.Image.fromBytes(
        width: scaled.width,
        height: scaled.height,
        bytes: rgb.buffer,
        numChannels: 3,
      );
      return Uint8List.fromList(img.encodeJpg(image, quality: _jpegQuality));
    } on Object {
      return null;
    } finally {
      scaled?.dispose();
      scaledCodec?.dispose();
      source?.dispose();
      sourceCodec?.dispose();
    }
  }

  static int _overWhite(int channel, int alpha) =>
      alpha == 255 ? channel : (channel * alpha + 255 * (255 - alpha)) ~/ 255;

  /// Whether [bytes] is a JPEG whose frame header states a size within
  /// [kMaxAcceptedSide]: read from the markers, never decoded.
  static bool isSound(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return false;
    var i = 2;
    while (i + 3 < bytes.length) {
      if (bytes[i] != 0xFF) return false;
      final marker = bytes[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      // Markers without a length: the standalone ones.
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        i += 2;
        continue;
      }
      final length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length < 2) return false;
      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        if (i + 9 > bytes.length) return false;
        final height = (bytes[i + 5] << 8) | bytes[i + 6];
        final width = (bytes[i + 7] << 8) | bytes[i + 8];
        return width > 0 &&
            height > 0 &&
            width <= kMaxAcceptedSide &&
            height <= kMaxAcceptedSide;
      }
      i += 2 + length;
    }
    return false;
  }
}
