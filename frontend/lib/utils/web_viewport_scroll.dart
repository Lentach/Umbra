import 'web_viewport_scroll_stub.dart'
    if (dart.library.js_interop) 'web_viewport_scroll_web.dart' as impl;

/// Clears accidental host document scroll (web only). Safe no-op elsewhere.
void resetWebDocumentScroll() => impl.resetWebDocumentScroll();
