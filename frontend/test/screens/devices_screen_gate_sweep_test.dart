// A2-DEV-10: the device-link gate's edge sweep removes the page routes already
// on the stack. A dialog the page had open used to be KEPT, floating over the
// gate and holding a future that runs against the page's disposed screen
// (confirming the revoke called `revokeDevice` on a disposed controller).
// The sweep now removes every route above a removed page, except the scanner.

import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/devices_screen.dart';
import 'package:fireplace/screens/link_scan_screen.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/device_link_route_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  int? get currentUserId => 7;

  final List<(String, dynamic)> emitted = [];

  @override
  void emit(String event, dynamic data) => emitted.add((event, data));

  LinkCeremonyController? sink;

  @override
  void registerProvisioningSink(ProvisioningEventSink sink) {
    this.sink = sink as LinkCeremonyController;
    super.registerProvisioningSink(sink);
  }
}

class _ToggleGate extends EncryptionProvider {
  bool _gated = false;

  @override
  bool get needsDeviceLink => _gated;

  @override
  int get ownDeviceId => 4;

  void raiseGate() {
    _gated = true;
    notifyListeners();
  }
}

const _list = DeviceList(
  userId: 7,
  version: 3,
  devices: [
    DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
    DeviceListEntry(deviceId: 4, platform: 'web', addedAtMs: 2000),
    DeviceListEntry(deviceId: 6, platform: 'web', addedAtMs: 3000),
  ],
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<(_FakeConnectionProvider, _ToggleGate)> pumpDevicesScreen(
    WidgetTester tester,
  ) async {
    final connection = _FakeConnectionProvider();
    final encryption = _ToggleGate();
    addTearDown(encryption.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _FakeAuthProvider(),
          ),
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorObservers: [DeviceLinkGateRouteGuard(encryption)],
          home: const Scaffold(body: Text('shell')),
        ),
      ),
    );
    await tester.pump();
    final navigator = Navigator.of(tester.element(find.text('shell')));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    connection.sink!
      ..listState = DeviceListState.enrolled
      ..verifiedList = _list
      ..holdsDak = true
      ..notifyListeners();
    await tester.pumpAndSettle();
    return (connection, encryption);
  }

  testWidgets('the gate rising over the Devices screen with its revoke '
      'confirm open removes the page AND the dialog', (tester) async {
    final (connection, encryption) = await pumpDevicesScreen(tester);

    await tester.tap(find.byKey(const Key('device-revoke-6')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-revoke-confirm')), findsOneWidget);

    encryption.raiseGate();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('devices-revoke-confirm')),
      findsNothing,
      reason: 'a dialog belonging to a swept page must not float over the gate',
    );
    expect(find.byType(DevicesScreen), findsNothing);
    expect(find.text('shell'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      connection.emitted.where((e) => e.$1 == 'revokeDevice'),
      isEmpty,
    );
  });

  testWidgets("the ceremony's scanner route above a swept page survives",
      (tester) async {
    final (_, encryption) = await pumpDevicesScreen(tester);
    const scanKey = Key('scanner-over-the-gate');
    Navigator.of(tester.element(find.byType(DevicesScreen)))
        .push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kLinkScanRouteName),
            builder: (_) => const Scaffold(key: scanKey, body: SizedBox()),
          ),
        )
        .ignore();
    await tester.pumpAndSettle();

    encryption.raiseGate();
    await tester.pumpAndSettle();

    expect(find.byKey(scanKey), findsOneWidget);
    expect(find.byType(DevicesScreen, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
