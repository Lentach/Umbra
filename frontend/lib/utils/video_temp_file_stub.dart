import 'dart:typed_data';

import 'package:video_player/video_player.dart';

Future<String> writeVideoTempFile(Uint8List bytes, Object id) async => '';

Future<void> deleteVideoTempFile(String? path) async {}

VideoPlayerController controllerForPath(String path) =>
    throw UnsupportedError('File-backed video playback is native-only');
