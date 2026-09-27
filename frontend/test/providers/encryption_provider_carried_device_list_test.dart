import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata-privacy slice (e), decisions 50–51, E50a–E50c: a friend's device
/// list carried INSIDE E2E (a `list_update`, or the new device's own
/// handoff) is adopted with no server lookup — but only under the DAK this
/// device last verified from the server. Every linked device, a revoked one
/// too, holds the account identity key, so a list signed by a DAK the
/// identity endorsed is NOT enough (E50a).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;
  const peerId = 42;

  late EncryptionProvider provider;
  late List<Map<String, dynamic>> emitted;
  late DeviceAuthorityEngine peerEngine;
  late IdentityKeyPair peerIdentity;
  late Map<String, dynamic> enrollment;

  List<DeviceListEntry> devicesUpTo(int n, {Set<int> revoked = const {}}) => [
    for (var d = 1; d <= n; d++)
      DeviceListEntry(
        deviceId: d,
        platform: 'web',
        addedAtMs: d * 1000,
        revokedAtMs: revoked.contains(d) ? 9000 : null,
      ),
  ];

  Map<String, dynamic> signedBy(
    DeviceAuthorityEngine engine,
    Map<String, dynamic> enrollmentPayload,
    int version,
    List<DeviceListEntry> devices,
  ) {
    final signed = engine.signList(
      DeviceList(userId: peerId, version: version, devices: devices),
    );
    return {
      'dakPub': enrollmentPayload['dakPub'],
      'enrollmentSig': enrollmentPayload['enrollmentSig'],
      'enrollmentCreatedAt': enrollmentPayload['createdAt'],
      'listVersion': version,
      'listSignature': signed['listSignature'],
      'listCanonical': signed['listCanonical'],
    };
  }

  Map<String, dynamic> genuine(int version, List<DeviceListEntry> devices) =>
      signedBy(peerEngine, enrollment, version, devices);

  /// A list a REVOKED device of the peer can mint: it holds the account
  /// identity key (link blob), so it endorses a DAK of its own.
  Map<String, dynamic> forgedByRevokedDevice(
    int version,
    List<DeviceListEntry> devices,
  ) {
    final rogue = DeviceAuthorityEngine();
    final rogueEnrollment = rogue.mintEnrollment(
      userId: peerId,
      identity: peerIdentity,
      createdAtMs: 555,
    );
    return signedBy(rogue, rogueEnrollment, version, devices);
  }

  int lookups() =>
      emitted.where((e) => e['event'] == 'getDeviceList').length;

  /// Serves [answer] to every `getDeviceList`.
  void serve(Map<String, dynamic>? Function() answer) {
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        provider.onDeviceList({'userId': peerId, 'authorization': answer()});
      }
    });
  }

  Future<EncryptionProvider> freshProvider() async {
    final p = EncryptionProvider();
    p.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'checkOwnKeyBundle') p.onOwnKeyBundleStatus({'exists': false});
    });
    await p.initializeE2E(ownUserId);
    return p;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = <Map<String, dynamic>>[];
    provider = await freshProvider();
    peerEngine = DeviceAuthorityEngine();
    peerIdentity = generateIdentityKeyPair();
    enrollment = peerEngine.mintEnrollment(
      userId: peerId,
      identity: peerIdentity,
      createdAtMs: 1234567890,
    );
    await provider.encryptionService.debugSavePeerIdentity(
      peerId,
      base64Encode(peerIdentity.getPublicKey().serialize()),
    );
  });

  /// The peer's list as the SERVER verified it: v1, devices 1–2.
  Future<void> serverVerified() async {
    serve(() => genuine(1, devicesUpTo(2)));
    await provider.getVerifiedDeviceList(peerId);
    emitted.clear();
  }

  test('a newer carried list under the pinned DAK is adopted with no lookup '
      '(decision 50)', () async {
    await serverVerified();

    final outcome = await provider.adoptCarriedDeviceList(
      peerId,
      genuine(2, devicesUpTo(3)),
    );

    expect(outcome, CarriedListOutcome.adopted);
    expect(provider.cachedDeviceList(peerId)?.version, 2);
    expect(provider.cachedDeviceList(peerId)?.liveDeviceIds, [1, 2, 3]);
    expect(lookups(), 0, reason: 'no server lookup names the pair');
  });

  test('E50a: a list signed by a DAK the account identity endorsed but the '
      'server never served is NOT adopted — one server lookup decides '
      '(falsification: a revoked device holds ikPriv)', () async {
    await serverVerified();
    serve(() => genuine(1, devicesUpTo(2)));

    final outcome = await provider.adoptCarriedDeviceList(
      peerId,
      forgedByRevokedDevice(5, devicesUpTo(4, revoked: {1, 2})),
    );

    expect(outcome, CarriedListOutcome.refetched);
    expect(
      provider.cachedDeviceList(peerId)?.liveDeviceIds,
      [1, 2],
      reason: 'the forged list must never enter the cache',
    );
    expect(lookups(), 1);
    await pumpEventQueue();
    expect(
      provider.peersWithChangedIdentity,
      isNot(contains(peerId)),
      reason: 'a carried list is peer data, never an I7 alarm',
    );
  });

  test('E50a: the fallback lookup is spent once per account per session', () async {
    await serverVerified();
    serve(() => genuine(1, devicesUpTo(2)));

    await provider.adoptCarriedDeviceList(
      peerId,
      forgedByRevokedDevice(5, devicesUpTo(3)),
    );
    final second = await provider.adoptCarriedDeviceList(
      peerId,
      forgedByRevokedDevice(6, devicesUpTo(3)),
    );

    expect(second, CarriedListOutcome.refused);
    expect(lookups(), 1, reason: 'a forger must not buy a lookup per frame');
  });

  test('a carried list at or below the held version is ignored before any '
      'check — a replay is never a rollback alarm', () async {
    serve(() => genuine(3, devicesUpTo(3)));
    await provider.getVerifiedDeviceList(peerId);
    emitted.clear();

    final outcome = await provider.adoptCarriedDeviceList(
      peerId,
      genuine(2, devicesUpTo(2)),
    );

    expect(outcome, CarriedListOutcome.stale);
    expect(provider.cachedDeviceList(peerId)?.version, 3);
    expect(lookups(), 0);
    await pumpEventQueue();
    expect(provider.peersWithChangedIdentity, isNot(contains(peerId)));
  });

  test('a carried list for an account never verified from the server is not '
      'adopted: the pin comes only from the server', () async {
    serve(() => genuine(2, devicesUpTo(3)));

    final outcome = await provider.adoptCarriedDeviceList(
      peerId,
      genuine(2, devicesUpTo(3)),
    );

    expect(outcome, CarriedListOutcome.refetched);
    expect(lookups(), 1);
    expect(provider.cachedDeviceList(peerId)?.version, 2);
  });

  test('a carried "not enrolled" is never adopted', () async {
    await serverVerified();

    final outcome = await provider.adoptCarriedDeviceList(peerId, null);

    expect(outcome, CarriedListOutcome.refused);
    expect(provider.cachedDeviceList(peerId)?.liveDeviceIds, [1, 2]);
    expect(lookups(), 0);
  });

  test('decision 51: a peer list survives a restart — the next process holds '
      'it with no lookup, and the DAK pin with it', () async {
    await serverVerified();
    await provider.adoptCarriedDeviceList(peerId, genuine(2, devicesUpTo(3)));

    final next = await freshProvider();
    emitted.clear();

    expect(next.cachedDeviceList(peerId)?.version, 2);
    expect(next.cachedDeviceList(peerId)?.liveDeviceIds, [1, 2, 3]);
    next.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
      if (event == 'getDeviceList') {
        next.onDeviceList({
          'userId': peerId,
          'authorization': genuine(2, devicesUpTo(3)),
        });
      }
    });

    final forged = await next.adoptCarriedDeviceList(
      peerId,
      forgedByRevokedDevice(9, devicesUpTo(4)),
    );
    expect(
      forged,
      CarriedListOutcome.refetched,
      reason: 'the restored pin still refuses a DAK the server never served',
    );
    expect(next.cachedDeviceList(peerId)?.version, 2);
  });

  test("only a box peer's list is kept: an old-path peer's is looked up "
      'afresh after a restart, as before slice (e)', () async {
    serve(() => genuine(1, devicesUpTo(2)));
    await provider.getVerifiedDeviceList(peerId);
    expect((await freshProvider()).cachedDeviceList(peerId), isNull);

    provider
      ..keepsDeviceListFor = ((peer) => peer == peerId)
      ..invalidateDeviceList(peerId);
    serve(() => genuine(2, devicesUpTo(3)));
    await provider.getVerifiedDeviceList(peerId);
    await pumpEventQueue();
    expect((await freshProvider()).cachedDeviceList(peerId)?.version, 2);
  });
}
