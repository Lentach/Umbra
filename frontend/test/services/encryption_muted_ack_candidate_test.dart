import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Audit row A3-SVC-A-1: with key-change warnings OFF (the default), the muted
/// demotion must never promote a pending candidate that no local libsignal
/// detection staged. A candidate staged by a refused session build ((lv)), by
/// a held foreign frame (decision 143) or by the compare screen ((xlvii)
/// clause 3) waits for a human, and a server-reported identity change — an
/// event the server alone decides to send — must not be what pins it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceId = 1;
  const bobId = 2;
  const malloryId = 3;

  late EncryptionService alice;
  late EncryptionService bob;
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
    mallory = await started(malloryId);
  });

  test('scenario 1: warnings OFF — a server event after a REFUSED build does '
      'not promote the served key the refusal staged', () async {
    final pinned = await pinBob();
    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(mallory),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    expect(
      (await alice.peerIdentityVerification(bobId)).offeredIdentityBase64,
      identityOf(mallory),
      reason: 'the refusal stages the served key for the compare screen',
    );

    await alice.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();

    expect(
      await alice.peerTofuIdentityBase64(bobId),
      pinned,
      reason: 'S1: a key the anchor refused was pinned with no human step',
    );
    expect(alice.peersWithChangedIdentity, contains(bobId));
    expect(alice.peersRefusedIdentity, contains(bobId));
  });

  test('scenario 2: warnings OFF — after a restart, a server event does not '
      'promote the identity of a HELD foreign frame', () async {
    final pinned = await pinBob();
    // Mallory writes to Alice under Bob's name: a PreKey frame carrying an
    // identity other than the pinned one. It is held, never decrypted.
    await mallory.buildSession(
      aliceId,
      flatBundleFrom(alice),
      expectedIdentityBase64: null,
    );
    final forged = await mallory.encrypt(aliceId, 'new number, send the code');
    await alice.holdForeignFrame(bobId, forged);
    expect(alice.peersHeldForIdentity, contains(bobId));
    expect(
      (await alice.peerIdentityVerification(bobId)).offeredIdentityBase64,
      identityOf(mallory),
    );

    // A new process on the same storage: the held mark is RAM and is gone
    // until the journal is read again; the candidate and the warning persist.
    final restarted = await started(aliceId);
    expect(restarted.peersHeldForIdentity, isEmpty);
    expect(restarted.peersWithChangedIdentity, contains(bobId));

    await restarted.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();

    expect(
      await restarted.peerTofuIdentityBase64(bobId),
      pinned,
      reason: "S2: the held frame's identity was pinned with no human step",
    );
    expect(restarted.peersWithChangedIdentity, contains(bobId));
  });

  test('scenario 3: warnings OFF — a server event does not promote a served '
      'key the compare screen staged', () async {
    final pinned = await pinBob();
    // The standing warning that opens the compare screen; nothing staged yet.
    await alice.recordPeerIdentityChangedFromServer(bobId);
    expect(alice.peersWithChangedIdentity, contains(bobId));
    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    // (xlvii) clause 3: the screen displays, and stages, the served key.
    final shown = await alice.peerIdentityVerification(
      bobId,
      servedIdentityBase64: identityOf(mallory),
    );
    expect(shown.offeredWasServed, isTrue);

    await alice.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();

    expect(
      await alice.peerTofuIdentityBase64(bobId),
      pinned,
      reason: 'S3: a key the user was only SHOWN was pinned by a server event',
    );
    expect(alice.peersWithChangedIdentity, contains(bobId));
  });

  test('warnings OFF — a server event with nothing staged leaves the pill, '
      'moves no anchor and still writes the muted note', () async {
    final pinned = await pinBob();

    await alice.recordPeerIdentityChangedFromServer(bobId);
    await pumpEventQueue();

    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersWithChangedIdentity, contains(bobId));
    expect(alice.peerKeyChangeNotes, contains(bobId));
  });

  test('the manual ceremony still promotes the DISPLAYED key after a refusal '
      'and a server event', () async {
    final pinned = await pinBob();
    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(mallory),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );
    await alice.recordPeerIdentityChangedFromServer(bobId);
    final shown = await alice.peerIdentityVerification(bobId);
    expect(shown.offeredIdentityBase64, identityOf(mallory));

    final advanced = await alice.acknowledgePeerIdentity(
      bobId,
      adoptIdentityBase64: shown.offeredIdentityBase64,
    );

    expect(advanced, isTrue);
    expect(await alice.peerTofuIdentityBase64(bobId), identityOf(mallory));
    expect(alice.peersWithChangedIdentity, isEmpty);
    expect(alice.peersRefusedIdentity, isEmpty);
  });

  test('warnings OFF — a local detection for a peer whose refusal already '
      'stands is not absorbed either', () async {
    final pinned = await pinBob();
    await expectLater(
      alice.buildSession(
        bobId,
        flatBundleFrom(mallory),
        expectedIdentityBase64: pinned,
      ),
      throwsA(isA<AccountIdentityMismatch>()),
    );

    await alice.buildSession(
      bobId,
      flatBundleFrom(mallory),
      expectedIdentityBase64: null,
    );
    await pumpEventQueue();

    expect(await alice.peerTofuIdentityBase64(bobId), pinned);
    expect(alice.peersWithChangedIdentity, contains(bobId));
  });
}
