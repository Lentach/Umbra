import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../support/verify_pinned.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Amendment (lxxix): the peer key-change surface is DEMOTED by default.
///
/// With `keyChangeWarnings` OFF (the default predicate), a locally detected
/// peer identity change auto-acknowledges: the I7 account anchor advances to
/// the new key through the SAME [EncryptionService.acknowledgePeerIdentity]
/// compare-and-swap the manual ceremony uses, and a one-shot muted note
/// ({peerId, occurredAt}) is persisted so the timeline line survives a reload
/// (falsification F12). With the predicate ON, today's manual-confirmation
/// behaviour is unchanged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;
  const malloryId = 3;

  late EncryptionService alice;
  late EncryptionService bob;
  late EncryptionService mallory;

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

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    alice = EncryptionService();
    bob = EncryptionService();
    mallory = EncryptionService();
    await alice.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    await bob.initialize(bobId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    await mallory.initialize(malloryId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
  });

  test(
      'F12: setting OFF — a local key change auto-acks, advances the anchor '
      'and persists the note across a service relaunch', () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    expect(alice.peerKeyChangeNotes, isEmpty);

    final substituted = flatBundleFrom(mallory);
    await alice.buildSession(bobId, substituted,
        expectedIdentityBase64: null);
    // The demotion runs fire-and-forget off the store callback; drain it.
    await pumpEventQueue();

    expect(
      alice.peersWithChangedIdentity,
      isEmpty,
      reason: 'with warnings demoted the change is acknowledged at once',
    );
    expect(
      await alice.peerTofuIdentityBase64(bobId),
      substituted['identityPublicKey'],
      reason: 'the I7 anchor must advance to the new key (auto-ack removed '
          '→ this assertion fails with the old pinned key)',
    );
    expect(alice.peerKeyChangeNotes, contains(bobId));
    expect(
      DateTime.tryParse(alice.peerKeyChangeNotes[bobId]!),
      isNotNull,
      reason: 'occurredAt is a parseable instant',
    );

    // The relaunch: a SECOND service over the same prefs still lists the note
    // and revives no warning (F12: the muted line persists across reload).
    final restarted = EncryptionService();
    await restarted.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    expect(restarted.peerKeyChangeNotes, contains(bobId));
    expect(restarted.peersWithChangedIdentity, isEmpty);
  });

  test('setting ON — today\'s manual warning stands and no note is recorded',
      () async {
    alice.keyChangeWarnings = () => true;
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    final pinned = await alice.peerTofuIdentityBase64(bobId);

    await alice.buildSession(bobId, flatBundleFrom(mallory),
        expectedIdentityBase64: null);
    await pumpEventQueue();

    expect(
      alice.peersWithChangedIdentity,
      contains(bobId),
      reason: 'toggle ignored → the warning would vanish (F11 service half)',
    );
    expect(await alice.peerTofuIdentityBase64(bobId), pinned,
        reason: 'no human confirmed, so the anchor must not move');
    expect(alice.peerKeyChangeNotes, isEmpty);
  });

  test('setting OFF — the server-event path records a persisted note too',
      () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);

    await alice.recordPeerIdentityChangedFromServer(bobId);

    expect(alice.peerKeyChangeNotes, contains(bobId));
    final restarted = EncryptionService();
    await restarted.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    expect(restarted.peerKeyChangeNotes, contains(bobId));
  });

  test('(lxxxiv) dismissPeerKeyChangeNote forgets the note across a relaunch',
      () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    await alice.recordPeerIdentityChangedFromServer(bobId);
    final at = alice.peerKeyChangeNotes[bobId];
    expect(at, isNotNull);
    var notified = 0;
    alice.onPeerIdentityChanged = (_) => notified++;

    // F49: a stale instant is a fresher note's evidence — must not remove.
    await alice.dismissPeerKeyChangeNote(bobId,
        occurredAt: '2000-01-01T00:00:00.000Z');
    expect(alice.peerKeyChangeNotes[bobId], at,
        reason: 'compare-and-remove: the screen decided on an older instant; '
            'a note written since was never superseded (F49)');
    expect(notified, 0);

    await alice.dismissPeerKeyChangeNote(bobId, occurredAt: at!);

    expect(alice.peerKeyChangeNotes, isEmpty);
    expect(notified, 1, reason: 'the open chat must rebuild without the line');
    final restarted = EncryptionService();
    await restarted.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    expect(restarted.peerKeyChangeNotes, isEmpty,
        reason: 'a dismissed note that came back on relaunch would flash the '
            'line on the next open');

    await alice.dismissPeerKeyChangeNote(bobId, occurredAt: at);
    expect(notified, 1, reason: 'dismissing an absent note is a silent no-op');
  });

  test('(lxxxiv) a corrupt note instant in storage is dropped at load',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'e2e_${aliceId}_peer_key_change_notes_v1',
      '[{"peerId":$bobId,"occurredAt":"not-a-date"},'
      '{"peerId":$malloryId,"occurredAt":"2026-09-12T00:00:00.000Z"}]',
    );

    final restarted = EncryptionService();
    await restarted.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

    expect(restarted.peerKeyChangeNotes.keys, [malloryId],
        reason: 'the screen orders notes against message times; a value it '
            'cannot order must never reach it');
  });

  test(
      'F48: setting OFF — a SECOND server-reported change for the same peer '
      'writes a fresh note after the first was evicted', () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    await alice.recordPeerIdentityChangedFromServer(bobId);
    // The muted ack has nothing staged, so the standing set keeps bob.
    expect(alice.peersWithChangedIdentity, contains(bobId));
    await alice.dismissPeerKeyChangeNote(bobId,
        occurredAt: alice.peerKeyChangeNotes[bobId]!);
    expect(alice.peerKeyChangeNotes, isEmpty);
    var notified = 0;
    alice.onPeerIdentityChanged = (_) => notified++;

    await alice.recordPeerIdentityChangedFromServer(bobId);

    expect(alice.peerKeyChangeNotes, contains(bobId),
        reason: 'bob linked ANOTHER device; the line must come back (F48)');
    expect(notified, greaterThanOrEqualTo(1));
  });

  test('setting ON — a repeat server event while the pill stands is a no-op',
      () async {
    alice.keyChangeWarnings = () => true;
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    await alice.recordPeerIdentityChangedFromServer(bobId);
    var notified = 0;
    alice.onPeerIdentityChanged = (_) => notified++;

    await alice.recordPeerIdentityChangedFromServer(bobId);

    expect(notified, 0);
    expect(alice.peerKeyChangeNotes, isEmpty);
  });
  test(
      'setting OFF — an account-identity refusal ((lv)) is NOT demoted: '
      'fail-closed, no auto-ack, no note, refused-set raised', () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    final pinned = await alice.peerTofuIdentityBase64(bobId);
    await alice.verifyPinned(bobId); // decision 152: unverified is accepted

    // The (xxxix)/(lv) gate: the served bundle carries a foreign identity.
    await expectLater(
      alice.buildSession(bobId, flatBundleFrom(mallory),
          expectedIdentityBase64: pinned),
      throwsA(isA<AccountIdentityMismatch>()),
    );

    expect(await alice.peerTofuIdentityBase64(bobId), pinned,
        reason: 'auto-adopting a key the anchor just refused would convert a '
            'live MITM refusal into silent trust');
    expect(alice.peerKeyChangeNotes, isEmpty,
        reason: 'a refused peer never gets the muted note');
    expect(
      alice.peersRefusedIdentity,
      contains(bobId),
      reason: 'the refusal must raise the always-on pill surface, or the '
          'muted default leaves a blocked chat with zero UI',
    );
    expect(alice.peersWithChangedIdentity, contains(bobId));

    // The ceremony is the door: a confirmed acknowledgement of the staged
    // offer advances the anchor and clears BOTH surfaces.
    final acked = await alice.acknowledgePeerIdentity(bobId);
    expect(acked, isTrue);
    expect(alice.peersRefusedIdentity, isEmpty,
        reason: 'the pill must come down once the human resolved it');
    expect(alice.peersWithChangedIdentity, isEmpty);
  });

  test('setting ON — the refusal is identical: fail-closed with the pill set',
      () async {
    alice.keyChangeWarnings = () => true;
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    final pinned = await alice.peerTofuIdentityBase64(bobId);

    await expectLater(
      alice.buildSession(bobId, flatBundleFrom(mallory),
          expectedIdentityBase64: pinned),
      throwsA(isA<AccountIdentityMismatch>()),
    );

    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersWithChangedIdentity, contains(bobId));
    expect(alice.peersRefusedIdentity, contains(bobId));
    expect(alice.peerKeyChangeNotes, isEmpty);
  });

  // ---- Amendment (lxxxiv) rider: per-account state must not cross logins ----

  test(
      'F47: initialising the SAME service for another account drops the '
      'previous account\'s notes, pills, and device-list pins', () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    await alice.recordPeerIdentityChangedFromServer(bobId);
    await alice.recordDeviceListPin(bobId, 5);
    // A second peer with warnings ON lands in the red-pill set, not the notes.
    await alice.buildSession(malloryId, flatBundleFrom(mallory),
        expectedIdentityBase64: null);
    alice.keyChangeWarnings = () => true;
    await alice.recordPeerIdentityChangedFromServer(malloryId);
    expect(alice.peerKeyChangeNotes, contains(bobId));
    expect(alice.peersWithChangedIdentity, contains(malloryId));
    expect(alice.deviceListPins[bobId], 5);

    // Logout does not rebuild the singleton; the next login re-initialises it.
    await alice.initialize(4,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

    expect(alice.peerKeyChangeNotes, isEmpty,
        reason: 'account 1\'s muted note would render in account 4\'s chat');
    expect(alice.peersWithChangedIdentity, isEmpty,
        reason: 'account 1\'s red pill would render in account 4\'s chat');
    expect(alice.deviceListPins, isEmpty,
        reason: 'account 1\'s rollback floor would make account 4 refuse '
            'peer 2\'s honest lower-version list');
  });

  test(
      'F47b: a same-account re-initialise (passcode re-lock → unlock) keeps '
      'the unpersisted refusal', () async {
    await alice.buildSession(bobId, flatBundleFrom(bob),
        expectedIdentityBase64: null);
    final pinned = await alice.peerTofuIdentityBase64(bobId);
    await alice.verifyPinned(bobId); // decision 152: unverified is accepted
    await expectLater(
      alice.buildSession(bobId, flatBundleFrom(mallory),
          expectedIdentityBase64: pinned),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    expect(alice.peersRefusedIdentity, contains(bobId));

    await alice.initialize(aliceId,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

    expect(alice.peersRefusedIdentity, contains(bobId),
        reason: 'a refusal blocks sending and is not persisted; clearing it '
            'on a same-user re-run would drop the only door to the ceremony');
    expect(alice.peersWithChangedIdentity, contains(bobId));
  });
}
