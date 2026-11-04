// Issue #175 — the device-link gate must stay the top surface.
//
// Device-observed 2026-09-13 on the 0.2.41 release APK: logging into an
// ENROLLED account put the user inside a chat full of `[encrypted]` bubbles
// with no hint that the device must be linked. The gate was mounted the whole
// time, underneath. Root cause: `MainShell` stays MOUNTED under `Offstage`
// while gated and `Offstage` still BUILDS, so its pending-notification
// consumer pushed a chat route on the ROOT navigator AFTER the gate verdict —
// and AuthGate's cure fired only on the `gated` edge, which had already passed.
//
// Falsification contract: restore the edge condition (`if (gated &&
// !_previousGated)`) in `main.dart` and test 1 goes RED — the orphan route
// stays on top and DeviceLinkGateScreen is never visible. Test 2 pins the
// carve-out that makes the sweep safe: the ceremony's OWN scanner route
// survives it. Test 3 is the control: an ungated tree is untouched.

import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/main.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/device_link_gate_screen.dart';
import 'package:fireplace/screens/link_scan_screen.dart';
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/device_link_route_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Logged in, never restoring, no network — same shape as the (lxvi) test.
class _StubAuth extends AuthProvider {
  @override
  bool get isLoggedIn => true;

  @override
  bool get isRestoringSession => false;

  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');

  @override
  Future<void> ensureSessionReady() => Completer<void>().future;
}

/// The gate verdict, flipped by hand. `needsDeviceLink` is what AuthGate
/// selects on; everything else stays the real provider's behaviour.
class _ToggleGate extends EncryptionProvider {
  bool _gated = false;

  @override
  bool get needsDeviceLink => _gated;

  void raiseGate() {
    _gated = true;
    notifyListeners();
  }
}

const _orphanKey = Key('route-pushed-over-the-device-link-gate');

Future<void> _pumpApp(
  WidgetTester tester,
  _StubAuth auth,
  _ToggleGate encryption,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(create: (_) => ConversationsProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider<PasscodeProvider>(
          create: (_) => PasscodeProvider(
            store: MemoryPasscodeStore(),
            kdf: FakePasscodeKdf(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Same wiring as FireplaceApp: the guard is what catches a route
        // pushed AFTER the verdict, since a push does not rebuild AuthGate.
        navigatorObservers: [DeviceLinkGateRouteGuard(encryption)],
        home: const AuthGate(),
      ),
    ),
  );
  await tester.pump();
}

/// Both shells animate continuously, so pumpAndSettle never quiesces.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Holds its identity: a keyless install waits behind the honeycomb.
    FlutterSecureStorage.setMockInitialValues({
      'e2e_7_identity_record_v1': '{}',
    });
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a page route pushed AFTER the gate verdict is swept off, so the gate is '
    'what the user sees',
    (tester) async {
      final auth = _StubAuth();
      final encryption = _ToggleGate();
      addTearDown(auth.dispose);
      addTearDown(encryption.dispose);
      await _pumpApp(tester, auth, encryption);

      encryption.raiseGate();
      await _pumpFrames(tester);
      expect(find.byType(DeviceLinkGateScreen), findsOneWidget);

      // The observed shape: something under the still-BUILDING Offstage shell
      // pushes a chat on the root navigator after the verdict has landed.
      unawaited(
        Navigator.of(tester.element(find.byType(DeviceLinkGateScreen))).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(key: _orphanKey, body: SizedBox()),
          ),
        ),
      );
      await _pumpFrames(tester, 30);

      expect(
        find.byKey(_orphanKey),
        findsNothing,
        reason: 'a route pushed over the gate must be swept off',
      );
      expect(find.byType(DeviceLinkGateScreen), findsOneWidget);
    },
  );

  testWidgets("the ceremony's own scanner route survives the sweep", (
    tester,
  ) async {
    final auth = _StubAuth();
    final encryption = _ToggleGate();
    addTearDown(auth.dispose);
    addTearDown(encryption.dispose);
    await _pumpApp(tester, auth, encryption);

    encryption.raiseGate();
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(DeviceLinkGateScreen))).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: kLinkScanRouteName),
          builder: (_) => const Scaffold(key: _orphanKey, body: SizedBox()),
        ),
      ),
    );
    await _pumpFrames(tester, 30);

    expect(
      find.byKey(_orphanKey),
      findsOneWidget,
      reason: 'sweeping the scanner would close the ceremony mid-flow',
    );
  });

  testWidgets('an UNgated logged-in tree keeps its pushed route', (
    tester,
  ) async {
    final auth = _StubAuth();
    final encryption = _ToggleGate();
    addTearDown(auth.dispose);
    addTearDown(encryption.dispose);
    await _pumpApp(tester, auth, encryption);

    unawaited(
      Navigator.of(tester.element(find.byType(MainShell))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: _orphanKey, body: SizedBox()),
        ),
      ),
    );
    await _pumpFrames(tester, 30);

    expect(find.byKey(_orphanKey), findsOneWidget);
    expect(find.byType(DeviceLinkGateScreen), findsNothing);
  });
}
