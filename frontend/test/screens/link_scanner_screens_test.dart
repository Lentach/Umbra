// Amendment (lxxvii) clause 3, falsification F6 — the scanner RESULT is fed
// to the controller.
//
// Both ceremony screens carry a `link-scan` door that pushes the full-screen
// `LinkScanScreen` with an injected scanner (tests need no camera). The pin on each side: firing the fake scanner's
// `onCode` advances the ceremony (an emit proves the controller consumed the
// scan), NOT firing it leaves the manual field empty and the wire silent —
// a scanner whose result never reaches the controller fails both halves.
// `onUnsupported` falls back to the typed field plus the unsupported notice.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/link_device_screen.dart';
import 'package:fireplace/screens/link_this_device_screen.dart';
import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _provisioningId = '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f';

final String _nCode = LinkOobCode(
  provisioningId: _provisioningId,
  ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
  platform: 'web',
).encode();

final String _pCode = LinkOobCode(
  provisioningId: _provisioningId,
  ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
  platform: 'web',
  role: LinkRole.primary,
).encode();

class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;
  @override
  Future<dynamic> ownIdentityKeyPair() async => throw StateError('unused');
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

class _StubDakStore extends DakStore {
  _StubDakStore(this._record);
  final DakRecord? _record;
  @override
  Future<DakRecord?> read({required int userId}) async => _record;
}

/// The injected scanner: two buttons instead of a camera.
class _FakeScanner extends StatelessWidget {
  const _FakeScanner({required this.onCode, this.onUnsupported, this.code});
  final void Function(String) onCode;
  final VoidCallback? onUnsupported;
  final String? code;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        key: const Key('fake-scan-hit'),
        onPressed: () => onCode(code!),
        child: const Text('scan'),
      ),
      TextButton(
        key: const Key('fake-scan-unsupported'),
        onPressed: onUnsupported,
        child: const Text('unsupported'),
      ),
    ],
  );
}

Widget _screenHost(Widget screen) => MaterialApp(
  theme: RpgTheme.themeDataDarkGray,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: screen,
);

Widget _bodyHost(Widget child) => MaterialApp(
  theme: RpgTheme.themeDataDarkGray,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  late List<(String, dynamic)> emitted;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    emitted = [];
  });

  int count(String event) => emitted.where((e) => e.$1 == event).length;

  group('LinkDeviceScreen (primary, flipped shape)', () {
    LinkCeremonyController primaryController() {
      final engine = DeviceAuthorityEngine();
      engine.mintEnrollment(
        userId: 7,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
      final dak = engine.exportDakForPersistence();
      return LinkCeremonyController(
        userId: 7,
        emit: (event, data) => emitted.add((event, data)),
        identity: _NoIdentity(),
        adoptSession: (_) async {},
        reconnect: (_) async {},
        engine: engine,
        dakStore: _StubDakStore(
          DakRecord(
            userId: 7,
            dakPub: dak['dakPub']!,
            dakPriv: dak['dakPriv']!,
            createdAtMs: 1755600000000,
          ),
        ),
      );
    }

    Future<LinkCeremonyController> pumpToShowCode(
      WidgetTester tester, {
      String? scanResult,
    }) async {
      final controller = primaryController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _screenHost(
          LinkDeviceScreen(
            controller: controller,
            scannerBuilder: ({required onCode, onUnsupported}) => _FakeScanner(
              onCode: onCode,
              onUnsupported: onUnsupported,
              code: scanResult,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.primaryStep, PrimaryLinkStep.opening);
      controller.onProvisioningOpened({
        'success': true,
        'provisioningId': _provisioningId,
      });
      await tester.pump();
      await tester.pump();
      expect(controller.primaryStep, PrimaryLinkStep.showCode);
      return controller;
    }

    testWidgets('mount opens as primary and shows the p code', (tester) async {
      await pumpToShowCode(tester);
      expect(count('openProvisioning'), 1);
      expect(emitted.single.$2, {'role': 'primary'});
      final codeText = tester.widget<SelectableText>(
        find.byKey(const Key('link-primary-oob-code')),
      );
      expect(codeText.data, endsWith('.p'));
      expect(find.byKey(const Key('link-scan')), findsOneWidget);
    });

    testWidgets('scanner result fed to onCode starts the classic flow', (
      tester,
    ) async {
      final controller = await pumpToShowCode(tester, scanResult: _nCode);
      await tester.ensureVisible(find.byKey(const Key('link-scan')));
      await tester.tap(find.byKey(const Key('link-scan')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('fake-scan-hit')));
      await tester.tap(find.byKey(const Key('fake-scan-hit')));
      // The ceremony's waiting step animates, so settle the route pop by
      // hand: post-frame pop + the transition.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The scan reached the controller: the hello left the device.
      expect(controller.primaryStep, PrimaryLinkStep.awaitingHelloAck);
      expect(count('provisioningHello'), 1);
    });

    testWidgets('scanner never fired: manual field stays empty, wire silent', (
      tester,
    ) async {
      final controller = await pumpToShowCode(tester, scanResult: _nCode);
      await tester.ensureVisible(find.byKey(const Key('link-enter-manually')));
      await tester.tap(find.byKey(const Key('link-enter-manually')));
      await tester.pump();
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const Key('link-code-field')),
      );
      expect(field.controller!.text, isEmpty);
      expect(controller.primaryStep, PrimaryLinkStep.showCode);
      expect(count('provisioningHello'), 0);
    });

    testWidgets('unsupported scanner falls back to the typed field', (
      tester,
    ) async {
      await pumpToShowCode(tester);
      await tester.ensureVisible(find.byKey(const Key('link-scan')));
      await tester.tap(find.byKey(const Key('link-scan')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('fake-scan-unsupported')));
      await tester.tap(find.byKey(const Key('fake-scan-unsupported')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('link-scan-unsupported')), findsOneWidget);
      expect(find.byKey(const Key('link-code-field')), findsOneWidget);
    });
  });

  group('LinkThisDeviceBody (new device)', () {
    Future<LinkCeremonyController> pumpBody(
      WidgetTester tester, {
      String? scanResult,
    }) async {
      final controller = LinkCeremonyController(
        userId: 7,
        emit: (event, data) => emitted.add((event, data)),
        identity: _NoIdentity(),
        adoptSession: (_) async {},
        reconnect: (_) async {},
        dakStore: _StubDakStore(null),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _bodyHost(
          LinkThisDeviceBody(
            controller: controller,
            scannerBuilder: ({required onCode, onUnsupported}) => _FakeScanner(
              onCode: onCode,
              onUnsupported: onUnsupported,
              code: scanResult,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      controller.onProvisioningOpened({
        'success': true,
        'provisioningId': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      });
      await tester.pump();
      await tester.pump();
      expect(controller.newDeviceStep, NewDeviceLinkStep.showCode);
      return controller;
    }

    testWidgets('a scanned p code runs the flipped hello-side flow', (
      tester,
    ) async {
      final controller = await pumpBody(tester, scanResult: _pCode);
      await tester.ensureVisible(find.byKey(const Key('link-scan')));
      await tester.tap(find.byKey(const Key('link-scan')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('fake-scan-hit')));
      await tester.tap(find.byKey(const Key('fake-scan-hit')));
      // The ceremony's waiting step animates, so settle the route pop by
      // hand: post-frame pop + the transition.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.newDeviceStep, NewDeviceLinkStep.awaitingHelloAck);
      // Its OWN stage was cancelled before the hello left.
      expect(count('cancelProvisioning'), 1);
      expect(count('provisioningHello'), 1);
    });

    testWidgets('a scanned n code is refused and the flow stays put', (
      tester,
    ) async {
      final controller = await pumpBody(tester, scanResult: _nCode);
      await tester.ensureVisible(find.byKey(const Key('link-scan')));
      await tester.tap(find.byKey(const Key('link-scan')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('fake-scan-hit')));
      await tester.tap(find.byKey(const Key('fake-scan-hit')));
      // The ceremony's waiting step animates, so settle the route pop by
      // hand: post-frame pop + the transition.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.newDeviceStep, NewDeviceLinkStep.showCode);
      expect(count('provisioningHello'), 0);
      expect(find.byKey(const Key('link-new-code-error')), findsOneWidget);
    });

    testWidgets('unsupported scanner reveals the labelled manual field', (
      tester,
    ) async {
      await pumpBody(tester);
      await tester.ensureVisible(find.byKey(const Key('link-scan')));
      await tester.tap(find.byKey(const Key('link-scan')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('fake-scan-unsupported')));
      await tester.tap(find.byKey(const Key('fake-scan-unsupported')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('link-scan-unsupported')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('link-new-code-field')),
      );
      expect(field.controller!.text, isEmpty);
      expect(find.byKey(const Key('link-new-code-continue')), findsOneWidget);
    });
  });
}
