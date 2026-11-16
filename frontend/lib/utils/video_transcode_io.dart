import 'dart:io';
import 'dart:typed_data';

import 'package:light_compressor_v2/light_compressor_v2.dart';

import 'video_temp_file_io.dart' as temp;

/// The size an oversize clip is transcoded toward, in MB. Deliberately under
/// [MediaCryptoService.maxBytes] (20 MB): `targetSizeMb` is approximate even
/// with two-pass, and an output that lands at 19.x MB still has to survive the
/// exact byte gate in `sendPickedVideo`.
const int _kTargetSizeMb = 18;

/// light_compressor_v2 ships natives for Android/iOS/macOS only; on
/// Windows/Linux (dev machines, VM test runs) the channel would throw, so the
/// caller must not even offer the "Compressing…" affordance there.
bool get isVideoTranscodeSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// Transcodes [bytes] toward [_kTargetSizeMb] on the device's hardware codec
/// (MediaCodec / AVFoundation — no FFmpeg).
///
/// Returns the compressed bytes, or null when transcoding is unavailable or
/// failed for any reason — the caller falls back to the "too large" toast, so
/// a null here degrades honestly rather than blocking the send path.
///
/// Physics note, measured against the plugin's own solver: the target bitrate
/// is clamped to a 2 Mbps floor, so clips longer than ~70 s cannot always
/// reach 18 MB — the caller MUST re-check the output against the real byte
/// cap instead of trusting this to have succeeded.
Future<Uint8List?> transcodeVideoToFit(Uint8List bytes) async {
  if (!isVideoTranscodeSupported) return null;
  String? srcPath;
  String? outPath;
  try {
    srcPath = await temp.writeVideoTempFile(bytes, 'tx_src');
    final result = await LightCompressor().compressVideo(
      path: srcPath,
      videoQuality: VideoQuality.medium,
      // The gate only calls this for clips ALREADY over the cap, so the
      // "skip low-bitrate sources" guard must not veto the one job we have.
      isMinBitrateCheckEnabled: false,
      // App-private output, never MediaStore/gallery: this is a wire artifact,
      // not a user file, and private storage needs no permissions.
      android: AndroidConfig(isSharedStorage: false),
      ios: IOSConfig(saveInGallery: false),
      video: Video(
        videoName:
            '${temp.transcodeOutputPrefix}'
            '${DateTime.now().microsecondsSinceEpoch}.mp4',
        targetSizeMb: _kTargetSizeMb,
        // Re-encode a second time only when the first pass overshoots.
        twoPass: true,
      ),
      // Voice-note-grade AAC; without this the source audio is copied through
      // untouched and a high-bitrate track eats the size budget.
      audio: const AudioConfig(bitrate: 96000),
    );
    if (result is! OnSuccess) return null;
    outPath = result.destinationPath;
    return await File(outPath).readAsBytes();
  } catch (_) {
    // Missing plugin (tests), codec failure, IO failure: all degrade to the
    // caller's oversize toast. Nothing here is worth crashing a send over.
    return null;
  } finally {
    await temp.deleteVideoTempFile(srcPath);
    await temp.deleteVideoTempFile(outPath);
  }
}
