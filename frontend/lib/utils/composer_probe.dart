import 'composer_probe_stub.dart'
    if (dart.library.js_interop) 'composer_probe_web.dart' as impl;

/// Compact one-line snapshot of the web layer used by the composer diagnostics
/// log: `active=<tag> vv.off=<n> vv.h=<n> sY=<n> dT=<n>`. Empty off-web.
String composerProbeString() => impl.composerProbeString();
