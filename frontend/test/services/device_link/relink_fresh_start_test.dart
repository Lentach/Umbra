// Issue #208 — a re-linked device starts fresh (owner, 2026-11-03).
//
// Prod (bob208's Android, revoked device 11, linked again as 18): the link
// wiped only Signal material, so the install kept the box queues, sibling
// book and request queue of the device it used to be. It drained the old
// queues into rows nobody could read, and its stale "the primary acked our
// self-queue" kept it from ever handing the primary its new address — the
// primary then refused every send (`own_uncovered`) until the phone was
// unlinked again.
//
// REAL EncryptionService and EncryptionProvider over mock storage.

import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  /// An install that was linked as [deviceId]: identity minted, material
  /// stamped for that id.
  Future<EncryptionProvider> linkedAs(int deviceId) async {
    final provider = EncryptionProvider()
      ..storedSessionDeviceId = (() async => deviceId);
    provider
      ..setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      })
      ..setOwnDeviceId(deviceId);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    expect(provider.isE2EReady, isTrue, reason: 'precondition');
    return provider;
  }

  group('the link adopt', () {
    test('keeps nothing of the device the install used to be', () async {
      await linkedAs(2);
      final prefs = await SharedPreferences.getInstance();
      // What the old life's box and history left in the account namespace.
      const oldLife = [
        'e2e_${ownUserId}_boxsib_v1',
        'e2e_${ownUserId}_boxreq_v1',
        'e2e_${ownUserId}_contact_v1_42',
        'e2e_${ownUserId}_boxin_v1_rid.1',
        'e2e_${ownUserId}_decrypted_123',
        'e2e_${ownUserId}_boxsync_v1',
      ];
      for (final key in oldLife) {
        await prefs.setString(key, '{}');
      }
      // Not this account's device life: must survive.
      await prefs.setString('e2e_8_contact_v1_1', '{}');
      await prefs.setBool('account_enrolled_hint_$ownUserId', true);

      final pair = generateIdentityKeyPair();
      final ikPub = base64Encode(pair.getPublicKey().serialize());
      final fresh = EncryptionProvider();
      await fresh.encryptionService.adoptProvisionedIdentity(
        userId: ownUserId,
        ikPubBase64: ikPub,
        ikPrivBase64: base64Encode(pair.getPrivateKey().serialize()),
        dakPubBase64: base64Encode(List<int>.filled(32, 3)),
        disposeStaleMaterial: true,
      );

      await prefs.reload();
      for (final key in oldLife) {
        expect(prefs.containsKey(key), isFalse, reason: '$key survived the link');
      }
      expect(prefs.containsKey('e2e_8_contact_v1_1'), isTrue);
      expect(prefs.getBool('account_enrolled_hint_$ownUserId'), isTrue);
      expect(
        await fresh.encryptionService.materialDeviceStamp(ownUserId),
        isNull,
        reason: 'the old stamp would gate the new device',
      );
      expect(
        await fresh.encryptionService.currentIdentityPublicKeyBase64(),
        ikPub,
      );
    });
  });

  group('an install that is no longer the device it was', () {
    test('shows the link gate before the server confirms its device id',
        () async {
      await linkedAs(2);
      // Revoked, then signed in with the password: the stored session now
      // names the primary.
      final relogged = EncryptionProvider()
        ..storedSessionDeviceId = (() async => 1);

      await relogged.checkPreviousDeviceLife(ownUserId);

      expect(relogged.needsDeviceLink, isTrue);
    });

    test('never comes up E2E-ready while its id is still unconfirmed',
        () async {
      await linkedAs(2);
      final relogged = EncryptionProvider()
        ..storedSessionDeviceId = (() async => 1);
      var ready = 0;
      relogged
        ..setEmitCallback((_, _) {})
        ..onE2EReady = () => ready++;

      // Init runs at transport connect, before `socketReady`: no
      // setOwnDeviceId yet.
      await relogged.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);

      expect(relogged.isE2EReady, isFalse);
      expect(ready, 0, reason: 'E2E-ready is what starts the box on the old queues');
      expect(relogged.needsDeviceLink, isTrue);
    });

    test('a device whose session names its own id is left alone', () async {
      await linkedAs(2);
      final sameDevice = EncryptionProvider()
        ..storedSessionDeviceId = (() async => 2);

      await sameDevice.checkPreviousDeviceLife(ownUserId);

      expect(sameDevice.needsDeviceLink, isFalse);
    });
  });
}
