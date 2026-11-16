import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Decrypted video handed to the platform player (and the send-side probe
/// and transcode source), in the temp directory. The launch sweep
/// (`plaintext_temp_sweep_io.dart`) deletes what a killed process left.
const String videoTempPrefix = 'fp_video_';

/// The transcoder's output (`umbra_tx_<µs>.mp4`, plus its second-pass
/// `….p2.mp4`), which light_compressor_v2 writes to the app's files
/// directory, not the temp directory.
const String transcodeOutputPrefix = 'umbra_tx_';

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
