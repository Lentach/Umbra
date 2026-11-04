// Full-stack regression for the 2026-07-11 stale-OTP bad-MAC outage, over the
// REAL wire (REST auth -> Socket.IO -> ChatGateway -> Postgres) with REAL
// libsignal on both ends.
//
//   docker-compose up                     # repo root: backend :3000 + Postgres
//   cd frontend && flutter test test_e2e/stale_otp_epoch_test.dart
//
// What it pins that the happy-path harness does NOT: a recipient who REGENERATES
// their Signal identity mid-life, re-publishing identity + one-time pre-keys,
// must never have a stale (old-epoch) OTP served again. Concretely:
//   * the sender always fetches the CURRENT identity epoch;
//   * every served OTP belongs to the current epoch and DECRYPTS (a stale one
//     would Bad-Mac exactly like the field logs — peers 37<->63);
//   * the current-epoch pool is non-empty after the re-upload (tagging + purge
//     kept the new keys and dropped the dead ones);
//   * both directions work.
//
// The PreKey ciphertexts are handed from sender to recipient IN-PROCESS: no
// server handler relays messages any more (Phase 4 step 5), and the claim
// that matters here — the served bundle/OTP is current-epoch and decrypts —
// needs no transport.
//
// Upload ORDER changed on 2026-08-19 and this file mirrors the client: the
// identity is published first and the keys are released by its ack. It used to
// emit both back to back ("unsafe production order"), which is how key material
// could be judged against an identity the account had not published yet; the
// server now refuses pre-keys under an unpublished identity, and
// `full_stack_e2e_test` pins that refusal.
//
// Scope of this test (precise): it pins the end-to-end PURGE + identity-TAGGING
// path — after regeneration the epoch-2 OTPs reuse keyId slots 0..N (UPSERT
// overwrites epoch-1) and upsertKeyBundle purges the rest, so no stale row
// physically survives here. It does NOT by itself isolate the fetch filter
// (a filter-less server would still serve only epoch-2 in this scenario).
// The identity fetch filter is pinned FAIL-CLOSED by the backend unit spec
// (key-bundles.service.spec.ts) — it asserts fetchPreKeyBundle's SQL carries
// `"identityPublicKey" = $2` with params [userId, bundle.identityPublicKey],
// so removing the filter reddens CI. Together: filter (unit spec) + purge +
// tagging (this test) are each guarded.

import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  final baseUrl = e2eBaseUrl();
  final runTag = DateTime.now().millisecondsSinceEpoch.toString();

  late E2eClient alice; // recipient who regenerates identity
  late E2eClient bob; // sender
  late String epoch1Identity;
  // The 0b registration lock (§6.1) requires the PREVIOUS identity key to
  // authorize a replacement, and clearAllKeys() below destroys it. This file's
  // subject is the OTP epoch invariant, not the lock, so it carries the proof
  // a legitimate rotation would; registration_lock_test covers the refusal.
  late String epoch1Pair;

  int wireType(String ciphertext) =>
      int.parse(ciphertext.substring(0, ciphertext.indexOf(':')));

  /// Re-upload alice's CURRENT (post-regeneration) keys in the PRODUCTION order
  /// (changed 2026-08-19): publish the identity, wait for the server's ack, and
  /// only then send the one-time pre-keys.
  ///
  /// It used to emit both back to back with no await — mirroring the client of
  /// the day — which let key material be judged against an identity the account
  /// had not published yet. `EncryptionProvider` now stashes the keys and
  /// releases them on `keyBundleUploaded { success: true }`, and the server
  /// refuses pre-keys tagged with an unpublished identity, so this helper
  /// mirrors that. The refusal itself is pinned in `full_stack_e2e_test`.
  Future<void> reuploadInProductionOrder(
    E2eClient c, {
    String? identitySignature,
    String? nonce,
  }) async {
    final keys = c.encryption.getKeysForUpload()!;
    final keyBundle = (keys['keyBundle'] as Map).cast<String, dynamic>();
    final otps = (keys['oneTimePreKeys'] as List).cast<Map<String, dynamic>>();
    final identity = keyBundle['identityPublicKey'];

    c.socketService.socket!.emit('uploadKeyBundle', {
      ...keyBundle,
      'identitySignature': ?identitySignature,
      'nonce': ?nonce,
    });
    final ack = await c.events.next(
      'keyBundleUploaded',
      reason: '${c.label} epoch-2 bundle ack',
    );
    if ((ack as Map)['success'] != true) {
      throw StateError('${c.label} epoch-2 bundle refused: $ack');
    }

    // The identity is published now, so its keys may follow.
    c.socketService.socket!.emit('uploadOneTimePreKeys', {
      'keys': otps,
      'identityPublicKey': identity,
    });
    await c.events.next(
      'oneTimePreKeysUploaded',
      reason: '${c.label} epoch-2 OTP ack',
    );
  }

  setUpAll(() async {
    await requireBackendUp(baseUrl);
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});

    alice = E2eClient('salice', baseUrl);
    bob = E2eClient('sbob', baseUrl);

    await alice.registerFresh();
    await bob.registerFresh();
    await alice.connectSocket();
    await bob.connectSocket();

    // Epoch 1: alice + bob upload their original identities and OTP pools.
    await alice.initializeAndUploadKeys();
    await bob.initializeAndUploadKeys();
    epoch1Identity =
        (alice.encryption.getKeysForUpload()!['keyBundle']
                as Map)['identityPublicKey']
            as String;
    epoch1Pair = await alice.exportIdentityPair();
  });

  tearDownAll(() {
    alice.dispose();
    bob.dispose();
  });

  /// bob builds a fresh session from alice's CURRENT server bundle and makes a
  /// PreKey message; alice must decrypt it to the exact plaintext. Returns the
  /// served bundle so the caller can assert epoch identity/OTP presence.
  Future<Map<String, dynamic>> bobPreKeyToAlice(
    String content,
  ) async {
    await bob.encryption.deleteSession(alice.userId); // force a fresh X3DH
    final bundle = await bob.fetchBundleFor(alice.userId);
    await bob.encryption.buildSession(alice.userId, bundle, expectedIdentityBase64: null);
    final ct = await bob.encryptText(alice.userId, content);
    expect(
      wireType(ct),
      3,
      reason: 'fresh session opener must be a PreKey (3:)',
    );
    // The load-bearing assertion: a stale OTP would throw Bad Mac here.
    expect(
      await alice.decryptText(bob.userId, ct),
      content,
      reason: 'alice must decrypt bob\'s PreKey message (no stale OTP served)',
    );
    return bundle;
  }

  group('stale-OTP epoch regression', () {
    test(
      'after alice regenerates identity, no stale OTP is ever served and both '
      'directions decrypt (identity published first, keys after its ack)',
      () async {
        // 1. alice regenerates identity (fresh install / key loss), SAME account.
        //    She now holds only epoch-2 private keys; epoch-1 OTP privates gone.
        await alice.encryption.clearAllKeys();
        await alice.encryption.initialize(
          alice.userId,
          checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
        );
        final epoch2Identity =
            (alice.encryption.getKeysForUpload()!['keyBundle']
                    as Map)['identityPublicKey']
                as String;
        expect(
          epoch2Identity,
          isNot(epoch1Identity),
          reason: 'regeneration must mint a new identity epoch',
        );

        // 2. Re-upload in the production order (identity published, ack, then
        //    keys), carrying the 0b proof so the replacement is authorized.
        final nonce = await alice.fetchRegistrationLockNonce();
        final proof = await alice.signIdentityChange(
          signerPairBase64: epoch1Pair,
          newIdentityPublicKeyBase64: epoch2Identity,
          nonceBase64: nonce,
        );
        await reuploadInProductionOrder(
          alice,
          identitySignature: proof,
          nonce: nonce,
        );

        // 3. bob -> alice PreKey, repeated to drain several current-epoch OTPs.
        //    Every claim must be epoch-2 and must decrypt.
        for (var i = 0; i < 3; i++) {
          final bundle = await bobPreKeyToAlice('epoch2-msg-$i-$runTag');
          expect(
            bundle['identityPublicKey'],
            epoch2Identity,
            reason: 'served bundle must carry the CURRENT identity epoch',
          );
          expect(bundle['identityPublicKey'], isNot(epoch1Identity));
          // Non-empty current-epoch pool proves tagging + purge kept the new keys.
          expect(
            bundle['oneTimePreKeyId'],
            isNotNull,
            reason: 'current-epoch OTP pool must be non-empty after re-upload',
          );
        }

        // 4. Reverse direction: alice -> bob (bob never rotated) must also work.
        await bob.encryption.deleteSession(alice.userId);
        final bobBundle = await alice.fetchBundleFor(bob.userId);
        await alice.encryption.buildSession(bob.userId, bobBundle, expectedIdentityBase64: null);
        final ct = await alice.encryptText(bob.userId, 'reverse-$runTag');
        expect(wireType(ct), 3);
        expect(await bob.decryptText(alice.userId, ct), 'reverse-$runTag');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
