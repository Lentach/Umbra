import 'dart:async';
import 'dart:convert';

import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory [DualStorage] whose next `session_` write parks until released,
/// so a test can hold a session build between "started" and "stored".
class _GatedStorage extends DualStorage {
  _GatedStorage() : super(const FlutterSecureStorage());

  final Map<String, String> store = {};
  Completer<void>? _armed;
  final Completer<void> _released = Completer<void>();
  final Completer<void> sessionWriteParked = Completer<void>();

  void holdNextSessionWrite() => _armed = Completer<void>();
  void release() => _released.complete();

  @override
  Future<void> write({required String key, required String value}) async {
    if (_armed != null && key.contains('session_')) {
      _armed = null;
      sessionWriteParked.complete();
      await _released.future;
    }
    store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => store[key];

  @override
  Future<void> delete({required String key}) async => store.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(store);
}

/// ENC-08: a wipe that lists the store while a session build is mid-write
/// lets the write land afterwards, so a "PROVEN complete" wipe leaves a
/// session record of the life it just ended.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 42;
  const peerUserId = 2;

  Map<String, dynamic> peerBundle() {
    final identity = generateIdentityKeyPair();
    final signed = generateSignedPreKey(identity, 0);
    final otp = generatePreKeys(0, 1).single;
    return {
      'registrationId': generateRegistrationId(false),
      'identityPublicKey': base64Encode(identity.getPublicKey().serialize()),
      'signedPreKeyId': 0,
      'signedPreKeyPublic': base64Encode(
        signed.getKeyPair().publicKey.serialize(),
      ),
      'signedPreKeySignature': base64Encode(signed.signature),
      'oneTimePreKeyId': otp.id,
      'oneTimePreKeyPublic': base64Encode(
        otp.getKeyPair().publicKey.serialize(),
      ),
    };
  }

  test('ENC-08: a reset wipe leaves no session of the old life behind when '
      'a session build is mid-write', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final storage = _GatedStorage();
    final service = EncryptionService()..debugSetDualStorage(storage);
    await service.initialize(
      ownUserId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    // This install is stamped as device 2; the reset names device 9, so the
    // disposal wipes.
    expect(await service.confirmMaterialDeviceId(2), isTrue);

    storage.holdNextSessionWrite();
    final build = service.buildSession(
      peerUserId,
      peerBundle(),
      expectedIdentityBase64: null,
    );
    await storage.sessionWriteParked.future;

    final wipe = service.disposeMismatchedMaterialForReset(9);
    await pumpEventQueue();
    storage.release();

    await build;
    expect(await wipe, isTrue);
    expect(
      storage.store.keys.where((k) => k.startsWith('e2e_${ownUserId}_')),
      isEmpty,
      reason: 'the build stored its session after the wipe listed the store',
    );
  });
}
