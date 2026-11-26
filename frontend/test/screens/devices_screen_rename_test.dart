// Amendment (lxxx) clauses 1-2 on the devices screen: every LIVE row can be
// given a name, a revoked tombstone cannot, and the "primary" badge is
// DERIVED as the lowest non-revoked id instead of being keyed on `deviceId
// == 1` (which every §6.2 reset and every (lxxviii) restore falsifies by
// re-homing the survivor onto a fresh id).

import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/devices_screen.dart';
import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:provider/provider.dart';

import '../support/encryption_fakes.dart';

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

_FakeConnectionProvider _connection = _FakeConnectionProvider();

Widget _host({
  int? revokeDeviceId,
  EncryptionProvider? encryption,
  Locale? locale,
}) {
  _connection = _FakeConnectionProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<ConnectionProvider>.value(value: _connection),
      ChangeNotifierProvider<EncryptionProvider>.value(
        value: encryption ?? FakeEncryptionProvider(),
      ),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: DevicesScreen(revokeDeviceId: revokeDeviceId),
    ),
  );
}

/// Seeds the Keystore with a real DAK for user 7, so the screen's own
/// controller can actually sign the rename it emits.
void _seedDak() {
  final engine = DeviceAuthorityEngine()
    ..mintEnrollment(
      userId: 7,
      identity: generateIdentityKeyPair(),
      createdAtMs: 1755600000000,
    );
  final persisted = engine.exportDakForPersistence();
  FlutterSecureStorage.setMockInitialValues({
    'dak_record_v1_7': jsonEncode(
      DakRecord(
        userId: 7,
        dakPub: persisted['dakPub']!,
        dakPriv: persisted['dakPriv']!,
        createdAtMs: 1755600000000,
      ),
    ),
  });
}

Future<LinkCeremonyController> _pumpEnrolled(
  WidgetTester tester,
  DeviceList list,
) async {
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
  final controller = _connection.sink!;
  controller.listState = DeviceListState.enrolled;
  controller.verifiedList = list;
  controller.holdsDak = true;
  controller.notifyListeners();
  await tester.pumpAndSettle();
  return controller;
}

class _OwnDeviceFour extends FakeEncryptionProvider {
  @override
  int get ownDeviceId => 4;
}

/// Opens the screen with [revokeDeviceId] (the chat list's "remove" line),
/// then lets the verified list arrive, the way a real visit does. Returns the
/// `revokeDevice` frames the screen signed and sent.
Future<List<(String, dynamic)>> _visitAsking(
  WidgetTester tester,
  int revokeDeviceId,
) async {
  _seedDak();
  await tester.pumpWidget(
    _host(
      revokeDeviceId: revokeDeviceId,
      encryption: _OwnDeviceFour(),
    ),
  );
  await tester.pumpAndSettle();
  _connection.sink!
    ..listState = DeviceListState.enrolled
    ..verifiedList = const DeviceList(
      userId: 7,
      version: 3,
      devices: [
        DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
        DeviceListEntry(deviceId: 4, platform: 'web', addedAtMs: 2000),
        DeviceListEntry(deviceId: 6, platform: 'web', addedAtMs: 3000),
        DeviceListEntry(
          deviceId: 8,
          platform: 'web',
          addedAtMs: 3500,
          revokedAtMs: 3600,
        ),
      ],
    )
    ..holdsDak = true
    ..notifyListeners();
  // The revoke is in flight against a fake that never answers: no settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return _connection.emitted
      .where((e) => e.$1 == 'revokeDevice')
      .toList();
}

const _twoLive = DeviceList(
  userId: 7,
  version: 3,
  devices: [
    DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
    DeviceListEntry(deviceId: 6, platform: 'web', addedAtMs: 2000),
  ],
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('every live row offers rename; a revoked one does not', (
    tester,
  ) async {
    await _pumpEnrolled(
      tester,
      const DeviceList(
        userId: 7,
        version: 4,
        devices: [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(
            deviceId: 2,
            platform: 'web',
            addedAtMs: 2000,
            revokedAtMs: 2500,
          ),
          DeviceListEntry(deviceId: 4, platform: 'web', addedAtMs: 4000),
        ],
      ),
    );

    // The primary and this device are both LIVE — a name is informational, so
    // both take one, unlike revoke.
    expect(find.byKey(const Key('device-rename-1')), findsOneWidget);
    expect(find.byKey(const Key('device-rename-4')), findsOneWidget);

    await tester.tap(find.byKey(const Key('devices-revoked-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-row-2')), findsOneWidget);
    expect(find.byKey(const Key('device-rename-2')), findsNothing);
  });

  // A2-DEV-03: a linked device holds no DAK, so the server always refuses
  // its revoke and rename. The icons must not be offered at all.
  testWidgets('a device without the DAK offers neither revoke nor rename', (
    tester,
  ) async {
    final controller = await _pumpEnrolled(tester, _twoLive);
    expect(find.byKey(const Key('device-revoke-6')), findsOneWidget);
    expect(find.byKey(const Key('device-rename-6')), findsOneWidget);

    controller
      ..holdsDak = false
      ..notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-row-6')), findsOneWidget);
    expect(find.byKey(const Key('device-revoke-6')), findsNothing);
    expect(find.byKey(const Key('device-rename-6')), findsNothing);
    expect(find.byKey(const Key('device-rename-1')), findsNothing);
  });

  testWidgets('the save button signs and emits updateDeviceList', (
    tester,
  ) async {
    _seedDak();
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final controller = await _pumpEnrolled(tester, _twoLive);

    await tester.tap(find.byKey(const Key('device-rename-6')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.devicesRenameTitle), findsOneWidget);
    expect(find.text(l10n.devicesRenameClearHint), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('device-rename-field')),
      'Telefon Ani',
    );
    await tester.tap(find.byKey(const Key('device-rename-save')));
    // The rename is in flight against a fake that never answers, so the row
    // keeps its spinner — `pumpAndSettle` would wait for it forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(controller.renameError, isNull);
    final update = _connection.emitted.firstWhere(
      (e) => e.$1 == 'updateDeviceList',
    );
    final signed = parseCanonicalDeviceList(
      base64Decode((update.$2 as Map<String, dynamic>)['listCanonical'] as String),
    );
    expect(signed.version, 4);
    expect(signed.devices.firstWhere((d) => d.deviceId == 6).name, 'Telefon Ani');
  });

  testWidgets('a named row renders the name, keeping platform · #id', (
    tester,
  ) async {
    await _pumpEnrolled(
      tester,
      const DeviceList(
        userId: 7,
        version: 5,
        devices: [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(
            deviceId: 6,
            platform: 'web',
            addedAtMs: 2000,
            name: 'Telefon Ani',
          ),
        ],
      ),
    );

    expect(find.text('Telefon Ani'), findsOneWidget);
    // The id stays discoverable on the secondary line — it is what every
    // refusal code names.
    expect(find.textContaining('web · #6'), findsOneWidget);
  });

  testWidgets('a failed rename surfaces devicesRenameFailed', (tester) async {
    // No DAK in the Keystore: the request never leaves the device and the
    // screen has to say so where the revoke error already appears.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final controller = await _pumpEnrolled(tester, _twoLive);

    await tester.tap(find.byKey(const Key('device-rename-6')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device-rename-field')),
      'Telefon',
    );
    await tester.tap(find.byKey(const Key('device-rename-save')));
    await tester.pumpAndSettle();

    expect(controller.renameError, 'no_dak');
    expect(find.byKey(const Key('devices-rename-error')), findsOneWidget);
    expect(find.text(l10n.devicesRenameFailed), findsOneWidget);
    expect(
      _connection.emitted.where((e) => e.$1 == 'updateDeviceList'),
      isEmpty,
    );
  });

  testWidgets(
    'F15: device 1 revoked and 3 live badges 3, never 1',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await _pumpEnrolled(
        tester,
        const DeviceList(
          userId: 7,
          version: 6,
          devices: [
            DeviceListEntry(
              deviceId: 1,
              platform: 'android',
              addedAtMs: 1000,
              revokedAtMs: 1500,
            ),
            DeviceListEntry(deviceId: 3, platform: 'web', addedAtMs: 3000),
          ],
        ),
      );

      // The badge sits on the LIVE row — and NOT on the revoked device 1,
      // which the old `deviceId == 1` rule would have labelled.
      final badge = l10n.devicesPrimaryBadge;
      expect(find.text('web · #3 · $badge'), findsOneWidget);
      expect(find.text('android · #1 · $badge'), findsNothing);

      await tester.tap(find.byKey(const Key('devices-revoked-toggle')));
      await tester.pumpAndSettle();
      // The tombstone is now on screen and still carries no badge.
      expect(find.byKey(const Key('device-row-1')), findsOneWidget);
      expect(find.text('android · #1'), findsOneWidget);
      expect(find.text('android · #1 · $badge'), findsNothing);
    },
  );

  // A2-DEV-09: the chat list's "remove" line opens this screen with the
  // device to revoke. It must revoke exactly that live sibling, and nothing
  // when the id is the primary, this device, a tombstone or unknown.
  testWidgets('revokeDeviceId revokes the named live sibling, once', (
    tester,
  ) async {
    final frames = await _visitAsking(tester, 6);

    expect(frames, hasLength(1));
    final signed = parseCanonicalDeviceList(
      base64Decode(
        (frames.single.$2 as Map<String, dynamic>)['listCanonical'] as String,
      ),
    );
    expect(
      signed.devices.where((d) => d.revokedAtMs != null).map((d) => d.deviceId),
      containsAll([6, 8]),
    );
    expect(
      signed.devices.firstWhere((d) => d.deviceId == 4).revokedAtMs,
      isNull,
    );
    expect(signed.devices.firstWhere((d) => d.deviceId == 1).revokedAtMs, isNull);
  });

  for (final (label, id) in [
    ('the primary', 1),
    ('this device', 4),
    ('an already revoked row', 8),
    ('an id the list does not name', 99),
  ]) {
    testWidgets('revokeDeviceId naming $label revokes nothing', (tester) async {
      final frames = await _visitAsking(tester, id);

      expect(frames, isEmpty);
    });
  }

  // A2-DEV-07: the screen reader names a row in the app's language.
  testWidgets('a device row is announced in Polish, not English', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(locale: const Locale('pl')));
    await tester.pumpAndSettle();
    _connection.sink!
      ..listState = DeviceListState.enrolled
      ..verifiedList = _twoLive
      ..holdsDak = true
      ..notifyListeners();
    await tester.pumpAndSettle();

    final pl = await AppLocalizations.delegate.load(const Locale('pl'));
    expect(
      find.bySemanticsLabel(RegExp('^${pl.devicesRowSemantics(6, 'web')}')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('^device 6')), findsNothing);
    semantics.dispose();
  });
}
