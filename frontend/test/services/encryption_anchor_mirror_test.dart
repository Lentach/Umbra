// The synchronous anchor mirror (invariant decisions, slice 1): the pinned
// account identity of a friend, answered WITHOUT an await from the Signal
// store's trusted memo; loaded for every friend at E2E init, and set BEFORE
// the storage write in the two movers, so a failed write leaves memo and
// store disagreeing only in the safe direction (memo = new).
//
// Also the reader for the remote identity of a session a whisper decrypted on.

import 'dart:convert';

import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory storage whose write to an ACCOUNT anchor row can be observed
/// (to see what the sync mirror says at that very instant) and made to fail.
class _ObservedStorage extends DualStorage {
  _ObservedStorage() : super(const FlutterSecureStorage());

  final Map<String, String> store = {};
  bool failAnchorWrite = false;
  void Function()? atAnchorWrite;

  static bool _isAnchor(String key) =>
      key.contains('account_identity_') && !key.contains('pending_');

  @override
  Future<void> write({required String key, required String value}) async {
    if (_isAnchor(key) && (atAnchorWrite != null || failAnchorWrite)) {
      atAnchorWrite?.call();
      if (failAnchorWrite) throw StateError('disk full');
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

String _b64(IdentityKey k) => base64Encode(k.serialize());

IdentityKey _fresh() => generateIdentityKeyPair().getPublicKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureIdentityKeyStore sync anchor mirror', () {
    late _ObservedStorage storage;
    late SecureIdentityKeyStore store;
    late IdentityKey oldKey;
    late IdentityKey newKey;

    setUp(() async {
      storage = _ObservedStorage();
      store = SecureIdentityKeyStore(storage, 'p_');
      oldKey = _fresh();
      newKey = _fresh();
      expect(await store.stageAccountIdentity('7', oldKey), isTrue);
    });

    test('a pinned anchor is answered without an await', () {
      expect(store.accountAnchorSync('7'), _b64(oldKey));
      expect(store.accountAnchorSync('8'), isNull);
    });

    test('promote sets the memo BEFORE the storage write', () async {
      await store.stagePendingAccountIdentity('7', newKey);
      String? atWrite;
      storage.atAnchorWrite = () => atWrite = store.accountAnchorSync('7');

      expect(
        await store.promotePendingAccountIdentity(
          '7',
          expectedIdentityBase64: _b64(newKey),
        ),
        isTrue,
      );

      expect(atWrite, _b64(newKey), reason: 'memo first, write second');
      expect(store.accountAnchorSync('7'), _b64(newKey));
    });

    test('a failing promote write leaves the mirror on the NEW identity and '
        'the store on the old one (the safe direction)', () async {
      await store.stagePendingAccountIdentity('7', newKey);
      storage.failAnchorWrite = true;

      await expectLater(
        store.promotePendingAccountIdentity(
          '7',
          expectedIdentityBase64: _b64(newKey),
        ),
        throwsStateError,
      );

      expect(store.accountAnchorSync('7'), _b64(newKey));
      expect(
        storage.store.entries
            .singleWhere(
              (e) =>
                  e.key.contains('account_identity_7') &&
                  !e.key.contains('pending'),
            )
            .value,
        _b64(oldKey),
      );
    });

    test('adopt sets the memo BEFORE the storage write, and a failing write '
        'leaves the mirror on the NEW identity', () async {
      String? atWrite;
      storage.atAnchorWrite = () => atWrite = store.accountAnchorSync('7');
      await store.adoptAccountIdentity(
        '7',
        newKey,
        expectedPendingBase64: null,
      );
      expect(atWrite, _b64(newKey), reason: 'memo first, write second');

      final third = _fresh();
      storage
        ..atAnchorWrite = null
        ..failAnchorWrite = true;
      await expectLater(
        store.adoptAccountIdentity('7', third, expectedPendingBase64: null),
        throwsStateError,
      );
      expect(store.accountAnchorSync('7'), _b64(third));
    });

    test('loadAccountAnchors loads every friend pinned in the store', () async {
      await store.stageAccountIdentity('8', newKey);
      // A legacy install: only the per-device row exists.
      final legacy = _fresh();
      await store.saveIdentity(const SignalProtocolAddress('9', 1), legacy);
      storage.store.remove('p_account_identity_9');

      final fresh = SecureIdentityKeyStore(storage, 'p_');
      expect(fresh.accountAnchorSync('7'), isNull);
      await fresh.loadAccountAnchors();

      expect(fresh.accountAnchorSync('7'), _b64(oldKey));
      expect(fresh.accountAnchorSync('8'), _b64(newKey));
      expect(fresh.accountAnchorSync('9'), _b64(legacy));
    });

    test('a first pin reports the identity it pinned; a move reports nothing',
        () async {
      final pins = <(String, String)>[];
      final fresh = SecureIdentityKeyStore(storage, 'p_')
        ..onAccountPinned = (name, idk) => pins.add((name, idk));

      await fresh.saveIdentity(const SignalProtocolAddress('20', 1), newKey);
      await fresh.stageAccountIdentity('21', oldKey);
      await fresh.stagePendingAccountIdentity('21', newKey);
      await fresh.promotePendingAccountIdentity(
        '21',
        expectedIdentityBase64: _b64(newKey),
      );

      expect(pins, [('20', _b64(newKey)), ('21', _b64(oldKey))]);
    });
  });

  group('EncryptionService', () {
    const fresh = ServerIdentityGuard(exists: false);
    const aliceId = 1;
    const bobId = 2;

    Map<String, dynamic> flatBundleFrom(EncryptionService peer) {
      final upload = peer.getKeysForUpload()!;
      final keyBundle = (upload['keyBundle'] as Map).cast<String, dynamic>();
      final otp = (upload['oneTimePreKeys'] as List)
          .cast<Map<String, dynamic>>()
          .first;
      return {
        ...keyBundle,
        'oneTimePreKeyId': otp['keyId'],
        'oneTimePreKeyPublic': otp['publicKey'],
      };
    }

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
    });

    test('the mirror is loaded for every friend at E2E init', () async {
      final first = EncryptionService();
      await first.initialize(17, checkServerIdentity: () async => fresh);
      final peerKey = _fresh();
      final peerStore = SecureIdentityKeyStore(
        DualStorage(const FlutterSecureStorage()),
        'e2e_17_',
      );
      await peerStore.stageAccountIdentity('42', peerKey);
      await peerStore.stageAccountIdentity('43', _fresh());

      final second = EncryptionService();
      expect(second.accountAnchorSync(42), isNull, reason: 'not initialized');
      await second.initialize(17, checkServerIdentity: () async => fresh);

      expect(second.accountAnchorSync(42), _b64(peerKey));
      expect(second.accountAnchorSync(43), isNotNull);
      expect(second.accountAnchorSync(44), isNull);
    });

    test('the remote identity of the session a whisper decrypted on', () async {
      final alice = EncryptionService();
      final bob = EncryptionService();
      await alice.initialize(aliceId, checkServerIdentity: () async => fresh);
      await bob.initialize(bobId, checkServerIdentity: () async => fresh);
      String identityOf(EncryptionService s) =>
          ((s.getKeysForUpload()!['keyBundle'] as Map)['identityPublicKey'])
              as String;

      expect(await bob.sessionRemoteIdentity(aliceId), isNull);

      await alice.buildSession(
        bobId,
        flatBundleFrom(bob),
        expectedIdentityBase64: null,
      );
      expect(await alice.sessionRemoteIdentity(bobId), identityOf(bob));
      expect(await bob.decrypt(aliceId, await alice.encrypt(bobId, 'open')),
          'open');
      final whisper = await bob.encrypt(aliceId, 'whisper');
      expect(whisper, startsWith('2:'));
      expect(await alice.decrypt(bobId, whisper), 'whisper');

      expect(await alice.sessionRemoteIdentity(bobId), identityOf(bob));
      expect(await bob.sessionRemoteIdentity(aliceId), identityOf(alice));
    });

    test('stamp-before-move: the hook sees the OLD anchor while it still '
        'holds, and a failing stamp refuses the move', () async {
      final service = EncryptionService();
      await service.initialize(17, checkServerIdentity: () async => fresh);
      service.keyChangeWarnings = () => true;
      final peerStore = SecureIdentityKeyStore(
        DualStorage(const FlutterSecureStorage()),
        'e2e_17_',
      );
      final oldKey = _fresh();
      final newKey = _fresh();
      await peerStore.saveIdentity(const SignalProtocolAddress('42', 1), oldKey);
      await service.peerTofuIdentityBase64(42);
      await peerStore.isTrustedIdentity(
        const SignalProtocolAddress('42', 4),
        newKey,
        Direction.receiving,
      );
      await service.recordPeerIdentityChangedFromServer(42);

      final seen = <(int, String, String?)>[];
      var stampOk = false;
      service.onBeforeAnchorMoves = (peer, old) async {
        seen.add((peer, old, service.accountAnchorSync(peer)));
        return stampOk;
      };

      expect(await service.acknowledgePeerIdentity(42), isFalse);
      expect(await service.peerTofuIdentityBase64(42), _b64(oldKey));
      expect(service.accountAnchorSync(42), _b64(oldKey));

      stampOk = true;
      expect(await service.acknowledgePeerIdentity(42), isTrue);
      expect(await service.peerTofuIdentityBase64(42), _b64(newKey));
      expect(seen, [
        (42, _b64(oldKey), _b64(oldKey)),
        (42, _b64(oldKey), _b64(oldKey)),
      ]);
    });

    test('stamp-before-move guards replaceStaleAccountAnchor too', () async {
      final service = EncryptionService();
      await service.initialize(17, checkServerIdentity: () async => fresh);
      final peerStore = SecureIdentityKeyStore(
        DualStorage(const FlutterSecureStorage()),
        'e2e_17_',
      );
      final oldKey = _fresh();
      final newKey = _fresh();
      await peerStore.stageAccountIdentity('42', oldKey);
      await service.peerTofuIdentityBase64(42);

      var stampOk = false;
      final stamped = <String>[];
      service.onBeforeAnchorMoves = (peer, old) async {
        stamped.add(old);
        return stampOk;
      };

      await expectLater(
        service.replaceStaleAccountAnchor(42, _b64(newKey)),
        throwsStateError,
      );
      expect(await service.peerTofuIdentityBase64(42), _b64(oldKey));

      stampOk = true;
      await service.replaceStaleAccountAnchor(42, _b64(newKey));
      expect(await service.peerTofuIdentityBase64(42), _b64(newKey));
      expect(stamped, [_b64(oldKey), _b64(oldKey)]);
    });

    test('a first pin is reported, a move is not', () async {
      final service = EncryptionService();
      await service.initialize(17, checkServerIdentity: () async => fresh);
      final pinned = <(int, String)>[];
      service.onAccountAnchorPinned = (peer, idk) => pinned.add((peer, idk));
      final key = _fresh();
      // The staging entry a first contact uses pins through the service's
      // own store; a second, different key is no first pin.
      expect(await service.stageAccountAnchor(50, _b64(key)), isTrue);
      expect(await service.stageAccountAnchor(50, _b64(_fresh())), isFalse);

      expect(pinned, [(50, _b64(key))]);
    });
  });
}
