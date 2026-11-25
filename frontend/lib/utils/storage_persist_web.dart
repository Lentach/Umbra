import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: request persistent storage via the StorageManager API.
/// `persisted()` reports current state; `persist()` requests it.
Future<Map<String, bool>> requestPersistentStorage() async {
  try {
    final storage = web.window.navigator.storage;
    final already = (await storage.persisted().toDart).toDart;
    if (already) return const {'supported': true, 'granted': true};
    final granted = (await storage.persist().toDart).toDart;
    return {'supported': true, 'granted': granted};
  } catch (_) {
    return const {'supported': false, 'granted': false};
  }
}
