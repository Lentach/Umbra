// (xlviii) and (xlix): the recovery (xlvii) built must survive a restart, and
// re-affirming the pinned key must not destroy a candidate that arrived while
// the dialog was open.
//
// WHY THESE CANNOT BE WIDGET OR UNIT TESTS OF THE OLD SHAPE: three of the four
// concerns here are PERSISTENCE properties. A test that drives one live object
// cannot see them at all — the in-memory Set is correct in-process, and the bug
// is only that it is in-memory. Every "restart" below is therefore a genuinely
// fresh EncryptionService/EncryptionProvider constructed over the SAME mock
// storage, which is exactly what a relaunch is.
//
// WHAT EACH TEST IS FOR:
//   1. (xlix) re-affirming the pin while a DIFFERENT candidate stands is
//      REFUSED — the candidate survives and the warning stands. This is the
//      security finding: a malicious server serves the honest key so the
//      out-of-band comparison SUCCEEDS, injects its own key under the open
//      dialog, and the user's CORRECT confirmation used to delete the evidence.
//   2. (xlix) clause 2 at the store: adoptAccountIdentity leaves a candidate it
//      was not told about.
//   3. (xlviii) clause 1: a confirmed recovery's rebuild intent survives a
//      restart.
//   4. (xlviii) clause 1: a REFUSED acknowledgement leaves no intent behind.
//   5. (xlviii) clause 1: the intent is cleared only once a session really got
//      rebuilt.
//   6. (xlviii) clause 2: the persisted warning set evicts the LEAST RECENTLY
//      warned peer, not the numerically smallest id.
//   7. (xlviii) clause 2: a server-sourced identity change for a peer we hold
//      no anchor for is ignored.
//   8. (xlviii) clause 3: the device-list rollback pin survives a restart, so a
//      replayed older list is still refused as a rollback.

import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;
  const peerId = 42;

  late EncryptionProvider enc;
  late EncryptionService peerService;

  Map<String, dynamic> flatBundleFrom(EncryptionService source) {
    final upload = source.getKeysForUpload();
    expect(upload, isNotNull);
    final keyBundle = (upload!['keyBundle'] as Map).cast<String, dynamic>();
    final otps = (upload['oneTimePreKeys'] as List).cast<Map<String, dynamic>>();
    expect(otps, isNotEmpty);
    return {
      ...keyBundle,
      'oneTimePreKeyId': otps.first['keyId'],
      'oneTimePreKeyPublic': otps.first['publicKey'],
    };
  }

  /// A provider wired to a server that always serves [peerService]'s bundle.
  Future<EncryptionProvider> freshProvider() async {
    final provider = EncryptionProvider();
    provider.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        provider.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'fetchPreKeyBundle') {
        provider.onPreKeyBundleResponse({
          'userId': (data as Map)['userId'],
          'deviceId': data['deviceId'] ?? 1,
          'bundle': flatBundleFrom(peerService),
        });
      }
    });
    await provider.initializeE2E(ownUserId);
    return provider;
  }

  /// The peer's identity as this device pinned it on first contact.
  Future<String> pinnedPeerKeyBase64() async {
    final fingerprintSource = await enc.encryptionService
        .peerTofuIdentityBase64(peerId);
    expect(
      fingerprintSource,
      isNotNull,
      reason: 'first contact must have pinned an account anchor',
    );
    return fingerprintSource!;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    // The peer, as a real service, so their bundle and identity are genuine.
    peerService = EncryptionService();
    await peerService.initialize(
      peerId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );

    enc = await freshProvider();
    // First contact pins the peer's key as our account anchor.
    await enc.encryptionService.buildSession(
      peerId,
      flatBundleFrom(peerService),
      expectedIdentityBase64: null,
    );
    expect(enc.peersWithChangedIdentity, isEmpty);
  });

  test(
    'reaffirming the pin is REFUSED while a different candidate stands',
    () async {
      // A warning is standing, corroborated by the server event.
      await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);
      expect(enc.peersWithChangedIdentity, contains(peerId));

      // The attacker's key lands in the candidate slot while the dialog is
      // open. Staging through the production clause-3 path is exactly what an
      // inbound ciphertext under a foreign key would do to that slot.
      final evil = base64Encode(
        generateIdentityKeyPair().getPublicKey().serialize(),
      );
      await enc.encryptionService.peerIdentityVerification(
        peerId,
        servedIdentityBase64: evil,
      );

      // The user compares the HONEST (pinned) number, which matches, and
      // confirms. Before (xlix) this deleted the attacker's candidate and
      // consumed the warning, leaving the injection unobservable forever.
      final pinned = await pinnedPeerKeyBase64();
      final advanced = await enc.acknowledgePeerIdentity(
        peerId,
        adoptIdentityBase64: pinned,
      );

      expect(
        advanced,
        isFalse,
        reason: 'a candidate that appeared after the display must be refused',
      );
      expect(
        enc.peersWithChangedIdentity,
        contains(peerId),
        reason: 'the warning is the only door back to the ceremony',
      );
      final verification = await enc.encryptionService.peerIdentityVerification(
        peerId,
      );
      expect(
        verification.offeredIdentityBase64,
        evil,
        reason: 'the injected candidate must survive to be compared',
      );
    },
  );

  test('adoptAccountIdentity leaves a candidate it was not told about',
      () async {
    final store = SecureIdentityKeyStore(
      DualStorage(const FlutterSecureStorage()),
      'durability_test_',
    );
    final candidate = generateIdentityKeyPair().getPublicKey();
    final accepted = generateIdentityKeyPair().getPublicKey();
    await store.stagePendingAccountIdentity('99', candidate);

    // Adopting while asserting "no candidate was observed" must not delete the
    // one that appeared since.
    await store.adoptAccountIdentity(
      '99',
      accepted,
      expectedPendingBase64: null,
    );

    final held = await store.pendingAccountIdentity('99');
    expect(held, isNotNull);
    expect(
      base64Encode(held!.serialize()),
      base64Encode(candidate.serialize()),
    );
  });

  // (lviii) Finding RC-03. The two (xlix) clauses each did their job and still
  // lost between them: the slot is read BEFORE the write, the guard inside the
  // store returned SILENTLY, and the caller — learning nothing — consumed the
  // warning that is the only door back to the ceremony.
  group('(lviii) the guarded write REPORTS whether its guard held', () {
    SecureIdentityKeyStore storeWith(DualStorage storage) =>
        SecureIdentityKeyStore(storage, 'lviii_test_');

    test('reports FALSE when a candidate it was not told about is present',
        () async {
      final store = storeWith(DualStorage(const FlutterSecureStorage()));
      final candidate = generateIdentityKeyPair().getPublicKey();
      final accepted = generateIdentityKeyPair().getPublicKey();
      await store.stagePendingAccountIdentity('99', candidate);

      final guardHeld = await store.adoptAccountIdentity(
        '99',
        accepted,
        expectedPendingBase64: null,
      );

      // This is the signal the caller needs to keep the warning standing.
      expect(guardHeld, isFalse);
      // And it still must not delete evidence it was never told about.
      expect(await store.pendingAccountIdentity('99'), isNotNull);
    });

    test('reports FALSE when the staged candidate CHANGED', () async {
      final store = storeWith(DualStorage(const FlutterSecureStorage()));
      final displayed = generateIdentityKeyPair().getPublicKey();
      final arrivedSince = generateIdentityKeyPair().getPublicKey();
      await store.stagePendingAccountIdentity('99', arrivedSince);

      final guardHeld = await store.adoptAccountIdentity(
        '99',
        displayed,
        expectedPendingBase64: base64Encode(displayed.serialize()),
      );

      expect(guardHeld, isFalse);
      expect(
        base64Encode((await store.pendingAccountIdentity('99'))!.serialize()),
        base64Encode(arrivedSince.serialize()),
        reason: 'the key that arrived since must survive to be compared',
      );
    });

    test('reports TRUE and consumes the candidate it WAS told about', () async {
      final store = storeWith(DualStorage(const FlutterSecureStorage()));
      final displayed = generateIdentityKeyPair().getPublicKey();
      await store.stagePendingAccountIdentity('99', displayed);

      final guardHeld = await store.adoptAccountIdentity(
        '99',
        displayed,
        expectedPendingBase64: base64Encode(displayed.serialize()),
      );

      expect(guardHeld, isTrue);
      expect(await store.pendingAccountIdentity('99'), isNull);
    });

    test('POSITIVE CONTROL: reports TRUE when the slot is genuinely empty',
        () async {
      final store = storeWith(DualStorage(const FlutterSecureStorage()));
      final accepted = generateIdentityKeyPair().getPublicKey();

      // The ordinary re-affirmation. If this reported false, every legitimate
      // acknowledgement would refuse to clear its own warning.
      expect(
        await store.adoptAccountIdentity(
          '99',
          accepted,
          expectedPendingBase64: null,
        ),
        isTrue,
      );
    });

    // NOT COVERED END TO END, deliberately. Reaching the caller's branch
    // requires a candidate to arrive BETWEEN the service reading the slot and
    // `adoptAccountIdentity` reading it again, and EncryptionService builds its
    // own stores from a key prefix — so there is no way to interleave a write
    // without adding a test-only seam to production code, which this codebase
    // does not do. A service-level test that merely STAGES a candidate first
    // would pass for the WRONG reason: a non-null slot is caught by the
    // pre-existing (xlix) clause-1 check and never reaches the new report.
    // The contract above is the whole fix; the caller consuming it is a
    // two-line branch.
  });

  test('a confirmed recovery rebuild intent survives a restart', () async {
    await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);
    final pinned = await pinnedPeerKeyBase64();

    // Re-affirming the pinned key is a legitimate resolution that advances the
    // anchor, so it takes the same durable path a served-key adoption does.
    final advanced = await enc.acknowledgePeerIdentity(
      peerId,
      adoptIdentityBase64: pinned,
    );
    expect(advanced, isTrue);
    expect(
      enc.encryptionService.pendingSessionRebuilds,
      contains((peerId, 1)),
      reason: 'the intent must be durable, not just in provider memory',
    );

    // RESTART: a brand new provider and service over the same storage.
    final revived = await freshProvider();
    expect(
      revived.needsSessionRebuild(peerId, deviceId: 1),
      isTrue,
      reason: 'the poisoned session must still be scheduled for rebuild',
    );
  });

  test('a refused acknowledgement leaves no rebuild intent behind', () async {
    await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);

    // A key this device never recorded: refused outright.
    final unrecorded = base64Encode(
      generateIdentityKeyPair().getPublicKey().serialize(),
    );
    final advanced = await enc.acknowledgePeerIdentity(
      peerId,
      adoptIdentityBase64: unrecorded,
    );
    expect(advanced, isFalse);
    expect(
      enc.encryptionService.pendingSessionRebuilds,
      isEmpty,
      reason: 'nothing advanced, so nothing is poisoned',
    );
  });

  test(
    'a refused second acknowledgement keeps the first one\'s rebuild intent',
    () async {
      await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);
      final pinned = await pinnedPeerKeyBase64();
      // The first acknowledgement goes through; its rebuild has not run yet
      // (a box friend with no served bundle throws and leaves the intent).
      expect(
        await enc.acknowledgePeerIdentity(peerId, adoptIdentityBase64: pinned),
        isTrue,
      );
      expect(enc.encryptionService.pendingSessionRebuilds, contains((peerId, 1)));

      // A stale dialog or a double tap acknowledges again: nothing is staged
      // any more, so it is refused and used to wipe EVERY intent for the peer.
      expect(
        await enc.acknowledgePeerIdentity(peerId, adoptIdentityBase64: pinned),
        isFalse,
      );

      // The app is killed before the rebuild happens.
      final revived = await freshProvider();
      expect(
        revived.needsSessionRebuild(peerId, deviceId: 1),
        isTrue,
        reason: 'the session is still keyed to the replaced identity',
      );
    },
  );

  test('the intent is cleared only once a session is really rebuilt', () async {
    await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);
    final pinned = await pinnedPeerKeyBase64();
    await enc.acknowledgePeerIdentity(peerId, adoptIdentityBase64: pinned);
    expect(enc.encryptionService.pendingSessionRebuilds, contains((peerId, 1)));

    await enc.ensureSession(peerId, deviceId: 1);

    expect(
      enc.encryptionService.pendingSessionRebuilds,
      isEmpty,
      reason: 'a built session satisfies the intent',
    );
    // And it does not come back on the next launch.
    final revived = await freshProvider();
    expect(revived.needsSessionRebuild(peerId, deviceId: 1), isFalse);
  });

  test('the warning set evicts the least recently warned, not the lowest id',
      () async {
    // The cap is a production constant (200) and must not be lowered to suit a
    // test, so this genuinely fills it. Every peer needs a pinned anchor,
    // because an identity change for a peer we hold no key for is now ignored.
    final bundle = flatBundleFrom(peerService);
    const flood = 205;
    for (var i = 1; i <= flood; i++) {
      final id = 1000 + i;
      await enc.encryptionService.buildSession(
        id,
        bundle,
        expectedIdentityBase64: null,
      );
      await enc.encryptionService.recordPeerIdentityChangedFromServer(id);
    }
    // peerId was warned LAST, and holds the numerically SMALLEST id of the set.
    await enc.encryptionService.recordPeerIdentityChangedFromServer(peerId);

    final revived = await freshProvider();
    expect(
      revived.peersWithChangedIdentity,
      contains(peerId),
      reason: 'the most recent warning must survive; sorting by id dropped it',
    );
    expect(
      revived.peersWithChangedIdentity,
      isNot(contains(1001)),
      reason: 'the oldest warning is the one a quota should drop',
    );
  });

  test('a server identity change for a peer with no anchor is ignored',
      () async {
    const stranger = 8888;
    await enc.encryptionService.recordPeerIdentityChangedFromServer(stranger);
    expect(
      enc.peersWithChangedIdentity,
      isNot(contains(stranger)),
      reason: 'no anchor means no identity could have changed',
    );
  });

  test('the device-list rollback pin survives a restart', () async {
    final engine = DeviceAuthorityEngine();
    final identity = generateIdentityKeyPair();
    final enrollment = engine.mintEnrollment(
      userId: peerId,
      identity: identity,
      createdAtMs: 1234567890,
    );
    final tofu = base64Encode(identity.getPublicKey().serialize());

    Map<String, dynamic> authorizationAt(int version) {
      final signed = engine.signList(
        DeviceList(
          userId: peerId,
          version: version,
          devices: [
            DeviceListEntry(
              deviceId: version,
              platform: 'web',
              addedAtMs: 1000 * version,
            ),
          ],
        ),
      );
      return {
        'dakPub': enrollment['dakPub'],
        'enrollmentSig': enrollment['enrollmentSig'],
        'enrollmentCreatedAt': enrollment['createdAt'],
        'listVersion': version,
        'listSignature': signed['listSignature'],
        'listCanonical': signed['listCanonical'],
      };
    }

    // Verify at v3 and persist the floor through the production hook.
    final cache = DeviceListCache();
    cache.onPinAdvanced = (id, version) {
      enc.encryptionService.recordDeviceListPin(id, version);
    };
    cache.adopt(
      userId: peerId,
      authorization: authorizationAt(3),
      tofuIdentityKeyBase64: tofu,
    );
    expect(cache.pinnedVersion(peerId), 3);

    // RESTART: a fresh service reads the persisted floor, and a fresh cache is
    // seeded from it exactly as the provider does on init.
    final revivedService = EncryptionService();
    await revivedService.initialize(
      ownUserId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
    );
    final revivedCache = DeviceListCache()
      ..seedPins(revivedService.deviceListPins);
    expect(
      revivedCache.pinnedVersion(peerId),
      3,
      reason: 'the floor must not reset on relaunch',
    );

    // The replayed older list is still a rollback.
    expect(
      () => revivedCache.adopt(
        userId: peerId,
        authorization: authorizationAt(1),
        tofuIdentityKeyBase64: tofu,
      ),
      throwsA(
        isA<DeviceListVerificationException>().having(
          (e) => e.reason,
          'reason',
          'version_rollback',
        ),
      ),
    );
    // And so is the enrolled -> not-enrolled downgrade the (xix) check refuses.
    expect(
      () => revivedCache.adopt(
        userId: peerId,
        authorization: null,
        tofuIdentityKeyBase64: tofu,
      ),
      throwsA(isA<DeviceListVerificationException>()),
    );
  });

  // (lvii) Finding F6. The floor used to be restored inside a bare
  // `catch (_) {}`, so an unreadable store was indistinguishable from "never
  // pinned" — and an empty floor is NOT neutral: it is exactly the state in
  // which a server may replay an older validly-signed list, or downgrade a
  // previously enrolled peer to the synthesised single device.
  group('(lvii) the rollback floor fails CLOSED', () {
    /// The key `_loadDeviceListPins` reads, for the OWN user.
    String pinsKey(int userId) => 'e2e_${userId}_devicelist_pins_v1';

    test('a CORRUPT pins blob makes initialize THROW, not start empty',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(pinsKey(ownUserId), '{not json at all');

      final revived = EncryptionService();
      await expectLater(
        revived.initialize(
          ownUserId,
          checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
        ),
        throwsA(anything),
        reason: 'silently continuing would reopen the (xix) rollback window',
      );
      // Nothing was invented to fill the gap.
      expect(revived.deviceListPins, isEmpty);
    });

    test('a non-map pins blob is refused too', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(pinsKey(ownUserId), '["not", "a", "map"]');

      final revived = EncryptionService();
      await expectLater(
        revived.initialize(
          ownUserId,
          checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('POSITIVE CONTROL: NO stored pins is a genuine absence, not an error',
        () async {
      // A device that never pinned anything has no floor to lose, so this must
      // stay silent — otherwise every fresh install fails to initialize.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pinsKey(ownUserId));

      final revived = EncryptionService();
      await expectLater(
        revived.initialize(
          ownUserId,
          checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
        ),
        completes,
      );
      expect(revived.deviceListPins, isEmpty);
    });

    test('POSITIVE CONTROL: one unusable ENTRY does not deny the others',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        pinsKey(ownUserId),
        '{"42": 7, "not-an-id": 3, "99": "not-an-int"}',
      );

      final revived = EncryptionService();
      await revived.initialize(
        ownUserId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: true),
      );

      // One lost floor is not a lost store: peer 42 keeps its pin.
      expect(revived.deviceListPins[42], 7);
      expect(revived.deviceListPins.containsKey(99), isFalse);
    });
  });
}
