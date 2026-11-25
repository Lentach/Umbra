// Amendment (lxviii) clauses 2-3 / (lxix) — the devices screen's enrolled
// branch: only the DAK holder is offered the primary flow, chain failures
// render for a healthy install, and revoked tombstones collapse behind one
// disclosure.
//
// The KEYLESS cases that used to live here ((lxiv)/(lxvii) — mismatch,
// incomplete, lock-refused) are gone with the branch itself: (lxxiii)
// clause 3's DeviceLinkGateScreen owns every keyless shape now, so this
// screen never renders for such an install and the CTA it pinned no longer
// exists.

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

  /// The screen's own controller, captured so a test can put it into an
  /// enrolled/chain-invalid state without a wire.
  LinkCeremonyController? sink;

  @override
  void registerProvisioningSink(ProvisioningEventSink sink) {
    this.sink = sink as LinkCeremonyController;
    super.registerProvisioningSink(sink);
  }
}

_FakeConnectionProvider _connection = _FakeConnectionProvider();

Widget _host(EncryptionProvider encryption) {
  _connection = _FakeConnectionProvider();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<ConnectionProvider>.value(value: _connection),
      ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
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
    DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
    DeviceListEntry(deviceId: 6, platform: 'web', addedAtMs: 2000),
  ],
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('healthy: a genuine chain failure IS still rendered', (
    tester,
  ) async {
    await tester.pumpWidget(_host(FakeEncryptionProvider()));
    await tester.pumpAndSettle();
    final controller = _connection.sink!;
    controller.listState = DeviceListState.chainInvalid;
    controller.listFailureReason = 'bad_signature';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(l10n.devicesChainInvalid), findsOneWidget);
  });

  // Amendment (lxviii) clause 2 — only the DAK holder is offered the primary
  // flow; a linked device is told where linking happens.
  group('enrolled', () {
    Future<LinkCeremonyController> pumpEnrolled(
      WidgetTester tester, {
      required bool? holdsDak,
    }) async {
      await tester.pumpWidget(_host(FakeEncryptionProvider()));
      await tester.pumpAndSettle();
      final controller = _connection.sink!;
      controller.listState = DeviceListState.enrolled;
      controller.verifiedList = _enrolledList;
      controller.holdsDak = holdsDak;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('the primary (DAK holder) is offered "link a device"', (
      tester,
    ) async {
      await pumpEnrolled(tester, holdsDak: true);
      expect(find.byKey(const Key('devices-link-a-device')), findsOneWidget);
      expect(find.byKey(const Key('devices-linked-device-note')), findsNothing);
    });

    testWidgets('a linked device (no DAK) gets the note, not the flow', (
      tester,
    ) async {
      await pumpEnrolled(tester, holdsDak: false);
      expect(find.byKey(const Key('devices-link-a-device')), findsNothing);
      expect(
        find.byKey(const Key('devices-linked-device-note')),
        findsOneWidget,
      );
      // Neither the device-side CTA: this install is linked and healthy.
      expect(find.byKey(const Key('devices-link-this-device')), findsNothing);
    });

    testWidgets('unresolved DAK presence offers nothing yet', (tester) async {
      await pumpEnrolled(tester, holdsDak: null);
      expect(find.byKey(const Key('devices-link-a-device')), findsNothing);
      expect(find.byKey(const Key('devices-linked-device-note')), findsNothing);
    });

    // Amendment (lxix) — tombstones are permanent in the signed bytes (§3:
    // ids are never reused), so the SCREEN collapses them: live rows lead,
    // revoked rows sit behind one disclosure, and the ordering is by liveness
    // first, never by id alone.
    group('revoked tombstones', () {
      const withTombstones = DeviceList(
        userId: 7,
        version: 9,
        devices: [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(
            deviceId: 2,
            platform: 'web',
            addedAtMs: 2000,
            revokedAtMs: 2500,
          ),
          DeviceListEntry(
            deviceId: 3,
            platform: 'web',
            addedAtMs: 3000,
            revokedAtMs: 3500,
          ),
          DeviceListEntry(deviceId: 4, platform: 'web', addedAtMs: 4000),
        ],
      );

      Future<void> pumpTombstones(WidgetTester tester) async {
        await tester.pumpWidget(_host(FakeEncryptionProvider()));
        await tester.pumpAndSettle();
        final controller = _connection.sink!;
        controller.listState = DeviceListState.enrolled;
        controller.verifiedList = withTombstones;
        controller.holdsDak = true;
        controller.notifyListeners();
        await tester.pumpAndSettle();
      }

      testWidgets('collapsed by default: live rows only, counted toggle', (
        tester,
      ) async {
        await pumpTombstones(tester);
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(find.byKey(const Key('device-row-1')), findsOneWidget);
        expect(find.byKey(const Key('device-row-4')), findsOneWidget);
        expect(find.byKey(const Key('device-row-2')), findsNothing);
        expect(find.byKey(const Key('device-row-3')), findsNothing);
        expect(find.text(l10n.devicesRevokedSection(2)), findsOneWidget);
        // The live #4 sits ABOVE the toggle — never below a graveyard.
        final row4 = tester.getTopLeft(find.byKey(const Key('device-row-4')));
        final toggle = tester.getTopLeft(
          find.byKey(const Key('devices-revoked-toggle')),
        );
        expect(row4.dy, lessThan(toggle.dy));
      });

      testWidgets('the toggle reveals the tombstones, and hides them again', (
        tester,
      ) async {
        await pumpTombstones(tester);
        await tester.tap(find.byKey(const Key('devices-revoked-toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('device-row-2')), findsOneWidget);
        expect(find.byKey(const Key('device-row-3')), findsOneWidget);
        await tester.tap(find.byKey(const Key('devices-revoked-toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('device-row-2')), findsNothing);
      });

      testWidgets('no tombstones: no toggle at all', (tester) async {
        await pumpEnrolled(tester, holdsDak: true);
        expect(find.byKey(const Key('devices-revoked-toggle')), findsNothing);
      });

      // The tombstone is the user's confirmation that the revoke took; a
      // collapsed section would make the row simply vanish. The screen builds
      // its controller on the default Keystore, so the DAK is planted there.
      Future<void> armDak() async {
        final engine = DeviceAuthorityEngine();
        engine.mintEnrollment(
          userId: 7,
          identity: generateIdentityKeyPair(),
          createdAtMs: 1755600000000,
        );
        final exported = engine.exportDakForPersistence();
        await DakStore().persistArmed(
          DakRecord(
            userId: 7,
            dakPub: exported['dakPub']!,
            dakPriv: exported['dakPriv']!,
            createdAtMs: 1755600000000,
          ),
        );
      }

      Future<void> revokeRow4(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('device-revoke-4')));
        await tester.pumpAndSettle();
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        await tester.tap(find.text(l10n.devicesRevokeAction).last);
        // The revoke is in flight against a fake that never answers, so the
        // busy indicator animates forever: pump frames, do not settle.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      testWidgets('confirming a revoke opens the section', (tester) async {
        await armDak();
        await pumpTombstones(tester);
        expect(find.byKey(const Key('device-row-2')), findsNothing);
        await revokeRow4(tester);
        expect(find.byKey(const Key('device-row-2')), findsOneWidget);
      });

      testWidgets('a revoke that never left the device opens nothing', (
        tester,
      ) async {
        // No DAK in the Keystore: `no_dak`, the request is never emitted, and
        // popping the section open would confirm a revoke that did not happen.
        await pumpTombstones(tester);
        await revokeRow4(tester);
        expect(find.byKey(const Key('device-row-2')), findsNothing);
      });
    });
  });
}
