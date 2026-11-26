import 'dart:typed_data';

import 'composer_paste_stub.dart'
    if (dart.library.js_interop) 'composer_paste_web.dart' as impl;

typedef PastedImageHandler = void Function(
    Uint8List bytes, String mimeType, String filename);
typedef PastedTextHandler = void Function(String text);

/// Installs the single capture-phase `window` `paste` listener (web only;
/// no-op elsewhere). `preventDefault()` fires ONLY when an image is consumed
/// — text-only pastes keep flowing into Flutter's hidden textarea natively.
/// [shouldHandle] is polled per event (composer mounted, not recording).
void installComposerPasteListener({
  required bool Function() shouldHandle,
  required PastedImageHandler onImage,
  required PastedTextHandler onText,
}) =>
    impl.installComposerPasteListener(
      shouldHandle: shouldHandle,
      onImage: onImage,
      onText: onText,
    );

/// Removes the listener and clears handlers (call from State.dispose).
void uninstallComposerPasteListener() => impl.uninstallComposerPasteListener();
