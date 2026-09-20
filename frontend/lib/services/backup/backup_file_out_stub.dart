import 'dart:typed_data';

import '../../utils/download_utils_web.dart'
    if (dart.library.io) '../../utils/download_utils_io.dart'
    as download_utils;

/// Web (and any host without `dart:io`): an ordinary browser download, which
/// is already the platform's own "give this to the user" gesture. No share
/// sheet, no temp file, no `share_plus` on the web build.
Future<void> emitBackupFile(Uint8List bytes, String filename) =>
    download_utils.saveBytesAsDownload(bytes, filename);
