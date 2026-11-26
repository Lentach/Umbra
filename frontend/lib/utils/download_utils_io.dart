import 'dart:io' show Directory, File, FileSystemException;

import 'package:path_provider/path_provider.dart';

/// Every file the user saves from a chat ("Save image", "Download") lives in
/// this ONE subfolder of the app documents directory (A3-MSG-A-04), so the
/// logout and the local-data wipes can delete exactly these decrypted copies
/// and never anything else the app owns (`audio_cache`, ...).
const String _savedDirName = 'saved_downloads';

/// The gallery's name for a saved image before the subfolder existed:
/// `image_<messageId>.<ext>` (`media_gallery.dart`), written straight into the
/// documents directory. Nothing else in the app writes such a name there, so
/// [deleteSavedDownloads] can take it. A document saved by the old code kept
/// the sender's file name and cannot be told apart from app data: it stays.
final RegExp _legacyImageName = RegExp(r'^image_-?\d+\.(png|gif|webp|jpg)$');

/// Save raw [bytes] as a user-visible download (app documents on native).
Future<void> saveBytesAsDownload(List<int> bytes, String filename) async {
  final dir = await _savedDir();
  await dir.create(recursive: true);
  final safe = _sanitizeFilename(filename);
  final file = File('${dir.path}/$safe');
  await file.writeAsBytes(bytes);
}

/// Deletes every saved copy: the subfolder, and the legacy top-level images.
/// True once nothing of them is left; a failure is reported, never thrown,
/// because it runs inside the sign-out and the wipes.
Future<bool> deleteSavedDownloads() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    var clean = true;
    final saved = Directory('${docs.path}/$_savedDirName');
    if (saved.existsSync()) await saved.delete(recursive: true);
    if (saved.existsSync()) clean = false;
    await for (final entity in docs.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!_legacyImageName.hasMatch(name)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        clean = false;
      }
    }
    return clean;
  } on Object {
    return false;
  }
}

Future<Directory> _savedDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/$_savedDirName');
}

String _sanitizeFilename(String name) {
  if (name.isEmpty) return 'document';
  final segments = name.replaceAll(RegExp(r'[/\\]'), ' ').split(RegExp(r'\s+'));
  String s = segments.last;
  if (s.isEmpty) s = 'document';
  return s.replaceAll(RegExp(r'[^\w\s.\-]'), '_');
}
