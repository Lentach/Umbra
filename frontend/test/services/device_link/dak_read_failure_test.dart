// A2-DEV-03: a THROWN key read is not "this device holds no DAK". The old
// presence check folded both into `holdsDak = false`, so one Keystore or
// storage glitch hid revoke and rename until the screen was reopened.

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const _userId = 7;

class _NoIdentity implements LinkIdentityGateway {
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
  }) async {}

  @override
  Future<void> discardProvisionedIdentity(int userId) async {}

  @override
  Future<void> settleProvisionedIdentity(int userId) async {}
}

/// Throws until [healthy] is set, then answers [record].
class _FlakyDakStore extends DakStore {
  _FlakyDakStore(this.record);
  final DakRecord? record;
  bool healthy = false;

  @override
  Future<DakRecord?> read({required int userId}) async {
    if (!healthy) throw StateError('keystore unavailable');
    return record;
  }
}

void main() {
  late LinkCeremonyController controller;
  late _FlakyDakStore store;

  setUp(() {
    final engine = DeviceAuthorityEngine()
      ..mintEnrollment(
        userId: _userId,
        identity: generateIdentityKeyPair(),
        createdAtMs: 1755600000000,
      );
    final dak = engine.exportDakForPersistence();
    store = _FlakyDakStore(
      DakRecord(
        userId: _userId,
        dakPub: dak['dakPub']!,
        dakPriv: dak['dakPriv']!,
        createdAtMs: 1755600000000,
      ),
    );
    controller = LinkCeremonyController(
      userId: _userId,
      emit: (_, _) {},
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      engine: engine,
      dakStore: store,
    );
  });

  tearDown(() => controller.dispose());

  test('a thrown read is reported as a failed read, not as "no DAK"', () async {
    controller.refreshDeviceList();
    await pumpEventQueue();

    expect(
      controller.holdsDak,
      isNot(false),
      reason: 'a glitch must not claim this device is not the primary',
    );
    expect(controller.dakReadFailed, isTrue);
  });

  test('the next read that succeeds replaces the failure', () async {
    controller.refreshDeviceList();
    await pumpEventQueue();
    store.healthy = true;

    controller.refreshDeviceList();
    await pumpEventQueue();

    expect(controller.holdsDak, isTrue);
    expect(controller.dakReadFailed, isFalse);
  });

  test('a store that answers "no key" still means a linked device', () async {
    final linked = LinkCeremonyController(
      userId: _userId,
      emit: (_, _) {},
      identity: _NoIdentity(),
      adoptSession: (_) async {},
      reconnect: (_) async {},
      dakStore: _EmptyDakStore(),
    )..refreshDeviceList();
    addTearDown(linked.dispose);
    await pumpEventQueue();

    expect(linked.holdsDak, isFalse);
    expect(linked.dakReadFailed, isFalse);
  });
}

class _EmptyDakStore extends DakStore {
  @override
  Future<DakRecord?> read({required int userId}) async => null;
}
