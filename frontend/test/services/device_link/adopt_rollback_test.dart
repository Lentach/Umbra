// A3-SVC-B-1 — a device link that fails half-way must leave the install as
// keyless as it was before the attempt.
//
// `adoptProvisionedIdentity` wrote the account's identity record first and
// everything else after it, with no rollback: a refused write (or a process
// death) past the record left the phone holding the account's identity. Every
// retry was then refused ("device already holds an identity"), and the next
// start loaded those keys as the install's own under the pre-link session.
//
// These tests drive the REAL EncryptionService over a secure storage that
// refuses the Nth write of the account namespace.
//
// Falsification contract: dropping the rollback in the adopt turns the
// "refused write" test RED from the second write on; dropping the unsettled
// marker (or its discard in `initialize`) turns both "killed" tests RED.

import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/passcode_wrap_hook.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userId = 7;
const _namespace = 'e2e_${_userId}_';

// The pre-link state of a keyless install: nothing of this account, and
// another account's record that no link of this one may touch.
const _preLink = {'e2e_8_identity_record_v1': 'another-account'};

/// Secure storage that refuses one chosen write of the account namespace.
/// With [killOnFault] every later operation throws too: the process died
/// there, so no rollback can run.
class _FaultySecure extends FlutterSecureStorage {
  _FaultySecure({this.failAt, this.killOnFault = false});

  /// 1-based index of the namespace write that throws; null = none.
  int? failAt;
  final bool killOnFault;
  int writes = 0;
  bool _dead = false;

  /// A key whose delete is refused (a failing rollback); null = none.
  String? undeletable;

  void _alive() {
    if (_dead) throw StateError('process is gone');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _alive();
    if (key.startsWith(_namespace)) {
      writes++;
      if (writes == failAt) {
        _dead = killOnFault;
        throw StateError('write refused');
      }
    }
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _alive();
    if (key == undeletable) throw StateError('delete refused');
    await super.delete(key: key);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _alive();
    return super.readAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secure = FlutterSecureStorage();

  const preLink = _preLink;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(Map.of(preLink));
    SharedPreferences.setMockInitialValues({});
  });

  ({String ikPub, String ikPriv, String dakPub}) mintBlobInputs() {
    final pair = generateIdentityKeyPair();
    return (
      ikPub: base64Encode(pair.getPublicKey().serialize()),
      ikPriv: base64Encode(pair.getPrivateKey().serialize()),
      dakPub: base64Encode(List<int>.filled(32, 3)),
    );
  }

  EncryptionService serviceOver(FlutterSecureStorage storage) =>
      EncryptionService()..debugSetDualStorage(DualStorage(storage));

  Future<void> adopt(
    EncryptionService service,
    ({String ikPub, String ikPriv, String dakPub}) blob,
  ) => service.adoptProvisionedIdentity(
    userId: _userId,
    ikPubBase64: blob.ikPub,
    ikPrivBase64: blob.ikPriv,
    dakPubBase64: blob.dakPub,
  );

  /// The next start of a keyless install of an enrolled account: the server
  /// says the account has an identity, so only a link may install one.
  Future<void> startAgain(EncryptionService service) => service.initialize(
    _userId,
    checkServerIdentity: () async =>
        const ServerIdentityGuard(exists: true, linkingEnabled: true),
  );

  /// How many namespace writes one clean adopt makes.
  Future<int> writesOfACleanAdopt() async {
    final storage = _FaultySecure();
    await adopt(serviceOver(storage), mintBlobInputs());
    FlutterSecureStorage.setMockInitialValues(Map.of(preLink));
    return storage.writes;
  }

  test('a refused write at any step of the adopt leaves the pre-link state, '
      'and the same process can link again', () async {
    final total = await writesOfACleanAdopt();
    expect(total, greaterThan(5));

    for (var n = 1; n <= total; n++) {
      FlutterSecureStorage.setMockInitialValues(Map.of(preLink));
      final storage = _FaultySecure(failAt: n);
      final service = serviceOver(storage);

      await expectLater(
        adopt(service, mintBlobInputs()),
        throwsStateError,
        reason: 'write $n of $total',
      );
      expect(
        await secure.readAll(),
        preLink,
        reason: 'write $n of $total refused: nothing of the adopt may stay',
      );
      expect(service.needsKeyUpload, isFalse, reason: 'write $n of $total');
      expect(service.getKeysForUpload(), isNull, reason: 'write $n of $total');

      // The retry of the same ceremony screen, in the same process.
      storage.failAt = null;
      final blob = mintBlobInputs();
      await adopt(service, blob);
      expect(
        await service.currentIdentityPublicKeyBase64(),
        blob.ikPub,
        reason: 'retry after write $n of $total',
      );
    }
  });

  test('killed at any step of the adopt: the next start holds no identity '
      'and waits on the link gate', () async {
    final total = await writesOfACleanAdopt();

    for (var n = 1; n <= total; n++) {
      FlutterSecureStorage.setMockInitialValues(Map.of(preLink));
      final dying = serviceOver(_FaultySecure(failAt: n, killOnFault: true));
      await expectLater(adopt(dying, mintBlobInputs()), throwsStateError);

      final next = serviceOver(secure);
      await expectLater(
        startAgain(next),
        throwsA(isA<E2eIdentityIncompleteException>()),
        reason: 'killed at write $n of $total',
      );
      expect(
        await secure.readAll(),
        preLink,
        reason: 'killed at write $n of $total',
      );

      // The link gate's ceremony then installs the identity.
      final blob = mintBlobInputs();
      await adopt(next, blob);
      expect(await next.currentIdentityPublicKeyBase64(), blob.ikPub);
    }
  });

  test('killed after the adopt, before the link settled: the next start '
      'discards the adopted identity', () async {
    await adopt(serviceOver(secure), mintBlobInputs());
    expect(
      await secure.read(key: '${_namespace}identity_record_v1'),
      isNotNull,
    );

    await expectLater(
      startAgain(serviceOver(secure)),
      throwsA(isA<E2eIdentityIncompleteException>()),
    );
    expect(await secure.readAll(), preLink);
  });

  test('a settled link is the device\'s own identity: the next start loads '
      'it and nothing may discard it', () async {
    final service = serviceOver(secure);
    final blob = mintBlobInputs();
    await adopt(service, blob);
    await service.settleProvisionedIdentity(_userId);

    await expectLater(
      service.discardProvisionedIdentity(_userId),
      throwsStateError,
    );
    final next = serviceOver(secure);
    await startAgain(next);
    expect(await next.currentIdentityPublicKeyBase64(), blob.ikPub);
  });

  test('a start in the process that runs the ceremony keeps the unsettled '
      'identity', () async {
    final service = serviceOver(secure);
    final blob = mintBlobInputs();
    await adopt(service, blob);

    // A reconnect while the ceremony waits for the server's answer.
    await startAgain(service);
    expect(await service.currentIdentityPublicKeyBase64(), blob.ikPub);
    expect(service.needsKeyUpload, isTrue);
  });

  test('a rolled-back adopt over stale material leaves the service '
      'uninitialized', () async {
    final storage = _FaultySecure();
    final service = serviceOver(storage);
    await service.initialize(
      _userId,
      checkServerIdentity: () async =>
          const ServerIdentityGuard(exists: false, linkingEnabled: false),
    );
    expect(service.isInitialized, isTrue);

    storage
      ..writes = 0
      ..failAt = 2;
    final blob = mintBlobInputs();
    await expectLater(
      service.adoptProvisionedIdentity(
        userId: _userId,
        ikPubBase64: blob.ikPub,
        ikPrivBase64: blob.ikPriv,
        dakPubBase64: blob.dakPub,
        disposeStaleMaterial: true,
      ),
      throwsStateError,
    );
    expect(
      service.isInitialized,
      isFalse,
      reason: 'the identity store is empty after the rollback',
    );
  });

  group('a marker left by a failed rollback (S1)', () {
    const markerKey = '${_namespace}link_unsettled_v1';

    ({String ikPub, String ikPriv, String dakPub}) blobOf(
      IdentityKeyPair pair,
    ) => (
      ikPub: base64Encode(pair.getPublicKey().serialize()),
      ikPriv: base64Encode(pair.getPrivateKey().serialize()),
      dakPub: base64Encode(List<int>.filled(32, 3)),
    );

    test('a phrase restore of the same identity after it survives the next '
        'start', () async {
      final total = await writesOfACleanAdopt();
      final storage = _FaultySecure(failAt: total)..undeletable = markerKey;
      final service = serviceOver(storage);
      final pair = generateIdentityKeyPair();
      final blob = blobOf(pair);

      await expectLater(adopt(service, blob), throwsStateError);
      expect(await secure.read(key: markerKey), isNotNull);

      // Same gate, same process: the user restores with the phrase instead.
      storage
        ..failAt = null
        ..undeletable = null;
      await service.adoptRestoredIdentity(
        userId: _userId,
        payload: IdentityBackupPayload(
          userId: _userId,
          identity: jsonEncode({
            'pair': base64Encode(pair.serialize()),
            'registrationId': 4242,
          }),
          dak: null,
        ),
      );

      final next = serviceOver(secure);
      await startAgain(next);
      expect(await next.currentIdentityPublicKeyBase64(), blob.ikPub);
      expect(await secure.read(key: markerKey), isNull);
    });

    test('the identity a completed reset minted after it survives the next '
        'start', () async {
      final storage = _FaultySecure()..undeletable = markerKey;
      final service = serviceOver(storage);
      await adopt(service, mintBlobInputs());
      // The ceremony aborts; its discard dies on the last delete.
      await expectLater(
        service.discardProvisionedIdentity(_userId),
        throwsStateError,
      );
      expect(await secure.read(key: markerKey), isNotNull);

      storage.undeletable = null;
      await service.initialize(
        _userId,
        checkServerIdentity: () async => const ServerIdentityGuard(
          exists: true,
          resetCompleted: true,
        ),
      );
      final minted = await service.currentIdentityPublicKeyBase64();
      expect(minted, isNotNull);

      final next = serviceOver(secure);
      await startAgain(next);
      expect(await next.currentIdentityPublicKeyBase64(), minted);
      expect(await secure.read(key: markerKey), isNull);
    });

    test('a marker that names another identity than the stored one is '
        'dropped and the stored identity stays', () async {
      final service = serviceOver(secure);
      final blob = mintBlobInputs();
      await adopt(service, blob);
      await service.settleProvisionedIdentity(_userId);
      await secure.write(key: markerKey, value: mintBlobInputs().ikPub);

      final next = serviceOver(secure);
      await startAgain(next);
      expect(await next.currentIdentityPublicKeyBase64(), blob.ikPub);
      expect(await secure.read(key: markerKey), isNull);
    });
  });

  // R11Svc S2: a second tab on the link gate gets `socketReady` between the
  // first tab's adopt and the server's `provisioningCompleted`, finds the
  // unsettled marker and used to delete the first tab's adopted keys out of
  // the shared storage. The tab running the ceremony holds
  // `fireplace-e2e-link-<uid>` from the marker until it settles or discards;
  // a start discards only when it can take that lock.
  group('two tabs of one origin (S2)', () {
    late _FakeOriginLocks locks;

    EncryptionService tab() => EncryptionService(
      linkLockHolder: locks.hold,
      linkLockIfAvailable: locks.ifAvailable,
    )..debugSetDualStorage(DualStorage(secure));

    setUp(() => locks = _FakeOriginLocks());

    test('a second tab starting during the first tab ceremony leaves the '
        'adopted identity alone, and the ceremony then settles', () async {
      final first = tab();
      final blob = mintBlobInputs();
      await adopt(first, blob);
      expect(locks.held, contains('fireplace-e2e-link-$_userId'));
      final before = await secure.readAll();
      final second = tab();

      await expectLater(
        startAgain(second),
        throwsA(isA<E2eIdentityCheckUnavailableException>()),
      );
      expect(second.isInitialized, isFalse, reason: 'must not adopt A keys');
      expect(await secure.readAll(), before, reason: 'no storage write');
      expect(
        await secure.read(key: '${_namespace}identity_record_v1'),
        isNotNull,
        reason: 'the other tab discarded the adopted identity',
      );
      expect(await secure.read(key: '${_namespace}link_unsettled_v1'), isNotNull);

      await first.settleProvisionedIdentity(_userId);
      final next = tab();
      await startAgain(next);
      expect(await next.currentIdentityPublicKeyBase64(), blob.ikPub);
    });

    test('a marker nobody holds the lock for is discarded as before', () async {
      await adopt(tab(), mintBlobInputs());
      locks.holderDied();

      await expectLater(
        startAgain(tab()),
        throwsA(isA<E2eIdentityIncompleteException>()),
      );
      expect(await secure.readAll(), preLink);
    });

    test('settling or discarding the ceremony frees the lock', () async {
      final settled = tab();
      await adopt(settled, mintBlobInputs());
      await settled.settleProvisionedIdentity(_userId);
      expect(locks.held, isEmpty);

      FlutterSecureStorage.setMockInitialValues(Map.of(preLink));
      final discarded = tab();
      await adopt(discarded, mintBlobInputs());
      expect(locks.held, isNotEmpty);
      await discarded.discardProvisionedIdentity(_userId);
      expect(locks.held, isEmpty);
    });

    test('a refused write that rolls the adopt back frees the lock', () async {
      final storage = _FaultySecure(failAt: 2);
      final service = EncryptionService(
        linkLockHolder: locks.hold,
        linkLockIfAvailable: locks.ifAvailable,
      )..debugSetDualStorage(DualStorage(storage));

      await expectLater(adopt(service, mintBlobInputs()), throwsStateError);

      expect(locks.held, isEmpty);
    });
  });

  group('through the ceremony controller', ceremonyTests);
}

/// The origin's Web Locks, shared by every "tab" of one test: `hold` takes a
/// name until released, `ifAvailable` runs only while nobody holds it.
class _FakeOriginLocks {
  final Set<String> held = {};

  Future<void Function()> hold(String name) async {
    held.add(name);
    return () => held.remove(name);
  }

  Future<bool> ifAvailable(String name, Future<void> Function() action) async {
    if (held.contains(name)) return false;
    await action();
    return true;
  }

  /// The tab holding a lock died: the browser frees it.
  void holderDied() => held.clear();
}

class _NoDakStore extends DakStore {
  @override
  Future<DakRecord?> read({required int userId}) async => null;
}

/// The ceremony controller over the REAL service and gateway: what the new
/// device runs from the blob to the session rebind.
void ceremonyTests() {
  const provisioningId = '3f2c8a1e-9b7d-4c5a-8e2f-1a6b3c9d0e4f';
  const secure = FlutterSecureStorage();

  late LinkCeremonyController controller;
  late EncryptionService service;
  late List<(String, dynamic)> emitted;
  late String adoptedIkPub;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(Map.of(_preLink));
    emitted = [];
    service = EncryptionService()
      ..debugSetDualStorage(DualStorage(const FlutterSecureStorage()));
    controller = LinkCeremonyController(
      userId: _userId,
      emit: (event, data) => emitted.add((event, data)),
      identity: EncryptionServiceLinkGateway(service),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      dakStore: _NoDakStore(),
    );
    addTearDown(controller.dispose);
    addTearDown(() => PasscodeWrapHook.afterRawKeysLanded = null);
  });

  /// The classic flow up to the sealed blob the primary would stage.
  Map<String, dynamic> reachBlob() {
    controller.startNewDeviceFlow(platform: 'web');
    controller.onProvisioningOpened({
      'success': true,
      'provisioningId': provisioningId,
    });
    final ephPubN = LinkOobCode.tryParse(controller.oobCode!)!.ephPub;
    final ephP = generateLinkEphemeral();
    final ephPubP = linkEphemeralPublicBytes(ephP);
    controller.onProvisioningHelloRelay({
      'provisioningId': provisioningId,
      'ephPubP': base64Encode(ephPubP),
    });
    final keys = deriveLinkBlobKeys(
      sharedSecret: linkSharedSecret(
        theirEphPub: ephPubN,
        ownEphPriv: ephP.privateKey,
      ),
      transcript: linkTranscript(
        provisioningId: provisioningId,
        ephPubN: ephPubN,
        ephPubP: ephPubP,
      ),
    );
    final pair = generateIdentityKeyPair();
    adoptedIkPub = base64Encode(pair.getPublicKey().serialize());
    final blob = sealLinkBlob(
      keys: keys,
      payload: LinkBlobPayload(
        userId: _userId,
        deviceId: 2,
        ikPub: adoptedIkPub,
        ikPriv: base64Encode(pair.getPrivateKey().serialize()),
        dakPub: base64Encode(List<int>.filled(32, 3)),
        enrollmentCreatedAt: 1755600000000,
        enrollmentSig: 'c2ln',
      ),
    );
    return {'provisioningId': provisioningId, 'blob': base64Encode(blob)};
  }

  test('a failing passcode wrap after the adopt aborts the link and leaves '
      'the pre-link state', () async {
    PasscodeWrapHook.afterRawKeysLanded = () async => throw StateError('wrap');
    controller.onProvisioningBlob(reachBlob());
    await pumpEventQueue(times: 200);

    expect(controller.newDeviceStep, NewDeviceLinkStep.aborted);
    expect(controller.newDeviceError, 'adopt_failed');
    expect(await secure.readAll(), _preLink);

    // The user's retry on the same screen is not refused.
    PasscodeWrapHook.afterRawKeysLanded = null;
    controller.onProvisioningBlob(reachBlob());
    await pumpEventQueue(times: 200);
    expect(await service.currentIdentityPublicKeyBase64(), adoptedIkPub);
  });

  test('the server commit settles the link: the next start keeps the '
      'identity', () async {
    controller.onProvisioningBlob(reachBlob());
    await pumpEventQueue(times: 200);
    expect(controller.newDeviceStep, NewDeviceLinkStep.completing);
    expect(
      await secure.read(key: '${_namespace}link_unsettled_v1'),
      isNotNull,
      reason: 'unsettled until the server committed the device',
    );

    controller.onProvisioningCompleted({
      'success': true,
      'access_token': 'a',
      'refresh_token': 'r',
    });
    await pumpEventQueue(times: 200);

    expect(controller.newDeviceStep, NewDeviceLinkStep.done);
    expect(await secure.read(key: '${_namespace}link_unsettled_v1'), isNull);
    final next = EncryptionService()
      ..debugSetDualStorage(DualStorage(const FlutterSecureStorage()));
    await next.initialize(
      _userId,
      checkServerIdentity: () async =>
          const ServerIdentityGuard(exists: true, linkingEnabled: true),
    );
    expect(await next.currentIdentityPublicKeyBase64(), adoptedIkPub);
  });
}
