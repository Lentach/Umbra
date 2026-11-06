// The §5.1 provisioning ceremony, as a reusable harness helper.
//
// `full_stack_e2e_test.dart` grew its own copy of this inline, closed over
// alice, because for three tickets alice was the only enrolled account. She is
// no longer: a §6.2 reset is destructive, so it needs an account nothing else
// depends on, and that account still has to link a second device to have more
// than one `(identity, deviceId)` partition to reason about.
//
// Deliberately NOT retro-fitted onto the main suite in the same change. That
// file's ceremony is load-bearing for falsifications 8/18/20 and the §5.5
// revocation test, and swapping it out for this while proving something else
// would put a refactor and a proof in one commit.

import 'dart:convert';

import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'e2e_test_client.dart';

/// A primary account, its device authority, and its identity — everything the
/// ceremony needs from the approving side.
class CeremonyPrimary {
  CeremonyPrimary({
    required this.client,
    required this.engine,
    required this.identity,
  });

  final E2eClient client;
  final DeviceAuthorityEngine engine;
  final IdentityKeyPair identity;

  /// The account's authorization as the server currently serves it.
  Future<Map<String, dynamic>> currentAuth() async {
    final own = await client.fetchDeviceList(client.userId);
    final auth = own['authorization'];
    if (auth is! Map) {
      throw StateError(
        '${client.label} is not enrolled — §5.1 needs a pinned DAK',
      );
    }
    return auth.cast<String, dynamic>();
  }

  /// DAK-signs the STORED list plus one entry for [deviceId] (platform label,
  /// no name — amendment (i)) at version stored+1.
  Future<Map<String, dynamic>> signAddedDevice(int deviceId) async {
    final auth = await currentAuth();
    final stored = parseCanonicalDeviceList(
      base64Decode(auth['listCanonical'] as String),
    );
    return engine.signList(
      DeviceList(
        userId: client.userId,
        version: stored.version + 1,
        devices: [
          ...stored.devices,
          DeviceListEntry(
            deviceId: deviceId,
            platform: 'harness',
            addedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );
  }

  /// The IK-bearing blob the primary seals for the new device.
  LinkBlobPayload blobFor(int deviceId, Map<String, dynamic> auth) =>
      LinkBlobPayload(
        userId: client.userId,
        deviceId: deviceId,
        ikPub: base64Encode(identity.getPublicKey().serialize()),
        ikPriv: base64Encode(identity.getPrivateKey().serialize()),
        dakPub: auth['dakPub'] as String,
        enrollmentCreatedAt: auth['enrollmentCreatedAt'] as int,
        enrollmentSig: auth['enrollmentSig'] as String,
      );
}

/// Links one new device of [primary] through the REAL ceremony and returns the
/// rebound client plus its assigned deviceId.
///
/// Every step is the production wire path: open → hello → SAS-derived blob →
/// staged signed list → one-shot commit → rebind under the deviceId-bound
/// token. Nothing here is short-circuited, because a device whose activation
/// was faked would prove nothing about what a reset then tears down.
Future<(E2eClient, int)> linkNewDevice(
  CeremonyPrimary primary,
  String label,
  String baseUrl,
) async {
  final device = E2eClient(label, baseUrl)..adoptAccountFrom(primary.client);
  await device.connectSocket();

  final ephN = generateLinkEphemeral();
  final opened = await device.openProvisioning();
  expect(opened['success'], isTrue, reason: '$opened');
  final provisioningId = opened['provisioningId'] as String;

  final ephP = generateLinkEphemeral();
  final ack = await primary.client.provisioningHello(
    provisioningId: provisioningId,
    ephPubP: base64Encode(linkEphemeralPublicBytes(ephP)),
  );
  expect(ack['success'], isTrue, reason: '$ack');
  final assignedId = ack['deviceId'] as int;

  final staged = await primary.signAddedDevice(assignedId);
  final auth = await primary.currentAuth();
  final transcript = linkTranscript(
    provisioningId: provisioningId,
    ephPubN: linkEphemeralPublicBytes(ephN),
    ephPubP: linkEphemeralPublicBytes(ephP),
  );
  final sealed = sealLinkBlob(
    keys: deriveLinkBlobKeys(
      sharedSecret: linkSharedSecret(
        theirEphPub: linkEphemeralPublicBytes(ephN),
        ownEphPriv: ephP.privateKey,
      ),
      transcript: transcript,
    ),
    payload: primary.blobFor(assignedId, auth),
  );
  final acked = await primary.client.provisionDevice({
    'provisioningId': provisioningId,
    'blob': base64Encode(sealed),
    'listCanonical': staged['listCanonical'],
    'listSignature': staged['listSignature'],
  });
  expect(acked['success'], isTrue, reason: '$acked');

  final completed = await device.provisioningComplete(provisioningId);
  expect(completed['success'], isTrue, reason: '$completed');

  // Rebind: only now is this socket authenticated AS the new device, which is
  // what makes the server file its key material under (userId, assignedId).
  device.socketService.disconnect();
  device.accessToken = completed['access_token'] as String;
  await device.connectSocket();

  return (device, assignedId);
}
