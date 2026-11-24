import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';

/// In-memory [DualStorage] that parks the next delete of a pending-candidate
/// row until the test releases it.
class _HoldPendingDeleteStorage extends DualStorage {
  _HoldPendingDeleteStorage() : super(const FlutterSecureStorage());

  final Map<String, String> store = {};
  bool armed = false;
  final Completer<void> parked = Completer<void>();
  final Completer<void> _released = Completer<void>();

  void release() => _released.complete();

  @override
  Future<void> write({required String key, required String value}) async {
    store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => store[key];

  @override
  Future<void> delete({required String key}) async {
    if (armed && key.contains('pending_account_identity_')) {
      armed = false;
      parked.complete();
      await _released.future;
    }
    store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ENC-03: a candidate a decrypt records while a promote is deleting '
      'the acknowledged one is not erased by that delete', () async {
    final storage = _HoldPendingDeleteStorage();
    final store = SecureIdentityKeyStore(storage, 'test_');
    final address = SignalProtocolAddress('peer', 1);
    final pinned = generateIdentityKeyPair().getPublicKey();
    final shown = generateIdentityKeyPair().getPublicKey();
    final arriving = generateIdentityKeyPair().getPublicKey();
    await store.saveIdentity(address, pinned);
    await store.stagePendingAccountIdentity('peer', shown);

    // The human confirms the candidate they were shown; the promote has
    // pinned it and is deleting the slot when a decrypt presents ANOTHER key.
    storage.armed = true;
    final promote = store.promotePendingAccountIdentity(
      'peer',
      expectedIdentityBase64: SecureIdentityKeyStore.encodedOf(shown),
    );
    await storage.parked.future;
    final decrypt = store.isTrustedIdentity(
      address,
      arriving,
      Direction.receiving,
    );
    await pumpEventQueue();
    storage.release();

    expect(await promote, isTrue);
    expect(await decrypt, isTrue);
    expect(
      (await store.pendingAccountIdentity('peer'))?.serialize(),
      arriving.serialize(),
      reason: 'the new candidate was never shown or promoted; erasing it '
          'leaves the per-device row on a key the anchor refuses',
    );
  });

  group('SecureIdentityKeyStore.isTrustedIdentity', () {
    late SecureIdentityKeyStore store;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = DualStorage(const FlutterSecureStorage());
      store = SecureIdentityKeyStore(storage, 'test_');
    });

    test('trusts first-time identity (TOFU)', () async {
      final keyPair = generateIdentityKeyPair();
      final address = SignalProtocolAddress('user1', 1);
      final result = await store.isTrustedIdentity(
          address, keyPair.getPublicKey(), Direction.sending);
      expect(result, isTrue);
    });

    test('trusts same identity seen again', () async {
      final keyPair = generateIdentityKeyPair();
      final address = SignalProtocolAddress('user1', 1);
      await store.saveIdentity(address, keyPair.getPublicKey());
      final result = await store.isTrustedIdentity(
          address, keyPair.getPublicKey(), Direction.sending);
      expect(result, isTrue);
    });

    test('accepts new identity from peer who rotated keys', () async {
      final oldKeyPair = generateIdentityKeyPair();
      final address = SignalProtocolAddress('user1', 1);
      await store.saveIdentity(address, oldKeyPair.getPublicKey());

      // Peer regenerated keys (storage eviction / reinstall)
      final newKeyPair = generateIdentityKeyPair();

      final result = await store.isTrustedIdentity(
          address, newKeyPair.getPublicKey(), Direction.receiving);

      // Rotation is accepted (TOFU with rotation trust) — see signal_stores.dart saveIdentity.
      expect(result, isTrue);
    });

    test('stores updated identity after key rotation so next check also trusts it', () async {
      final oldKeyPair = generateIdentityKeyPair();
      final address = SignalProtocolAddress('user1', 1);
      await store.saveIdentity(address, oldKeyPair.getPublicKey());

      final newKeyPair = generateIdentityKeyPair();
      await store.isTrustedIdentity(
          address, newKeyPair.getPublicKey(), Direction.receiving);

      // The rotated identity must be PERSISTED, not just accepted: getIdentity
      // returns the new key and no longer the old one. Fails if saveIdentity
      // stopped writing the rotated key.
      final stored = await store.getIdentity(address);
      expect(stored, isNotNull);
      expect(stored!.serialize(), newKeyPair.getPublicKey().serialize());
      expect(stored.serialize(),
          isNot(equals(oldKeyPair.getPublicKey().serialize())));
    });

    test('rejects null identity (does not trust or throw)', () async {
      final address = SignalProtocolAddress('user1', 1);
      final result =
          await store.isTrustedIdentity(address, null, Direction.receiving);
      expect(result, isFalse);
    });
  });
}
