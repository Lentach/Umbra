import 'privacy_curtain_stub.dart'
    if (dart.library.js_interop) 'privacy_curtain_web.dart' as impl;

/// The DOM privacy curtain (`#fp-curtain` in `web/index.html`), web only.
///
/// Why a DOM element and not a Flutter widget: on wake the browser re-shows
/// the last painted frame before any code runs, and a real screen-off leaves
/// 80–400 ms between `blur` and the page going hidden (measured on a Pixel_7,
/// 2026-09-06) — not enough for a Flutter frame. The DOM curtain is shown by
/// the page's own `blur`/`visibilitychange` handler, synchronously, while
/// armed; Dart only decides when it is lifted, because lifting it before the
/// return verdict would flash the chat for the frame before a lock lands.
///
/// No-ops off web.
void armDomCurtain(bool enabled) => impl.armDomCurtain(enabled);

void showDomCurtain() => impl.showDomCurtain();

void hideDomCurtain() => impl.hideDomCurtain();
