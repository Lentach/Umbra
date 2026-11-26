import 'package:flutter/material.dart';

import '../providers/encryption_provider.dart';
import '../screens/link_scan_screen.dart' show kLinkScanRouteName;

/// What the device-link gate's route sweep KEEPS on the root navigator.
///
/// Page routes are the only thing that can hide the gate, so they go. Dialogs,
/// sheets and snack routes are NOT page routes and are left alone — the reset
/// ceremony raises its own confirmations from inside the gate. The scanner is
/// a page route the ceremony itself pushes, so it is allowlisted by name.
bool gateKeepsRoute(Route<dynamic> route) =>
    route.isFirst ||
    route is! PageRoute ||
    route.settings.name == kLinkScanRouteName;

/// Keeps the device-link gate the TOP surface while it is up (issue #175).
///
/// The gate is a `Stack` child in `AuthGate`, not a route, so anything pushed
/// on the root navigator covers it completely. `AuthGate` pops what is already
/// on the stack when the verdict lands, but that is a one-shot: it cannot see
/// a route pushed LATER, and pushing a route does not rebuild `AuthGate`.
///
/// Device-observed 2026-09-13 on the 0.2.41 release APK: `MainShell` stays
/// MOUNTED under `Offstage` while gated, `Offstage` still BUILDS, and its
/// pending-notification consumer pushed a chat over the gate. The user got a
/// keyless `[encrypted]` shell with no way forward and no hint that the device
/// needed linking.
///
/// Removal is deferred to a post-frame callback: `didPush` fires mid-push, and
/// tearing the route down inside that call races the transition.
///
/// The guard also owns the edge sweep: when the verdict lands, every page route
/// ALREADY on the stack goes. It walks its own route list instead of using
/// `popUntil(gateKeepsRoute)`, which stops at the first kept route from the
/// top — a dialog open over a pushed page left that page standing under it
/// (A2-DEV-10).
class DeviceLinkGateRouteGuard extends NavigatorObserver {
  DeviceLinkGateRouteGuard(this._encryption) {
    _wasGated = _gated;
    _encryption.addListener(_onEncryptionChanged);
  }

  final EncryptionProvider _encryption;
  final List<Route<dynamic>> _routes = [];
  bool _wasGated = false;

  bool get _gated =>
      _encryption.needsDeviceLink || _encryption.identityCheckUnavailable;

  void _onEncryptionChanged() {
    final gated = _gated;
    final rising = gated && !_wasGated;
    _wasGated = gated;
    if (!rising) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_gated) return;
      // Bottom to top. Once a page goes, everything pushed above it belongs
      // to that page (its dialogs, sheets, pages it opened) and goes too: a
      // dialog kept over the gate would hold a future that runs against the
      // page's disposed screen. Only the ceremony's scanner is spared.
      var sweptBelow = false;
      for (final route in List.of(_routes)) {
        if (!route.isActive || route.isFirst) continue;
        final isScanner = route.settings.name == kLinkScanRouteName;
        if (!gateKeepsRoute(route) || (sweptBelow && !isScanner)) {
          sweptBelow = true;
          navigator?.removeRoute(route);
        }
      }
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    if (!_gated || gateKeepsRoute(route)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check: the verdict can clear between the push and the frame, and
      // the route may already be gone.
      if (!_gated || !route.isActive) return;
      navigator?.removeRoute(route);
    });
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (at >= 0 && newRoute != null) {
      _routes[at] = newRoute;
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
  }
}
