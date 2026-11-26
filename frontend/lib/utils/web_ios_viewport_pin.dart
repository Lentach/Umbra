import 'web_ios_viewport_pin_stub.dart'
    if (dart.library.js_interop) 'web_ios_viewport_pin_web.dart' as impl;

/// Scoped iOS-WebKit composer viewport pin. Active ONLY while the composer is
/// focused and fully reverted on blur — NOT the banned always-on global
/// scroll-lock. While active it pins `<body>`/`<flutter-view>` to the visual
/// viewport (clip + counter the OS pan) so the keyboard-shrunk layout has no
/// overflow for iOS to scroll/pan to. No-op off iOS WebKit.
void setIOSComposerViewportPin(bool active) =>
    impl.setIOSComposerViewportPin(active);
