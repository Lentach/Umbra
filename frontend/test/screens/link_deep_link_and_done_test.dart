// Amendment (lxx) — the QR is a deep link, and a finished ceremony returns
// to the devices screen.
//
// Owner's first real link (2026-09-02, prod 0.2.0): scanning the QR with the
// phone camera opened a search page — the QR carried the bare code, and the
// primary has no in-app scanner. And both ceremony screens ended on a
// checkmark the user had to back out of. Pins: (1) a code parked from the
// URL fragment opens the primary ceremony PREFILLED, but only once this
// install is known to hold the DAK ((lxviii) clause 2); (2) it is consumed
// once — never replayed on a second visit; (3) `done` on either side pops
// back to the caller and toasts there.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/devices_screen.dart';
import 'package:fireplace/screens/link_device_screen.dart';
import 'package:fireplace/screens/link_this_device_screen.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_link/pending_link_code.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../support/l10n.dart';

/// A canonical code minted by the real ephemeral generator (a hand-typed key
/// segment fails the strict re-encode check).
final String _code = LinkOobCode(
  provisioningId: '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f',
  ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
  platform: 'web',
).encode();

class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  int? get currentUserId => 7;
  LinkCeremonyController? sink;
  @override
  void registerProvisioningSink(ProvisioningEventSink sink) {
    this.sink = sink as LinkCeremonyController;
    super.registerProvisioningSink(sink);
  }
}

class _HealthyEncryption extends EncryptionProvider {
  @override
  bool get deviceMaterialMismatch => false;
  @override
  bool get identityIncomplete => false;
  @override
  bool get identityUploadLocked => false;
}

late _FakeConnectionProvider _connection;

Widget _devicesHost() {
  _connection = _FakeConnectionProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<ConnectionProvider>.value(value: _connection),
      ChangeNotifierProvider<EncryptionProvider>(
        create: (_) => _HealthyEncryption(),
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

const _list = DeviceList(
  userId: 7,
  version: 3,
  devices: [DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1)],
);

/// A bare controller with no wire: steps are driven by hand.
LinkCeremonyController _bareController() => LinkCeremonyController(
  userId: 7,
  emit: (_, _) {},
  identity: _NoIdentity(),
  adoptSession: (_) async {},
  reconnect: (_) async {},
);

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

/// Hosts a ceremony screen above a marker page so a pop is observable.
Widget _ceremonyHost(Widget Function(BuildContext) push) {
  return MaterialApp(
    theme: RpgTheme.themeDataDarkGray,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          key: const Key('open'),
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute(builder: push)),
          child: const Text('marker-page'),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    PendingLinkCode.take();
  });

  group('pending deep-link code on the devices screen', () {
    Future<LinkCeremonyController> pump(
      WidgetTester tester, {
      required bool? holdsDak,
    }) async {
      await tester.pumpWidget(_devicesHost());
      await tester.pumpAndSettle();
      final c = _connection.sink!;
      c.listState = DeviceListState.enrolled;
      c.verifiedList = _list;
      c.holdsDak = holdsDak;
      c.notifyListeners();
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('a DAK holder is taken straight into the ceremony, prefilled', (
      tester,
    ) async {
      PendingLinkCode.arm(_code);
      final c = await pump(tester, holdsDak: true);
      expect(find.byType(LinkDeviceScreen), findsOneWidget);
      // The flow started from the parked code without a keystroke: the code
      // PARSED (else `invalid_code`) and the mock Keystore holds no DAK, so
      // it fails there — one step past idle is the proof the scan was used.
      expect(c.primaryStep, PrimaryLinkStep.failed);
      expect(c.primaryError, 'no_dak');
      // Consumed: nothing left to replay.
      expect(PendingLinkCode.isArmed, isFalse);
    });

    // Observed live on the first deep-link run: on a cold boot the Keystore
    // read (holdsDak) beat the list fetch. The screen must NOT hold the code
    // back for the list — a list that never verifies would park it forever,
    // a silent no-op worse than the search page. The ceremony opens on the
    // DAK alone; waiting for the list is the controller's job at staging
    // (test/services/device_link/stage_waits_for_list_test.dart).
    testWidgets('DAK known, list still loading: the ceremony still opens', (
      tester,
    ) async {
      PendingLinkCode.arm(_code);
      await tester.pumpWidget(_devicesHost());
      await tester.pumpAndSettle();
      final c = _connection.sink!;
      c.holdsDak = true;
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(LinkDeviceScreen), findsOneWidget);
      expect(PendingLinkCode.isArmed, isFalse);
    });

    testWidgets('a linked device (no DAK) is NOT walked into a doomed flow', (
      tester,
    ) async {
      PendingLinkCode.arm(_code);
      await pump(tester, holdsDak: false);
      expect(find.byType(LinkDeviceScreen), findsNothing);
      // The code stays parked for a primary that can use it.
      expect(PendingLinkCode.isArmed, isTrue);
    });

    testWidgets('unresolved DAK presence opens nothing yet', (tester) async {
      PendingLinkCode.arm(_code);
      await pump(tester, holdsDak: null);
      expect(find.byType(LinkDeviceScreen), findsNothing);
      expect(PendingLinkCode.isArmed, isTrue);
    });

    testWidgets('no pending code: the screen behaves as before', (
      tester,
    ) async {
      await pump(tester, holdsDak: true);
      expect(find.byType(LinkDeviceScreen), findsNothing);
    });
  });

  qrTests();

  group('a finished ceremony returns to the caller', () {
    testWidgets('primary side: done pops and toasts', (tester) async {
      final c = _bareController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _ceremonyHost((_) => LinkDeviceScreen(controller: c)),
      );
      await tester.tap(find.byKey(const Key('open')));
      // The screen auto-opens the flipped flow on mount ((lxxvii)); with no
      // DAK in the mock Keystore it lands on `failed` — irrelevant here, the
      // pin is the POP on `done`.
      await tester.pumpAndSettle();
      expect(find.byType(LinkDeviceScreen), findsOneWidget);

      c.primaryStep = PrimaryLinkStep.done;
      c.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.byType(LinkDeviceScreen), findsNothing);
      expect(find.text('marker-page'), findsOneWidget);
      expect(find.text(l10n.linkPrimaryDone), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

// Appended: the QR must carry the DEEP-LINK form, not the bare code — the
// bare code is what a phone camera turns into a search page.
void qrTests() {
  testWidgets('the QR encodes /link#<code>, the text shows the bare code', (
    tester,
  ) async {
    final c = _bareController();
    addTearDown(() async {
      await c.abortNewDevice('cancelled');
      c.dispose();
    });
    await tester.pumpWidget(
      _ceremonyHost(
        (_) => Scaffold(
          body: SingleChildScrollView(child: LinkThisDeviceBody(controller: c)),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    // Drive the controller to the code-showing step by hand.
    c.oobCode = _code;
    c.newDeviceStep = NewDeviceLinkStep.showCode;
    c.notifyListeners();
    await tester.pump();
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.semanticsLabel, endsWith('/link#$_code'));
    expect(qr.semanticsLabel, startsWith('link qr http'));
    expect(find.text(_code), findsOneWidget);
  });
}
