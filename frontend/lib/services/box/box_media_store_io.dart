import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'box_media_store.dart';

BoxMediaStore deviceBoxMediaStore() => IoBoxMediaStore();

/// Deletes every account's copies (`<app support>/box_media`), for the
/// in-app erase (`deleteLocalMessageStoreFiles`). True once the directory is
/// confirmed gone.
Future<bool> deleteAllBoxMediaCopies({
  Future<Directory> Function()? root,
}) async {
  try {
    final dir = await (root ?? getApplicationSupportDirectory)();
    final media = Directory('${dir.path}${Platform.pathSeparator}box_media');
    if (media.existsSync()) await media.delete(recursive: true);
    return !media.existsSync();
  } on Object {
    return false;
  }
}

/// Native: one file per copy, `<app support>/box_media/<userId>/<id>`.
class IoBoxMediaStore implements BoxMediaStore {
  IoBoxMediaStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _root;

  /// Temp names stay unique across instances: the sender's copy and a
  /// download may be written by different stores.
  static int _writes = 0;

  Future<File> _file(int userId, Uint8List id) async {
    final name = boxMediaIdName(id);
    final sep = Platform.pathSeparator;
    final dir = await _root();
    return File('${dir.path}${sep}box_media$sep$userId$sep$name');
  }

  @override
  Future<void> put(int userId, Uint8List id, Uint8List ciphertext) async {
    final file = await _file(userId, id);
    await file.parent.create(recursive: true);
    // Written aside, then renamed over: a crash mid-write never leaves a
    // truncated copy that a later read would take for the file.
    final temp = File('${file.path}.${_writes++}.tmp');
    try {
      await temp.writeAsBytes(ciphertext, flush: true);
      await temp.rename(file.path);
    } on Object {
      try {
        await temp.delete();
      } on FileSystemException {
        // Already gone, or never created.
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List?> get(int userId, Uint8List id) async {
    final file = await _file(userId, id);
    try {
      return await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<bool> has(int userId, Uint8List id) async =>
      (await _file(userId, id)).existsSync();

  @override
  Future<void> delete(int userId, Uint8List id) async {
    final file = await _file(userId, id);
    try {
      await file.delete();
    } on PathNotFoundException {
      // No copy: nothing to delete.
    }
  }
}
