import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// IndexedDB shared with the push service worker. Names must match
/// `DEEPLINK_DB` / `DEEPLINK_STORE` / `BOX_NIDS_KEY` / `BOX_WAKE_KEY` in
/// `web/web-push-sw.js` (the open below is `pending_deep_link_web.dart`'s).
const String _dbName = 'fireplace-push';
const String _storeName = 'kv';
const String _nidsKey = 'box-nids';
const String _wakeKey = 'box-wake';

/// Replaces the worker's nid → chat table (`{ <nid>: <chat id> }`).
Future<void> writeBoxPushNids(Map<String, int> table) async {
  final db = await _openDb();
  if (db == null) return;
  try {
    await _done(
      db
          .transaction(_storeName.toJS, 'readwrite')
          .objectStore(_storeName)
          .put(table.jsify(), _nidsKey.toJS),
    );
  } finally {
    db.close();
  }
}

/// Removes the table and the worker's wake-up counts: another account must
/// not be shown this one's chats (logout, account switch).
Future<void> clearBoxPushNids() async {
  final db = await _openDb();
  if (db == null) return;
  try {
    final store = db
        .transaction(_storeName.toJS, 'readwrite')
        .objectStore(_storeName);
    await _done(store.delete(_nidsKey.toJS));
    await _done(store.delete(_wakeKey.toJS));
  } on Object {
    // Nothing to remove, or the store is gone: the next write replaces it.
  } finally {
    db.close();
  }
}

Future<web.IDBDatabase?> _openDb() {
  final completer = Completer<web.IDBDatabase?>();
  try {
    final request = web.window.indexedDB.open(_dbName, 1);
    request
      ..onupgradeneeded = ((web.Event _) {
        try {
          final db = request.result as web.IDBDatabase?;
          if (db != null && !db.objectStoreNames.contains(_storeName)) {
            db.createObjectStore(_storeName);
          }
        } on Object {
          // Reported by the open failing.
        }
      }).toJS
      ..onsuccess = ((web.Event _) {
        completer.complete(request.result as web.IDBDatabase?);
      }).toJS
      ..onerror = ((web.Event _) {
        completer.complete(null);
      }).toJS;
  } on Object {
    return Future.value();
  }
  return completer.future;
}

/// Completes when [request] ends, either way (a failed write is retried by
/// the next trigger; a failed delete is retried by the next logout).
Future<void> _done(web.IDBRequest request) {
  final completer = Completer<void>();
  request
    ..onsuccess = ((web.Event _) => completer.complete()).toJS
    ..onerror = ((web.Event _) => completer.complete()).toJS;
  return completer.future;
}
