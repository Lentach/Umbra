import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// IndexedDB shared with the push service worker. Names must match
/// `DEEPLINK_DB` / `DEEPLINK_STORE` / `WAKE_SESSION_KEY` in
/// `web/web-push-sw.js` (the open below is `box_push_nids_web.dart`'s).
const String _dbName = 'fireplace-push';
const String _storeName = 'kv';
const String _sessionKey = 'wake-session';

/// Leaves the worker the one thing it needs to ask the server whether this
/// device was revoked while the app is closed (decision 129, E129a): the
/// refresh token and the API origin, as `{refresh, api}`.
///
/// The worker cannot read localStorage, where the session lives on web, and
/// it holds no key. The token already sits in localStorage in the clear on
/// web (`AuthTokenStore`), so this adds no exposure class — same-origin
/// scripts only, like the nid table (decision 77) — and the worker deletes
/// its copy when it acts on a revocation. The worker also stamps the record
/// (`liveAt`, `attemptAt`) to pace its checks, so an unchanged session is left
/// as it is: a rewrite would reset them.
Future<void> writeWakeSession({
  required String refresh,
  required String api,
}) async {
  final db = await _openDb();
  if (db == null) return;
  final done = Completer<void>();
  try {
    final store = db
        .transaction(_storeName.toJS, 'readwrite')
        .objectStore(_storeName);
    final read = store.get(_sessionKey.toJS);
    read
      ..onsuccess = ((web.Event _) {
        try {
          final held = read.result.dartify();
          if (held is Map && held['refresh'] == refresh && held['api'] == api) {
            done.complete();
            return;
          }
          store.put(
              {'refresh': refresh, 'api': api}.jsify(),
              _sessionKey.toJS,
            )
            ..onsuccess = ((web.Event _) => done.complete()).toJS
            ..onerror = ((web.Event _) => done.complete()).toJS;
        } on Object {
          if (!done.isCompleted) done.complete();
        }
      }).toJS
      ..onerror = ((web.Event _) => done.complete()).toJS;
    await done.future;
  } on Object {
    // Written again by the next token write.
  } finally {
    db.close();
  }
}

/// Removes the record: logout, a session that ended here. Another account
/// must never inherit this one's token.
Future<void> clearWakeSession() async {
  final db = await _openDb();
  if (db == null) return;
  try {
    await _done(
      db
          .transaction(_storeName.toJS, 'readwrite')
          .objectStore(_storeName)
          .delete(_sessionKey.toJS),
    );
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

/// Completes when [request] ends, either way.
Future<void> _done(web.IDBRequest request) {
  final completer = Completer<void>();
  request
    ..onsuccess = ((web.Event _) => completer.complete()).toJS
    ..onerror = ((web.Event _) => completer.complete()).toJS;
  return completer.future;
}
