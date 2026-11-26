// A3-SVC-B-2 — the refusals of `adoptRestoredIdentity` that no test reached.
//
// A restore overwrites the account's identity on this device, so each guard
// is what stops a wrong backup (or a wrong store) from silently replacing keys
// every session is keyed to. Falsification contract: deleting the matching
// check in `adoptRestoredIdentity` turns that test RED — the `userId` compare,
// the `heldPub != backupPub` refusal, the DAK record's own `userId` compare,
// and the DAK read-back compare.

import 'dart:convert';

import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userId = 7;

/// Secure storage whose read of the DAK record returns something else: a
/// store that does not hold what was just written.
class _LyingDakStorage extends FlutterSecureStorage {
  const _LyingDakStorage();

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = await super.read(key: key);
    return key == 'dak_record_v1_$_userId' && value != null ? 'other' : value;
  }
}

IdentityBackupPayload _backupOf(
  IdentityKeyPair pair, {
  int userId = _userId,
  String? dak,
}) => IdentityBackupPayload(
  userId: userId,
  identity: jsonEncode({
    'pair': base64Encode(pair.serialize()),
    'registrationId': 4242,
  }),
  dak: dak,
);

String _dakRecord(int userId) => jsonEncode({
  'userId': userId,
  'dakPub': base64Encode(List<int>.filled(32, 1)),
  'dakPriv': base64Encode(List<int>.filled(32, 2)),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secure = FlutterSecureStorage();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  /// A device that already holds an identity of its own for [_userId].
  Future<EncryptionService> holdingDevice(FlutterSecureStorage storage) async {
    final service = EncryptionService()
      ..debugSetDualStorage(DualStorage(storage));
    await service.initialize(
      _userId,
      checkServerIdentity: () async =>
          const ServerIdentityGuard(exists: false),
    );
    return service;
  }

  test('a backup of another account is refused and nothing is written',
      () async {
    final service = await holdingDevice(secure);
    final before = await secure.readAll();

    await expectLater(
      service.adoptRestoredIdentity(
        userId: _userId,
        payload: _backupOf(generateIdentityKeyPair(), userId: _userId + 1),
      ),
      throwsA(
        isA<StateError>().having((e) => '$e', 'message', contains('belongs')),
      ),
    );
    expect(await secure.readAll(), before);
  });

  test('a DIFFERENT held identity is refused without a disposal '
      'authorization, and the held one is untouched', () async {
    final service = await holdingDevice(secure);
    final held = await service.currentIdentityPublicKeyBase64();
    final before = await secure.readAll();

    await expectLater(
      service.adoptRestoredIdentity(
        userId: _userId,
        payload: _backupOf(generateIdentityKeyPair()),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'message',
          contains('already holds'),
        ),
      ),
    );
    expect(await secure.readAll(), before);
    expect(await service.currentIdentityPublicKeyBase64(), held);
  });

  test('a DAK record naming another account is refused as corrupt and '
      'nothing is written', () async {
    final service = await holdingDevice(secure);
    final before = await secure.readAll();
    final pair = IdentityKeyPair.fromSerialized(
      base64Decode(
        (jsonDecode((await secure.read(key: 'e2e_${_userId}_identity_record_v1'))!)
                as Map<String, dynamic>)['pair']
            as String,
      ),
    );

    await expectLater(
      service.adoptRestoredIdentity(
        userId: _userId,
        payload: _backupOf(pair, dak: _dakRecord(_userId + 1)),
      ),
      throwsA(
        isA<IdentityBackupCorrupt>().having(
          (e) => e.reason,
          'reason',
          'dak_record',
        ),
      ),
    );
    expect(await secure.readAll(), before);
  });

  test('a store that does not return the DAK record it was given fails the '
      'restore', () async {
    const lying = _LyingDakStorage();
    final service = await holdingDevice(lying);
    final pair = generateIdentityKeyPair();

    await expectLater(
      service.adoptRestoredIdentity(
        userId: _userId,
        payload: _backupOf(pair, dak: _dakRecord(_userId)),
        disposeStaleMaterial: true,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'message',
          contains('read-back'),
        ),
      ),
    );
  });
}
