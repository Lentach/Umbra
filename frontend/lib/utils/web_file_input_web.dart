import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:web/web.dart' as web;

import 'web_file_input.dart' show WebPickedFile;

bool get webAnchoredFileInputSupported => true;

/// See the facade doc in web_file_input.dart for the full rationale.
///
/// Contract, each clause load-bearing:
/// - The input is RENDERED (fixed-position container at [anchorRect],
///   opacity ~0, pointer-events none) so Safari has a real source rect to
///   anchor its file popover to. `display:none` or a detached node reproduces
///   the orb/black-flash popover morph.
/// - `.click()` fires synchronously in the caller's gesture stack: no await
///   before it, or Safari silently blocks the dialog (08-19 §3.5).
/// - The element stays attached until change/cancel resolves, then is removed.
/// - Focus is never touched: the composer's FocusNode state is none of this
///   function's business.
Future<List<WebPickedFile>?> pickFilesViaAnchoredInput({
  required Rect anchorRect,
  required String accept,
  String? capture,
  bool multiple = false,
}) {
  final completer = Completer<List<WebPickedFile>?>();

  // A previous invocation whose dialog was dismissed by an engine without
  // the 'cancel' event leaves its container behind (its Future never
  // resolves). Sweep it here so containers never accumulate.
  web.document.getElementById('fp-anchored-file-input')?.remove();

  final container = web.document.createElement('div') as web.HTMLElement;
  container.id = 'fp-anchored-file-input';
  final cs = container.style;
  cs.position = 'fixed';
  cs.left = '${anchorRect.left}px';
  cs.top = '${anchorRect.top}px';
  cs.width = '${anchorRect.width}px';
  cs.height = '${anchorRect.height}px';
  // Invisible in practice but still rendered: Safari refuses to anchor to
  // fully transparent/undisplayed nodes in some versions — 1% is repaint-safe.
  cs.opacity = '0.01';
  cs.pointerEvents = 'none';
  cs.overflow = 'hidden';
  cs.zIndex = '0';

  final input = web.document.createElement('input') as web.HTMLInputElement;
  input.type = 'file';
  input.accept = accept;
  if (capture != null) input.setAttribute('capture', capture);
  input.multiple = multiple;
  final istyle = input.style;
  istyle.width = '100%';
  istyle.height = '100%';
  istyle.opacity = '0.01';
  istyle.pointerEvents = 'none';

  container.append(input);
  web.document.body!.append(container);

  JSFunction? changeListener;
  JSFunction? cancelListener;

  void cleanup() {
    if (changeListener != null) {
      input.removeEventListener('change', changeListener);
    }
    if (cancelListener != null) {
      input.removeEventListener('cancel', cancelListener);
    }
    container.remove();
  }

  void resolve(List<WebPickedFile>? value) {
    if (completer.isCompleted) return;
    cleanup();
    completer.complete(value);
  }

  changeListener = ((web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      resolve(null);
      return;
    }
    // Only the File handles are kept: each one is read when its turn to send
    // comes, so ten picked photos never sit in RAM together. A File stays
    // readable after its input leaves the DOM.
    resolve([
      for (var i = 0; i < files.length; i++)
        if (files.item(i) case final file?)
          WebPickedFile(name: file.name, readBytes: () => _readFile(file)),
    ]);
  }).toJS;

  // 'cancel' (Chrome 113+ / Safari 16.4+, all supported targets) is the ONLY
  // cancellation signal — deliberately NO window-focus timeout fallback. A
  // full-screen picker activity (camera, Files) can FREEZE the page
  // (observed on the emulator 2026-08-21: Chrome then cancels the pending
  // chooser outright); on a thaw where the chooser survives, the flushed
  // `focus` precedes the `change` carrying the file by an unbounded gap, so
  // any focus-based timer would resolve null and destroy a real pick. An
  // ancient engine without 'cancel' leaks one unresolved Future per dismissed
  // dialog and holds the composer's native-picker span until its safety cap
  // (composer_keyboard_signals.dart) force-clears it; the sweep above
  // reclaims the DOM node.
  cancelListener = ((web.Event _) => resolve(null)).toJS;

  input.addEventListener('change', changeListener);
  input.addEventListener('cancel', cancelListener);

  // Same-gesture: nothing above awaited, so this click carries the user tap.
  input.click();

  return completer.future;
}

Future<Uint8List?> _readFile(web.File file) async {
  try {
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } on Object {
    return null;
  }
}
