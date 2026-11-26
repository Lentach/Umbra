import 'package:flutter/widgets.dart' show Color;

import 'web_document_background_stub.dart'
    if (dart.library.js_interop) 'web_document_background_web.dart'
    as impl;

/// CSS `#rrggbb` for [color] (alpha dropped — document backgrounds are
/// opaque). Pure so the VM suite can pin the format.
String webDocumentBackgroundCss(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

/// Paints the browser document (`<html>` + `<body>`) in the app's background
/// color.
///
/// Android PWA keyboard hide resizes the OS window; Chrome exposes the
/// reclaimed strip BEFORE Flutter's canvas has grown to cover it
/// (flutter/flutter #179208 — the old audit's A1 white-void signature,
/// device-reproduced 2026-07-09 with screenshots: the composer sits pinned to
/// the top of the band, i.e. Flutter's layout is already settled and only the
/// canvas is short). The browser default background is white, so the lag reads
/// as a white flash on every keyboard dismiss. We cannot control Chrome's
/// resize timing; painting the document in the theme background makes the
/// strip invisible. Inert CSS only — no layout, scroll, or viewport-meta
/// change (see the banned list in
/// docs/review/ios-composer-keyboard-flash-handoff.md §3).
///
/// `web/index.html` ships the default Hot Stone value (`#F7F4F0`) for first
/// paint; this keeps it in sync when the user switches themes. No-op off web.
void syncWebDocumentBackground(Color color) =>
    impl.syncWebDocumentBackground(color);
