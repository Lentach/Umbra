// CONT-05 — the new-device blob handler is single-flight and honours an
// abort that lands while it is parked.
//
// `onProvisioningBlob` accepted a blob in `showSas`, and the step left
// `showSas` only AFTER the adopt and the passcode wrap returned: a second
// delivery in that window started a second adopt beside the first (each one
// wipes the account namespace on a stale install). And an abort during
// those awaits saw nothing adopted, skipped the discard, and was then
// overwritten by the handler finishing: `completing`, a complete emit, and
// an adopted identity on a device that had aborted (abort hygiene I1).

import 'dart:async';
import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/passcode_wrap_hook.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';
import 'package:flutter_test/flutter_test.dart';

const _userId = 7;
const _provisioningId = '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f';

/// A gateway whose adopt parks until the test releases it, and which keeps
/// the device's key state the way the real service does: an adopt lands
/// material, a discard removes it.
class _ParkedIdentity implements LinkIdentityGateway {
  final List<Completer<void>> gates = [];
  int running = 0;
  int maxRunning = 0;
  int discarded = 0;

  /// Whether this device holds adopted key material right now.
  bool holdsIdentity = false;

  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async => null;

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) async {
    final gate = Completer<void>();
    gates.add(gate);
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      await gate.future;
      holdsIdentity = true;
    } finally {
      running--;
    }
  }

  @override
  Future<void> discardProvisionedIdentity(int userId) async {
    discarded++;
    holdsIdentity = false;
  }
}

class _NoDakStore extends DakStore {
  @override
  Future<DakRecord?> read({required int userId}) async => null;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late List<(String, dynamic)> emitted;
  late _ParkedIdentity identity;
  late LinkCeremonyController controller;

  setUp(() {
    emitted = [];
    linkCeremonyActive.value = false;
    identity = _ParkedIdentity();
    controller = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: identity,
      adoptSession: (_) async {},
      reconnect: (_) async {},
      dakStore: _NoDakStore(),
    );
    addTearDown(controller.dispose);
    addTearDown(() => PasscodeWrapHook.afterRawKeysLanded = null);
  });

  int count(String event) => emitted.where((e) => e.$1 == event).length;

  /// Classic flow up to the SAS screen; returns a blob message the primary
  /// would have staged for this stage (sealed under the real session keys).
  Future<Map<String, dynamic>> reachSasAndSealBlob() async {
    await controller.startNewDeviceFlow(platform: 'web');
    controller.onProvisioningOpened({
      'success': true,
      'provisioningId': _provisioningId,
    });
    final ephPubN = LinkOobCode.tryParse(controller.oobCode!)!.ephPub;
    final ephP = generateLinkEphemeral();
    final ephPubP = linkEphemeralPublicBytes(ephP);
    controller.onProvisioningHelloRelay({
      'provisioningId': _provisioningId,
      'ephPubP': base64Encode(ephPubP),
    });
    expect(controller.newDeviceStep, NewDeviceLinkStep.showSas);
    final keys = deriveLinkBlobKeys(
      sharedSecret: linkSharedSecret(
        theirEphPub: ephPubN,
        ownEphPriv: ephP.privateKey,
      ),
      transcript: linkTranscript(
        provisioningId: _provisioningId,
        ephPubN: ephPubN,
        ephPubP: ephPubP,
      ),
    );
    final blob = sealLinkBlob(
      keys: keys,
      payload: const LinkBlobPayload(
        userId: _userId,
        deviceId: 2,
        ikPub: 'aWtQdWI=',
        ikPriv: 'aWtQcml2',
        dakPub: 'ZGFrUHVi',
        enrollmentCreatedAt: 1755600000000,
        enrollmentSig: 'c2ln',
      ),
    );
    return {'provisioningId': _provisioningId, 'blob': base64Encode(blob)};
  }

  test(
    'a second blob while the first adopt is running never adopts beside it',
    () async {
      final blob = await reachSasAndSealBlob();

      controller
        ..onProvisioningBlob(blob)
        ..onProvisioningBlob(blob);
      await _settle();
      for (final gate in List.of(identity.gates)) {
        gate.complete();
      }
      await _settle();
      // Anything queued behind the first run is released too.
      for (final gate in identity.gates.where((g) => !g.isCompleted).toList()) {
        gate.complete();
      }
      await _settle();

      expect(identity.maxRunning, 1);
      expect(controller.newDeviceStep, NewDeviceLinkStep.completing);
      expect(count('provisioningComplete'), greaterThanOrEqualTo(1));
    },
  );

  test(
    'a NEW blob after stale_version re-runs the adopt and completes again',
    () async {
      final blob = await reachSasAndSealBlob();

      controller.onProvisioningBlob(blob);
      await _settle();
      identity.gates.single.complete();
      await _settle();
      expect(count('provisioningComplete'), 1);

      // The primary lost a version race: it re-signs and re-stages.
      controller
        ..onProvisioningCompleted({'success': false, 'error': 'stale_version'})
        ..onProvisioningBlob(blob);
      await _settle();
      expect(identity.gates, hasLength(2));
      identity.gates.last.complete();
      await _settle();

      expect(identity.maxRunning, 1);
      expect(controller.newDeviceStep, NewDeviceLinkStep.completing);
      expect(count('provisioningComplete'), 2);
    },
  );

  test(
    'an abort while the adopt is parked stays aborted and leaves no identity',
    () async {
      final blob = await reachSasAndSealBlob();
      controller.onProvisioningBlob(blob);
      await _settle();
      expect(identity.gates, hasLength(1));

      // The relay's cancel push (the other side walked away).
      controller.onProvisioningCancelled({'provisioningId': _provisioningId});
      await _settle();
      expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);

      identity.gates.single.complete();
      await _settle();

      expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);
      expect(controller.newDeviceError, 'cancelled');
      expect(count('provisioningComplete'), 0);
      expect(identity.holdsIdentity, isFalse);
      expect(linkCeremonyActive.value, isFalse);
    },
  );

  test(
    'an abort while the passcode wrap is parked stays aborted too',
    () async {
      final wrap = Completer<void>();
      PasscodeWrapHook.afterRawKeysLanded = () => wrap.future;
      final blob = await reachSasAndSealBlob();
      controller.onProvisioningBlob(blob);
      await _settle();
      identity.gates.single.complete();
      await _settle();
      expect(identity.holdsIdentity, isTrue);

      await controller.abortNewDevice('cancelled_locally');
      wrap.complete();
      await _settle();

      expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);
      expect(controller.newDeviceError, 'cancelled_locally');
      expect(count('provisioningComplete'), 0);
      expect(identity.holdsIdentity, isFalse);
    },
  );
}
