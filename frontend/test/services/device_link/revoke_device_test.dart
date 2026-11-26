import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Client half of revocation (multi-device spec §5.5 + §12 amendment (xxi)).
///
/// The server never mints a list version, so the REQUEST is only half of what
/// revocation is: the other half is the DAK-signed list whose canonical bytes
/// already show the device revoked. The server refuses the pair outright if
/// they disagree (`list_device_mismatch`), so these tests pin exactly what the
/// client signs.
class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async =>
      throw StateError('not used by the revoke flow');

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

/// A DakStore that answers exactly one record (or none) — the Keystore seam the
/// controller reads before it may sign anything.
class _StubDakStore extends DakStore {
  _StubDakStore(this._record);

  final DakRecord? _record;

  @override
  Future<DakRecord?> read({required int userId}) async => _record;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 42;

  late List<(String, dynamic)> emitted;
  late DeviceAuthorityEngine engine;
  late LinkCeremonyController controller;

  /// The account's current list: primary + a linked device 2.
  DeviceList currentList({int version = 2}) => DeviceList(
    userId: userId,
    version: version,
    devices: const [
      DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
      DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
    ],
  );

  setUp(() {
    emitted = [];
    engine = DeviceAuthorityEngine();
    // Arm the engine with a DAK, which is all the revoke path needs; minting
    // the enrollment itself is T2's territory.
    engine.mintEnrollment(
      userId: userId,
      identity: generateIdentityKeyPair(),
      createdAtMs: 1755600000000,
    );
    // The controller reads the Keystore before it signs, exactly as production
    // does — so the shared fixture supplies the DAK it just minted.
    final persisted = engine.exportDakForPersistence();
    controller = LinkCeremonyController(
      userId: userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: engine,
      dakStore: _StubDakStore(
        DakRecord(
          userId: userId,
          dakPub: persisted['dakPub']!,
          dakPriv: persisted['dakPriv']!,
          createdAtMs: 1755600000000,
        ),
      ),
    );
    controller.verifiedList = currentList();
  });

  DeviceList signedListFromEmit() {
    final revoke = emitted.firstWhere((e) => e.$1 == 'revokeDevice');
    final payload = revoke.$2 as Map<String, dynamic>;
    return parseCanonicalDeviceList(
      base64Decode(payload['listCanonical'] as String),
    );
  }

  test('arms the DAK from the Keystore before signing', () async {
    // The regression this pins: the devices screen builds a FRESH controller
    // every time it opens, so its engine holds no DAK. Signing without one
    // throws and the request never leaves the device — which is exactly what
    // the T6 app-proof caught, with the unit suite green because it had
    // pre-armed the engine.
    final coldEngine = DeviceAuthorityEngine();
    final armed = DeviceAuthorityEngine()
      ..mintEnrollment(
        userId: userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
    final stored = armed.exportDakForPersistence();
    final cold = LinkCeremonyController(
      userId: userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: coldEngine,
      dakStore: _StubDakStore(
        DakRecord(
          userId: userId,
          dakPub: stored['dakPub']!,
          dakPriv: stored['dakPriv']!,
          createdAtMs: 1755600000000,
        ),
      ),
    );
    cold.verifiedList = currentList();

    await cold.revokeDevice(2);

    expect(
      emitted.where((e) => e.$1 == 'revokeDevice').length,
      1,
      reason: 'a cold controller must restore the DAK, not fail to sign',
    );
    expect(cold.revokeError, isNull);
  });

  test('refuses cleanly when this device holds NO DAK', () async {
    final cold = LinkCeremonyController(
      userId: userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: DeviceAuthorityEngine(),
      dakStore: _StubDakStore(null),
    );
    cold.verifiedList = currentList();

    await cold.revokeDevice(2);

    // A non-primary device cannot sign a list mutation at all, so it must say
    // so instead of emitting a request the server would refuse.
    expect(emitted.where((e) => e.$1 == 'revokeDevice'), isEmpty);
    expect(cold.revokeError, 'no_dak');
    expect(cold.revokingDeviceId, isNull);
  });

  test('signs a list that revokes EXACTLY the requested device', () async {
    await controller.revokeDevice(2);

    final revoke = emitted.firstWhere((e) => e.$1 == 'revokeDevice');
    final payload = revoke.$2 as Map<String, dynamic>;
    expect(payload['deviceId'], 2);
    expect(payload['listSignature'], isA<String>());

    final signed = signedListFromEmit();
    // The signed bytes and the request must agree, or the server refuses the
    // whole thing (amendment (xxi), `list_device_mismatch`).
    expect(
      signed.devices.firstWhere((d) => d.deviceId == 2).revokedAtMs,
      isNotNull,
    );
    // And nothing else changes: the primary stays live.
    expect(
      signed.devices.firstWhere((d) => d.deviceId == 1).revokedAtMs,
      isNull,
    );
  });

  test('keeps the revoked entry ON the list, never removes it', () async {
    await controller.revokeDevice(2);

    final signed = signedListFromEmit();
    // A removed entry would tell peers nothing; the revoked STAMP is what makes
    // them stop addressing envelopes to it and lets a receiver refuse its
    // ciphertext at decrypt time (amendment (e)).
    expect(signed.devices.map((d) => d.deviceId), [1, 2]);
    expect(signed.devices.firstWhere((d) => d.deviceId == 2).platform, 'web');
    expect(signed.devices.firstWhere((d) => d.deviceId == 2).addedAtMs, 2000);
  });

  test('ADVANCES the list version by exactly one', () async {
    controller.verifiedList = currentList(version: 7);

    await controller.revokeDevice(2);

    expect(signedListFromEmit().version, 8);
  });

  test(
    'refuses to revoke a device already revoked, without emitting',
    () async {
      controller.verifiedList = DeviceList(
        userId: userId,
        version: 3,
        devices: const [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(
            deviceId: 2,
            platform: 'web',
            addedAtMs: 2000,
            revokedAtMs: 2500,
          ),
        ],
      );

      await controller.revokeDevice(2);

      expect(emitted.where((e) => e.$1 == 'revokeDevice'), isEmpty);
    },
  );

  test('refuses an unknown device id, without emitting', () async {
    await controller.revokeDevice(9);

    expect(emitted.where((e) => e.$1 == 'revokeDevice'), isEmpty);
  });

  test('does nothing without a verified list — never signs blind', () async {
    controller.verifiedList = null;

    await controller.revokeDevice(2);

    expect(emitted.where((e) => e.$1 == 'revokeDevice'), isEmpty);
  });

  test('one revocation at a time', () async {
    await controller.revokeDevice(2);
    await controller.revokeDevice(2);

    expect(emitted.where((e) => e.$1 == 'revokeDevice').length, 1);
    expect(controller.revokingDeviceId, 2);
  });

  group('the server answer', () {
    test('success clears the in-flight state and refreshes the list', () async {
      await controller.revokeDevice(2);
      emitted.clear();

      controller.onDeviceRevocationCompleted({
        'success': true,
        'deviceId': 2,
        'listVersion': 3,
      });

      expect(controller.revokingDeviceId, isNull);
      expect(controller.revokeError, isNull);
      expect(emitted.map((e) => e.$1), contains('getDeviceList'));
    });

    test('a refusal surfaces the server code and clears the spinner', () async {
      await controller.revokeDevice(2);

      controller.onDeviceRevocationCompleted({
        'success': false,
        'error': 'cannot_revoke_primary',
      });

      expect(controller.revokingDeviceId, isNull);
      expect(controller.revokeError, 'cannot_revoke_primary');
    });

    test('a malformed answer still clears the spinner', () async {
      await controller.revokeDevice(2);

      controller.onDeviceRevocationCompleted('nonsense');

      expect(controller.revokingDeviceId, isNull);
      expect(controller.revokeError, 'revoke_failed');
    });

    test('an answer with nothing in flight is ignored', () {
      controller.onDeviceRevocationCompleted({'success': true});

      expect(controller.revokeError, isNull);
      expect(emitted, isEmpty);
    });
  });
}
