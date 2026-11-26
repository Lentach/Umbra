import 'dart:typed_data';

import 'video_preview.dart';

/// Fallback probe for hosts with neither `dart:html` nor `dart:io` — notably a
/// `--wasm` web build, where `dart.library.html` is false (the same trap that
/// silently disables the cross-context Signal lock).
///
/// Answers "unknown", so the composer cannot enforce the duration cap and the
/// chat bubble falls back to its legacy fixed frame. Both are graceful.
Future<VideoPreview> probeVideoPreview(
  Uint8List bytes, {
  String mimeType = 'video/mp4',
}) async => VideoPreview.unknown;
