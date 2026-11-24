// Amendment (lxxiv) clauses 1-2 — a web PRIMARY is asked to be INSTALLED.
//
// Clause 1: the not-enrolled branch offers "enable linking" on web ONLY when
// the app runs installed (standalone display mode); a plain browser tab gets
// an install instruction instead, because a tab's origin storage is the first
// thing a cache sweep takes and a wiped primary's only exit is the §6.2
// delay. Enabling on web is confirmed by a one-paragraph warning dialog; the
// confirm then routes to the MANDATORY (lxxviii) phrase screen, and only a
// phrase that landed a sealed backup lets the enrolment run at all.
// Clause 2: an already-enrolled web primary in a plain tab is nudged (one
// line, informational) above the "link a device" action.
//
// WEB DETECTION SEAM: `flutter test` runs the VM build (`kIsWeb == false`),
// so these tests reach the web branches through
// `debugInstalledDisplayModeOverride` (utils/web_display_mode.dart) — a
// NON-NULL override means "web" (`isWebPlatformForInstallRules`), its value
// is the installed/tab answer (`isInstalledDisplayMode`), and `null` (the
// tearDown reset) is native, where behaviour is unchanged.
//
// ENROLMENT ORDER ((lxxviii) clause 4): "enable" = mintDak (pure keygen +
// armed persist, no wire) → RecoveryKeyScreen → `enableLinking` ONLY on a
// `true` pop. The screen's EncryptionService is never initialized here, so
// the phrase step can never pop true — which is exactly what makes the abort
// path (F9) observable: the account stays notEnrolled with no enroll error.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/devices_screen.dart';
import 'package:fireplace/screens/recovery_key_screen.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/web_display_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/encryption_fakes.dart';

class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  int? get currentUserId => 7;

  /// The screen's own controller, captured so a test can put it into a
  /// not-enrolled/enrolled state without a wire.
  LinkCeremonyController? sink;

  @override
  void registerProvisioningSink(ProvisioningEventSink sink) {
    this.sink = sink as LinkCeremonyController;
    super.registerProvisioningSink(sink);
  }
}

_FakeConnectionProvider _connection = _FakeConnectionProvider();

Widget _host() {
  _connection = _FakeConnectionProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<ConnectionProvider>.value(value: _connection),
      ChangeNotifierProvider<EncryptionProvider>.value(
        value: FakeEncryptionProvider(),
      ),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const DevicesScreen(),
    ),
  );
}

const _enrolledList = DeviceList(
  userId: 7,
  version: 3,
  devices: [
    DeviceListEntry(deviceId: 1, platform: 'web', addedAtMs: 1000),
    DeviceListEntry(deviceId: 6, platform: 'android', addedAtMs: 2000),
  ],
);

Future<LinkCeremonyController> _pumpNotEnrolled(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
  final controller = _connection.sink!;
  controller.listState = DeviceListState.notEnrolled;
  controller.notifyListeners();
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _pumpEnrolledPrimary(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
  final controller = _connection.sink!;
  controller.listState = DeviceListState.enrolled;
  controller.verifiedList = _enrolledList;
  controller.holdsDak = true;
  controller.notifyListeners();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => debugInstalledDisplayModeOverride = null);

  group('clause 1: not enrolled', () {
    testWidgets('a plain browser tab gets the install instruction, no button', (
      tester,
    ) async {
      debugInstalledDisplayModeOverride = false;
      await _pumpNotEnrolled(tester);

      expect(find.byKey(const Key('devices-install-first')), findsOneWidget);
      expect(find.byKey(const Key('devices-enable-linking')), findsNothing);
    });

    testWidgets('installed web: the button, and confirm routes to the '
        'MANDATORY phrase screen before enrolling', (tester) async {
      debugInstalledDisplayModeOverride = true;
      final controller = await _pumpNotEnrolled(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.byKey(const Key('devices-install-first')), findsNothing);
      await tester.tap(find.byKey(const Key('devices-enable-linking')));
      await tester.pumpAndSettle();

      // The one-paragraph warning, not an immediate enroll, and it now names
      // the phrase as mandatory ((lxxviii) clause 4).
      expect(find.text(l10n.devicesEnableLinkingWebWarningTitle), findsOneWidget);
      expect(
        find.textContaining(l10n.recoveryKeyRequiredForLinking),
        findsOneWidget,
      );
      expect(find.byKey(const Key('devices-enroll-error')), findsNothing);

      await tester.tap(find.byKey(const Key('devices-enable-linking-confirm')));
      await tester.pumpAndSettle();

      // mintDak ran (pure keygen + armed persist, no server call) and the
      // phrase screen is on top. Nothing is enrolled yet: `enableLinking`
      // waits for the screen to pop `true`.
      expect(find.byType(RecoveryKeyScreen), findsOneWidget);
      expect(find.byKey(const Key('devices-enroll-error')), findsNothing);
      expect(controller.listState, DeviceListState.notEnrolled);
    });

    testWidgets('installed web: cancel enables nothing', (tester) async {
      debugInstalledDisplayModeOverride = true;
      await _pumpNotEnrolled(tester);

      await tester.tap(find.byKey(const Key('devices-enable-linking')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(const DefaultMaterialLocalizations().cancelButtonLabel),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('devices-enable-linking-confirm')), findsNothing);
      expect(find.byKey(const Key('devices-enroll-error')), findsNothing);
    });

    testWidgets('native: no dialog, straight to the phrase screen', (
      tester,
    ) async {
      // Override left null: the native path, which skips only the (lxxiv)
      // install warning — the (lxxviii) phrase step is NOT platform-gated.
      final controller = await _pumpNotEnrolled(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      await tester.tap(find.byKey(const Key('devices-enable-linking')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.devicesEnableLinkingWebWarningTitle), findsNothing);
      expect(find.byType(RecoveryKeyScreen), findsOneWidget);
      expect(find.byKey(const Key('devices-enroll-error')), findsNothing);
      expect(controller.listState, DeviceListState.notEnrolled);
    });

    testWidgets('F9: backing out of the phrase screen enrolls NOTHING', (
      tester,
    ) async {
      debugInstalledDisplayModeOverride = true;
      final controller = await _pumpNotEnrolled(tester);

      await tester.tap(find.byKey(const Key('devices-enable-linking')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-enable-linking-confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyScreen), findsOneWidget);

      // A plain route push: back returns to the devices screen, and the
      // abort must leave the account un-enrolled. The minted DAK merely waits
      // in the keystore for the next attempt (mintDak is idempotent).
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.byType(RecoveryKeyScreen), findsNothing);
      expect(find.byType(DevicesScreen), findsOneWidget);
      expect(controller.listState, DeviceListState.notEnrolled);
      expect(find.byKey(const Key('devices-enable-linking')), findsOneWidget);
      expect(find.byKey(const Key('devices-enroll-error')), findsNothing);
    });
  });

  group('clause 2: enrolled web primary', () {
    testWidgets('a plain tab is nudged to install, above the link action', (
      tester,
    ) async {
      debugInstalledDisplayModeOverride = false;
      await _pumpEnrolledPrimary(tester);

      expect(find.byKey(const Key('devices-install-nudge')), findsOneWidget);
      expect(find.byKey(const Key('devices-link-a-device')), findsOneWidget);
      final nudge = tester.getTopLeft(
        find.byKey(const Key('devices-install-nudge')),
      );
      final button = tester.getTopLeft(
        find.byKey(const Key('devices-link-a-device')),
      );
      expect(nudge.dy, lessThan(button.dy));
    });

    testWidgets('installed: no nudge', (tester) async {
      debugInstalledDisplayModeOverride = true;
      await _pumpEnrolledPrimary(tester);

      expect(find.byKey(const Key('devices-install-nudge')), findsNothing);
      expect(find.byKey(const Key('devices-link-a-device')), findsOneWidget);
    });
  });
}
