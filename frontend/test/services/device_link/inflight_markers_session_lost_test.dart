// CONT-07 — an in-flight marker the server never answers must not outlive the
// socket it was sent on.
//
// `revokingDeviceId`, `renamingDeviceId`, the primary `staging` step and
// `enrolling` were cleared only by a server answer. A socket lost between the
// emit and the answer left them set, so every later revoke or rename returned
// early (and the enable button stayed spinning) until the screen was rebuilt.

import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _userId = 42;

class _Identity implements LinkIdentityGateway {
  _Identity(this.pair);
  final IdentityKeyPair pair;

  @override
  Future<String?> ownIdentityPublicKeyBase64() async =>
      base64Encode(pair.getPublicKey().serialize());

  @override
  Future<dynamic> ownIdentityKeyPair() async => pair;

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
}

class _StubDakStore extends DakStore {
  _StubDakStore(this._record);
  final DakRecord? _record;
  @override
  Future<DakRecord?> read({required int userId}) async => _record;
}

Map<String, dynamic> _asServed(Map<String, dynamic> enrollment) => {
  'dakPub': enrollment['dakPub'],
  'enrollmentSig': enrollment['enrollmentSig'],
  'enrollmentCreatedAt': enrollment['createdAt'],
  'listVersion': 1,
  'listCanonical': enrollment['listCanonical'],
  'listSignature': enrollment['listSignature'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<(String, dynamic)> emitted;
  late LinkCeremonyController controller;

  setUp(() async {
    emitted = [];
    final pair = generateIdentityKeyPair();
    final engine = DeviceAuthorityEngine();
    final authorization = _asServed(
      engine.mintEnrollment(
        userId: _userId,
        identity: pair,
        createdAtMs: 1755600000000,
      ),
    );
    final dak = engine.exportDakForPersistence();
    controller = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _Identity(pair),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: engine,
      dakStore: _StubDakStore(
        DakRecord(
          userId: _userId,
          dakPub: dak['dakPub']!,
          dakPriv: dak['dakPriv']!,
          createdAtMs: 1755600000000,
        ),
      ),
    )
      // A verified two-device list, the way the screen holds it.
      ..onDeviceList({
        'userId': _userId,
        'authorization': authorization,
      });
    await pumpEventQueue();
    controller.verifiedList = const DeviceList(
      userId: _userId,
      version: 2,
      devices: [
        DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
        DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
      ],
    );
  });

  tearDown(() => controller.dispose());

  int count(String event) => emitted.where((e) => e.$1 == event).length;

  test('a revoke whose socket died can be asked again', () async {
    await controller.revokeDevice(2);
    expect(count('revokeDevice'), 1);
    expect(controller.revokingDeviceId, 2);

    controller.onSessionLost();

    expect(controller.revokingDeviceId, isNull);
    expect(controller.revokeError, isNotNull);
    await controller.revokeDevice(2);
    expect(count('revokeDevice'), 2);
  });

  test('a rename whose socket died can be asked again', () async {
    await controller.renameDevice(2, 'Kitchen');
    expect(count('updateDeviceList'), 1);
    expect(controller.renamingDeviceId, 2);

    controller.onSessionLost();

    expect(controller.renamingDeviceId, isNull);
    expect(controller.renameError, isNotNull);
    await controller.renameDevice(2, 'Kitchen');
    expect(count('updateDeviceList'), 2);
  });

  test('an enrolment whose socket died stops spinning', () async {
    await controller.enableLinking(platform: 'android');
    expect(count('enrollDeviceAuthority'), 1);
    expect(controller.enrolling, isTrue);

    controller.onSessionLost();

    expect(controller.enrolling, isFalse);
    expect(controller.enrollError, 'enroll_failed');
  });

  test('a stage whose socket died fails instead of waiting for ever', () async {
    await controller.startPrimaryFlow(
      LinkOobCode(
        provisioningId: '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f',
        ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
        platform: 'web',
      ).encode(),
    );
    controller.onProvisioningHelloAck({'success': true, 'deviceId': 3});
    await controller.approvePrimary();
    expect(count('provisionDevice'), 1);
    expect(controller.primaryStep, PrimaryLinkStep.staging);

    controller.onSessionLost();

    expect(controller.primaryStep, PrimaryLinkStep.failed);
    expect(controller.primaryError, 'stage_failed');
  });

  test('a marker nothing was sent for is left alone', () async {
    controller.onSessionLost();

    expect(controller.revokeError, isNull);
    expect(controller.renameError, isNull);
    expect(controller.enrollError, isNull);
    expect(controller.primaryStep, PrimaryLinkStep.idle);
  });
}
