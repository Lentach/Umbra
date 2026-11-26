import 'dart:async';

import 'tab_visibility_stub.dart'
    if (dart.library.js_interop) 'tab_visibility_web.dart' as tab_visibility_impl;

/// Registers [onChanged] for tab visibility (web only). Returns subscription or null.
StreamSubscription<dynamic>? registerTabVisibilityListener(
  void Function(bool isVisible) onChanged,
) {
  return tab_visibility_impl.registerTabVisibilityListener(onChanged);
}
