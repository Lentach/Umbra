import 'package:flutter/foundation.dart';

import 'web_display_mode_stub.dart'
    if (dart.library.js_interop) 'web_display_mode_web.dart' as impl;

/// Test seam for the (lxxiv) install rules. `flutter test` runs the VM build
/// (`kIsWeb == false`, the stub always answers "installed"), so widget tests
/// force a shape by setting this: `false` = web browser tab, `true` = web
/// installed. A NON-NULL override also makes [isWebPlatformForInstallRules]
/// answer `true` — the override only exists to simulate web, and this is the
/// only way a VM test can reach the web branches at all. Reset to null in
/// tearDown.
@visibleForTesting
bool? debugInstalledDisplayModeOverride;

/// Whether the app runs "installed" — standalone PWA on web
/// (`matchMedia('(display-mode: standalone)')` OR `navigator.standalone`),
/// always true on native (multi-device amendment (lxxiv) clause 1).
bool isInstalledDisplayMode() =>
    debugInstalledDisplayModeOverride ?? impl.isInstalledDisplayMode();

/// Whether the (lxxiv) web install rules apply: real web, or a test that set
/// [debugInstalledDisplayModeOverride] (see its doc). Android and desktop
/// native are unchanged by (lxxiv) and always answer false here.
bool isWebPlatformForInstallRules() =>
    debugInstalledDisplayModeOverride != null || kIsWeb;
