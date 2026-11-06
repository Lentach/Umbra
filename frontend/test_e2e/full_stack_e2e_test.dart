// Full-stack two-account wire harness for the key, device-list and
// provisioning contracts that survive the Phase 4 step 5 removal of the
// server's message/friend path.
//
// NOT part of the default `flutter test` suite — this directory is a sibling
// of `test/` precisely so `flutter test` (local + CI) never picks it up.
//
// Invocation contract:
//
//   docker-compose up                     # repo root: backend :3000 + Postgres
//   cd frontend && flutter test test_e2e
//
// What it proves, over the REAL wire (REST auth -> Socket.IO -> ChatGateway ->
// DTO validation -> Postgres -> broadcast) with REAL libsignal on both ends:
//   1. register -> socketReady (parseable, plausible serverTime) -> WS key upload
//   2. first contact: `setRequestQueue` + `searchUsers` hand a stranger each
//      device with a bundle and the published request queue (PR3.2)
//   3. a SERVED bundle builds a real session: first ciphertext is PreKey (3:),
//      replies ratchet to whisper (2:), a mid-conversation rebuild goes PreKey
//      again (the shape of the 2026-07 field incidents). The ciphertext is
//      handed across IN-PROCESS: no server handler relays messages any more,
//      and `box_roundtrip_test.dart` owns transport.
//   4. per-device key material, DAK enrollment + signed device list, the
//      provisioning ceremony and device revocation
//
// Fresh accounts EVERY run, by design: the server never purges unused
// one-time pre-keys and serves them oldest-first, so reusing accounts with
// fresh client keys would deterministically produce phantom bad-MAC failures.
// Register throttle is 10/hr per IP; `docker compose restart backend` resets
// the in-memory counters when iterating.
// Each run leaves 2 throwaway accounts (key bundles/OTPs, linked devices) in
// the TARGET dev DB — harmless local cruft; never point E2E_BASE_URL at
// production.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/services/device_link/link_crypto.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Must come AFTER binding init: the binding's HttpOverrides answers every
  // real request with 400, which would silently break REST and the WS upgrade.
  enableRealNetwork();

  final baseUrl = e2eBaseUrl();
  final runTag = DateTime.now().millisecondsSinceEpoch.toString();

  late E2eClient alice;
  late E2eClient bob;
  // PR3.2 first contact, captured in setUpAll and asserted in the group.
  late List<dynamic> bobFirstContact;
  late String bobRequestSid;
  late String bobSealPub;
  // Shared by the T2 device-list group (which enrolls alice) and the T3
  // provisioning group (which signs later mutations): the DAK private key
  // exists ONLY inside this engine instance.
  final engine = DeviceAuthorityEngine();

  /// Asserts the `"{type}:{base64}"` wire format and returns the type
  /// (3 = PreKeySignalMessage, 2 = SignalMessage/whisper).
  int wireType(String ciphertext) {
    expect(
      ciphertext,
      matches(RegExp(r'^\d+:[A-Za-z0-9+/]+=*$')),
      reason: 'ciphertext must be "{type}:{base64}"',
    );
    return int.parse(ciphertext.substring(0, ciphertext.indexOf(':')));
  }

  /// Pins the server clock field which protects irreversible expiry purges.
  void expectSocketReadyServerTime(dynamic payload, String clientLabel) {
    expect(
      payload,
      isA<Map<dynamic, dynamic>>(),
      reason: '$clientLabel socketReady must carry an object payload',
    );
    final serverTime = (payload as Map)['serverTime'];
    expect(
      serverTime,
      isA<String>(),
      reason: '$clientLabel socketReady.serverTime must be a string',
    );

    final serverTimeString = serverTime as String;
    expect(
      serverTimeString,
      isNotEmpty,
      reason: '$clientLabel socketReady.serverTime must not be empty',
    );
    final parsed = DateTime.tryParse(serverTimeString);
    expect(
      parsed,
      isNotNull,
      reason:
          '$clientLabel socketReady.serverTime must be a parseable ISO-8601 instant',
    );
    expect(
      parsed!.isUtc,
      isTrue,
      reason: '$clientLabel socketReady.serverTime must be UTC',
    );
    expect(
      parsed.difference(DateTime.now().toUtc()).abs(),
      lessThan(const Duration(minutes: 5)),
      reason:
          '$clientLabel socketReady.serverTime must be close to the test machine clock',
    );
  }

  /// Encrypts [content] on [sender] and decrypts it on [recipient], handing
  /// the ciphertext across in-process: the server relay that used to carry it
  /// is gone (transport is `box_roundtrip_test.dart`'s). Asserts the wire type
  /// and the exact plaintext.
  Future<void> hop(
    E2eClient sender,
    E2eClient recipient,
    String content, {
    required int expectedWireType,
  }) async {
    final ciphertext = await sender.encryptText(recipient.userId, content);
    expect(
      wireType(ciphertext),
      expectedWireType,
      reason: 'unexpected ciphertext type for "$content"',
    );
    expect(await recipient.decryptText(sender.userId, ciphertext), content);
  }

  setUpAll(() async {
    await requireBackendUp(baseUrl);

    // In-memory Signal key storage, same pattern as the in-process roundtrip
    // test. Both clients share one mock store via per-user key prefixes.
    // The analyzer only recognizes @visibleForTesting use under `test/`;
    // this IS a test, deliberately outside the default suite dir.
    // ignore: invalid_use_of_visible_for_testing_member
    FlutterSecureStorage.setMockInitialValues({});
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});

    alice = E2eClient('alice', baseUrl);
    bob = E2eClient('bob', baseUrl);

    // 1. Fresh accounts + tokens (REST).
    await alice.registerFresh();
    await bob.registerFresh();

    // 2. Real sockets, authenticated via handshake auth token.
    final aliceSocketReady = await alice.connectSocket();
    expectSocketReadyServerTime(aliceSocketReady, alice.label);
    await bob.connectSocket();

    // 3. Signal identity + key bundle upload (WS, like EncryptionProvider).
    await alice.initializeAndUploadKeys();
    await bob.initializeAndUploadKeys();

    // 3b. First contact (metadata-privacy PR3.2), while still strangers: bob
    // publishes a request queue, alice finds him by handle. Captured here,
    // asserted by the first test of the group.
    String canonical32() => base64Url
        .encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    bobRequestSid = canonical32();
    bobSealPub = canonical32();
    bob.events.discard('requestQueueSet');
    bob.socketService.socket!.emit('setRequestQueue', {
      'sid': bobRequestSid,
      'sealPub': bobSealPub,
    });
    expect(
      await bob.events.next('requestQueueSet', reason: 'bob publishes'),
      {'success': true},
    );
    alice.events.discard('searchUsersResult');
    alice.socketService.searchUsers('${bob.username}#${bob.tag}');
    bobFirstContact =
        await alice.events.next(
              'searchUsersResult',
              reason: 'alice searches bob',
            )
            as List<dynamic>;
  });

  tearDownAll(() {
    alice.dispose();
    bob.dispose();
  });

  group('full-stack E2E wire', () {
    test('searchUsers hands a stranger each device with a live one-time '
        'pre-key and the request queue it published (PR3.2)', () async {
      expect(bobFirstContact, hasLength(1));
      final found = bobFirstContact.single as Map;
      expect(found['id'], bob.userId);
      expect(found['authorization'], isNull, reason: 'bob never enrolled');
      final devices = found['devices'] as List;
      expect(devices, hasLength(1), reason: 'bob has exactly device 1');
      final device = devices.single as Map;
      expect(device['deviceId'], 1);
      expect(device['requestSid'], bobRequestSid);
      expect(device['sealPub'], bobSealPub);
      final bundle = device['bundle'] as Map;
      final otpId = bundle['oneTimePreKeyId'];
      expect(otpId, isA<int>(), reason: 'design §4.4: bundle WITH an OTP');
      // The claim hit the real pool: that one-time pre-key is spent, so no
      // later fetch can hand it out a second time.
      final spent = await e2eSql(
        'SELECT used FROM public.one_time_pre_keys '
        'WHERE "userId" = ${bob.userId} AND "deviceId" = 1 '
        'AND "keyId" = $otpId;',
      );
      expect(spent, [
        ['t'],
      ]);
    });

    test(
      'a served bundle builds a real session: first ciphertext is PreKey (3:) '
      'and the peer decrypts it',
      () async {
        final bundle = await alice.fetchBundleFor(bob.userId);
        expect(bundle['identityPublicKey'], isA<String>());
        expect(
          bundle['oneTimePreKeyId'],
          isNotNull,
          reason: 'fresh account must have unused one-time pre-keys',
        );
        await alice.encryption.buildSession(
          bob.userId,
          bundle,
          expectedIdentityBase64: null,
        );

        await hop(alice, bob, 'first-contact-$runTag', expectedWireType: 3);
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'replies ratchet to whisper (2:) in both directions, in order',
      () async {
        await hop(bob, alice, 'reply-1-$runTag', expectedWireType: 2);
        await hop(alice, bob, 'msg-2-$runTag', expectedWireType: 2);
        await hop(bob, alice, 'reply-2-$runTag', expectedWireType: 2);

        // Same plaintext twice must produce different ciphertexts (ratchet
        // advanced), and both must decrypt.
        final ct1 = await alice.encryptText(bob.userId, 'twin-$runTag');
        final ct2 = await alice.encryptText(bob.userId, 'twin-$runTag');
        expect(ct1, isNot(ct2), reason: 'ratchet must advance per message');
        expect(await bob.decryptText(alice.userId, ct1), 'twin-$runTag');
        expect(await bob.decryptText(alice.userId, ct2), 'twin-$runTag');
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'mid-conversation session rebuild goes PreKey (3:) and peer recovers',
      () async {
        // The 2026-07 field-incident shape: sender loses/rebuilds its session
        // mid-conversation; next message is a type-3 that the receiver must
        // process over its existing session state.
        await alice.encryption.deleteSession(bob.userId);
        final bundle = await alice.fetchBundleFor(bob.userId);
        await alice.encryption.buildSession(
          bob.userId,
          bundle,
          expectedIdentityBase64: null,
        );

        await hop(alice, bob, 'post-rebuild-$runTag', expectedWireType: 3);

        // Bidirectional sanity after the rebuild.
        await hop(bob, alice, 'post-rebuild-reply-$runTag', expectedWireType: 2);
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    // Phase 1 (spec §4 + §5.1 + §8): key material is namespaced by
    // (userId, deviceId), the device a bundle lands in comes from the
    // SESSION, and a device that published nothing is served nothing.
    //
    // Hosted here rather than in a file of its own because /auth/register is
    // throttled 10/hr per IP and this suite already spends every one of them;
    // alice is an account with real published keys, which is all this needs.
    group('per-device key material (Phase 1 §4)', () {
      late String sharedIdentity;
      late int deviceOneRegistration;

      setUpAll(() async {
        final deviceOne = await alice.fetchBundleFor(alice.userId, deviceId: 1);
        sharedIdentity = deviceOne['identityPublicKey'] as String;
        deviceOneRegistration = deviceOne['registrationId'] as int;
      });

      test(
        'an upload lands on the SESSION\'s device, whatever the payload claims',
        () async {
          // A client naming someone else's device could scatter key material
          // across namespaces peers later fetch, or park a bundle where the
          // account's real device-1 lookup never sees it (spec §5.1). The
          // SAME-install re-upload (same registrationId — amendment (lxiv))
          // proves the claim is ignored:
          final claimed = await alice.uploadDeviceKeyBundle(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            registrationId: deviceOneRegistration,
          );
          expect(claimed['success'], isTrue);

          // It went to device 1 — this session's device...
          final one = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(one['registrationId'], deviceOneRegistration);
          expect(
            one['identityPublicKey'],
            sharedIdentity,
            reason: 'the account identity is unchanged, so no lock refusal',
          );

          // ...and device 2 still does not exist.
          final two = await alice.fetchBundleRawFor(alice.userId, deviceId: 2);
          expect(two['bundle'], isNull);

          // Amendment (lxiv) clause 1: the same upload with a DIFFERENT
          // registrationId is by construction a foreign install writing into a
          // namespace it does not own (identity and registrationId are minted
          // together, once) — the revoked-device-signs-back-in shape whose
          // clobber mixes two installs' X3DH halves. Refused, nothing written.
          // Pre-(lxiv) this very upload SUCCEEDED and this test asserted the
          // clobber landing; the contract changed deliberately.
          final foreign = await alice.uploadDeviceKeyBundle(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            registrationId: deviceOneRegistration + 1,
          );
          expect(foreign['success'], isFalse);
          expect(foreign['error'], 'device_material_conflict');
          final after = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(
            after['registrationId'],
            deviceOneRegistration,
            reason: 'a refused foreign write must leave the row untouched',
          );
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'one-time pre-keys follow the session device too',
        () async {
          await alice.uploadDeviceOneTimePreKeys(
            deviceId: 2,
            identityPublicKey: sharedIdentity,
            keyIds: const [900, 901],
            publicKeyPrefix: 'claimed-dev2-otp-',
          );

          // Device 2 has no bundle, so nothing is served for it at all.
          final two = await alice.fetchBundleRawFor(alice.userId, deviceId: 2);
          expect(two['bundle'], isNull);

          // The keys landed in device 1's namespace, where this session lives.
          final one = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(one['oneTimePreKeyPublic'], isNotNull);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'an unknown device is served nothing, never another device\'s keys',
        () async {
          // Fail-closed: serving device 1's bundle for a device that never
          // uploaded one would build a session no such device can decrypt.
          final missing = await alice.fetchBundleRawFor(
            alice.userId,
            deviceId: 97,
          );

          expect(missing['bundle'], isNull);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test(
        'a client that names no device still gets device 1 (§8 rollout)',
        () async {
          final legacy = await alice.fetchBundleFor(alice.userId);

          expect(legacy['identityPublicKey'], sharedIdentity);
          expect(legacy['registrationId'], deviceOneRegistration);
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );
    });

    // Phase 2 T2 (spec §3/§5.2 + §12 amendments (d)/(g)): DAK enrollment,
    // the DAK-signed device list, and its falsifications — 2 (IK-signed
    // mutation), 3 (rollback/replay), 23 (byte-exact canonical), 25
    // (cross-construction signatures). Reuses alice (enrolling primary) and
    // bob (verifying peer): the register throttle budget is spent
    // (10/hr/IP across the suite), so NO new accounts here.
    group('DAK-signed device list (Phase 2 T2)', () {
      late IdentityKeyPair aliceIdentity;
      late int enrolledCreatedAt;
      late Map<String, dynamic> enrollPayload;
      late Map<String, dynamic> enrolledAuthorization;

      setUpAll(() async {
        aliceIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await alice.exportIdentityPair()),
        );
      });

      test('enrollment pins DAK + v1 signed list, serves it byte-exact, and a '
          'peer chain-verifies IK→E→DAK→list (I7, falsification 23)', () async {
        // An unenrolled account answers null — the fail-closed shape a
        // legacy-server probe also relies on (§8).
        final before = await bob.searchPeer(alice);
        expect(before['authorization'], isNull);

        alice.events.discard('deviceListChanged');
        enrolledCreatedAt = DateTime.now().millisecondsSinceEpoch;
        final result = await engine.enroll(
          userId: alice.userId,
          identity: aliceIdentity,
          createdAtMs: enrolledCreatedAt,
          send: (payload) {
            enrollPayload = payload;
            return alice.enrollDeviceAuthority(payload);
          },
        );
        expect(result.accepted, isTrue, reason: 'error=${result.error}');

        // The account's sessions learn about the accepted write (§7 row
        // 424: deviceListChanged).
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['userId'] == alice.userId,
          reason: 'alice deviceListChanged v1',
        );
        expect((changed as Map)['listVersion'], 1);

        // Served BYTE-EXACT: the stored base64 is the minted base64,
        // character for character (falsification 23 transport rule).
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['listCanonical'], enrollPayload['listCanonical']);
        expect(auth['listSignature'], enrollPayload['listSignature']);
        expect(auth['dakPub'], enrollPayload['dakPub']);
        expect(auth['enrollmentSig'], enrollPayload['enrollmentSig']);
        expect(
          auth['enrollmentCreatedAt'],
          enrolledCreatedAt,
          reason: 'peers re-verify E over the exact signed createdAt',
        );
        expect(auth['listVersion'], 1);

        // Peer view: bob looks alice up the way a stranger does (`searchUsers`
        // serves the account's signed list beside each device's bundle — the
        // server no longer answers a peer's `getDeviceList`) and verifies the
        // FULL chain against his TOFU'd view of alice's identity key (I7).
        final found = await bob.searchPeer(alice);
        final tofuBundle =
            ((found['devices'] as List).single as Map)['bundle'] as Map;
        enrolledAuthorization = (found['authorization'] as Map)
            .cast<String, dynamic>();
        expect(
          enrolledAuthorization['listCanonical'],
          enrollPayload['listCanonical'],
          reason: 'listCanonical must survive the wire byte-exact',
        );
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: enrolledAuthorization,
          tofuIdentityKeyBase64: tofuBundle['identityPublicKey'] as String,
          expectedUserId: alice.userId,
        );
        expect(verdict.ok, isTrue, reason: 'reason=${verdict.reason}');
        expect(verdict.deviceList!.devices.single.deviceId, 1);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test(
        'one-time pre-keys under an UNPUBLISHED identity are refused on an '
        'ENROLLED account and the published pool survives (§5.1)',
        () async {
          // Observed live 2026-08-18: the lock refused a session's identity and
          // that same session still upserted 20 OTPs over the legitimate
          // device's keyId 0..19 slots. Unservable (the fetch filter pins the
          // published identity) but the victim's pool went empty until a peer
          // fetch re-triggered replenishment.
          //
          // Runs AFTER alice's enrolment: since (lxxiii) clause 1 the OTP site
          // is exempt on an UN-enrolled account (bundle + OTPs are emitted back
          // to back and the keys may land first), so only an enrolled account
          // refuses here.
          final before = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          final publishedIdentity = before['identityPublicKey'] as String;

          await alice.uploadDeviceOneTimePreKeys(
            deviceId: 1,
            identityPublicKey: 'unpublished-identity-$runTag',
            keyIds: const [0, 1],
            publicKeyPrefix: 'foreign-otp-',
            expectRefusal: 'identity_locked',
          );

          // The account still serves a key, and never the refused epoch's.
          final served = await alice.fetchBundleFor(alice.userId, deviceId: 1);
          expect(served['identityPublicKey'], publishedIdentity);
          final otp = served['oneTimePreKeyPublic'] as String?;
          expect(
            otp,
            isNotNull,
            reason: 'the refusal must not have emptied the pool',
          );
          expect(otp, isNot(startsWith('foreign-otp-')));
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );

      test('a second enrollment is refused — first-write-wins, the DAK '
          'authority is born once (I2)', () async {
        final second = DeviceAuthorityEngine();
        final result = await second.enroll(
          userId: alice.userId,
          identity: aliceIdentity,
          send: alice.enrollDeviceAuthority,
        );
        expect(result.accepted, isFalse);
        expect(result.error, 'already_enrolled');

        // Nothing moved: the pinned enrollment is the original one.
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['dakPub'], enrollPayload['dakPub']);
        expect(auth['listVersion'], 1);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('a list mutation signed by IK instead of DAK is rejected by the '
          'server and by the peer verifier (falsification 2)', () async {
        final canonical = encodeCanonicalDeviceList(
          DeviceList(
            userId: alice.userId,
            version: 2,
            devices: [
              DeviceListEntry(
                deviceId: 1,
                platform: 'android',
                addedAtMs: enrolledCreatedAt,
              ),
            ],
          ),
        );
        // Signed with the CORRECT list context but the WRONG authority:
        // the account's identity key (what a compromised linked PWA holds).
        final ikSignature = Curve.calculateSignature(
          aliceIdentity.getPrivateKey(),
          buildDeviceListMessage(canonical),
        );
        final answer = await alice.updateDeviceList({
          'listCanonical': base64Encode(canonical),
          'listSignature': base64Encode(ikSignature),
        });
        expect(answer['success'], isFalse);
        expect(answer['error'], 'invalid_list_signature');

        // Client half: the same forgery presented as a getDeviceList
        // answer is refused by the chain verifier.
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: {
            ...enrolledAuthorization,
            'listVersion': 2,
            'listCanonical': base64Encode(canonical),
            'listSignature': base64Encode(ikSignature),
          },
          tofuIdentityKeyBase64: base64Encode(
            aliceIdentity.getPublicKey().serialize(),
          ),
          expectedUserId: alice.userId,
        );
        expect(verdict.ok, isFalse);
        expect(verdict.reason, 'invalid_list_signature');

        // The stored list did not move.
        final own = await alice.fetchDeviceList(alice.userId);
        expect((own['authorization'] as Map)['listVersion'], 1);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('version rollback, replay, and unsigned mutations are refused '
          'loudly; a valid v2 advances (falsification 3)', () async {
        final v2 = DeviceList(
          userId: alice.userId,
          version: 2,
          devices: [
            DeviceListEntry(
              deviceId: 1,
              platform: 'android',
              addedAtMs: enrolledCreatedAt,
              name: 'primary',
            ),
          ],
        );
        alice.events.discard('deviceListChanged');
        final v2Payload = engine.signList(v2);
        final accepted = await alice.updateDeviceList(v2Payload);
        expect(accepted['success'], isTrue, reason: '$accepted');
        expect(accepted['listVersion'], 2);
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == 2,
          reason: 'alice deviceListChanged v2',
        );
        expect((changed as Map)['userId'], alice.userId);

        // Replay of the accepted v2 → refused (version <= stored).
        final replayed = await alice.updateDeviceList(v2Payload);
        expect(replayed['success'], isFalse);
        expect(replayed['error'], 'stale_version');

        // Rollback: a FRESH valid signature over version 1 → refused.
        final rollback = await alice.updateDeviceList(
          engine.signList(
            DeviceList(
              userId: alice.userId,
              version: 1,
              devices: [
                DeviceListEntry(
                  deviceId: 1,
                  platform: 'android',
                  addedAtMs: enrolledCreatedAt,
                ),
              ],
            ),
          ),
        );
        expect(rollback['success'], isFalse);
        expect(rollback['error'], 'stale_version');

        // Unsigned/garbage signature at a NEW version → refused.
        final v3 = engine.signList(
          DeviceList(userId: alice.userId, version: 3, devices: v2.devices),
        );
        final unsigned = await alice.updateDeviceList({
          'listCanonical': v3['listCanonical'],
          'listSignature': base64Encode(Uint8List(64)),
        });
        expect(unsigned['success'], isFalse);
        expect(unsigned['error'], 'invalid_list_signature');

        // The stored list is exactly the accepted v2, byte-exact.
        final own = await alice.fetchDeviceList(alice.userId);
        final auth = (own['authorization'] as Map).cast<String, dynamic>();
        expect(auth['listVersion'], 2);
        expect(auth['listCanonical'], v2Payload['listCanonical']);

        // Client half of the rollback flag: a peer that pinned v2 and is
        // then served the old v1 answer raises the LOUD flag (I7).
        final verdict = DeviceAuthorityEngine.verifyPeerDeviceList(
          authorization: enrolledAuthorization,
          tofuIdentityKeyBase64: base64Encode(
            aliceIdentity.getPublicKey().serialize(),
          ),
          expectedUserId: alice.userId,
          previousVersion: 2,
        );
        expect(verdict.ok, isFalse);
        expect(verdict.reason, 'version_rollback');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('an ambiguous canonical is rejected AT PARSE even when correctly '
          'DAK-signed (falsification 23)', () async {
        // Duplicate-key bytes a canonical writer can never produce, signed
        // with the REAL enrolled DAK so only the parser can refuse them.
        final duplicateKey = Uint8List.fromList(
          utf8.encode(
            '{"userId":${alice.userId},"version":4,"version":4,"devices":'
            '[{"addedAt":1,"deviceId":1,"platform":"android"}]}',
          ),
        );
        // ignore: invalid_use_of_visible_for_testing_member
        final dupSig = engine.debugSignCanonicalBytes(duplicateKey);
        final dup = await alice.updateDeviceList({
          'listCanonical': base64Encode(duplicateKey),
          'listSignature': base64Encode(dupSig),
        });
        expect(dup['success'], isFalse);
        expect(dup['error'], 'invalid_canonical');

        // Whitespace re-serialization of a valid list: same rejection.
        final whitespace = Uint8List.fromList(
          utf8.encode(
            '{"userId":${alice.userId}, "version":4,"devices":'
            '[{"addedAt":1,"deviceId":1,"platform":"android"}]}',
          ),
        );
        // ignore: invalid_use_of_visible_for_testing_member
        final wsSig = engine.debugSignCanonicalBytes(whitespace);
        final ws = await alice.updateDeviceList({
          'listCanonical': base64Encode(whitespace),
          'listSignature': base64Encode(wsSig),
        });
        expect(ws['success'], isFalse);
        expect(ws['error'], 'invalid_canonical');

        // The client parser refuses the identical bytes (shared grammar).
        expect(
          () => parseCanonicalDeviceList(duplicateKey),
          throwsA(isA<CanonicalDeviceListException>()),
        );

        final own = await alice.fetchDeviceList(alice.userId);
        expect((own['authorization'] as Map)['listVersion'], 2);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('a signature minted for one construction is rejected by every '
          'other construction\'s verifier (falsification 25)', () async {
        // Enrollment signature presented as a list signature.
        final crossList = await alice.updateDeviceList({
          'listCanonical': enrollPayload['listCanonical'],
          'listSignature': enrollPayload['enrollmentSig'],
        });
        expect(crossList['success'], isFalse);
        expect(crossList['error'], 'invalid_list_signature');

        // bob (unenrolled) attempts enrollment whose E-slot carries other
        // constructions' signatures. His engine mints honestly, then the
        // signature is swapped — everything else stays valid.
        final bobIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await bob.exportIdentityPair()),
        );
        final bobEngine = DeviceAuthorityEngine();
        final bobPayload = bobEngine.mintEnrollment(
          userId: bob.userId,
          identity: bobIdentity,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        );

        // (a) The DAK list signature presented as the enrollment sig.
        final listAsEnroll = await bob.enrollDeviceAuthority({
          ...bobPayload,
          'enrollmentSig': bobPayload['listSignature'],
        });
        expect(listAsEnroll['success'], isFalse);
        expect(listAsEnroll['error'], 'invalid_enrollment_signature');

        // (b) A FROZEN §6.1 registration-lock signature (0x05-leading
        // layout, no context) presented as the enrollment sig — the
        // CVE-2022-39250-class replay amendment (d) exists to kill.
        final ikSerialized = bobIdentity.getPublicKey().serialize();
        final lockMessage = Uint8List.fromList([
          ...ikSerialized,
          ...utf8.encode('${bob.userId}'),
          ...List<int>.generate(32, (i) => i),
        ]);
        final lockSig = Curve.calculateSignature(
          bobIdentity.getPrivateKey(),
          lockMessage,
        );
        final lockAsEnroll = await bob.enrollDeviceAuthority({
          ...bobPayload,
          'enrollmentSig': base64Encode(lockSig),
        });
        expect(lockAsEnroll['success'], isFalse);
        expect(lockAsEnroll['error'], 'invalid_enrollment_signature');

        // The refusals wrote nothing: bob is still unenrolled.
        final bobOwn = await bob.fetchDeviceList(bob.userId);
        expect(bobOwn['authorization'], isNull);
      }, timeout: const Timeout(Duration(minutes: 1)));
    });

    // Phase 2 T3 (spec §5.1 + §12 amendments (a)-(c)/(i)-(iv)): the
    // provisioning ceremony — two-round DH-bound SAS, secrets last,
    // two-phase commit. Falsifications 8 (session-bound one-shot complete),
    // 18 (two-phase kill + abort), 20 (concurrent double-link) and the
    // amendment (a) idempotency extensions. Reuses alice (the T2 group left
    // her ENROLLED and the shared `engine` holds her real DAK) — the
    // register throttle budget is spent, so the "new device" is a second
    // authenticated session of her account (adoptAccountFrom), exactly the
    // §5.1 shape: N is logged in, deviceId pending.
    group('provisioning ceremony (Phase 2 T3 §5.1)', () {
      late IdentityKeyPair aliceIdentity;

      setUpAll(() async {
        aliceIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await alice.exportIdentityPair()),
        );
      });

      /// Alice's authorization as the server currently serves it.
      Future<Map<String, dynamic>> currentAuth() async {
        final own = await alice.fetchDeviceList(alice.userId);
        return (own['authorization'] as Map).cast<String, dynamic>();
      }

      /// DAK-signs the STORED list plus one new entry for [deviceId]
      /// (platform label, NO name — amendment (i)) at version stored+1.
      Future<Map<String, dynamic>> signAddedDevice(int deviceId) async {
        final auth = await currentAuth();
        final stored = parseCanonicalDeviceList(
          base64Decode(auth['listCanonical'] as String),
        );
        return engine.signList(
          DeviceList(
            userId: alice.userId,
            version: stored.version + 1,
            devices: [
              ...stored.devices,
              DeviceListEntry(
                deviceId: deviceId,
                platform: 'harness',
                addedAtMs: DateTime.now().millisecondsSinceEpoch,
              ),
            ],
          ),
        );
      }

      /// The IK-bearing blob payload the primary seals for the new device.
      LinkBlobPayload blobPayloadFor(int deviceId, Map<String, dynamic> auth) =>
          LinkBlobPayload(
            userId: alice.userId,
            deviceId: deviceId,
            ikPub: base64Encode(aliceIdentity.getPublicKey().serialize()),
            ikPriv: base64Encode(aliceIdentity.getPrivateKey().serialize()),
            dakPub: auth['dakPub'] as String,
            enrollmentCreatedAt: auth['enrollmentCreatedAt'] as int,
            enrollmentSig: auth['enrollmentSig'] as String,
          );

      test('full link: open → OOB code → hello → equal SAS → staged blob+list '
          '→ one-shot session-bound commit → rebind → keys land on the new '
          'device, device 1 untouched (§5.1, falsification 8, amendments '
          '(a)/(b)/(iii))', () async {
        final n = E2eClient('linkN', baseUrl);
        n.adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // Device 1's bundle as served BEFORE the ceremony: the primary's key
        // material must be byte-identical after N uploads its own.
        final deviceOneBefore = await bob.fetchBundleFor(
          alice.userId,
          deviceId: 1,
        );

        // N opens. The answer carries NO deviceId — N learns its id from the
        // decrypted blob only (amendment (a)).
        final ephN = generateLinkEphemeral();
        final opened = await n.openProvisioning();
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        // The OOB code round-trips the new device's ephemeral WITHOUT the
        // server (amendment (c)): this string is the only channel it ever
        // travels. The role segment names the DISPLAYING side — here `n`,
        // the default, i.e. the classic v1-shaped ceremony ((lxxvii) cl. 2).
        final code = LinkOobCode(
          provisioningId: provisioningId,
          ephPub: linkEphemeralPublicBytes(ephN),
          platform: 'harness',
        ).encode();
        final scanned = LinkOobCode.tryParse(code);
        expect(scanned, isNotNull);
        expect(scanned!.provisioningId, provisioningId);
        expect(scanned.role, LinkRole.newDevice);

        // Primary hello: the ack is how the primary learns the id it must
        // sign; the relay reaches N's opener socket.
        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;
        expect(assignedId, greaterThanOrEqualTo(2));
        final relayed = await n.events.next(
          'provisioningHello',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'hello relay to the opener socket',
        );
        expect((relayed as Map)['ephPubP'], ephPubP);

        // Idempotency (amendment (a)): the SAME ephemeral re-acks success
        // with the SAME memoized id; a DIFFERENT one is refused.
        final retried = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(retried['success'], isTrue);
        expect(retried['deviceId'], assignedId);
        final rogue = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(
            linkEphemeralPublicBytes(generateLinkEphemeral()),
          ),
        );
        expect(rogue['success'], isFalse);
        expect(rogue['error'], 'ephemeral_already_pinned');

        // Both sides derive the SAS from their OWN DH computation over the
        // pinned transcript — equal, and formatted for humans (§12 (ii)).
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: scanned.ephPub,
          ephPubP: base64Decode(ephPubP),
        );
        final sdhP = linkSharedSecret(
          theirEphPub: scanned.ephPub,
          ownEphPriv: ephP.privateKey,
        );
        final sdhN = linkSharedSecret(
          theirEphPub: base64Decode(relayed['ephPubP'] as String),
          ownEphPriv: ephN.privateKey,
        );
        final sasP = deriveLinkSas(sharedSecret: sdhP, transcript: transcript);
        final sasN = deriveLinkSas(sharedSecret: sdhN, transcript: transcript);
        expect(sasP, sasN, reason: 'both humans must read the same code');
        expect(sasP, matches(RegExp(r'^\d{3} \d{3}$')));

        // Primary approves: blob under the SAS-verified secret + the signed
        // v+1 list adding EXACTLY the assigned id. N receives the blob push.
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        final blob = sealLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhP, transcript: transcript),
          payload: blobPayloadFor(assignedId, auth),
        );
        final staged = await signAddedDevice(assignedId);
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(blob),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final pushed = await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob push to the opener socket',
        );

        // N opens the blob under ITS OWN derivation: the identity, the DAK
        // pin, and the assigned id arrive intact (secrets-last, I3) — and N
        // can re-verify its own enrollment chain from the blob alone.
        final payload = openLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhN, transcript: transcript),
          blob: base64Decode((pushed as Map)['blob'] as String),
        );
        expect(payload.deviceId, assignedId);
        expect(payload.userId, alice.userId);
        expect(
          payload.ikPub,
          base64Encode(aliceIdentity.getPublicKey().serialize()),
        );
        expect(payload.dakPub, auth['dakPub']);
        expect(
          verifyEnrollmentSignature(
            identityPubSerialized: base64Decode(payload.ikPub),
            userId: payload.userId,
            dakPubSerialized: base64Decode(payload.dakPub),
            createdAtMs: payload.enrollmentCreatedAt,
            signature: base64Decode(payload.enrollmentSig),
          ),
          isTrue,
          reason: 'N re-verifies IK→E→DAK from the blob fields',
        );

        // Falsification 8: a complete from ANOTHER session of the same
        // account — authenticated, primary, knows the id — is refused.
        final foreign = await alice.provisioningComplete(provisioningId);
        expect(foreign['success'], isFalse);
        expect(foreign['error'], 'not_opener');

        // One-shot commit on the opener socket. The deviceId-bound token
        // pair travels in the answer (amendments (b)/(iii)).
        alice.events.discard('deviceListChanged');
        final completed = await n.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');
        expect(completed['deviceId'], assignedId);
        final rebindToken = completed['access_token'] as String;
        expect(completed['refresh_token'], isA<String>());
        expect(rebindToken, isNot(alice.accessToken));

        // The stage is retired, not forgotten: a duplicate complete is
        // answered as such, and the blob can NEVER be re-fetched after
        // commit (amendment (a)).
        final duplicate = await n.provisioningComplete(provisioningId);
        expect(duplicate['success'], isFalse);
        expect(duplicate['error'], 'already_completed');
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['error'], 'no_blob');

        // Every session of the account learns about the committed mutation,
        // and the list advanced by exactly the staged bytes.
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == versionBefore + 1,
          reason: 'commit broadcast',
        );
        expect((changed as Map)['userId'], alice.userId);
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore + 1);
        expect(after['listCanonical'], staged['listCanonical']);

        // Rebind (amendment (b)): N reconnects under the deviceId-bound
        // token and only THEN uploads key material — which lands on ITS
        // device (the session id rules; the payload id is ignored).
        n.socketService.disconnect();
        n.accessToken = rebindToken;
        await n.connectSocket();
        final uploaded = await n.uploadDeviceKeyBundle(
          deviceId: assignedId,
          identityPublicKey: deviceOneBefore['identityPublicKey'] as String,
          registrationId: 7777,
        );
        expect(uploaded['success'], isTrue, reason: '$uploaded');
        await n.uploadDeviceOneTimePreKeys(
          deviceId: assignedId,
          identityPublicKey: deviceOneBefore['identityPublicKey'] as String,
          keyIds: const [0, 1],
          publicKeyPrefix: 'link-n-otp-',
        );
        final deviceN = await bob.fetchBundleFor(
          alice.userId,
          deviceId: assignedId,
        );
        expect(deviceN['registrationId'], 7777);

        // The primary's device-1 bundle is untouched by all of it.
        final deviceOneAfter = await bob.fetchBundleFor(
          alice.userId,
          deviceId: 1,
        );
        expect(
          deviceOneAfter['identityPublicKey'],
          deviceOneBefore['identityPublicKey'],
        );
        expect(
          deviceOneAfter['registrationId'],
          deviceOneBefore['registrationId'],
        );
        expect(
          deviceOneAfter['signedPreKeyPublic'],
          deviceOneBefore['signedPreKeyPublic'],
        );
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('two-phase kill: no complete → nothing committed, blob '
          're-fetchable by the opener ONLY; cancel discards the stage '
          '(falsification 18, §5.1 abort hygiene)', () async {
        final n = E2eClient('linkAbort', baseUrl);
        n.adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // An unenrolled account cannot even open (§5.1 needs a pinned DAK).
        final unenrolled = await bob.openProvisioning();
        expect(unenrolled['success'], isFalse);
        expect(unenrolled['error'], 'not_enrolled');

        final ephN = generateLinkEphemeral();
        final opened = await n.openProvisioning();
        expect(opened['success'], isTrue, reason: '$opened');
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;

        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: base64Decode(ephPubP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        final staged = await signAddedDevice(assignedId);
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(
            sealLinkBlob(
              keys: deriveLinkBlobKeys(
                sharedSecret: sdh,
                transcript: transcript,
              ),
              payload: blobPayloadFor(assignedId, auth),
            ),
          ),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob push before the kill',
        );

        // The ceremony dies HERE — N never completes. Nothing committed:
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore);
        // The allocated id was never activated; no bundle is served for it.
        final ghost = await bob.fetchBundleRawFor(
          alice.userId,
          deviceId: assignedId,
        );
        expect(ghost['bundle'], isNull);

        // The blob stays re-fetchable until TTL — from the opener ONLY.
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['blob'], isA<String>());
        final foreignFetch = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(foreignFetch['success'], isFalse);
        expect(foreignFetch['error'], 'not_opener');

        // Stage existence never leaks: a bogus id and a FOREIGN ACCOUNT's
        // probe of the real id are answered identically (falsification 8's
        // "knowledge of provisioningId alone drives nothing").
        final bogus = await n.provisioningComplete(
          '00000000-0000-4000-8000-000000000000',
        );
        expect(bogus['error'], 'unknown_stage');
        final crossAccount = await bob.provisioningComplete(provisioningId);
        expect(crossAccount['error'], 'unknown_stage');

        // Cancel — from another authenticated session of the account —
        // discards the stage and tells the opener (I1 abort hygiene).
        n.events.discard('provisioningCancelled');
        final cancelled = await alice.cancelProvisioning(provisioningId);
        expect(cancelled['success'], isTrue, reason: '$cancelled');
        await n.events.next(
          'provisioningCancelled',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'cancel notice to the opener',
        );
        final gone = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(gone['error'], 'unknown_stage');
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('(lxxvii) flipped ceremony: the PRIMARY opens, the NEW device says '
          'hello, the relay carries the assigned deviceId, and only the '
          'primary may stage the blob (falsification F4)', () async {
        final n = E2eClient('linkFlipN', baseUrl)..adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        // Alice — the enrolled primary — holds the ceremony open. Answer
        // shape is unchanged: still no deviceId (amendment (a)).
        alice.events.discard('provisioningHello');
        final ephP = generateLinkEphemeral();
        final opened = await alice.openProvisioning(role: 'primary');
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        // The primary's code carries ITS ephemeral out of band, tagged `p` —
        // the whole point of (lxxvii) clause 2: either side may scan.
        final scanned = LinkOobCode.tryParse(
          LinkOobCode(
            provisioningId: provisioningId,
            ephPub: linkEphemeralPublicBytes(ephP),
            platform: 'harness',
            role: LinkRole.primary,
          ).encode(),
        );
        expect(scanned, isNotNull);
        expect(scanned!.role, LinkRole.primary);

        // The NEW device says hello. Its ack AND the relay to the opener
        // carry the allocated deviceId — with the primary on the opener
        // socket, the relay is the ONLY way it learns the id it must sign.
        final ephN = generateLinkEphemeral();
        final ephPubN = base64Encode(linkEphemeralPublicBytes(ephN));
        final ack = await n.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubN,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final assignedId = ack['deviceId'] as int;
        expect(assignedId, greaterThanOrEqualTo(2));
        final relayed = await alice.awaitProvisioningHelloRelay();
        expect(relayed['provisioningId'], provisioningId);
        expect(relayed['ephPubP'], ephPubN);
        expect(
          relayed['deviceId'],
          assignedId,
          reason: 'the primary signs the list for exactly this id',
        );

        // The SAS stays DH-bound to both ephemerals: which socket said hello
        // is not a crypto input, which is what makes the flip safe.
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: base64Decode(relayed['ephPubP'] as String),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdhP = linkSharedSecret(
          theirEphPub: base64Decode(relayed['ephPubP'] as String),
          ownEphPriv: ephP.privateKey,
        );
        final sdhN = linkSharedSecret(
          theirEphPub: scanned.ephPub,
          ownEphPriv: ephN.privateKey,
        );
        expect(
          deriveLinkSas(sharedSecret: sdhN, transcript: transcript),
          deriveLinkSas(sharedSecret: sdhP, transcript: transcript),
          reason: 'both humans still read the same code',
        );

        // F4: the new device holds no DAK, so ITS blob is refused — an
        // authenticated session of the account is not a role.
        final auth = await currentAuth();
        final staged = await signAddedDevice(assignedId);
        final blob = base64Encode(
          sealLinkBlob(
            keys: deriveLinkBlobKeys(
              sharedSecret: sdhP,
              transcript: transcript,
            ),
            payload: blobPayloadFor(assignedId, auth),
          ),
        );
        final stagePayload = {
          'provisioningId': provisioningId,
          'blob': blob,
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        };
        final refused = await n.provisionDevice(stagePayload);
        expect(refused['success'], isFalse);
        expect(refused['error'], 'not_primary');

        // The primary — the OPENER here — is accepted, and the blob is
        // relayed to the NEW device's socket, never back to the opener.
        n.events.discard('provisioningBlob');
        final acked = await alice.provisionDevice(stagePayload);
        expect(acked['success'], isTrue, reason: '$acked');
        final pushed = await n.events.next(
          'provisioningBlob',
          where: (p) => p is Map && p['provisioningId'] == provisioningId,
          reason: 'blob relay to the new device (F4)',
        );
        expect((pushed as Map)['blob'], blob);

        // Re-fetch binds to the hello side now, and the opener is refused by
        // the SAME v1 `not_opener` code.
        final refetch = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(refetch['blob'], blob);
        final byPrimary = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(byPrimary['success'], isFalse);
        expect(byPrimary['error'], 'not_opener');

        // The new device opens the blob under ITS own derivation: the
        // identity really crossed the flipped ceremony.
        final delivered = openLinkBlob(
          keys: deriveLinkBlobKeys(sharedSecret: sdhN, transcript: transcript),
          blob: base64Decode(refetch['blob'] as String),
        );
        expect(delivered.deviceId, assignedId);
        expect(delivered.userId, alice.userId);
        expect(
          delivered.ikPub,
          base64Encode(aliceIdentity.getPublicKey().serialize()),
        );

        // Deliberately NOT completed: `provisioningComplete` is 10 per 15 min
        // per USER and this group already spends most of that budget. Cancel
        // keeps the stage table clean.
        await alice.cancelProvisioning(provisioningId);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('(lxxvii) an explicit role:new open is still the classic ceremony: '
          'the hello side becomes the primary and the opener keeps the blob '
          'roles', () async {
        final n = E2eClient('linkRoleNew', baseUrl)..adoptAccountFrom(alice);
        await n.connectSocket();
        addTearDown(n.dispose);

        n.events.discard('provisioningHello');
        final opened = await n.openProvisioning(role: 'new');
        expect(opened['success'], isTrue, reason: '$opened');
        expect(opened.containsKey('deviceId'), isFalse);
        final provisioningId = opened['provisioningId'] as String;

        final ephP = generateLinkEphemeral();
        final ephPubP = base64Encode(linkEphemeralPublicBytes(ephP));
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: ephPubP,
        );
        expect(ack['success'], isTrue, reason: '$ack');
        final relayed = await n.awaitProvisioningHelloRelay();
        expect(relayed['ephPubP'], ephPubP);
        expect(relayed['deviceId'], ack['deviceId']);

        // The role slots are the v1 ones, and the two DIFFERENT refusals are
        // what prove it without spending a `provisionDevice` slot: the hello
        // side fails the role gate, the opener gets past it to "no blob yet".
        final byPrimary = await alice.fetchProvisioningBlobAnswer(
          provisioningId,
        );
        expect(byPrimary['success'], isFalse);
        expect(byPrimary['error'], 'not_opener');
        final byOpener = await n.fetchProvisioningBlobAnswer(provisioningId);
        expect(byOpener['success'], isFalse);
        expect(
          byOpener['error'],
          'no_blob',
          reason: 'the opener IS the new device under role:new',
        );

        await alice.cancelProvisioning(provisioningId);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('concurrent double-link: two stages race one version slot; the '
          'loser re-signs v+2 against the SAME stage and lands; exactly one '
          'device per ceremony (falsification 20)', () async {
        final n1 = E2eClient('linkRace1', baseUrl)..adoptAccountFrom(alice);
        final n2 = E2eClient('linkRace2', baseUrl)..adoptAccountFrom(alice);
        await n1.connectSocket();
        await n2.connectSocket();
        addTearDown(n1.dispose);
        addTearDown(n2.dispose);

        // Open + hello both ceremonies.
        Future<(String, int, Uint8List, Uint8List)> openAndHello(
          E2eClient n,
        ) async {
          final ephN = generateLinkEphemeral();
          final opened = await n.openProvisioning();
          expect(opened['success'], isTrue, reason: '$opened');
          final provisioningId = opened['provisioningId'] as String;
          final ephP = generateLinkEphemeral();
          final ephPubP = linkEphemeralPublicBytes(ephP);
          final ack = await alice.provisioningHello(
            provisioningId: provisioningId,
            ephPubP: base64Encode(ephPubP),
          );
          expect(ack['success'], isTrue, reason: '$ack');
          final sdh = linkSharedSecret(
            theirEphPub: linkEphemeralPublicBytes(ephN),
            ownEphPriv: ephP.privateKey,
          );
          final transcript = linkTranscript(
            provisioningId: provisioningId,
            ephPubN: linkEphemeralPublicBytes(ephN),
            ephPubP: ephPubP,
          );
          return (provisioningId, ack['deviceId'] as int, sdh, transcript);
        }

        final (idA, deviceA, sdhA, transcriptA) = await openAndHello(n1);
        final (idB, deviceB, sdhB, transcriptB) = await openAndHello(n2);
        expect(deviceA, isNot(deviceB), reason: 'ids never collide');

        // Both staged against the SAME stored version → both sign v+1.
        final auth = await currentAuth();
        final versionBefore = auth['listVersion'] as int;
        Future<Map<String, dynamic>> stage(
          String provisioningId,
          int deviceId,
          Uint8List sdh,
          Uint8List transcript,
        ) async {
          final staged = await signAddedDevice(deviceId);
          final acked = await alice.provisionDevice({
            'provisioningId': provisioningId,
            'blob': base64Encode(
              sealLinkBlob(
                keys: deriveLinkBlobKeys(
                  sharedSecret: sdh,
                  transcript: transcript,
                ),
                payload: blobPayloadFor(deviceId, auth),
              ),
            ),
            'listCanonical': staged['listCanonical'],
            'listSignature': staged['listSignature'],
          });
          expect(acked['success'], isTrue, reason: '$acked');
          return staged;
        }

        await stage(idA, deviceA, sdhA, transcriptA);
        await stage(idB, deviceB, sdhB, transcriptB);

        // First complete wins the version slot.
        final wonA = await n1.provisioningComplete(idA);
        expect(wonA['success'], isTrue, reason: '$wonA');
        expect((await currentAuth())['listVersion'], versionBefore + 1);

        // Second complete LOSES on the version law — stage restored, not
        // burned (amendment (a)).
        final lostB = await n2.provisioningComplete(idB);
        expect(lostB['success'], isFalse);
        expect(lostB['error'], 'stale_version');

        // The primary re-signs v+2 against the SAME stage (a retried
        // provisionDevice overwrites the staged mutation and re-uses the
        // memoized id) and the retried complete lands.
        await stage(idB, deviceB, sdhB, transcriptB);
        final retriedB = await n2.provisioningComplete(idB);
        expect(retriedB['success'], isTrue, reason: '$retriedB');
        expect(retriedB['deviceId'], deviceB);

        // Exactly one device per ceremony: the final list carries BOTH new
        // ids, at exactly two committed versions past the start.
        final after = await currentAuth();
        expect(after['listVersion'], versionBefore + 2);
        final list = parseCanonicalDeviceList(
          base64Decode(after['listCanonical'] as String),
        );
        final ids = list.devices.map((d) => d.deviceId).toSet();
        expect(ids.contains(deviceA), isTrue);
        expect(ids.contains(deviceB), isTrue);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('§5.5: revoking a device kicks it and refuses its reconnect, and '
          'its key material is purged with it — while the primary keeps '
          'working', () async {
        // A real second device of ALICE through the real ceremony (the harness
        // holds her DAK, so she is the only account that can sign a mutation).
        final doomed = E2eClient('revokeTarget', baseUrl)
          ..adoptAccountFrom(alice);
        await doomed.connectSocket();
        addTearDown(doomed.dispose);

        final ephN = generateLinkEphemeral();
        final opened = await doomed.openProvisioning();
        final provisioningId = opened['provisioningId'] as String;
        final ephP = generateLinkEphemeral();
        final ack = await alice.provisioningHello(
          provisioningId: provisioningId,
          ephPubP: base64Encode(linkEphemeralPublicBytes(ephP)),
        );
        final doomedId = ack['deviceId'] as int;
        final staged = await signAddedDevice(doomedId);
        final auth = await currentAuth();
        final transcript = linkTranscript(
          provisioningId: provisioningId,
          ephPubN: linkEphemeralPublicBytes(ephN),
          ephPubP: linkEphemeralPublicBytes(ephP),
        );
        final sdh = linkSharedSecret(
          theirEphPub: linkEphemeralPublicBytes(ephN),
          ownEphPriv: ephP.privateKey,
        );
        final acked = await alice.provisionDevice({
          'provisioningId': provisioningId,
          'blob': base64Encode(
            sealLinkBlob(
              keys: deriveLinkBlobKeys(
                sharedSecret: sdh,
                transcript: transcript,
              ),
              payload: blobPayloadFor(doomedId, auth),
            ),
          ),
          'listCanonical': staged['listCanonical'],
          'listSignature': staged['listSignature'],
        });
        expect(acked['success'], isTrue, reason: '$acked');
        final completed = await doomed.provisioningComplete(provisioningId);
        expect(completed['success'], isTrue, reason: '$completed');
        doomed.socketService.disconnect();
        doomed.accessToken = completed['access_token'] as String;
        await doomed.connectSocket();

        // It is a fully working device first: key material of its own, right
        // up to the revocation.
        final deviceOne = await bob.fetchBundleFor(alice.userId, deviceId: 1);
        final identityKey = deviceOne['identityPublicKey'] as String;
        final live = await doomed.uploadDeviceKeyBundle(
          deviceId: doomedId,
          identityPublicKey: identityKey,
          registrationId: 8811,
        );
        expect(live['success'], isTrue, reason: '$live');

        // ---- the revocation itself ----
        final beforeAuth = await currentAuth();
        final beforeList = parseCanonicalDeviceList(
          base64Decode(beforeAuth['listCanonical'] as String),
        );
        final versionBefore = beforeAuth['listVersion'] as int;
        final revokingList = engine.signList(
          DeviceList(
            userId: alice.userId,
            version: versionBefore + 1,
            devices: [
              for (final d in beforeList.devices)
                if (d.deviceId == doomedId)
                  DeviceListEntry(
                    deviceId: d.deviceId,
                    platform: d.platform,
                    addedAtMs: d.addedAtMs,
                    name: d.name,
                    revokedAtMs: DateTime.now().millisecondsSinceEpoch,
                  )
                else
                  d,
            ],
          ),
        );

        // The caller here IS device 1, so asking to revoke device 1 is a
        // self-revoke — refused before anything else is even looked at
        // (amendment (xxi)). It is also the primary, and the primary is the
        // only DAK holder: revoking it would leave the account unable to sign
        // any future list version, with the §6.2 reset as the only way back.
        final selfRevoke = await alice.revokeDevice({
          'deviceId': 1,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(selfRevoke['success'], isFalse);
        expect(selfRevoke['error'], 'cannot_revoke_self', reason: '$selfRevoke');

        // `list_device_mismatch`, the other half of (xxi): the request and the
        // signed bytes must agree, or the teardown would cut off a device the
        // account's own signed list still calls LIVE — and peers follow the
        // list, so they would keep addressing envelopes to it.
        //
        // The payload is the account's CURRENT stored list, which is genuinely
        // DAK-signed and still shows `doomed` live. That is the point: an
        // honest signature over the wrong SET is exactly the case the rung
        // exists for, and it proves the refusal is not merely a signature
        // check wearing a different name.
        //
        // This reaches the rung with ONE live non-primary device, not two: the
        // second device the older note asked for is the PRIMARY CALLER, which
        // every enrolled account already has. It must run BEFORE the real
        // revocation below — afterwards `doomed` is revoked and `already_revoked`
        // (an earlier rung) would answer instead.
        final mismatch = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': beforeAuth['listCanonical'],
          'listSignature': beforeAuth['listSignature'],
        });
        expect(mismatch['success'], isFalse);
        expect(
          mismatch['error'],
          'list_device_mismatch',
          reason: '$mismatch',
        );
        // Refused PRE-WRITE: the stored list did not move, and the very next
        // block revokes this same device successfully — so a refusal that had
        // leaked a partial teardown would break the proof that follows it.
        expect(
          (await currentAuth())['listCanonical'],
          beforeAuth['listCanonical'],
        );

        alice.events.discard('deviceListChanged');
        doomed.events.discard('deviceRevoked');
        final result = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(result['success'], isTrue, reason: '$result');
        expect(result['listVersion'], versionBefore + 1);

        // The kicked device is TOLD (amendment (xxvi)) and the account learns
        // the list moved.
        final notice = await doomed.events.next(
          'deviceRevoked',
          where: (p) => p is Map && p['deviceId'] == doomedId,
          reason: 'the revoked device must learn WHY its session ended',
        );
        expect((notice as Map)['userId'], alice.userId);
        final changed = await alice.events.next(
          'deviceListChanged',
          where: (p) => p is Map && p['listVersion'] == versionBefore + 1,
          reason: 'revocation broadcast',
        );
        expect((changed as Map)['userId'], alice.userId);

        // The stored list is byte-exactly what the primary signed.
        final afterAuth = await currentAuth();
        expect(afterAuth['listCanonical'], revokingList['listCanonical']);

        // A duplicate revocation is refused, not re-run.
        final again = await alice.revokeDevice({
          'deviceId': doomedId,
          'listCanonical': revokingList['listCanonical'],
          'listSignature': revokingList['listSignature'],
        });
        expect(again['success'], isFalse);
        expect(again['error'], anyOf('already_revoked', 'stale_version'));

        // ---- the session is gone, and stays gone ----
        // The still-valid access JWT buys nothing: the connect gate refuses it
        // and says why (amendments (xxii)/(xxvi)).
        doomed.socketService.disconnect();
        final refused = await doomed.connectExpectingRevoked();
        expect(refused['deviceId'], doomedId);

        // ---- its key material is gone, and it cannot publish more ----
        // T3's `device_not_active` upload rejection: wire-unreachable until
        // revocation existed, reachable now. The upload rides a session the
        // gate refuses, so this asserts the durable teardown instead: the
        // revoked device's bundle no longer exists to serve.
        final gone = await bob.fetchBundleRawFor(
          alice.userId,
          deviceId: doomedId,
        );
        expect(
          gone['success'] == false || gone['registrationId'] == null,
          isTrue,
          reason:
              'the revoked device\'s key bundle was purged with it: $gone',
        );
      }, timeout: const Timeout(Duration(minutes: 4)));
    });

    test('no unexpected socket errors surfaced during the run', () {
      expect(
        alice.events.errors,
        isEmpty,
        reason: 'alice received server error events',
      );
      expect(
        bob.events.errors,
        isEmpty,
        reason: 'bob received server error events',
      );
    });
  });
}
