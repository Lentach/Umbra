import 'dart:typed_data';

import 'image_clipboard_stub.dart'
    if (dart.library.js_interop) 'image_clipboard_web.dart'
    as impl;

/// Whether the current platform can copy an image to the system clipboard.
/// Only the web build supports it (browser Async Clipboard API); Flutter has no
/// cross-platform image-clipboard on mobile/desktop, so this is false there.
bool get canCopyImageToClipboard => impl.canCopyImageToClipboard;

/// Copies raw image [bytes] (of [mimeType]) to the system clipboard.
/// Throws on failure; callers should try/catch and surface a message.
Future<void> copyImageToClipboard(Uint8List bytes, String mimeType) =>
    impl.copyImageToClipboard(bytes, mimeType);
