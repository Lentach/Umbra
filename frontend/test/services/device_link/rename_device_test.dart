import 'dart:convert';

import 'package:fireplace/services/device_link/dak_store.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Client half of DEVICE RENAME (multi-device spec §12 (lxxx) clause 1).
///
/// There is no rename wire and no server change: the mutation is exactly the
/// revoke shape with `name` set instead of `revokedAt`, emitted on the
/// EXISTING `updateDeviceList` and answered by `deviceListUpdated`. So these
/// tests pin what the client signs — including the two things that cannot be
/// re-derived from the server: the DAK must be armed from the Keystore first,
/// and CLEARING a name must reach the same canonical bytes as a list that was
/// never named.
class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async =>
      throw StateError('not used by the rename flow');

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 42;

  late List<(String, dynamic)> emitted;
  late DeviceAuthorityEngine engine;
  late LinkCeremonyController controller;
  late Map<String, String> persistedDak;

  DeviceList currentList({int version = 2}) => DeviceList(
    userId: userId,
    version: version,
    devices: const [
      DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
      DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
    ],
  );

  LinkCeremonyController build({
    DeviceAuthorityEngine? withEngine,
    DakRecord? dak,
  }) => LinkCeremonyController(
    userId: userId,
    emit: (event, data) => emitted.add((event, data)),
    identity: _NoIdentity(),
    adoptSession: (_) async {},
    reconnect: (_) async {},
    engine: withEngine ?? engine,
    dakStore: _StubDakStore(dak),
  );

  setUp(() {
    emitted = [];
    engine = DeviceAuthorityEngine();
    engine.mintEnrollment(
      userId: userId,
      identity: generateIdentityKeyPair(),
      createdAtMs: 1755600000000,
    );
    persistedDak = engine.exportDakForPersistence();
    controller = build(
      dak: DakRecord(
        userId: userId,
        dakPub: persistedDak['dakPub']!,
        dakPriv: persistedDak['dakPriv']!,
        createdAtMs: 1755600000000,
      ),
    );
    controller.verifiedList = currentList();
  });

  Map<String, dynamic> updatePayload() =>
      emitted.firstWhere((e) => e.$1 == 'updateDeviceList').$2
          as Map<String, dynamic>;

  DeviceList signedList() => parseCanonicalDeviceList(
    base64Decode(updatePayload()['listCanonical'] as String),
  );

  test('names the requested row at version+1 and signs it under the DAK', () async {
    controller.verifiedList = currentList(version: 7);

    await controller.renameDevice(2, 'Telefon Ani');

    final payload = updatePayload();
    final signed = signedList();
    expect(signed.version, 8);
    expect(signed.devices.firstWhere((d) => d.deviceId == 2).name, 'Telefon Ani');
    // Nothing else moves: the other row keeps its absent name.
    expect(signed.devices.firstWhere((d) => d.deviceId == 1).name, isNull);
    // The signature is the only thing that makes the server accept it.
    expect(
      verifyDeviceListSignature(
        dakPubSerialized: base64Decode(persistedDak['dakPub']!),
        canonicalBytes: base64Decode(payload['listCanonical'] as String),
        signature: base64Decode(payload['listSignature'] as String),
      ),
      isTrue,
    );
    // The request is the EXISTING mutating one — no new event.
    expect(emitted.map((e) => e.$1), contains('updateDeviceList'));
  });

  test('arms the DAK from the Keystore before signing (F13)', () async {
    // The devices screen builds a FRESH controller every time it opens, so its
    // engine holds no DAK; signing without one throws and nothing leaves the
    // device. This is the same hole the T6 app-proof caught on revoke.
    final cold = build(
      withEngine: DeviceAuthorityEngine(),
      dak: DakRecord(
        userId: userId,
        dakPub: persistedDak['dakPub']!,
        dakPriv: persistedDak['dakPriv']!,
        createdAtMs: 1755600000000,
      ),
    );
    cold.verifiedList = currentList();

    await cold.renameDevice(2, 'Laptop');

    expect(
      emitted.where((e) => e.$1 == 'updateDeviceList').length,
      1,
      reason: 'a cold controller must restore the DAK, not fail to sign',
    );
    expect(cold.renameError, isNull);
    expect(
      signedList().devices.firstWhere((d) => d.deviceId == 2).name,
      'Laptop',
    );
  });

  test('refuses cleanly when this device holds NO DAK', () async {
    final cold = build(withEngine: DeviceAuthorityEngine(), dak: null);
    cold.verifiedList = currentList();

    await cold.renameDevice(2, 'Laptop');

    expect(emitted.where((e) => e.$1 == 'updateDeviceList'), isEmpty);
    expect(cold.renameError, 'no_dak');
    expect(cold.renamingDeviceId, isNull);
  });

  test('refuses a REVOKED row — a tombstone must not spend a version', () async {
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

    await controller.renameDevice(2, 'Stary telefon');

    expect(emitted.where((e) => e.$1 == 'updateDeviceList'), isEmpty);
    expect(controller.renamingDeviceId, isNull);
  });

  test('refuses an unknown device id, and never signs blind', () async {
    await controller.renameDevice(9, 'Nowy');
    controller.verifiedList = null;
    await controller.renameDevice(2, 'Nowy');

    expect(emitted.where((e) => e.$1 == 'updateDeviceList'), isEmpty);
  });

  test('caps an over-long name at kDeviceNameMaxLength', () async {
    await controller.renameDevice(2, 'x' * (kDeviceNameMaxLength + 40));

    final name = signedList().devices.firstWhere((d) => d.deviceId == 2).name;
    expect(name, 'x' * kDeviceNameMaxLength);
    // And it is signed: the cap has to happen BEFORE the encoder, which
    // rejects an over-long name outright.
    expect(updatePayload()['listSignature'], isA<String>());
  });

  test(
    'a whitespace-only name CLEARS it — byte-identical to never named (F14)',
    () async {
      controller.verifiedList = DeviceList(
        userId: userId,
        version: 5,
        devices: const [
          DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
          DeviceListEntry(
            deviceId: 2,
            platform: 'web',
            addedAtMs: 2000,
            name: 'Telefon Ani',
          ),
        ],
      );

      await controller.renameDevice(2, '   ');

      final cleared = base64Decode(updatePayload()['listCanonical'] as String);
      // The list as it would be if device 2 had NEVER been named. `""` would
      // encode a `"name":""` key and diverge here.
      final neverNamed = encodeCanonicalDeviceList(
        DeviceList(
          userId: userId,
          version: 6,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 1000),
            DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
          ],
        ),
      );
      expect(cleared, neverNamed);
      expect(utf8.decode(cleared), isNot(contains('name')));
    },
  );

  test('one rename at a time', () async {
    await controller.renameDevice(2, 'A');
    await controller.renameDevice(2, 'B');

    expect(emitted.where((e) => e.$1 == 'updateDeviceList').length, 1);
    expect(controller.renamingDeviceId, 2);
  });

  group('the server answer', () {
    test('success clears the spinner and refreshes the list', () async {
      await controller.renameDevice(2, 'Telefon');
      emitted.clear();

      controller.onDeviceListUpdated({'success': true, 'listVersion': 3});

      expect(controller.renamingDeviceId, isNull);
      expect(controller.renameError, isNull);
      expect(emitted.map((e) => e.$1), contains('getDeviceList'));
    });

    test('a refusal surfaces rename_failed and clears the spinner', () async {
      await controller.renameDevice(2, 'Telefon');

      controller.onDeviceListUpdated({
        'success': false,
        'error': 'rate_limited',
      });

      expect(controller.renamingDeviceId, isNull);
      expect(controller.renameError, 'rename_failed');
    });

    test('a malformed answer still clears the spinner', () async {
      await controller.renameDevice(2, 'Telefon');

      controller.onDeviceListUpdated('nonsense');

      expect(controller.renamingDeviceId, isNull);
      expect(controller.renameError, 'rename_failed');
    });

    test(
      'an answer with nothing in flight is left to the restore machine',
      () {
        // The (lxxviii) restore emits the same request from
        // EncryptionProvider and awaits its own completer; this controller
        // must not touch it or refresh on its behalf.
        controller.onDeviceListUpdated({'success': true, 'listVersion': 9});

        expect(controller.renameError, isNull);
        expect(emitted, isEmpty);
      },
    );
  });

  group('names the storage gate would refuse (NFC, (lxxx) clause 1)', () {
    test('a DECOMPOSED name is refused before anything is signed', () async {
      // "Telefon Zosi" with a decomposed "ó": base 'o' + U+0301. The server
      // rejects a non-NFC name outright, so signing it would burn version+1
      // and come back as `invalid_canonical` with only a generic error.
      await controller.renameDevice(2, 'Telefo\u006E Zo\u0301si');

      expect(controller.renameError, 'not_storable');
      expect(
        emitted,
        isEmpty,
        reason: 'nothing may reach the wire, and no version may be spent',
      );
      expect(controller.renamingDeviceId, isNull);
    });

    test('the PRECOMPOSED form of the same name is accepted', () async {
      // The control: identical text, single code point U+00F3. Without it
      // "refused" could just mean "rename is broken for Polish".
      await controller.renameDevice(2, 'Telefon Z\u00F3si');

      expect(controller.renameError, isNull);
      expect(emitted.map((e) => e.$1), contains('updateDeviceList'));
    });

    test('a mark that is normal in its own script is NOT refused', () async {
      // Arabic fatha (U+064E) is ordinary NFC text; the check must only cover
      // the Latin/Greek/Cyrillic decomposition blocks.
      await controller.renameDevice(2, '\u0647\u0627\u062A\u0641\u064E');

      expect(controller.renameError, isNull);
      expect(emitted.map((e) => e.$1), contains('updateDeviceList'));
    });
  });
}
