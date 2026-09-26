import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'box_media_store.dart';

/// Deleted by name on an in-app wipe (`origin_storage_wipe_web.dart`).
const String _dbName = 'umbra-box-media';
const String _storeName = 'media';

/// Bounded, so a hung IndexedDB fails the call instead of stalling the
/// download queue forever. A 20 MiB write gets the longer wait.
const Duration _openWait = Duration(seconds: 5);
const Duration _txWait = Duration(seconds: 30);

BoxMediaStore deviceBoxMediaStore() => const _IdbBoxMediaStore();

/// Web: one IndexedDB record per copy, key `<userId>:<id>`. Each call opens
/// and closes its own connection, so a wipe's `deleteDatabase` is never
/// blocked by a connection this store left open.
class _IdbBoxMediaStore implements BoxMediaStore {
  const _IdbBoxMediaStore();

  static String _key(int userId, Uint8List id) =>
      '$userId:${boxMediaIdName(id)}';

  @override
  Future<void> put(int userId, Uint8List id, Uint8List ciphertext) async {
    final key = _key(userId, id);
    // A structured clone of a view stores its WHOLE buffer: an unframed
    // ciphertext is a view into its 32 MiB rung.
    final tight =
        ciphertext.offsetInBytes == 0 &&
            ciphertext.lengthInBytes == ciphertext.buffer.lengthInBytes
        ? ciphertext
        : Uint8List.fromList(ciphertext);
    await _run('readwrite', (s) => s.put(tight.toJS, key.toJS));
  }

  @override
  Future<Uint8List?> get(int userId, Uint8List id) async {
    final key = _key(userId, id);
    final result = await _run('readonly', (s) => s.get(key.toJS));
    if (result == null || !result.isA<JSUint8Array>()) return null;
    return (result as JSUint8Array).toDart;
  }

  @override
  Future<bool> has(int userId, Uint8List id) async {
    final key = _key(userId, id);
    final result = await _run('readonly', (s) => s.count(key.toJS));
    return result.isA<JSNumber>() && (result! as JSNumber).toDartInt > 0;
  }

  @override
  Future<void> delete(int userId, Uint8List id) async {
    final key = _key(userId, id);
    await _run('readwrite', (s) => s.delete(key.toJS));
  }
}

/// Runs [op] in one transaction and answers its request's result once the
/// transaction COMMITTED (a request's success alone is not durable).
Future<JSAny?> _run(
  String mode,
  web.IDBRequest Function(web.IDBObjectStore store) op,
) async {
  final db = await _openDb();
  try {
    final done = Completer<JSAny?>();
    final tx = db.transaction(_storeName.toJS, mode);
    final request = op(tx.objectStore(_storeName));
    void fail(web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('box media store: transaction failed'));
      }
    }

    tx
      ..oncomplete = ((web.Event _) {
        if (!done.isCompleted) done.complete(request.result);
      }).toJS
      ..onerror = fail.toJS
      ..onabort = fail.toJS;
    return await done.future.timeout(_txWait);
  } finally {
    db.close();
  }
}

Future<web.IDBDatabase> _openDb() {
  final completer = Completer<web.IDBDatabase>();
  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }

  final timer = Timer(
    _openWait,
    () => fail(TimeoutException('box media store: open', _openWait)),
  );
  try {
    final request = web.window.indexedDB.open(_dbName, 1);
    request
      ..onupgradeneeded = ((web.Event _) {
        final db = request.result! as web.IDBDatabase;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      }).toJS
      ..onsuccess = ((web.Event _) {
        timer.cancel();
        final db = request.result! as web.IDBDatabase;
        // Timed out meanwhile: nobody will close it, so close it now.
        if (completer.isCompleted) {
          db.close();
          return;
        }
        // Another tab wiping the origin: step aside for its deleteDatabase.
        db.onversionchange = ((web.Event _) => db.close()).toJS;
        completer.complete(db);
      }).toJS
      ..onblocked = ((web.Event _) {
        fail(StateError('box media store: open blocked'));
      }).toJS
      ..onerror = ((web.Event _) {
        timer.cancel();
        fail(StateError('box media store: open failed'));
      }).toJS;
  } on Object catch (e) {
    timer.cancel();
    fail(e);
  }
  return completer.future;
}
