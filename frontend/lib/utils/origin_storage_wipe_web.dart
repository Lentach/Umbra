import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: destroy every store in this origin's bucket.
///
/// This exists because the obvious user move — "remove the installed PWA and
/// reinstall it" — does NOT reliably clear origin storage. web.dev states it
/// outright ("Deleting the icon may not clear the storage that a PWA is
/// using"), and the W3C declined a manifest uninstall event
/// (https://github.com/w3c/manifest/issues/1201), so a reinstalled app can
/// come back with the old `localStorage` — including the passcode flag. An
/// in-app wipe is therefore the only reset that actually resets.
///
/// Covers all three stores the boot-marker forensics track
/// (`utils/boot_markers_web.dart`): localStorage (SharedPreferences, the
/// Signal `sig_` namespace, the sealed content KV, the JWT), IndexedDB and
/// CacheStorage. The service-worker REGISTRATION is deliberately left alone:
/// it holds no user data, and unregistering it while offline would leave the
/// user unable to load the app at all after the reload.
///
/// Every arm is isolated: a browser that refuses one store must not stop the
/// others, because a half-erased origin is the worst outcome for someone who
/// just typed a confirmation to destroy their data.
Future<List<String>> wipeOriginStorage() async {
  final failed = <String>[];

  try {
    web.window.localStorage.clear();
  } catch (_) {
    failed.add('localStorage');
  }

  try {
    web.window.sessionStorage.clear();
  } catch (_) {
    failed.add('sessionStorage');
  }

  try {
    await _deleteAllIndexedDbs();
  } catch (_) {
    failed.add('indexedDB');
  }

  try {
    await _deleteAllCaches();
  } catch (_) {
    failed.add('cacheStorage');
  }

  return failed;
}

/// `indexedDB.databases()` is unavailable on Safari/Firefox, so the known
/// names are always deleted too — an enumeration gap must not leave a
/// database behind. Verified against a live origin on 2026-09-04: the app
/// creates `fireplace-boot-marker`, `fireplace-deep-link` and
/// `fireplace-push`; `umbra-box-media` (box attachment copies,
/// `services/box/box_media_store_web.dart`) came with PR3.1.
const List<String> _knownIdbNames = <String>[
  'fireplace-boot-marker',
  'fireplace-deep-link',
  'fireplace-push',
  'umbra-box-media',
];

Future<void> _deleteAllIndexedDbs() async {
  final names = <String>{..._knownIdbNames};
  try {
    final infos = await web.window.indexedDB.databases().toDart;
    for (final info in infos.toDart) {
      final name = info.name;
      if (name.isNotEmpty) names.add(name);
    }
  } catch (_) {
    // Enumeration unsupported or blocked; the known names still go.
  }

  for (final name in names) {
    try {
      await _deleteDb(name);
    } catch (_) {
      // A database held open by another tab blocks forever; skip it rather
      // than hanging the erase.
    }
  }
}

/// `deleteDatabase` fires `blocked` (never `success`) while another tab holds
/// the database open, so the wait is bounded instead of indefinite.
Future<void> _deleteDb(String name) {
  final completer = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase(name);
  void finish() {
    if (!completer.isCompleted) completer.complete();
  }

  request.onsuccess = ((web.Event _) => finish()).toJS;
  request.onerror = ((web.Event _) => finish()).toJS;
  request.onblocked = ((web.Event _) => finish()).toJS;
  return completer.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );
}

Future<void> _deleteAllCaches() async {
  final keys = await web.window.caches.keys().toDart;
  for (final key in keys.toDart) {
    await web.window.caches.delete(key.toDart).toDart;
  }
}
