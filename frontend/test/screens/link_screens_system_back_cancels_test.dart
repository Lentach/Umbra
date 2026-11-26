// Amendment (lxvi) clause 3 — every way off a ceremony screen cancels the
// ceremony.
//
// Live QA 2026-09-02: both §5.1 screens cancelled only from their own app-bar
// arrow. The system back (Android gesture/hardware back, browser back) popped
// the route and left the ceremony running — observed as the primary's screen
// reopening in the previous ceremony's `done` state; by the same code a new
// device that backs out mid-SAS leaves a live stage the primary can still
// approve (I1 abort hygiene, skipped on the one exit users take on purpose).
//
// The system back is what `Navigator.maybePop` delivers, so that is what these
// tests drive — NOT the arrow.
//
// Falsification contract: removing either screen's `PopScope` turns its test
// RED (no `cancelProvisioning` on the wire, step left live).

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/link_device_screen.dart';
import 'package:fireplace/screens/link_this_device_screen.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async =>
      throw StateError('not used here');

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) async {}

  @override
  Future<void> discardProvisionedIdentity(int userId) async {}

  @override
  Future<void> settleProvisionedIdentity(int userId) async {}
}

const _homeKey = Key('link-test-home');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<(String, dynamic)> emitted;
  late LinkCeremonyController controller;

  setUp(() {
    emitted = [];
    controller = LinkCeremonyController(
      userId: 42,
      emit: (event, data) => emitted.add((event, data)),
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
    );
  });

  tearDown(() => controller.dispose());

  /// Both screens animate continuously, so pumpAndSettle never quiesces.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// A home route plus the screen under test pushed above it, so a pop has
  /// somewhere to land — exactly the devices-screen shape.
  Future<void> pumpPushed(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            key: _homeKey,
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => screen)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpFrames(tester);
  }

  /// What the platform back button / browser back delivers to the navigator.
  Future<void> systemBack(WidgetTester tester) async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await pumpFrames(tester);
  }

  testWidgets(
    'new-device screen: system back aborts a live stage and tells the server',
    (tester) async {
      await pumpPushed(tester, LinkThisDeviceScreen(controller: controller));
      // The screen opened the stage; the server answers with an id.
      expect(emitted.map((e) => e.$1), contains('openProvisioning'));
      controller.onProvisioningOpened({
        'success': true,
        'provisioningId': 'stage-1',
      });
      await tester.pump();
      expect(controller.newDeviceStep, NewDeviceLinkStep.showCode);

      await systemBack(tester);

      expect(find.byKey(_homeKey), findsOneWidget);
      expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);
      final cancel = emitted.where((e) => e.$1 == 'cancelProvisioning');
      expect(cancel, hasLength(1));
      expect((cancel.single.$2 as Map)['provisioningId'], 'stage-1');
    },
  );

  testWidgets('primary screen: system back resets a live ceremony', (
    tester,
  ) async {
    await pumpPushed(tester, LinkDeviceScreen(controller: controller));
    // Mid-ceremony on the primary side: the SAS is on screen.
    controller.primaryStep = PrimaryLinkStep.showSas;
    controller.primarySas = '123 456';
    controller.notifyListeners();
    await tester.pump();

    await systemBack(tester);

    expect(find.byKey(_homeKey), findsOneWidget);
    // Idle again — reopening the screen shows a fresh code field, not the
    // previous ceremony's state.
    expect(controller.primaryStep, PrimaryLinkStep.idle);
    expect(controller.primarySas, isNull);
  });

  // (lxx) clause 2: `done` pops the route by itself — the exit is no longer
  // the user's back tap. The (lxvi) clause 3 contract this pins is
  // unchanged: that exit is a plain one, resetting the flow and never
  // telling the server "cancelled" about a stage it already consumed.
  testWidgets('primary screen: done exits by itself, as a plain exit', (
    tester,
  ) async {
    await pumpPushed(tester, LinkDeviceScreen(controller: controller));
    controller.primaryStep = PrimaryLinkStep.done;
    controller.notifyListeners();
    await pumpFrames(tester);

    expect(find.byType(LinkDeviceScreen), findsNothing);
    expect(controller.primaryStep, PrimaryLinkStep.idle);
    // A consumed stage is never "cancelled" on the wire.
    expect(emitted.where((e) => e.$1 == 'cancelProvisioning'), isEmpty);
    // Drain the confirmation toast's dismiss timer.
    await tester.pump(const Duration(seconds: 3));
  });
}
