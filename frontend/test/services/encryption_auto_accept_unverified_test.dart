import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/verify_pinned.dart';

/// Owner decision 152 (2026-11-26): with key-change warnings OFF, a friend
/// the user has NOT verified whose new key arrives in a concrete artifact (a
/// served bundle, a PreKey frame) is accepted without a human step; a
/// verified friend, or warnings ON, keeps the refusal and the red pill.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;
  // Bob after a reinstall: another identity, addressed under Bob's id.
  const newBobStore = 3;
  const malloryId = 4;

  late EncryptionService alice;
  late EncryptionService bob;
  late EncryptionService newBob;
  late EncryptionService mallory;

  Future<EncryptionService> started(int userId) async {
    final service = EncryptionService();
    await service.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    return service;
  }

  Map<String, dynamic> flatBundleFrom(EncryptionService peer) {
    final upload = peer.getKeysForUpload();
    expect(upload, isNotNull);
    final keyBundle = (upload!['keyBundle'] as Map).cast<String, dynamic>();
    final otps = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>();
    expect(otps, isNotEmpty);
    return {
      ...keyBundle,
      'oneTimePreKeyId': otps.first['keyId'],
      'oneTimePreKeyPublic': otps.first['publicKey'],
    };
  }

  String identityOf(EncryptionService peer) =>
      flatBundleFrom(peer)['identityPublicKey'] as String;

  /// Alice pins Bob on first contact; returns the pinned account identity.
  Future<String> pinBob() async {
    await alice.buildSession(
      bobId,
      flatBundleFrom(bob),
      expectedIdentityBase64: null,
    );
    final pinned = await alice.peerTofuIdentityBase64(bobId);
    expect(pinned, identityOf(bob));
    return pinned!;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    alice = await started(aliceId);
    bob = await started(bobId);
    newBob = await started(newBobStore);
    mallory = await started(malloryId);
  });

  test('warnings OFF, unverified friend: a bundle under a new key builds the '
      'session, the pin moves to that key and no pill is raised', () async {
    final pinned = await pinBob();

    await alice.buildSession(
      bobId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: pinned,
    );
    await pumpEventQueue();

    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(newBob));
    expect(alice.peersWithChangedIdentity, isEmpty);
    expect(alice.peersRefusedIdentity, isEmpty);
    final sent = await alice.encrypt(bobId, 'are you back?');
    expect(await newBob.decrypt(aliceId, sent), 'are you back?');
  });

  Future<void> expectRefused(String pinned, EncryptionService from) async {
    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(from),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersRefusedIdentity, contains(bobId));
  }

  test('a VERIFIED friend is still refused with warnings OFF', () async {
    final pinned = await pinBob();
    expect(await alice.verifyPinned(bobId), isTrue);
    await expectRefused(pinned, newBob);
  });

  test('warnings ON: an unverified friend is still refused', () async {
    final pinned = await pinBob();
    alice.keyChangeWarnings = () => true;
    await expectRefused(pinned, newBob);
  });

  test('a different key already in the pending slot is not auto-accepted',
      () async {
    final pinned = await pinBob();
    alice.keyChangeWarnings = () => true;
    await expectRefused(pinned, mallory); // stages mallory for a human
    alice.keyChangeWarnings = () => false;

    await expectRefused(pinned, newBob);
    expect(
      (await alice.peerIdentityVerification(bobId)).offeredIdentityBase64,
      identityOf(mallory),
      reason: 'the evidence in the slot is untouched',
    );
  });

  test('a server event after a refusal adopts nothing, verified or not, and '
      'with a key staged earlier', () async {
    final pinned = await pinBob();
    alice.keyChangeWarnings = () => true;
    await expectRefused(pinned, mallory);
    alice.keyChangeWarnings = () => false;
    // Unverified, OFF, slot holds M: a claim alone moves nothing.
    await alice.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersWithChangedIdentity, contains(bobId));
    // Verified: the same.
    await alice.verifyPinned(bobId);
    await alice.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
  });

  test('first contact is not an accepted change: no anchor, no auto-accept',
      () async {
    await newBob.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    final frame = await newBob.encrypt(aliceId, 'hi');
    expect(
      await alice.autoAcceptForeignFrame(bobId, frame, deviceId: 1),
      isNull,
    );
    expect(await alice.peerTofuIdentityBase64(bobId), isNull);
    expect(alice.keyChangeLogOf(bobId), isEmpty);
  });

  test('a foreign PreKey frame is accepted, decrypts in the same pass, the '
      'reply works, the friend stays unverified and the note is permanent',
      () async {
    await pinBob();
    await alice.verifyPinned(bobId);
    await alice.holdForeignFrame(bobId, 'x'); // no key: no effect on pin
    // Verified friend: the frame is NOT accepted.
    await newBob.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    final frame = await newBob.encrypt(aliceId, 'new phone');
    expect(
      await alice.autoAcceptForeignFrame(bobId, frame, deviceId: 1),
      isNull,
    );

    // Unverified friend (a second Alice with an unverified pin).
    final pinned = await alice.peerTofuIdentityBase64(bobId);
    expect(pinned, identityOf(bob));
    final other = await started(5);
    await other.buildSession(
      bobId,
      flatBundleFrom(bob),
      expectedIdentityBase64: null,
    );
    await newBob.buildSession(
      5,
      flatBundleFrom(other),
      expectedIdentityBase64: null,
    );
    final frame2 = await newBob.encrypt(5, 'new phone');
    final seen = <(int, int)>[];
    other.onPeerAutoAccepted = (p, d) => seen.add((p, d));
    expect(
      await other.autoAcceptForeignFrame(bobId, frame2, deviceId: 1),
      isNotNull,
    );
    expect(seen, [(bobId, 1)]);
    expect(await other.decrypt(bobId, frame2), 'new phone');
    expect(await other.peerTofuIdentityBase64(bobId), identityOf(newBob));
    expect(await other.isPeerVerified(bobId), isFalse);
    expect(other.peersWithChangedIdentity, isEmpty);
    final reply = await other.encrypt(bobId, 'welcome back');
    expect(await newBob.decrypt(5, reply), 'welcome back');

    expect(other.keyChangeLogOf(bobId), hasLength(1));
    final restarted = await started(5);
    expect(restarted.keyChangeLogOf(bobId), hasLength(1),
        reason: 'survives a restart');
    await restarted.forgetKeyChangeLog(peerId: bobId);
    expect((await started(5)).keyChangeLogOf(bobId), isEmpty);
  });

  test('the verified flag survives a restart, clears when the anchor moves '
      'another way and is re-bound by a confirm', () async {
    final pinned = await pinBob();
    await alice.verifyPinned(bobId);
    final restarted = await started(aliceId);
    expect(await restarted.isPeerVerified(bobId), isTrue);

    // Anchor moves by a human accept of a refused key (flag not re-bound).
    await expectLater(
      restarted.buildSession(
        bobId,
        flatBundleFrom(newBob),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    final shown = await restarted.peerIdentityVerification(bobId);
    expect(
      await restarted.acknowledgePeerIdentity(
        bobId,
        adoptIdentityBase64: shown.offeredIdentityBase64,
      ),
      isTrue,
    );
    expect(await restarted.isPeerVerified(bobId), isFalse);

    expect(await restarted.verifyPinned(bobId), isTrue);
    expect(await restarted.isPeerVerified(bobId), isTrue);
    expect(await restarted.peerTofuIdentityBase64(bobId), identityOf(newBob));
  });

  test('the local history wipe removes the permanent notes', () async {
    final pinned = await pinBob();
    await alice.buildSession(
      bobId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: pinned,
    );
    expect(alice.keyChangeLogOf(bobId), hasLength(1));
    await alice.clearDecryptedContentCache();
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect((await started(aliceId)).keyChangeLogOf(bobId), isEmpty);
  });

  test('the note cap is per peer: flooding one friend never evicts another '
      "friend's note, and a flooded friend keeps its first 5 and newest 45",
      () async {
    // Friend Y (id 4): one accepted change.
    await alice.buildSession(
      malloryId,
      flatBundleFrom(mallory),
      expectedIdentityBase64: null,
    );
    await alice.buildSession(
      malloryId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: identityOf(mallory),
    );
    final other = alice.keyChangeLogOf(malloryId);
    expect(other, hasLength(1));

    // Friend Bob flips between two keys 120 times.
    var anchor = await pinBob();
    for (var i = 0; i < 120; i++) {
      final to = i.isEven ? newBob : bob;
      await alice.buildSession(
        bobId,
        flatBundleFrom(to),
        expectedIdentityBase64: anchor,
      );
      anchor = identityOf(to);
    }

    expect(alice.keyChangeLogOf(malloryId), other,
        reason: "another friend's note survives the flood");
    expect(alice.keyChangeLogOf(bobId), hasLength(50));
    final restarted = await started(aliceId);
    expect(restarted.keyChangeLogOf(malloryId), other);
    expect(restarted.keyChangeLogOf(bobId), hasLength(50));
  });

  test('the note and the rebuild intents are written BEFORE the anchor '
      'moves', () async {
    final pinned = await pinBob();
    alice.knownAddressesOf = (_) => {1, 2};
    var seen = false;
    alice.debugBeforeAutoAcceptSwap = () async {
      seen = true;
      expect(alice.keyChangeLogOf(bobId), hasLength(1));
      expect(alice.pendingSessionRebuilds, contains((bobId, 2)));
      expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    };

    await alice.buildSession(
      bobId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: pinned,
    );

    expect(seen, isTrue);
    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(newBob));
    expect(alice.pendingSessionRebuilds, contains((bobId, 2)));
    expect(alice.pendingSessionRebuilds, isNot(contains((bobId, 1))),
        reason: 'the address the artifact built is fresh');
  });

  test('a refused swap leaves no note and no rebuild intent', () async {
    alice.knownAddressesOf = (_) => {1, 2};
    final pinned = await pinBob();
    // A different candidate lands in the slot between the checks and the swap.
    alice.debugBeforeAutoAcceptSwap = () =>
        alice.debugStagePending(bobId, identityOf(mallory));

    await expectRefused(pinned, newBob);

    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(alice.pendingSessionRebuilds, isEmpty);
    expect((await started(aliceId)).keyChangeLogOf(bobId), isEmpty);
  });

  test('a bundle whose signed pre-key is not signed by the offered identity '
      'moves no anchor and writes no note', () async {
    final pinned = await pinBob();
    final forged = {
      ...flatBundleFrom(newBob),
      // A signature that is valid for ANOTHER identity.
      'signedPreKeySignature': flatBundleFrom(bob)['signedPreKeySignature'],
    };
    await expectLater(
      alice.buildSession(bobId, forged, expectedIdentityBase64: pinned),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(alice.peersRefusedIdentity, contains(bobId));
  });

  test('a build that fails after the accept takes the accept back', () async {
    final pinned = await pinBob();
    alice.knownAddressesOf = (_) => {1, 2};
    final broken = {...flatBundleFrom(newBob), 'registrationId': 'not-an-int'};
    await expectLater(
      alice.buildSession(bobId, broken, expectedIdentityBase64: pinned),
      throwsA(isA<TypeError>()),
    );
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(alice.pendingSessionRebuilds, isEmpty);
  });

  test('a frame accept is provisional: reverting restores the anchor, the '
      'note and the intents', () async {
    final pinned = await pinBob();
    alice.knownAddressesOf = (_) => {1, 2};
    await newBob.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    final frame = await newBob.encrypt(aliceId, 'hi');
    final accepted = await alice.autoAcceptForeignFrame(
      bobId,
      frame,
      deviceId: 1,
    );
    expect(accepted, isNotNull);
    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(newBob));

    await alice.revertAutoAccept(bobId, accepted!);

    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(alice.pendingSessionRebuilds, isEmpty);
  });

  test('a stale expectation for the key that is ALREADY pinned builds the '
      'session: no bar, no second note, whatever the setting', () async {
    await pinBob();
    alice.keyChangeWarnings = () => true;
    await alice.verifyPinned(bobId);

    await alice.buildSession(
      bobId,
      flatBundleFrom(bob),
      expectedIdentityBase64: identityOf(mallory), // stale
    );

    expect(alice.peersRefusedIdentity, isEmpty);
    expect(alice.peersWithChangedIdentity, isEmpty);
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(await alice.isPeerVerified(bobId), isTrue);
  });

  Future<String> frameFrom(EncryptionService sender) async {
    await sender.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    return sender.encrypt(aliceId, 'hi');
  }

  test('N1a: reverting a frame accept does not overwrite a LATER legitimate '
      'accept', () async {
    final pinned = await pinBob();
    final accepted = await alice.autoAcceptForeignFrame(
      bobId,
      await frameFrom(newBob),
      deviceId: 1,
    );
    expect(accepted, isNotNull);
    // Before that frame's decrypt fails, a pre-build accepts the friend's
    // real new bundle.
    await alice.buildSession(
      bobId,
      flatBundleFrom(mallory),
      expectedIdentityBase64: identityOf(newBob),
    );
    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(mallory));

    await alice.revertAutoAccept(bobId, accepted!);

    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(mallory),
        reason: 'the later accept stands, not the anchor from before ($pinned)');
    expect(alice.keyChangeLogOf(bobId), hasLength(2));
  });

  test('N1b: reverting puts back the standing warning and the pending '
      'candidate the accept cleared, durably', () async {
    final pinned = await pinBob();
    alice.keyChangeWarnings = () => true;
    await expectRefused(pinned, newBob); // warned + refused, candidate = K1
    alice.keyChangeWarnings = () => false;
    final accepted = await alice.autoAcceptForeignFrame(
      bobId,
      await frameFrom(newBob),
      deviceId: 1,
    );
    expect(accepted, isNotNull);
    expect(alice.peersWithChangedIdentity, isEmpty);

    await alice.revertAutoAccept(bobId, accepted!);

    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersWithChangedIdentity, contains(bobId));
    expect(alice.peersRefusedIdentity, contains(bobId));
    final restarted = await started(aliceId);
    expect(restarted.peersWithChangedIdentity, contains(bobId));
    expect(
      (await restarted.peerIdentityVerification(bobId)).offeredIdentityBase64,
      identityOf(newBob),
    );
  });

  test('NIT-6 on the frame path: a frame under the key already pinned moves '
      'nothing and writes no note', () async {
    await pinBob();
    await bob.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    final frame = await bob.encrypt(aliceId, 'same key');

    final accepted = await alice.autoAcceptForeignFrame(
      bobId,
      frame,
      deviceId: 1,
    );

    expect(accepted, isNotNull, reason: 'already accepted: the frame reads');
    expect(alice.keyChangeLogOf(bobId), isEmpty);
    expect(alice.peersWithChangedIdentity, isEmpty);
  });

  test('N3: an unreadable verified record counts every PINNED friend as '
      'verified (hold) until it reads again', () async {
    final pinned = await pinBob();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('e2e_${aliceId}_peer_verified_v1', '{nope');

    final restarted = await started(aliceId);

    expect(await restarted.isPeerVerified(bobId), isTrue,
        reason: 'uncertainty answers the safe way');
    expect(await restarted.isPeerVerified(7), isFalse,
        reason: 'nothing pinned, nothing to hold');
    await expectLater(
      restarted.buildSession(
        bobId,
        flatBundleFrom(newBob),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    expect(await restarted.peerTofuIdentityBase64(bobId), pinned);

    // The record reads again (here: repaired empty): back to unverified.
    await prefs.setString('e2e_${aliceId}_peer_verified_v1', '{}');
    expect(await restarted.isPeerVerified(bobId), isFalse);
  });

  test('N4: a verification made in another tab is seen by the accept '
      'decision, not just at load', () async {
    final pinned = await pinBob();
    final tab2 = await started(aliceId); // another tab, same storage
    expect(await tab2.verifyPinned(bobId), isTrue);

    // This tab loaded before: it must still hold the friend.
    await expectRefused(pinned, newBob);
  });

  test("N4: a note written by another tab is not overwritten by this tab's "
      'next accept', () async {
    final pinned = await pinBob();
    final tab2 = await started(aliceId);
    await tab2.buildSession(
      malloryId,
      flatBundleFrom(mallory),
      expectedIdentityBase64: null,
    );
    // This tab accepts Bob's new key first, then the other tab accepts Y's.
    await alice.buildSession(
      bobId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: pinned,
    );
    await tab2.buildSession(
      malloryId,
      flatBundleFrom(newBob),
      expectedIdentityBase64: identityOf(mallory),
    );

    final fresh = await started(aliceId);
    expect(fresh.keyChangeLogOf(bobId), hasLength(1),
        reason: "the first tab's note survives the other tab's write");
    expect(fresh.keyChangeLogOf(malloryId), hasLength(1));
  });

  test('R2: a revert never overwrites a candidate that is in the slot now',
      () async {
    final pinned = await pinBob();
    alice.keyChangeWarnings = () => true;
    await expectRefused(pinned, newBob); // candidate K1
    alice.keyChangeWarnings = () => false;
    final accepted = await alice.autoAcceptForeignFrame(
      bobId,
      await frameFrom(newBob),
      deviceId: 1,
    );
    expect(accepted, isNotNull);
    // A new piece of evidence lands in the (now empty) slot.
    await alice.debugStagePending(bobId, identityOf(mallory));

    await alice.revertAutoAccept(bobId, accepted!);

    expect(
      (await alice.peerIdentityVerification(bobId)).offeredIdentityBase64,
      identityOf(mallory),
      reason: 'evidence in the slot is never overwritten',
    );
  });

  test('R3: while the verified record is unreadable nothing is written over '
      'it, so a repaired read still knows the other friends', () async {
    final pinned = await pinBob();
    expect(await alice.verifyPinned(bobId), isTrue);
    final prefs = await SharedPreferences.getInstance();
    final good = prefs.getString('e2e_${aliceId}_peer_verified_v1')!;
    await prefs.setString('e2e_${aliceId}_peer_verified_v1', '{nope');
    final tab = await started(aliceId);
    await tab.buildSession(
      malloryId,
      flatBundleFrom(mallory),
      expectedIdentityBase64: null,
    );

    expect(await tab.verifyPinned(malloryId), isFalse,
        reason: 'cannot mark while the record is unreadable');
    expect(prefs.getString('e2e_${aliceId}_peer_verified_v1'), '{nope');

    await prefs.setString('e2e_${aliceId}_peer_verified_v1', good);
    expect(await tab.isPeerVerified(bobId), isTrue);
    expect(await tab.peerTofuIdentityBase64(bobId), pinned);
  });

  test('R3: the verification reports "unknown", not "verified", while the '
      'record is unreadable', () async {
    await pinBob();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('e2e_${aliceId}_peer_verified_v1', '{nope');
    final tab = await started(aliceId);

    final v = await tab.peerIdentityVerification(bobId);

    expect(v.verified, isFalse);
    expect(v.verifiedUnknown, isTrue);
  });

  test('R4: a mark whose write was lost is still held by this tab after the '
      'read-through (union, not replace)', () async {
    final pinned = await pinBob();
    expect(await alice.verifyPinned(bobId), isTrue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('e2e_${aliceId}_peer_verified_v1'); // the write was lost

    await expectRefused(pinned, newBob);
  });

  test('R4: the swap fails when the anchor moved since the decision read it',
      () async {
    final pinned = await pinBob();
    final tab2 = await started(aliceId);
    alice.debugBeforeAutoAcceptSwap = () =>
        tab2.replaceStaleAccountAnchor(bobId, identityOf(mallory));

    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(newBob),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );

    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(mallory),
        reason: 'the anchor that moved meanwhile stands');
    expect(alice.keyChangeLogOf(bobId), isEmpty);
  });

  test('S3a: a confirmed standing change never writes over an unreadable '
      'verified record', () async {
    final pinned = await pinBob();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('e2e_${aliceId}_peer_verified_v1', '{nope');
    final tab = await started(aliceId);
    await expectLater(
      tab.buildSession(
        bobId,
        flatBundleFrom(newBob),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    ); // held: the record is unreadable, so the friend counts as verified
    final shown = await tab.peerIdentityVerification(bobId);

    expect(
      await tab.acknowledgePeerIdentity(
        bobId,
        adoptIdentityBase64: shown.offeredIdentityBase64,
        markVerified: true,
      ),
      isTrue,
    );

    expect(prefs.getString('e2e_${aliceId}_peer_verified_v1'), '{nope',
        reason: "one friend's mark must not replace the unreadable record");
  });

  test('S3b/c: an accept whose decision read an anchor that was reverted '
      'meanwhile does not swap', () async {
    final pinned = await pinBob();
    // A provisional frame accept moves the anchor to K1.
    final tokenA = await alice.autoAcceptForeignFrame(
      bobId,
      await frameFrom(newBob),
      deviceId: 1,
    );
    expect(tokenA, isNotNull);
    // A bundle under K2 is decided against K1; before its swap the first
    // accept is reverted (its decrypt failed): the anchor is back at O.
    alice.debugBeforeAutoAcceptSwap = () =>
        alice.revertAutoAccept(bobId, tokenA!);

    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(mallory),
        expectedIdentityBase64: identityOf(newBob),
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );

    expect(await alice.peerTofuIdentityBase64(bobId), pinned,
        reason: 'a decision taken against a reverted anchor does not swap');
    expect(alice.keyChangeLogOf(bobId), isEmpty);
  });
}
