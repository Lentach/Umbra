import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stage C1 of T4 (spec §5.2/§5.4): the crypto layer addresses sessions by
/// (userId, deviceId), not userId alone. Two devices of one peer hold
/// INDEPENDENT ratchets, and the serialization seam — the per-address tail
/// queue plus the cross-context Web Lock name — must key on the composite,
/// or one device's store clobbers the other's advance.
///
/// Both "devices" of the peer run the app's real [EncryptionService]
/// (real libsignal, no crypto mocking), each initialized under its OWN
/// storage-namespace userId — exactly how two physical devices have two
/// disjoint stores. What makes them "the same peer, two devices" is the
/// ADDRESS the sender encrypts to: (peerId, 1) and (peerId, 2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;

  /// Assembles the FLAT map [EncryptionService.buildSession] expects from
  /// the nested `getKeysForUpload()` shape, like `fetchPreKeyBundle` serves.
  Map<String, dynamic> flatBundleFrom(EncryptionService peer) {
    final upload = peer.getKeysForUpload();
    expect(upload, isNotNull);
    final keyBundle = (upload!['keyBundle'] as Map).cast<String, dynamic>();
    final otps = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>();
    expect(otps, isNotEmpty);
    final otp = otps.first;
    return {
      ...keyBundle,
      'oneTimePreKeyId': otp['keyId'],
      'oneTimePreKeyPublic': otp['publicKey'],
    };
  }

  group('per-device Signal addressing (T4 C1)', () {
    late EncryptionService alice;
    late EncryptionService bobDev1;
    late EncryptionService bobDev2;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      alice = EncryptionService();
      bobDev1 = EncryptionService();
      bobDev2 = EncryptionService();
      await alice.initialize(
        aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
      );
      // Distinct storage namespaces stand in for the two devices' disjoint
      // local stores (keys are `e2e_${userId}_`-prefixed).
      await bobDev1.initialize(
        bobId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
      );
      await bobDev2.initialize(99, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    });

    test('sessions to (peer,1) and (peer,2) are independent: distinct '
        'ciphertexts, each decrypts only on its own device, and building '
        'device 2 never disturbs device 1', () async {
      await alice.buildSession(bobId, flatBundleFrom(bobDev1), expectedIdentityBase64: null);
      const first = 'to device 1 before device 2 exists';
      final wireBefore = await alice.encrypt(bobId, first);
      expect(await bobDev1.decrypt(aliceId, wireBefore), first);

      // Device 2 appears; its session is built at the SAME userId under
      // deviceId 2 — the device-1 record must be untouched.
      await alice.buildSession(bobId, flatBundleFrom(bobDev2), deviceId: 2, expectedIdentityBase64: null);
      expect(await alice.hasSession(bobId), isTrue);
      expect(await alice.hasSession(bobId, deviceId: 2), isTrue);

      const plaintext = 'same words to both devices';
      final wire1 = await alice.encrypt(bobId, plaintext);
      final wire2 = await alice.encrypt(bobId, plaintext, deviceId: 2);
      expect(
        wire1,
        isNot(wire2),
        reason:
            'each device gets its OWN pairwise ciphertext — '
            'reusing one bricks a ratchet',
      );

      expect(await bobDev1.decrypt(aliceId, wire1), plaintext);
      expect(await bobDev2.decrypt(aliceId, wire2), plaintext);

      // Device 1's ratchet still advances cleanly after device-2 traffic —
      // proof the two records never shared state.
      const followUp = 'device 1 still healthy';
      final wireAfter = await alice.encrypt(bobId, followUp);
      expect(await bobDev1.decrypt(aliceId, wireAfter), followUp);
    });

    test(
      'deleteSession of device 2 leaves the device-1 record standing',
      () async {
        await alice.buildSession(bobId, flatBundleFrom(bobDev1), expectedIdentityBase64: null);
        await alice.buildSession(bobId, flatBundleFrom(bobDev2), deviceId: 2, expectedIdentityBase64: null);
        await alice.deleteSession(bobId, deviceId: 2);
        expect(await alice.hasSession(bobId, deviceId: 2), isFalse);
        expect(await alice.hasSession(bobId), isTrue);
      },
    );

    // Issue #208: a handoff over a session the friend never answered is a
    // PreKey message it refuses unasked. Mutation: answer `hasSession`.
    test('a session this device opened is ANSWERED only once a reply from '
        'that device decrypts', () async {
      await alice.buildSession(bobId, flatBundleFrom(bobDev1), expectedIdentityBase64: null);
      expect(await alice.hasSession(bobId), isTrue);
      expect(await alice.hasAnsweredSession(bobId, deviceId: 1), isFalse);

      final hello = await alice.encrypt(bobId, 'hello');
      expect(await alice.hasAnsweredSession(bobId, deviceId: 1), isFalse);
      expect(await bobDev1.decrypt(aliceId, hello), 'hello');
      final reply = await bobDev1.encrypt(aliceId, 'hi');
      expect(await alice.decrypt(bobId, reply), 'hi');

      expect(await alice.hasAnsweredSession(bobId, deviceId: 1), isTrue);
      expect(await alice.hasAnsweredSession(bobId, deviceId: 2), isFalse);
    });

    test('serialization lock names do not collapse two devices of one peer, '
        'and device 1 keeps the exact legacy name', () async {
      final lockNames = <String>[];
      final locked = EncryptionService(
        sessionCrossContextLock: <T>(name, action) {
          lockNames.add(name);
          return action();
        },
      );
      await locked.initialize(
        aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
      );
      await locked.buildSession(bobId, flatBundleFrom(bobDev1), expectedIdentityBase64: null);
      await locked.buildSession(bobId, flatBundleFrom(bobDev2), deviceId: 2, expectedIdentityBase64: null);
      // Legacy name EXACTLY for device 1: an old PWA tab still locks it
      // during a rollout window, and a rename would let two builds
      // interleave on the same persisted device-1 record.
      expect(lockNames, contains('fireplace-e2e-session-$aliceId-$bobId'));
      expect(lockNames, contains('fireplace-e2e-session-$aliceId-$bobId-d2'));
    });
  });

  group('EncryptionProvider per-device fetch pairing (T4 C1)', () {
    late EncryptionProvider provider;
    late List<Map<String, dynamic>> emitted;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      emitted = <Map<String, dynamic>>[];
      provider = EncryptionProvider();
      provider.setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await provider.initializeE2E(7);
    });

    test('fetchPreKeyBundle emit carries deviceId for devices >= 2 and '
        'omits it for device 1 (older-server compat)', () async {
      final f1 = provider.ensureSession(50);
      final f2 = provider.ensureSession(50, deviceId: 2);
      await Future<void>.delayed(Duration.zero);
      final fetches = emitted
          .where((e) => e['event'] == 'fetchPreKeyBundle')
          .map((e) => e['data'] as Map<String, dynamic>)
          .toList();
      expect(fetches, hasLength(2));
      expect(fetches[0], {'userId': 50});
      expect(fetches[1], {'userId': 50, 'deviceId': 2});
      // Refuse both so the test ends deterministically.
      provider.onPreKeyBundleResponse({'userId': 50, 'bundle': null});
      provider.onPreKeyBundleResponse({
        'userId': 50,
        'deviceId': 2,
        'bundle': null,
      });
      await expectLater(f1, throwsStateError);
      await expectLater(f2, throwsStateError);
    });

    test('a response WITHOUT deviceId is treated as device 1', () async {
      final f1 = provider.ensureSession(60);
      await Future<void>.delayed(Duration.zero);
      expect(provider.pendingPreKeyFetches.containsKey((60, 1)), isTrue);
      provider.onPreKeyBundleResponse({'userId': 60, 'bundle': null});
      await expectLater(f1, throwsStateError);
      expect(provider.pendingPreKeyFetches.containsKey((60, 1)), isFalse);
    });

    test('a device-2 response never completes the device-1 fetch', () async {
      final f1 = provider.ensureSession(70);
      final f2 = provider.ensureSession(70, deviceId: 2);
      await Future<void>.delayed(Duration.zero);
      provider.onPreKeyBundleResponse({
        'userId': 70,
        'deviceId': 2,
        'bundle': null,
      });
      await expectLater(f2, throwsStateError);
      expect(
        provider.pendingPreKeyFetches.containsKey((70, 1)),
        isTrue,
        reason: 'the device-1 fetch must still be in flight',
      );
      provider.onPreKeyBundleResponse({'userId': 70, 'bundle': null});
      await expectLater(f1, throwsStateError);
    });
  });
}
