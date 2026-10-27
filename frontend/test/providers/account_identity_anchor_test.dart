import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
// F4 / KA-02 (spec §12 amendment (lvi)): the (xxxix) expected-identity gate was
// VACUOUS in the two states that are the default rather than the edge.
//
// `_accountIdentityAnchor` resolved the anchor by scanning per-device rows of
// the CACHED verified device list, excluding the device being built, and
// `buildSession` no-ops when the expected identity is null. So the anchor came
// back null — and the §3 account-wide identity binding went unenforced — for:
//
//   1. ANY COLD CACHE. The verified-list cache is memory-only, so every first
//      send after launch resolved nothing.
//   2. ANY SINGLE-LIVE-DEVICE PEER. `notEnrolled()` synthesises device 1 alone,
//      so the only candidate IS the device being built, and it is skipped. That
//      is every non-enrolled account — i.e. most users.
//
// These tests drive the REAL provider `ensureSession` against a server that
// serves a FOREIGN identity key for a peer whose real key this device already
// pinned. That is exactly the capability §2 says a server alone does not have.
//
// WHAT EACH TEST IS FOR:
//   1. cold cache: the substitution is REFUSED, not silently trusted
//   2. cold cache: the refusal is VISIBLE ((lv)), or it is just a dead chat
//   3. single-live-device peer: same refusal on the most common account shape
//   4. POSITIVE CONTROL: the peer's OWN key still builds on a cold cache — the
//      fix must not block ordinary messaging, which is the whole risk of (lvi)
//   5. POSITIVE CONTROL: genuine first contact with an ACCOUNT stays TOFU
//
// Everything here is a real production object except the socket transport.

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;
  const peerId = 42;

  late EncryptionProvider enc;
  late EncryptionService peer;
  late EncryptionService mallory;

  /// Which identity the stubbed server serves for the peer's bundle.
  late EncryptionService served;

  /// How many times the stubbed server was asked for a prekey bundle. This is
  /// what distinguishes a REAL rebuild from `ensureSession` returning early
  /// because a session already exists.
  late int bundleFetches;

  /// The authorization the stubbed server answers `getDeviceList` with, or null
  /// to leave the verified-list cache COLD (the default every launch begins in).
  Map<String, dynamic>? servedAuthorization;

  /// When set, bundle fetches are HELD here instead of answered, so a test
  /// decides when (and whether) the stubbed server answers each one.
  List<int>? heldFetches;

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

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    peer = EncryptionService();
    await peer.initialize(peerId, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    mallory = EncryptionService();
    await mallory.initialize(99, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    served = peer;
    bundleFetches = 0;
    servedAuthorization = null;
    heldFetches = null;

    enc = EncryptionProvider();
    enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'fetchPreKeyBundle') {
        bundleFetches++;
        final deviceId = (data as Map)['deviceId'] as int? ?? 1;
        if (heldFetches case final held?) {
          held.add(deviceId);
          return;
        }
        enc.onPreKeyBundleResponse({
          'userId': peerId,
          'deviceId': deviceId,
          'bundle': flatBundleFrom(served),
        });
      }
      if (event == 'getDeviceList') {
        // Answered ONLY when a test opts in. Left null the cache stays EMPTY,
        // which is the cold-cache state every launch begins in.
        if (servedAuthorization == null) return;
        enc.onDeviceList({
          'userId': peerId,
          'authorization': servedAuthorization,
        });
      }
    });
    await enc.initializeE2E(ownUserId);
    // (lxxix) flipped the DEFAULT to demoted (auto-acknowledge). These tests
    // assert the manual ceremony/refusal surface, so they opt back in.
    enc.encryptionService.keyChangeWarnings = () => true;
  });

  /// First contact the honest way: pins the peer's real key as the ACCOUNT
  /// anchor, exactly as an ordinary conversation would.
  Future<void> pinPeerHonestly() async {
    await enc.encryptionService.buildSession(
      peerId,
      flatBundleFrom(peer),
      expectedIdentityBase64: null,
    );
    expect(enc.peersWithChangedIdentity, isEmpty);
    expect(
      await enc.encryptionService.peerTofuIdentityBase64(peerId),
      isNotNull,
      reason: 'the account anchor is the state the whole fix depends on',
    );
  }

  group('(lvi) the account anchor backs the (xxxix) gate', () {
    test('COLD CACHE: a substituted identity is REFUSED', () async {
      await pinPeerHonestly();
      expect(
        enc.cachedDeviceList(peerId),
        isNull,
        reason: 'this test is only meaningful while the cache is cold',
      );

      // The server now answers the peer's bundle fetch with Mallory's key, on
      // a device id the peer's list could legitimately name.
      served = mallory;

      await expectLater(
        enc.ensureSession(peerId, deviceId: 2),
        throwsA(isA<AccountIdentityMismatch>()),
      );

      // Fail CLOSED: nothing trusted, so a retry cannot find the attacker's
      // key already in place.
      expect(await enc.encryptionService.peerIdentityAt(peerId, 2), isNull);
    });

    test('COLD CACHE: the refusal is VISIBLE, not a dead chat', () async {
      await pinPeerHonestly();
      served = mallory;

      await expectLater(
        enc.ensureSession(peerId, deviceId: 2),
        throwsA(isA<AccountIdentityMismatch>()),
      );

      // (lv) is a hard prerequisite of (lvi): without the banner this ruling
      // would trade a MITM window for a permanent unexplained lockout.
      expect(enc.peersWithChangedIdentity, contains(peerId));
      final verification = await enc.encryptionService
          .peerIdentityVerification(peerId);
      expect(
        verification.offeredIdentityBase64,
        flatBundleFrom(mallory)['identityPublicKey'],
        reason: 'the ceremony must be able to show the key that was refused',
      );
    });

    test('SINGLE LIVE DEVICE: the substitution is REFUSED there too', () async {
      await pinPeerHonestly();

      // The most common account shape: the peer has never enrolled, so their
      // synthesised list names device 1 alone — the very device being built.
      // Before (lvi) the per-device scan skipped it and resolved nothing.
      await expectLater(
        enc.ensureSession(peerId),
        completes,
        reason: 'device 1 with the peer OWN key must still build',
      );

      served = mallory;
      enc.markSessionRebuild(peerId);

      await expectLater(
        enc.ensureSession(peerId),
        throwsA(isA<AccountIdentityMismatch>()),
      );
      expect(enc.peersWithChangedIdentity, contains(peerId));
    });

    test('POSITIVE CONTROL: the peer OWN key builds on a cold cache', () async {
      await pinPeerHonestly();
      expect(enc.cachedDeviceList(peerId), isNull);

      // THE RISK OF (lvi) IS EXACTLY THIS CASE. The account anchor is now
      // consulted for almost every send, so a bug here does not weaken
      // security — it blocks ordinary messaging for everyone.
      await expectLater(enc.ensureSession(peerId, deviceId: 2), completes);

      expect(
        await enc.encryptionService.peerIdentityAt(peerId, 2),
        await enc.encryptionService.peerTofuIdentityBase64(peerId),
        reason: 'a legitimate sibling device shares the account identity (§3)',
      );
      expect(enc.peersWithChangedIdentity, isEmpty);
    });

    test('POSITIVE CONTROL: genuine first contact stays TOFU', () async {
      // No anchor for this account at all, so there is nothing to compare and
      // the gate must stay trusting — first contact is irreducibly TOFU.
      expect(
        await enc.encryptionService.peerTofuIdentityBase64(peerId),
        isNull,
      );

      await expectLater(enc.ensureSession(peerId), completes);
      expect(enc.peersWithChangedIdentity, isEmpty);
    });
  });

  // (lix) Finding RC-04. The in-memory rebuild intent was consumed on the first
  // line of ensureSession and never restored, so ONE failed rebuild made every
  // later call in the process short-circuit on `hasSession` and hand back the
  // very session the rebuild existed to replace.
  group('(lix) a failed rebuild keeps its intent', () {
    test('the intent SURVIVES a refused rebuild', () async {
      await pinPeerHonestly();
      await enc.ensureSession(peerId);
      expect(await enc.encryptionService.hasSession(peerId), isTrue);

      enc.markSessionRebuild(peerId);
      expect(enc.needsSessionRebuild(peerId), isTrue);

      // The rebuild is refused — the (lvi) path, and the same branch a server
      // that never answers fetchPreKeyBundle reaches by timeout.
      served = mallory;
      await expectLater(
        enc.ensureSession(peerId),
        throwsA(isA<AccountIdentityMismatch>()),
      );

      // THE FINDING: without this the poisoned session is reused silently for
      // the rest of the process.
      expect(
        enc.needsSessionRebuild(peerId),
        isTrue,
        reason: 'a consumed intent must be restored when the rebuild fails',
      );
    });

    test('so a LATER attempt actually rebuilds instead of short-circuiting',
        () async {
      await pinPeerHonestly();
      await enc.ensureSession(peerId);

      enc.markSessionRebuild(peerId);
      served = mallory;
      await expectLater(
        enc.ensureSession(peerId),
        throwsA(isA<AccountIdentityMismatch>()),
      );

      // The server stops lying. The retry must go through the FULL rebuild —
      // asserting only that it "completes" would pass even when the intent was
      // lost, because the early return completes too. The fetch count is what
      // tells a real rebuild from a short-circuit.
      served = peer;
      final fetchesBefore = bundleFetches;
      await expectLater(enc.ensureSession(peerId), completes);
      expect(
        bundleFetches,
        fetchesBefore + 1,
        reason: 'a restored intent must drive a genuine refetch and rebuild',
      );
      expect(
        enc.needsSessionRebuild(peerId),
        isFalse,
        reason: 'a successful rebuild finally consumes the intent',
      );
    });


    test('POSITIVE CONTROL: a SUCCESSFUL rebuild consumes the intent once',
        () async {
      await pinPeerHonestly();
      await enc.ensureSession(peerId);

      enc.markSessionRebuild(peerId);
      await expectLater(enc.ensureSession(peerId), completes);

      // The restore must not re-arm a rebuild that succeeded, or every send
      // would rebuild forever.
      expect(enc.needsSessionRebuild(peerId), isFalse);
    });
  });

  // (lxi)/(lxii)/(lxiii), from the SECOND gate round, which reviewed (lv)/(lvi)
  // themselves. The gate is only as good as the value it compares against, and
  // (lvi) resolved that value from the WEAKER of two sources.
  group('(lxi) the ACCOUNT anchor wins over a per-device row', () {
    test('a poisoned per-device row cannot arm the gate', () async {
      // The peer's REAL pair, so the enrollment that signs their device list is
      // made by the same identity their served bundle carries (§3: one IK per
      // account). Overriding the bundle's identityPublicKey instead would
      // invalidate its signed-prekey signature and fail for the wrong reason.
      final peerIdentity = await peer.identityKeyPairForLinking();
      final peerIdentityB64 =
          flatBundleFrom(peer)['identityPublicKey'] as String;
      final engine = DeviceAuthorityEngine();
      final enrollment = engine.mintEnrollment(
        userId: peerId,
        identity: peerIdentity,
        createdAtMs: 1234567890,
      );
      final signed = engine.signList(
        DeviceList(
          userId: peerId,
          version: 1,
          devices: const [
            DeviceListEntry(deviceId: 1, platform: 'web', addedAtMs: 1000),
            DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 2000),
          ],
        ),
      );

      // 1. Pin the peer's REAL key as the account anchor, the honest way.
      await enc.encryptionService.buildSession(
        peerId,
        flatBundleFrom(peer),
        expectedIdentityBase64: null,
      );
      expect(
        await enc.encryptionService.peerTofuIdentityBase64(peerId),
        peerIdentityB64,
      );

      // 2. Cache a genuinely VERIFIED list naming devices 1 and 2, so the
      //    per-device scan has a candidate to find at all. Driven through the
      //    real request/answer round trip: onDeviceList completes a pending
      //    fetch, so an unsolicited push caches nothing.
      servedAuthorization = {
        'dakPub': enrollment['dakPub'],
        'enrollmentSig': enrollment['enrollmentSig'],
        'enrollmentCreatedAt': enrollment['createdAt'],
        'listVersion': 1,
        'listSignature': signed['listSignature'],
        'listCanonical': signed['listCanonical'],
      };
      final verified = await enc.getVerifiedDeviceList(peerId);
      expect(
        verified.liveDeviceIds,
        [1, 2],
        reason: 'the scan needs a cached list, or this proves nothing',
      );
      expect(enc.cachedDeviceList(peerId), isNotNull);

      // 3. POISON the (peer, device 2) row through the production TOFU path:
      //    a build with no expectation saves whatever key arrives. This is
      //    what an admitted inbound ciphertext does via isTrustedIdentity.
      await enc.encryptionService.buildSession(
        peerId,
        flatBundleFrom(mallory),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      expect(
        await enc.encryptionService.peerIdentityAt(peerId, 2),
        flatBundleFrom(mallory)['identityPublicKey'],
        reason: 'the per-device row is now the attacker key',
      );
      // The ACCOUNT anchor must NOT have moved — only a human moves it.
      expect(
        await enc.encryptionService.peerTofuIdentityBase64(peerId),
        peerIdentityB64,
      );

      // 4. Now rebuild device 1 while the server serves the attacker key.
      //    Pre-(lxi) the scan skipped device 1, found the poisoned device-2
      //    row, and compared the attacker's key to itself — a silent BUILD.
      served = mallory;
      enc.markSessionRebuild(peerId);
      await expectLater(
        enc.ensureSession(peerId),
        throwsA(isA<AccountIdentityMismatch>()),
        reason: 'the human-gated anchor must decide, not a TOFU-written row',
      );
    });

    test('POSITIVE CONTROL: the per-device row still answers with NO anchor',
        () async {
      // A peer known only from a per-device row (pre-(xlvi) storage, or an
      // anchor that never landed) must still get an expectation rather than
      // none — that fallback is what (lvi) exists for.
      expect(
        await enc.encryptionService.peerTofuIdentityBase64(peerId),
        isNull,
      );
      await expectLater(enc.ensureSession(peerId), completes);
      expect(enc.peersWithChangedIdentity, isEmpty);
    });
  });

  group('(lxii) a failed anchor READ is not an absence', () {
    test('the gate accessor THROWS rather than answering null', () async {
      // The device-list chain wants null on failure (it becomes
      // no_tofu_identity and refuses); this gate treats null as first contact
      // and stays TRUSTING, so null on failure is fail-OPEN. Two contracts.
      final fresh = EncryptionService();
      await expectLater(
        fresh.peerAccountAnchorForGate(peerId),
        throwsA(isA<StateError>()),
      );
      // The other contract is unchanged and still answers null.
      expect(await fresh.peerTofuIdentityBase64(peerId), isNull);
    });
  });

  group('(lxiii) the refusal must not clobber a genuine candidate', () {
    test('an existing candidate SURVIVES a later refusal', () async {
      await pinPeerHonestly();

      // A candidate recorded from a real inbound key, via the production TOFU
      // path: this stages mallory's key as the pending candidate.
      await enc.encryptionService.buildSession(
        peerId,
        flatBundleFrom(mallory),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      final staged = (await enc.encryptionService.peerIdentityVerification(
        peerId,
      )).offeredIdentityBase64;
      expect(staged, flatBundleFrom(mallory)['identityPublicKey']);

      // Now a refusal offering a THIRD key. Pre-(lxiii) this overwrote the
      // candidate, destroying the evidence a human was about to compare — and,
      // repeated with a rotating key, held the ceremony permanently
      // un-completable.
      final rotating = EncryptionService();
      await rotating.initialize(77, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      served = rotating;
      enc.markSessionRebuild(peerId);
      await expectLater(
        enc.ensureSession(peerId),
        throwsA(isA<AccountIdentityMismatch>()),
      );

      expect(
        (await enc.encryptionService.peerIdentityVerification(
          peerId,
        )).offeredIdentityBase64,
        staged,
        reason: 'the candidate the human will compare must not be replaced',
      );
    });
  });

  group('two session builds for one device overlap', () {
    // Native 0.2.71 after a wipe (staging drive 10-27): the connect's session
    // pre-build fetched the friend's bundle; its answer arrived and, while
    // that session was still being BUILT, the queue handoff asked for the same
    // device. No session yet and no fetch pending, so it fetched again; the
    // server refuses a second fetch for the same pair within its interval
    // with a bare `error`, the handoff timed out after 10 s, and the friend
    // kept writing to the dead pre-wipe queue until the next app start.
    test('the second joins the first build: one fetch, both get the session',
        () async {
      heldFetches = [];
      final first = enc.ensureSession(peerId);
      await pumpEventQueue();
      expect(heldFetches, [1]);

      // The server answers the first fetch; the second caller arrives while
      // that answer is being built into a session. Like the real server, a
      // repeat fetch inside the interval is never answered.
      enc.onPreKeyBundleResponse({
        'userId': peerId,
        'deviceId': 1,
        'bundle': flatBundleFrom(peer),
      });
      final second = enc.ensureSession(peerId);

      await expectLater(first, completes);
      await expectLater(second, completes);
      expect(bundleFetches, 1, reason: 'a repeat fetch is refused by the server');
      expect(await enc.encryptionService.hasSession(peerId), isTrue);
    });
  });
}
