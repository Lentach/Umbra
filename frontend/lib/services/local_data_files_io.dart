import 'dart:io';

import 'package:flutter/foundation.dart';

import 'box/box_media_store_io.dart';
import 'encryption/content_db.dart';

/// Native: delete the SQLCipher content store, WAL and shm included, and the
/// box attachment copies (`<app support>/box_media`, decision 40) — their
/// keys lived in the store, so they go with it.
///
/// Only Android ships, and only there does a directory exist to look in — on
/// a test host `getApplicationSupportDirectory` has no platform channel, so
/// asking would throw and report a failed arm for a store that was never
/// created.
Future<bool> deleteLocalMessageStoreFiles() async {
  if (kIsWeb || !Platform.isAndroid) return true;
  final store = await DriftRecordDb.deleteDatabaseFiles();
  final media = await deleteAllBoxMediaCopies();
  return store && media;
}
