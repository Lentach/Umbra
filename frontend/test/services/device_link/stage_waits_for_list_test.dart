// Amendment (lxx) — staging a provision waits for the verified list.
//
// Observed live (2026-09-03, first deep-link run): on a cold boot the
// Keystore read that resolves `holdsDak` beat the list fetch, the parked
// QR code started the ceremony at once, and Approve failed with
// `list_unavailable` — the stage was valid, only the list had not arrived.
// The manual path has the same latent race. Pins: (1) a missing list at
// staging asks for the list and re-stages when it verifies, emitting
// `provisionDevice` exactly once; (2) a list that does NOT verify fails the
// ceremony with the reason instead of leaving it in `staging` forever;
// (3) a not-enrolled answer does the same.

import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _userId = 7;

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

  @override
  Future<void> settleProvisionedIdentity(int userId) async {}
}

class _StubDakStore extends DakStore {
  _StubDakStore(this._record);
  final DakRecord? _record;
  @override
  Future<DakRecord?> read({required int userId}) async => _record;
}

/// The enrollment as the SERVER serves it back on `deviceList`: the upload
/// shape plus the two fields the verifier reads by their served names.
Map<String, dynamic> _asServed(Map<String, dynamic> enrollment) => {
  'dakPub': enrollment['dakPub'],
  'enrollmentSig': enrollment['enrollmentSig'],
  'enrollmentCreatedAt': enrollment['createdAt'],
  'listVersion': 1,
  'listCanonical': enrollment['listCanonical'],
  'listSignature': enrollment['listSignature'],
};

void main() {
  late List<(String, dynamic)> emitted;
  late LinkCeremonyController controller;
  late Map<String, dynamic> authorization;

  setUp(() {
    emitted = [];
    final identity = generateIdentityKeyPair();
    final engine = DeviceAuthorityEngine();
    authorization = _asServed(
      engine.mintEnrollment(
        userId: _userId,
        identity: identity,
        createdAtMs: 1755600000000,
      ),
    );
    final dak = engine.exportDakForPersistence();
    controller = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _Identity(identity),
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
    );
  });

  tearDown(() => controller.dispose());

  int count(String event) => emitted.where((e) => e.$1 == event).length;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Drive the primary flow to the SAS step WITHOUT a list in hand — the
  /// deep-link cold-boot shape.
  Future<void> reachSasWithoutList() async {
    final code = LinkOobCode(
      provisioningId: '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f',
      ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
      platform: 'web',
    ).encode();
    await controller.startPrimaryFlow(code);
    expect(controller.primaryStep, PrimaryLinkStep.awaitingHelloAck);
    controller.onProvisioningHelloAck({'success': true, 'deviceId': 2});
    expect(controller.primaryStep, PrimaryLinkStep.showSas);
    expect(controller.verifiedList, isNull);
  }

  test(
    'approve without a list fetches it, then stages once it verifies',
    () async {
      await reachSasWithoutList();
      emitted.clear();

      await controller.approvePrimary();

      // Not failed, not staged: asked for the list.
      expect(controller.primaryStep, PrimaryLinkStep.staging);
      expect(controller.primaryError, isNull);
      expect(count('getDeviceList'), 1);
      expect(count('provisionDevice'), 0);

      controller.onDeviceList({
        'userId': _userId,
        'authorization': authorization,
      });
      await settle();

      expect(controller.primaryStep, PrimaryLinkStep.staging);
      expect(count('provisionDevice'), 1);
    },
  );

  test('a list that does not verify fails the ceremony, never hangs', () async {
    await reachSasWithoutList();
    await controller.approvePrimary();
    expect(controller.primaryStep, PrimaryLinkStep.staging);

    // Same shape, wrong identity: the enrollment signature will not verify.
    final foreign = _asServed(
      DeviceAuthorityEngine().mintEnrollment(
        userId: _userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      ),
    );
    controller.onDeviceList({'userId': _userId, 'authorization': foreign});
    await settle();

    expect(controller.primaryStep, PrimaryLinkStep.failed);
    expect(controller.primaryError, 'list_unavailable');
    expect(count('provisionDevice'), 0);
  });

  test('a malformed answer while staging fails, never hangs', () async {
    await reachSasWithoutList();
    await controller.approvePrimary();
    expect(controller.primaryStep, PrimaryLinkStep.staging);

    controller.onDeviceList({'userId': _userId, 'authorization': 'junk'});

    expect(controller.primaryStep, PrimaryLinkStep.failed);
    expect(controller.primaryError, 'list_unavailable');
  });

  test('a not-enrolled answer while staging fails, never hangs', () async {
    await reachSasWithoutList();
    await controller.approvePrimary();
    expect(controller.primaryStep, PrimaryLinkStep.staging);

    controller.onDeviceList({'userId': _userId, 'authorization': null});

    expect(controller.primaryStep, PrimaryLinkStep.failed);
    expect(controller.primaryError, 'list_unavailable');
    expect(count('provisionDevice'), 0);
  });
}
