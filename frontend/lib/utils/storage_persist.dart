// Keyed on dart.library.js_interop, NOT dart.library.html: under
// `flutter build web --wasm` the latter is false and the persistent-storage
// request would never be made at all — one iOS eviction away from unrecoverable
// Signal key loss. The web implementation is package:web + dart:js_interop.
import 'storage_persist_stub.dart'
    if (dart.library.js_interop) 'storage_persist_web.dart' as impl;

/// Asks the browser to make this origin's storage persistent (exempt from
/// automatic eviction) and reports the resulting state. No-op off web.
///
/// Returns `{supported, granted}`. On an installed PWA with engagement the
/// browser usually grants this, which stops OS-driven eviction of the Signal
/// keystore in `localStorage`. It does NOT protect against the user manually
/// clearing site data.
Future<Map<String, bool>> requestPersistentStorage() =>
    impl.requestPersistentStorage();
