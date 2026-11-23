import 'dart:io' show File;

import 'package:path_provider/path_provider.dart';

/// Save raw [bytes] as a user-visible download (app documents on native).
Future<void> saveBytesAsDownload(List<int> bytes, String filename) async {
  final dir = await getApplicationDocumentsDirectory();
  final safe = _sanitizeFilename(filename);
  final file = File('${dir.path}/$safe');
  await file.writeAsBytes(bytes);
}

String _sanitizeFilename(String name) {
  if (name.isEmpty) return 'document';
  final segments = name.replaceAll(RegExp(r'[/\\]'), ' ').split(RegExp(r'\s+'));
  String s = segments.last;
  if (s.isEmpty) s = 'document';
  return s.replaceAll(RegExp(r'[^\w\s.\-]'), '_');
}
