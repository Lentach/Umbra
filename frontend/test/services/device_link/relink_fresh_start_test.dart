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
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
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

  ({String pub, String priv}) blobIdentity() {
    final pair = generateIdentityKeyPair();
    return (
      pub: base64Encode(pair.getPublicKey().serialize()),
      priv: base64Encode(pair.getPrivateKey().serialize()),
    );
  }

  // What the old life's box and history left in the account namespace.
  const oldLife = [
    'e2e_${ownUserId}_boxsib_v1',
    'e2e_${ownUserId}_boxreq_v1',
    'e2e_${ownUserId}_contact_v1_42',
    'e2e_${ownUserId}_boxin_v1_rid.1',
    'e2e_${ownUserId}_decrypted_123',
  ];
  const counterKey = 'e2e_${ownUserId}_boxlid_v1';

  Future<SharedPreferences> seedOldLife() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in oldLife) {
      await prefs.setString(key, '{}');
    }
    await prefs.setString(counterKey, '281474976710700');
    return prefs;
  }

  group('the link adopt', () {
    test('keeps nothing of the device the install used to be', () async {
      await linkedAs(2);
      final prefs = await seedOldLife();
      // Not this account's device life: must survive.
      await prefs.setString('e2e_8_contact_v1_1', '{}');
      await prefs.setBool('account_enrolled_hint_$ownUserId', true);

      final blob = blobIdentity();
      final fresh = EncryptionProvider();
      await fresh.encryptionService.adoptProvisionedIdentity(
        userId: ownUserId,
        ikPubBase64: blob.pub,
        ikPrivBase64: blob.priv,
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
        prefs.getString(counterKey),
        '281474976710700',
        reason: 'a lowered local-id counter names the old life\'s cache '
            'entries (voice notes) again (decision 14)',
      );
      expect(
        await fresh.encryptionService.materialDeviceStamp(ownUserId),
        isNull,
        reason: 'the old stamp would gate the new device',
      );
      expect(
        await fresh.encryptionService.currentIdentityPublicKeyBase64(),
        blob.pub,
      );
    });

    // Mutation: ignore `ContentKv.remove`'s answer in the wipe.
    test('a delete the store refuses aborts the link and leaves the install '
        'a previous life', () async {
      final old = await linkedAs(2);
      await seedOldLife();
      old.encryptionService.debugSetContentKv(
        _RefusingKv(
          await PrefsContentKv.open(),
          refuse: 'e2e_${ownUserId}_boxsib_v1',
        ),
      );
      final blob = blobIdentity();

      await expectLater(
        old.encryptionService.adoptProvisionedIdentity(
          userId: ownUserId,
          ikPubBase64: blob.pub,
          ikPrivBase64: blob.priv,
          dakPubBase64: base64Encode(List<int>.filled(32, 3)),
          disposeStaleMaterial: true,
        ),
        throwsStateError,
      );
      expect(
        await old.encryptionService.materialDeviceStamp(ownUserId),
        2,
        reason: 'the stamp keeps the install on the gate until a proven wipe',
      );
    });

    // Mutation: run `beforeWipe` before the blob is parsed.
    test('starts the fresh device life only for a blob that parses',
        () async {
      await linkedAs(2);
      var teardowns = 0;
      Future<void> teardown() async => teardowns++;
      final service = EncryptionProvider().encryptionService;

      await expectLater(
        service.adoptProvisionedIdentity(
          userId: ownUserId,
          ikPubBase64: 'not base64',
          ikPrivBase64: 'not base64',
          dakPubBase64: base64Encode(List<int>.filled(32, 3)),
          disposeStaleMaterial: true,
          beforeWipe: teardown,
        ),
        throwsA(anything),
      );
      expect(teardowns, 0, reason: 'the box and store of a refused link stay');

      final blob = blobIdentity();
      await service.adoptProvisionedIdentity(
        userId: ownUserId,
        ikPubBase64: blob.pub,
        ikPrivBase64: blob.priv,
        dakPubBase64: base64Encode(List<int>.filled(32, 3)),
        disposeStaleMaterial: true,
        beforeWipe: teardown,
      );
      expect(teardowns, 1);
    });
  });

  group('a phrase restore', () {
    IdentityBackupPayload backupOf(IdentityKeyPair pair) =>
        IdentityBackupPayload(
          userId: ownUserId,
          identity: jsonEncode({
            'pair': base64Encode(pair.serialize()),
            'registrationId': 4242,
          }),
          dak: null,
        );

    // Mutation: keep the Signal-only wipe for a stale restore (owner
    // 2026-11-03: "fresh start too").
    test('on a previous device life starts it fresh, like a link', () async {
      final old = await linkedAs(2);
      final prefs = await seedOldLife();
      var teardowns = 0;

      await old.encryptionService.adoptRestoredIdentity(
        userId: ownUserId,
        payload: backupOf(generateIdentityKeyPair()),
        disposeStaleMaterial: true,
        beforeWipe: () async => teardowns++,
      );

      await prefs.reload();
      for (final key in oldLife) {
        expect(prefs.containsKey(key), isFalse, reason: '$key survived');
      }
      expect(teardowns, 1);
    });

    test('on a keyless install keeps its history', () async {
      final prefs = await seedOldLife();
      var teardowns = 0;

      await EncryptionProvider().encryptionService.adoptRestoredIdentity(
        userId: ownUserId,
        payload: backupOf(generateIdentityKeyPair()),
        beforeWipe: () async => teardowns++,
      );

      await prefs.reload();
      expect(prefs.containsKey('e2e_${ownUserId}_decrypted_123'), isTrue);
      expect(teardowns, 0);
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

/// A content store that refuses to delete [refuse] (a dropped commit).
class _RefusingKv implements ContentKv {
  _RefusingKv(this._inner, {required this.refuse});

  final ContentKv _inner;
  final String refuse;

  @override
  Future<bool> remove(String key) async =>
      key != refuse && await _inner.remove(key);
  @override
  Future<void> reload() => _inner.reload();
  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      _inner.authoritativeSnapshot();
  @override
  String? getString(String key) => _inner.getString(key);
  @override
  int? getInt(String key) => _inner.getInt(key);
  @override
  bool containsKey(String key) => _inner.containsKey(key);
  @override
  Set<String> getKeys() => _inner.getKeys();
  @override
  Future<bool> setString(String key, String value) =>
      _inner.setString(key, value);
  @override
  Future<bool> setInt(String key, int value) => _inner.setInt(key, value);
}
