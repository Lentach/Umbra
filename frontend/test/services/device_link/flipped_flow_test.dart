// Amendment (lxxvii) clauses 2–3 — the FLIPPED ceremony (primary displays a
// `p` code, the new device scans and says hello) plus the role gates.
//
// Falsification F5 (both directions): a code fed to the wrong side is refused
// with the stable `wrong_code_role` BEFORE any emit — a `p` key in the N slot
// would derive a SAS the other side can never match.
//
// The end-to-end test wires TWO real controllers through a hand-driven relay
// shaped exactly like chat-provisioning.service.ts (ack to the hello caller,
// `provisioningHello { provisioningId, ephPubP, deviceId }` to the opener)
// and asserts the SAS is EQUAL on both sides — the fixed N-then-P transcript
// with role-assigned slots is the whole point of the flip.
//
// (lxxvi) clause 2: `linkCeremonyActive` is raised from the first emit until
// the terminal state of either flow, including aborts.

import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/passcode_wrap_hook.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _userId = 7;
const _provisioningId = '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f';

class _Identity implements LinkIdentityGateway {
  _Identity(this.pair);
  final IdentityKeyPair pair;

  /// Recorded adopt calls (new-device side assertions).
  final List<Map<String, Object?>> adopted = [];
  int discarded = 0;

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
  }) async {
    adopted.add({
      'userId': userId,
      'ikPub': ikPubBase64,
      'ikPriv': ikPrivBase64,
      'dakPub': dakPubBase64,
    });
  }

  @override
  Future<void> discardProvisionedIdentity(int userId) async {
    discarded++;
  }
}

class _StubDakStore extends DakStore {
  _StubDakStore([this.record]);
  DakRecord? record;
  @override
  Future<DakRecord?> read({required int userId}) async => record;
  @override
  Future<void> persistArmed(DakRecord next) async {
    record = next;
  }
}

/// The enrollment as the SERVER serves it back on `deviceList`.
Map<String, dynamic> _asServed(Map<String, dynamic> enrollment) => {
  'dakPub': enrollment['dakPub'],
  'enrollmentSig': enrollment['enrollmentSig'],
  'enrollmentCreatedAt': enrollment['createdAt'],
  'listVersion': 1,
  'listCanonical': enrollment['listCanonical'],
  'listSignature': enrollment['listSignature'],
};

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late List<(String, dynamic)> emitted;

  LinkCeremonyController keylessController({
    List<Map<String, dynamic>>? adoptedTokens,
    _Identity? identity,
  }) => LinkCeremonyController(
    userId: _userId,
    emit: (event, data) => emitted.add((event, data)),
    identity: identity ?? _Identity(generateIdentityKeyPair()),
    adoptSession: (tokens) async => adoptedTokens?.add(tokens),
    reconnect: (_) async {},
    dakStore: _StubDakStore(),
  );

  setUp(() {
    emitted = [];
    linkCeremonyActive.value = false;
  });

  int count(String event) => emitted.where((e) => e.$1 == event).length;
  dynamic payloadOf(String event) =>
      emitted.lastWhere((e) => e.$1 == event).$2;

  String nCode() => LinkOobCode(
    provisioningId: _provisioningId,
    ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
    platform: 'web',
  ).encode();

  String pCode() => LinkOobCode(
    provisioningId: _provisioningId,
    ephPub: linkEphemeralPublicBytes(generateLinkEphemeral()),
    platform: 'web',
    role: LinkRole.primary,
  ).encode();

  group('role gates (F5)', () {
    test('startPrimaryFlow refuses a p code with wrong_code_role', () async {
      final engine = DeviceAuthorityEngine();
      final enrollment = engine.mintEnrollment(
        userId: _userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
      final dak = engine.exportDakForPersistence();
      final controller = LinkCeremonyController(
        userId: _userId,
        emit: (event, data) => emitted.add((event, data)),
        identity: _Identity(generateIdentityKeyPair()),
        adoptSession: (_) async {},
        reconnect: (_) async {},
        engine: engine,
        dakStore: _StubDakStore(
          DakRecord(
            userId: _userId,
            dakPub: dak['dakPub']!,
            dakPriv: dak['dakPriv']!,
            createdAtMs: enrollment['createdAt'] as int,
          ),
        ),
      );
      addTearDown(controller.dispose);

      await controller.startPrimaryFlow(pCode());

      expect(controller.primaryStep, PrimaryLinkStep.failed);
      expect(controller.primaryError, 'wrong_code_role');
      expect(count('provisioningHello'), 0);
    });

    test(
      'startNewDeviceFromCode refuses an n code without touching the flow',
      () async {
        final controller = keylessController();
        addTearDown(controller.dispose);

        final refusal = await controller.startNewDeviceFromCode(
          nCode(),
          platform: 'web',
        );

        expect(refusal, 'wrong_code_role');
        expect(controller.newDeviceStep, NewDeviceLinkStep.idle);
        expect(emitted, isEmpty);
      },
    );

    test('startNewDeviceFromCode refuses garbage as invalid_code', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);

      expect(
        await controller.startNewDeviceFromCode('junk', platform: 'web'),
        'invalid_code',
      );
      expect(emitted, isEmpty);
    });
  });

  test(
    'a scanned p code cancels this device\'s own open stage first',
    () async {
      final controller = keylessController();
      addTearDown(controller.dispose);

      await controller.startNewDeviceFlow(platform: 'web');
      expect(payloadOf('openProvisioning'), {'role': 'new'});
      controller.onProvisioningOpened({
        'success': true,
        'provisioningId': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      });
      expect(controller.newDeviceStep, NewDeviceLinkStep.showCode);

      final refusal = await controller.startNewDeviceFromCode(
        pCode(),
        platform: 'web',
      );

      expect(refusal, isNull);
      expect(count('cancelProvisioning'), 1);
      expect(payloadOf('cancelProvisioning'), {
        'provisioningId': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      });
      expect(controller.newDeviceStep, NewDeviceLinkStep.awaitingHelloAck);
      expect(payloadOf('provisioningHello')['provisioningId'], _provisioningId);
    },
  );

  test('flipped flow end to end: SAS equal, blob adopted, rebind done', () async {
    // --- Primary controller (enrolled, holds the DAK) ---
    final primaryEmitted = <(String, dynamic)>[];
    final engine = DeviceAuthorityEngine();
    final primaryIdentity = generateIdentityKeyPair();
    final authorization = _asServed(
      engine.mintEnrollment(
        userId: _userId,
        identity: primaryIdentity,
        createdAtMs: 1755600000000,
      ),
    );
    final dak = engine.exportDakForPersistence();
    final primary = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => primaryEmitted.add((event, data)),
      identity: _Identity(primaryIdentity),
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
    addTearDown(primary.dispose);

    // --- New-device controller (keyless) ---
    final newIdentity = _Identity(generateIdentityKeyPair());
    final adoptedTokens = <Map<String, dynamic>>[];
    final newDevice = keylessController(
      adoptedTokens: adoptedTokens,
      identity: newIdentity,
    );
    addTearDown(newDevice.dispose);

    // Primary opens with role 'primary' and shows a p code.
    await primary.startPrimaryShowFlow(platform: 'web');
    expect(primaryEmitted.last.$1, 'openProvisioning');
    expect(primaryEmitted.last.$2, {'role': 'primary'});
    primary.onProvisioningOpened({
      'success': true,
      'provisioningId': _provisioningId,
    });
    expect(primary.primaryStep, PrimaryLinkStep.showCode);
    final code = primary.primaryOobCode!;
    expect(code.split('.')[5], 'p');

    // New device scans the p code and says hello.
    final refusal = await newDevice.startNewDeviceFromCode(
      code,
      platform: 'web',
    );
    expect(refusal, isNull);
    final hello =
        payloadOf('provisioningHello') as Map<String, dynamic>;
    expect(hello['provisioningId'], _provisioningId);

    // Server: ack to the caller, relay (with deviceId) to the opener.
    newDevice.onProvisioningHelloAck({'success': true, 'deviceId': 2});
    primary.onProvisioningHelloRelay({
      'provisioningId': _provisioningId,
      'ephPubP': hello['ephPubP'],
      'deviceId': 2,
    });

    expect(newDevice.newDeviceStep, NewDeviceLinkStep.showSas);
    expect(primary.primaryStep, PrimaryLinkStep.showSas);
    expect(primary.primarySas, isNotNull);
    expect(primary.primarySas, newDevice.newDeviceSas);
    expect(primary.assignedDeviceId, 2);

    // Primary has its verified list, approves, stages the blob.
    primary.onDeviceList({'userId': _userId, 'authorization': authorization});
    await primary.approvePrimary();
    await _settle();
    final staged = primaryEmitted
        .lastWhere((e) => e.$1 == 'provisionDevice')
        .$2 as Map<String, dynamic>;
    expect(staged['provisioningId'], _provisioningId);

    // (lxxvi) clause 3: the adopt lands raw keys — the wrap hook must run
    // right after, before the complete emit.
    var wrapRuns = 0;
    PasscodeWrapHook.afterRawKeysLanded = () async => wrapRuns++;
    addTearDown(() => PasscodeWrapHook.afterRawKeysLanded = null);

    // Server relays the blob to the new device.
    newDevice.onProvisioningBlob({
      'provisioningId': _provisioningId,
      'blob': staged['blob'],
    });
    await _settle();
    expect(newDevice.newDeviceStep, NewDeviceLinkStep.completing);
    expect(wrapRuns, 1);
    expect(newIdentity.adopted, hasLength(1));
    expect(newIdentity.adopted.single['userId'], _userId);
    expect(
      newIdentity.adopted.single['ikPub'],
      base64Encode(primaryIdentity.getPublicKey().serialize()),
    );
    expect(count('provisioningComplete'), 1);

    // Commit: tokens back to the new device, rebind, done.
    newDevice.onProvisioningCompleted({
      'success': true,
      'access_token': 'a',
      'refresh_token': 'r',
    });
    await _settle();
    expect(newDevice.newDeviceStep, NewDeviceLinkStep.done);
    expect(adoptedTokens.single['access_token'], 'a');
  });

  group('linkCeremonyActive ((lxxvi) clause 2)', () {
    test('new-device flow: true from first emit, false on abort', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);
      expect(linkCeremonyActive.value, isFalse);

      await controller.startNewDeviceFlow(platform: 'web');
      expect(linkCeremonyActive.value, isTrue);

      await controller.abortNewDevice('cancelled_locally');
      expect(linkCeremonyActive.value, isFalse);
    });

    test('flipped new-device flow raises it too', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);

      await controller.startNewDeviceFromCode(pCode(), platform: 'web');
      expect(linkCeremonyActive.value, isTrue);

      await controller.abortNewDevice('cancelled_locally');
      expect(linkCeremonyActive.value, isFalse);
    });

    test('primary flows: true while live, false on cancel and failure', () async {
      final engine = DeviceAuthorityEngine();
      engine.mintEnrollment(
        userId: _userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
      final dak = engine.exportDakForPersistence();
      final controller = LinkCeremonyController(
        userId: _userId,
        emit: (event, data) => emitted.add((event, data)),
        identity: _Identity(generateIdentityKeyPair()),
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
      addTearDown(controller.dispose);

      await controller.startPrimaryShowFlow(platform: 'web');
      expect(linkCeremonyActive.value, isTrue);
      controller.cancelPrimary();
      expect(linkCeremonyActive.value, isFalse);

      // The classic paste flow raises it too, and a refusal lowers it.
      await controller.startPrimaryFlow(nCode());
      expect(linkCeremonyActive.value, isTrue);
      controller.onProvisioningHelloAck({'success': false, 'error': 'x'});
      expect(linkCeremonyActive.value, isFalse);
    });

    test('a mid-flow dispose lowers the exemption', () async {
      final controller = keylessController();
      await controller.startNewDeviceFlow(platform: 'web');
      expect(linkCeremonyActive.value, isTrue);
      controller.dispose();
      expect(linkCeremonyActive.value, isFalse);
    });
  });

  test('enableLinking enrols over the DAK mintDak persisted', () async {
    final store = _StubDakStore();
    final identity = generateIdentityKeyPair();
    final engine = DeviceAuthorityEngine();
    final controller = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: _Identity(identity),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: engine,
      dakStore: store,
    );
    addTearDown(controller.dispose);

    await controller.mintDak();
    final minted = store.record;
    expect(minted, isNotNull);

    // Idempotent: a second mint keeps the persisted pair.
    await controller.mintDak();
    expect(store.record!.dakPub, minted!.dakPub);

    await controller.enableLinking(platform: 'web');
    final payload = payloadOf('enrollDeviceAuthority') as Map<String, dynamic>;
    // The enrolment is signed over the SAME pair the backup flow sealed —
    // a fresh mint here would orphan the blob (fails without reuseHeldDak).
    expect(payload['dakPub'], minted.dakPub);
  });

  // (lxxx) clause 3: in the FLIPPED direction the hello is the ONLY channel
  // by which the joining device's label reaches the signer, so every device
  // linked that way used to land on the list as `unknown`.
  group('the hello relays the platform label', () {
    LinkCeremonyController primaryController() {
      final identity = generateIdentityKeyPair();
      final engine = DeviceAuthorityEngine();
      final authorization = _asServed(
        engine.mintEnrollment(
          userId: _userId,
          identity: identity,
          createdAtMs: 1755600000000,
        ),
      );
      final dak = engine.exportDakForPersistence();
      final controller = LinkCeremonyController(
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
      addTearDown(controller.dispose);
      controller.onDeviceList({
        'userId': _userId,
        'authorization': authorization,
      });
      return controller;
    }

    /// Drives a primary to `showSas` with the given hello relay payload and
    /// returns the platform of the entry it signs.
    Future<String> stagedPlatform(Map<String, dynamic> extraRelay) async {
      final primary = primaryController();
      await primary.startPrimaryShowFlow(platform: 'web');
      primary.onProvisioningOpened({
        'success': true,
        'provisioningId': _provisioningId,
      });
      final newDevice = keylessController();
      addTearDown(newDevice.dispose);
      await newDevice.startNewDeviceFromCode(
        primary.primaryOobCode!,
        platform: 'android',
      );
      final hello = payloadOf('provisioningHello') as Map<String, dynamic>;
      primary.onProvisioningHelloRelay({
        'provisioningId': _provisioningId,
        'ephPubP': hello['ephPubP'],
        'deviceId': 2,
        ...extraRelay,
      });
      await primary.approvePrimary();
      await _settle();
      final staged =
          emitted.lastWhere((e) => e.$1 == 'provisionDevice').$2
              as Map<String, dynamic>;
      final list = parseCanonicalDeviceList(
        base64Decode(staged['listCanonical'] as String),
      );
      return list.devices.firstWhere((d) => d.deviceId == 2).platform;
    }

    test('the joining device sends its own label', () async {
      final primary = primaryController();
      await primary.startPrimaryShowFlow(platform: 'web');
      primary.onProvisioningOpened({
        'success': true,
        'provisioningId': _provisioningId,
      });
      final newDevice = keylessController();
      addTearDown(newDevice.dispose);

      await newDevice.startNewDeviceFromCode(
        primary.primaryOobCode!,
        platform: 'android',
      );

      final hello = payloadOf('provisioningHello') as Map<String, dynamic>;
      expect(hello['platform'], 'android');
    });

    test('the primary signs the RELAYED label', () async {
      expect(await stagedPlatform({'platform': 'android'}), 'android');
    });

    test('an older client that sends none stays unknown, never a crash', () async {
      expect(await stagedPlatform(const {}), 'unknown');
    });
  });

  // A2-DEV-01: a deep-linked `p` code is consumed at the gate's first frame,
  // before `socketReady`. The server drops a hello from a socket with no user
  // WITHOUT answering, so the hello must go out again once the session is up
  // or the gate spins on `awaitingHelloAck` forever.
  group('the hello waits for the session (A2-DEV-01)', () {
    test('a hello sent before the session is ready is sent again at '
        'socketReady, with the same ephemeral', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);

      await controller.startNewDeviceFromCode(pCode(), platform: 'android');
      final first = payloadOf('provisioningHello');

      controller.onSessionReady();

      expect(count('provisioningHello'), 2);
      // The server pins the FIRST ephemeral and re-answers only an identical
      // retry; a fresh one would be refused `ephemeral_already_pinned`.
      expect(payloadOf('provisioningHello'), first);
      expect(controller.newDeviceStep, NewDeviceLinkStep.awaitingHelloAck);
    });

    test('a code that arrives on a ready session says hello exactly once', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);
      controller.onSessionReady();

      await controller.startNewDeviceFromCode(pCode(), platform: 'web');
      expect(count('provisioningHello'), 1);

      // A second ready with no loss in between owes nothing.
      controller.onSessionReady();
      expect(count('provisioningHello'), 1);
    });

    test('a hello still unanswered when the socket is lost is sent again on '
        'the next session', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);
      controller.onSessionReady();
      await controller.startNewDeviceFromCode(pCode(), platform: 'web');

      controller
        ..onSessionLost()
        ..onSessionReady();

      expect(count('provisioningHello'), 2);
    });

    test('an answered hello is never repeated', () async {
      final controller = keylessController();
      addTearDown(controller.dispose);
      await controller.startNewDeviceFromCode(pCode(), platform: 'web');
      controller.onProvisioningHelloAck({'success': true, 'deviceId': 2});
      expect(controller.newDeviceStep, NewDeviceLinkStep.showSas);

      controller
        ..onSessionReady()
        ..onSessionLost()
        ..onSessionReady();

      expect(count('provisioningHello'), 1);
    });
  });
}
