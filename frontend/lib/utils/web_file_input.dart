import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'web_file_input_stub.dart'
    if (dart.library.html) 'web_file_input_web.dart' as impl;

/// A file picked through the anchored web `<input type=file>` door. Its bytes
/// are read on demand, so a multi-file pick holds one file in RAM at a time
/// instead of all of them at once.
class WebPickedFile {
  const WebPickedFile({required this.name, required this.readBytes});

  final String name;

  /// Null when the browser could not read the file.
  final Future<Uint8List?> Function() readBytes;
}

/// True only on web, where [pickFilesViaAnchoredInput] is implemented.
bool get webAnchoredFileInputSupported => impl.webAnchoredFileInputSupported;

/// Opens the browser file dialog from a REAL, RENDERED `<input type=file>`
/// positioned at [anchorRect] (logical px == CSS px on Flutter web), and keeps
/// that element ATTACHED to the DOM until the dialog resolves.
///
/// Why this exists instead of `FilePicker.pickFiles` (file_picker 11.0.2 web):
/// file_picker styles its input `display:none` and REMOVES it from the DOM in
/// the same synchronous call stack as `.click()`. iOS Safari anchors its
/// Photo Library / Take Photo or Video / Choose File popover to the input's
/// rect — with a detached, unrendered anchor it animates the popover from a
/// degenerate source rect: the dark morphing blob + full-screen flash the
/// owner reported (2026-08-21), device-corroborated by the 08-19 static-page
/// probe where a real visible input got a clean menu anchored AT the control.
///
/// The DOM setup and `.click()` happen synchronously before this function's
/// first await, so the browser still sees the originating user gesture
/// (deferred clicks are silently blocked by Safari — proven 08-19 §3.5).
///
/// [accept] is the raw accept attribute value; [capture] optionally sets the
/// capture attribute (Android camera door); [multiple] lets the user select
/// several files. Returns the files in the order the browser lists them, or
/// null on cancel.
Future<List<WebPickedFile>?> pickFilesViaAnchoredInput({
  required Rect anchorRect,
  required String accept,
  String? capture,
  bool multiple = false,
}) => impl.pickFilesViaAnchoredInput(
  anchorRect: anchorRect,
  accept: accept,
  capture: capture,
  multiple: multiple,
);
