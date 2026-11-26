import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Trigger browser download of decrypted [bytes].
Future<void> saveBytesAsDownload(List<int> bytes, String filename) async {
  await _saveBytesAsDownload(bytes, filename);
}

/// Web saves go through the browser's download manager, outside the app's
/// reach: there is no saved copy of ours to delete.
Future<bool> deleteSavedDownloads() async => true;

Future<void> _saveBytesAsDownload(List<int> bytes, String filename) async {
  final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final blob = web.Blob([u8.toJS].toJS);
  final objectUrl = web.URL.createObjectURL(blob);
  _triggerAnchorDownload(objectUrl, filename);
  Future.delayed(const Duration(milliseconds: 500), () {
    web.URL.revokeObjectURL(objectUrl);
  });
}

void _triggerAnchorDownload(String objectUrl, String filename) {
  final anchor = web.HTMLAnchorElement()
    ..href = objectUrl
    ..download = _sanitizeFilename(filename)
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

String _sanitizeFilename(String name) {
  if (name.isEmpty) return 'document';
  final segments = name.replaceAll(RegExp(r'[/\\]'), ' ').split(RegExp(r'\s+'));
  String s = segments.last;
  if (s.isEmpty) s = 'document';
  return s.replaceAll(RegExp(r'[^\w\s.\-]'), '_');
}
