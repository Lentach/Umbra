import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Decrypted video handed to the platform player (and the send-side probe
/// and transcode source), in the temp directory.
const String videoTempPrefix = 'fp_video_';

/// The transcoder's output (`umbra_tx_<µs>.mp4`, plus its second-pass
/// `….p2.mp4`), which light_compressor_v2 writes to the app's files
/// directory, not the temp directory.
const String transcodeOutputPrefix = 'umbra_tx_';

/// light_compressor_v2's audio spill file for a transcode, in the temp
/// directory.
const String _transcodeAudioPrefix = 'lc_audio_';

/// Write decrypted video bytes to a temp file for [VideoPlayerController.file].
/// The caller owns the file and must delete it on dispose.
Future<String> writeVideoTempFile(Uint8List bytes, Object id) async {
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}${Platform.pathSeparator}'
    '$videoTempPrefix${id}_${DateTime.now().microsecondsSinceEpoch}.mp4',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<void> deleteVideoTempFile(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best-effort; the launch sweep catches what is left.
  }
}

VideoPlayerController controllerForPath(String path) =>
    VideoPlayerController.file(File(path));

/// Deletes the plaintext video files a killed process left behind (hardening
/// A5): every owner deletes its file on dispose or in a `finally`, which a
/// kill skips. Run once at launch; never throws.
Future<int> sweepStaleVideoTempFiles() async {
  final before = DateTime.now();
  try {
    return await sweepVideoTempDirs(
      temp: await getTemporaryDirectory(),
      support: await getApplicationSupportDirectory(),
      before: before,
    );
  } on Object {
    return 0;
  }
}

/// [sweepStaleVideoTempFiles] over explicit directories. Only this app's own
/// names are touched, and only files last modified before [before]: anything
/// newer belongs to a video opened after the sweep began.
@visibleForTesting
Future<int> sweepVideoTempDirs({
  required Directory temp,
  required Directory support,
  required DateTime before,
}) async {
  var deleted = 0;
  Future<void> sweep(Directory dir, List<String> prefixes) async {
    if (!dir.existsSync()) return;
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!prefixes.any(name.startsWith)) continue;
      try {
        if (!entry.lastModifiedSync().isBefore(before)) continue;
        await entry.delete();
        deleted++;
      } on Object {
        // Gone already or busy: the next launch tries again.
      }
    }
  }

  await sweep(temp, [videoTempPrefix, _transcodeAudioPrefix]);
  await sweep(support, [transcodeOutputPrefix]);
  return deleted;
}
