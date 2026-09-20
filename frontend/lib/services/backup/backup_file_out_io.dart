import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Hands the backup to the user through the system share sheet.
///
/// NOT `saveBytesAsDownload`: on Android that writes into app-private
/// documents, which no file manager can reach and which `pm clear` — the very
/// event this backup exists for — deletes along with everything else. The
/// share sheet is what puts the bytes somewhere the user actually owns
/// (Drive, Files, a chat with themselves).
///
/// The temp copy is written first because the platform channel takes a path,
/// and it is deleted afterwards on a best-effort basis: the share target has
/// already copied the bytes by the time the sheet closes, and leaving a
/// readable plaintext-free (but still sealed) file in the cache is harmless.
Future<void> emitBackupFile(Uint8List bytes, String filename) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'application/octet-stream')]),
    );
  } finally {
    try {
      await file.delete();
    } on Object {
      // A surviving temp file is sealed and expendable; the cache is cleared
      // by the OS. Never fail an otherwise successful export over it.
    }
  }
}
