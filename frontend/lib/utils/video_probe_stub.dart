import 'dart:typed_data';

import 'video_preview.dart';

/// Fallback probe for hosts with neither `dart:js_interop` nor `dart:io` —
/// notably a `--wasm` web build, where `dart.library.html` is false, which is
/// why the web files select on `dart.library.js_interop` instead.
///
/// Answers "unknown", so the composer cannot enforce the duration cap and the
/// chat bubble falls back to its legacy fixed frame. Both are graceful.
Future<VideoPreview> probeVideoPreview(
  Uint8List bytes, {
  String mimeType = 'video/mp4',
}) async => VideoPreview.unknown;
