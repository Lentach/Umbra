// CONT-06 — a primary-side stage parked in its identity read must not outlive
// the ceremony it belongs to.
//
// `_stageProvisionDevice` awaits `ownIdentityKeyPair()` and then reads the
// ephemeral state the ceremony holds. A cancel (or a screen dispose) during
// that await used to leave `_ephPubP` null: the stage threw into its own
// catch and reported `failed / stage_failed` on a ceremony nobody was running,
// and a restart in between made it emit the IK-bearing blob under the OLD
// provisioningId with the NEW ceremony's ephemeral.

import 'dart:async';
import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _userId = 7;

class _GatedIdentity implements LinkIdentityGateway {
  _GatedIdentity(this.pair);
  final IdentityKeyPair pair;

  /// When set, the next `ownIdentityKeyPair` waits on it.
  Completer<void>? gate;

  @override
  Future<String?> ownIdentityPublicKeyBase64() async =>
      base64Encode(pair.getPublicKey().serialize());

  @override
  Future<dynamic> ownIdentityKeyPair() async {
    final g = gate;
    if (g != null) {
      gate = null;
      await g.future;
    }
    return pair;
  }

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

String _code(String provisioningId) => LinkOobCode(
  provisioningId: provisioningId,
  ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
  platform: 'web',
).encode();

void main() {
  late List<(String, dynamic)> emitted;
  late LinkCeremonyController controller;
  late _GatedIdentity identity;

  setUp(() async {
    emitted = [];
    final pair = generateIdentityKeyPair();
    identity = _GatedIdentity(pair);
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
      identity: identity,
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
      // The verified own list is in hand, so the stage goes straight to the
      // identity read.
      ..onDeviceList({'userId': _userId, 'authorization': authorization});
    await pumpEventQueue();
    expect(controller.verifiedList, isNotNull);
  });

  tearDown(() => controller.dispose());

  int count(String event) => emitted.where((e) => e.$1 == event).length;

  Future<void> reachSas(String provisioningId) async {
    await controller.startPrimaryFlow(_code(provisioningId));
    controller.onProvisioningHelloAck({'success': true, 'deviceId': 2});
    expect(controller.primaryStep, PrimaryLinkStep.showSas);
  }

  test('a cancel during the identity read leaves the ceremony cancelled, '
      'not failed', () async {
    await reachSas('3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f');
    final release = identity.gate = Completer<void>();
    final staging = controller.approvePrimary();
    expect(controller.primaryStep, PrimaryLinkStep.staging);

    controller.cancelPrimary();
    var notified = 0;
    controller.addListener(() => notified++);
    release.complete();
    await staging;

    expect(controller.primaryStep, PrimaryLinkStep.idle);
    expect(controller.primaryError, isNull);
    expect(count('provisionDevice'), 0);
    expect(notified, 0, reason: 'a cancelled stage must not wake the screen');
  });

  test('a stage parked across a cancel and a restart never emits under the '
      'old ceremony', () async {
    await reachSas('3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f');
    final release = identity.gate = Completer<void>();
    final staging = controller.approvePrimary();

    controller.cancelPrimary();
    await reachSas('aaaaaaaa-9b7d-4c5a-8e2f-1a6b3c9d0e4f');
    release.complete();
    await staging;

    expect(count('provisionDevice'), 0);
    expect(controller.primaryStep, PrimaryLinkStep.showSas);
  });
}
