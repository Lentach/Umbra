import 'dart:typed_data';

import 'box_media_store_io.dart'
    if (dart.library.js_interop) 'box_media_store_web.dart'
    as impl;
import 'box_wire.dart';

/// This device's copy of each box attachment (decision 40): the box drops a
/// file after 14 days (D8), so every device keeps what it downloaded, and the
/// sender keeps its own. Holds the UNFRAMED AES-GCM ciphertext only — the
/// file key lives in the sealed message record, so a copy here holds nothing
/// the box did not. Keyed by account and the box's 32-byte media id.
///
/// A failure that is not an absent copy (disk, IndexedDB, a store that never
/// answers) throws; [get] is null only when there is no copy.
abstract interface class BoxMediaStore {
  /// This platform's store: files on native, IndexedDB on the web (where the
  /// copy is device-local like the rest of the PWA's history, D9).
  factory BoxMediaStore.device() => impl.deviceBoxMediaStore();

  Future<void> put(int userId, Uint8List id, Uint8List ciphertext);

  Future<Uint8List?> get(int userId, Uint8List id);

  /// Whether a copy of [id] is kept, without reading it: the restore path
  /// asks this for every attachment row it brings back.
  Future<bool> has(int userId, Uint8List id);

  Future<void> delete(int userId, Uint8List id);
}

/// The one spelling of a media id in a store key or file name: the box's own
/// (unpadded base64url, filesystem-safe). Throws unless [id] is 32 bytes.
String boxMediaIdName(Uint8List id) {
  if (id.length != kBoxMediaIdBytes) {
    throw ArgumentError.value(
      id.length,
      'id',
      'must be $kBoxMediaIdBytes bytes',
    );
  }
  return boxB64(id);
}

/// In memory, for tests.
class MemoryBoxMediaStore implements BoxMediaStore {
  final Map<String, Uint8List> _copies = {};

  String _key(int userId, Uint8List id) => '$userId:${boxMediaIdName(id)}';

  @override
  Future<void> put(int userId, Uint8List id, Uint8List ciphertext) async {
    _copies[_key(userId, id)] = Uint8List.fromList(ciphertext);
  }

  @override
  Future<Uint8List?> get(int userId, Uint8List id) async =>
      _copies[_key(userId, id)];

  @override
  Future<bool> has(int userId, Uint8List id) async =>
      _copies.containsKey(_key(userId, id));

  @override
  Future<void> delete(int userId, Uint8List id) async {
    _copies.remove(_key(userId, id));
  }
}
