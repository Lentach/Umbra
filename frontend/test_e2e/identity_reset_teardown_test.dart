// §6.2 identity reset, END TO END against a real backend and a real Postgres:
// the roster teardown (amendment (f)/(xxviii)) and falsification 12, the
// per-device epoch claim.
//
//   docker-compose up
//   cd frontend && flutter test test_e2e/identity_reset_teardown_test.dart \
//     --dart-define=RESET_PROBE=true
//
// WHY THIS IS OPT-IN, and it is not squeamishness. Two hard constraints:
//
//  1. `/auth/register` is 10 per HOUR per IP and — with no nginx in front —
//     every account in `test_e2e/` shares one bucket. Measured 2026-08-22: the
//     default run already spends it to the edge, and adding a THIRD account to
//     `full_stack_e2e_test.dart` pushed `takeover_alarm_test.dart` into
//     `ThrottlerException` on register. So a new account cannot simply be added
//     to the shared suite; the alternative was raising a production anti-abuse
//     cap to fit a test, which is not a trade this program makes.
//  2. The ceremony is DESTRUCTIVE. It replaces the account identity, revokes
//     every device and burns a device id forward permanently. It therefore
//     needs an account nothing else depends on — never a shared fixture.
//
// It follows the house pattern for probes with special preconditions
// (`box_roundtrip_test.dart`, `encryption_proof_test.dart`): skipped unless a
// dart-define asks for it.
//
// THE DELAY IS AGED, NOT WAITED (spec §12 (xxxvi)). §6.2's shortest real path
// is one hour with a valid recovery phrase. This ages
// `identity_reset_requests."deadlineAt"` by direct SQL and then lets the REAL
// per-minute `completeDueResets` sweep authorize the replacement. Forcing
// `status` to `completed` would skip that sweep and prove less.

// Mock-store setup is legitimate here: this file is a test, but `test_e2e/` is
// a sibling of `test/` so the analyzer does not treat it as one.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';

import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';
import 'support/link_ceremony.dart';

const _enabled = bool.fromEnvironment('RESET_PROBE');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  // The skip lives on the GROUP, not on the test. A test-level `skip:` still
  // runs the group's `setUpAll` — which registers an account and links a
  // device — so the default run would pay this probe's whole cost, including
  // the registration the budget has no room for, to then skip it. Observed,
  // not assumed.
  group(
    '§6.2 reset teardown + falsification 12 (per-device epoch)',
    () {
      final baseUrl = e2eBaseUrl();
      final runTag = DateTime.now().millisecondsSinceEpoch.toString();

      late E2eClient carol;
      late IdentityKeyPair carolIdentity;
      late String carolIdentityPublic;
      final carolEngine = DeviceAuthorityEngine();
      E2eClient? deviceTwo;
      late int deviceTwoId;
      E2eClient? recovering;

      /// A single scalar from the harness's Postgres.
      Future<String?> scalar(String sql) async {
        final rows = await e2eSql(sql);
        if (rows.isEmpty || rows.first.isEmpty) return null;
        return rows.first.first;
      }

      setUpAll(() async {
        await requireBackendUp(baseUrl);
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        // An account of its own, enrolled with its OWN device authority:
        // `DeviceAuthorityEngine` holds ONE DAK pair and minting overwrites it,
        // so an engine may never be shared between accounts.
        carol = E2eClient('rst', baseUrl);
        await carol.registerFresh();
        await carol.connectSocket();
        await carol.initializeAndUploadKeys();
        carolIdentity = IdentityKeyPair.fromSerialized(
          base64Decode(await carol.exportIdentityPair()),
        );
        carolIdentityPublic = base64Encode(
          carolIdentity.getPublicKey().serialize(),
        );

        final enrolled = await carolEngine.enroll(
          userId: carol.userId,
          identity: carolIdentity,
          send: carol.enrollDeviceAuthority,
        );
        expect(enrolled.accepted, isTrue, reason: '${enrolled.error}');

        // THE SECOND PARTITION, and it is the whole reason this setup is not
        // trivial. Falsification 12 claims purge/claim/count stay strictly
        // inside `(identityPublicKey, deviceId)`. With ONE device that claim is
        // trivially true and the test cannot fail (§12 (xxxvi)), so the account
        // gets a real second device through the real ceremony, with its own
        // one-time pre-keys carrying a marker this test can look for afterwards.
        final primary = CeremonyPrimary(
          client: carol,
          engine: carolEngine,
          identity: carolIdentity,
        );
        final linked = await linkNewDevice(primary, 'rstd2', baseUrl);
        deviceTwo = linked.$1;
        deviceTwoId = linked.$2;

        await deviceTwo!.uploadDeviceKeyBundle(
          deviceId: deviceTwoId,
          identityPublicKey: carolIdentityPublic,
          registrationId: 4242,
        );
        await deviceTwo!.uploadDeviceOneTimePreKeys(
          deviceId: deviceTwoId,
          identityPublicKey: carolIdentityPublic,
          keyIds: const [0, 1, 2],
          // The marker: opaque to the server, and the thing whose SURVIVAL would
          // falsify the per-device epoch claim.
          publicKeyPrefix: 'carol-d2-otp-$runTag-',
        );
      });

      tearDownAll(() {
        carol.dispose();
        deviceTwo?.dispose();
        recovering?.dispose();
      });

      test(
        'the replacement is refused until the SQL-aged sweep authorizes it, then '
        'the teardown re-keys strictly within (identity, deviceId): every sibling '
        'device is revoked and purged, a FRESH id is allocated, and the '
        'enrollment row is REPLACED not dropped '
        '(spec §6.2, amendments (f)/(xxviii)/(xxix)/(xxxvi), falsification 12)',
        () async {
          // ---- the pre-reset world, read from the server's own tables ----
          final devicesBefore = await e2eSql(
            'SELECT "deviceId","isPrimary","revokedAt" FROM devices '
            'WHERE "userId" = ${carol.userId} ORDER BY "deviceId";',
          );
          expect(
            devicesBefore.length,
            greaterThanOrEqualTo(2),
            reason: 'the epoch claim needs two partitions to be non-vacuous',
          );
          final markerBefore = await scalar(
            'SELECT count(*) FROM one_time_pre_keys WHERE "userId" = '
            '${carol.userId} AND "publicKey" LIKE \'carol-d2-otp-$runTag-%\';',
          );
          expect(
            markerBefore,
            '3',
            reason: 'device 2 must really own OTP rows before the reset',
          );
          final authBefore = await scalar(
            'SELECT "listCanonical" FROM account_authorizations '
            'WHERE "userId" = ${carol.userId};',
          );
          expect(authBefore, isNotNull, reason: 'carol is enrolled');
          final authVersionBefore = await scalar(
            'SELECT "listVersion" FROM account_authorizations '
            'WHERE "userId" = ${carol.userId};',
          );
          final nextDeviceIdBefore = int.parse(
            (await scalar(
              'SELECT "nextDeviceId" FROM users WHERE id = ${carol.userId};',
            ))!,
          );

          // ---- a second installation, which is what a recovery looks like ----
          // Brand-new Signal keys on carol's account: the shape of a legitimate
          // reinstall AND of a password-only takeover, which is exactly why §6.1
          // refuses it without proof.
          recovering = E2eClient('rstr', baseUrl)..adoptAccountFrom(carol);
          await recovering!.connectSocket();
          FlutterSecureStorage.setMockInitialValues({});
          final freshKeys = await recovering!.initializeKeys();
          final freshIdentity =
              (freshKeys['keyBundle'] as Map)['identityPublicKey'] as String;
          expect(freshIdentity, isNot(carolIdentityPublic));

          final locked = await recovering!.uploadKeyBundleRaw(freshKeys);
          expect(locked['success'], isFalse);
          expect(
            locked['error'],
            'identity_locked',
            reason: 'the §6.1 lock is what makes a reset necessary at all',
          );

          // ---- the ceremony ----
          expect(
            await carol.setRecoveryKey('reset-probe-phrase-$runTag'),
            isTrue,
          );
          // §12 (xlii): a phrase younger than the full reset delay may not
          // SHORTEN, or a password thief would enrol one and skip the wait it
          // exists to gate. Carol is the legitimate owner, so age the row in
          // seconds instead of waiting three days.
          await e2eSql(
            'UPDATE recovery_keys SET "createdAt" = NOW() - INTERVAL \'4 days\' '
            'WHERE "userId" = ${carol.userId};',
          );
          final requested = await carol.requestIdentityReset(
            recoveryPhrase: 'reset-probe-phrase-$runTag',
          );
          expect(requested['status'], 'pending', reason: '$requested');
          expect(
            requested['shortened'],
            isTrue,
            reason: 'a valid phrase SHORTENS the delay; it never silences it',
          );

          // PENDING IS NOT COMPLETED. Without this the aging step below could be
          // doing nothing and the test would still pass — the upload would just
          // be succeeding for a reason nobody checked.
          final stillLocked = await recovering!.uploadKeyBundleRaw(freshKeys);
          expect(
            stillLocked['error'],
            'identity_locked',
            reason: 'a PENDING ceremony must not yet authorize a replacement',
          );

          // Age the deadline into the past and let the REAL per-minute sweep
          // find it (§12 (xxxvi)). Forcing `status` here would skip the sweep.
          await e2eSql(
            'UPDATE identity_reset_requests SET "deadlineAt" = now() - '
            'interval \'5 seconds\' WHERE "userId" = ${carol.userId} '
            'AND status = \'pending\';',
          );
          var status = 'pending';
          for (var i = 0; i < 40 && status != 'completed'; i++) {
            await Future<void>.delayed(const Duration(seconds: 3));
            status = (await scalar(
              'SELECT status FROM identity_reset_requests WHERE "userId" = '
              '${carol.userId} ORDER BY id DESC LIMIT 1;',
            ))!;
          }
          expect(
            status,
            'completed',
            reason:
                'the real completeDueResets sweep must be what completes it — '
                'if this times out the cron is not running, which is the bug',
          );

          // ---- the replacement now lands, and fires the teardown ----
          // Drop anything buffered so the assertion below can only be satisfied
          // by the silence of THIS teardown, never by an empty backlog.
          recovering!.events.discard('deviceRevoked');
          final accepted = await recovering!.uploadKeyBundleRaw(freshKeys);
          expect(accepted['success'], isTrue, reason: '$accepted');
          final newDeviceId = accepted['deviceId'] as int;

          // (f)(i): a FRESH id, never device 1 again, never a reused one.
          expect(newDeviceId, nextDeviceIdBefore);
          expect(newDeviceId, isNot(1));
          expect(newDeviceId, isNot(deviceTwoId));

          // §12 (xli) ON THE WIRE — the guard that was wrong TWICE, and until
          // now was proven only against a mock. This socket is still
          // authenticated as its PRE-reset device id, so it sits in a room the
          // teardown just revoked. `_onOwnDeviceRevoked` does NOT filter on
          // device id: it reads the id for a diagnostic line, then logs out
          // unconditionally. So a room-wide announcement would make the
          // recovering client wipe the session it adopted three lines above,
          // and the recovery would strand on every run. The server must
          // exclude the caller from the announcement, not merely from the
          // disconnect.
          await recovering!.events.none(
            'deviceRevoked',
            within: const Duration(seconds: 3),
            reason:
                'the recovering caller must never be told its own old device '
                'id was revoked',
          );

          // REBIND, and it is not ceremony. The teardown allocated a new device
          // id and issued a token bound to it; this socket is still authenticated
          // as the OLD device 1, which the teardown just revoked. Uploading
          // anything before rebinding files it under the revoked partition —
          // observed first-hand here: 20 fresh-epoch pre-keys landed on device 1
          // instead of the recovering device, unreachable behind a revoked row.
          recovering!.socketService.disconnect();
          recovering!.accessToken = accepted['access_token'] as String;
          await recovering!.connectSocket();

          // ---- falsification 12: the teardown stayed inside its partitions ----
          final devicesAfter = await e2eSql(
            'SELECT "deviceId","isPrimary","revokedAt" FROM devices '
            'WHERE "userId" = ${carol.userId} ORDER BY "deviceId";',
          );
          for (final row in devicesAfter) {
            final id = int.parse(row[0]);
            final revokedAt = row[2];
            if (id == newDeviceId) {
              expect(row[1], 't', reason: 'the recovering device is primary');
              expect(revokedAt, isEmpty, reason: 'and it is live');
            } else {
              expect(
                revokedAt,
                isNotEmpty,
                reason: 'every sibling device must be revoked: device $id',
              );
            }
          }

          // The marker is the load-bearing half: device 2's key material lived in
          // its OWN (identity, deviceId) partition, and the reset had to reach
          // into that partition to remove it — while never serving, counting or
          // resurrecting it anywhere else.
          expect(
            await scalar(
              'SELECT count(*) FROM one_time_pre_keys WHERE "userId" = '
              '${carol.userId} AND "publicKey" LIKE \'carol-d2-otp-$runTag-%\';',
            ),
            '0',
            reason:
                'a revoked sibling device keeps no claimable pre-keys after a '
                'reset — this is the row a cross-partition purge would miss',
          );
          // Every pre-key of the OLD epoch is gone — including the recovering
          // device's own, because the epoch is `(identityPublicKey, deviceId)`
          // and the identity half just changed.
          expect(
            await scalar(
              'SELECT count(*) FROM one_time_pre_keys '
              'WHERE "userId" = ${carol.userId};',
            ),
            '0',
          );
          // The CLAIM/COUNT half of falsification 12, which the purge alone does
          // not prove: the recovering device republishes under the NEW epoch, and
          // every surviving row must sit in exactly that one partition. Without
          // this the "no row outside the partition" check iterates an empty set
          // and cannot fail.
          await recovering!.uploadOneTimePreKeys(
            freshKeys,
            tagIdentityEpoch: true,
          );
          final partitions = await e2eSql(
            'SELECT "deviceId","identityPublicKey",count(*) '
            'FROM one_time_pre_keys WHERE "userId" = ${carol.userId} '
            'GROUP BY "deviceId","identityPublicKey";',
          );
          expect(
            partitions.length,
            1,
            reason:
                'exactly ONE (identity, deviceId) partition may hold pre-keys',
          );
          expect(int.parse(partitions.single[0]), newDeviceId);
          expect(partitions.single[1], freshIdentity);
          expect(
            int.parse(partitions.single[2]),
            (freshKeys['oneTimePreKeys'] as List).length,
            reason: 'the count is exactly what the new epoch uploaded',
          );
          final bundleDevices = await e2eSql(
            'SELECT "deviceId","identityPublicKey" FROM key_bundles '
            'WHERE "userId" = ${carol.userId};',
          );
          expect(bundleDevices.length, 1);
          expect(int.parse(bundleDevices.single[0]), newDeviceId);
          expect(
            bundleDevices.single[1],
            freshIdentity,
            reason: 'the served identity is the NEW epoch',
          );

          // (xxix): the enrollment row survives the reset. Dropping it would
          // destroy the listVersion (f)(iii) requires be carried forward and make
          // the account read as never-enrolled, which the (xix) rollback pin
          // refuses. It is REPLACED later, by a fresh IK-signed enrollment.
          expect(
            await scalar(
              'SELECT "listCanonical" FROM account_authorizations '
              'WHERE "userId" = ${carol.userId};',
            ),
            authBefore,
            reason:
                'the reset must NOT clear, drop or version-restart the '
                'enrollment — a test expecting that asserts a spec violation',
          );

          // ...and "REPLACED later" is amendment (xlv) clause 1. Until the
          // recovering device re-enrolls, the surviving row still names the
          // devices this teardown just revoked and omits the id it allocated,
          // and the DAK that signed it died with the lost devices — so
          // `updateDeviceList` is not open to this client.
          //
          // AMENDMENT (l) — this used to FETCH that row and assert it does not
          // verify under the new identity. The server no longer serves it at
          // all. (xlv) clause 2 already withheld the roster for the
          // never-enrolled shape; (l) widened that to the SURVIVING-row shape
          // for the reason finding F3 proved: the row still names the pre-reset
          // devices LIVE, so a peer holding the pre-reset anchor VERIFIES that
          // dead roster — it was signed by the very key it pinned — commits
          // with a null envelope, and the loss is silent, permanent and
          // bidirectional. Withholding downgrades that to a visible send
          // failure. Silence is fail-closed on the client (I5: "cannot verify",
          // never "no devices"), matching the entitlement and error paths.
          //
          // The property the old fetch asserted still holds and is still
          // proven, deductively and by stronger evidence than a wire read: the
          // enrollment row is byte-identical to the pre-reset one (asserted
          // immediately above) while the served identity is the NEW epoch
          // (asserted at the key_bundles check), so the surviving row is signed
          // by a key that is no longer the account's and cannot verify under
          // it. If the reset had NOT changed the identity, that key_bundles
          // assertion would already have failed.
          recovering!.events.discard('deviceList');
          recovering!.socketService.socket!.emit('getDeviceList', {
            'userId': carol.userId,
          });
          await recovering!.events.none(
            'deviceList',
            within: const Duration(seconds: 4),
            reason:
                'a surviving enrollment row names only revoked devices, and a '
                'peer with the pre-reset anchor would VERIFY that dead roster '
                'and lose every message in both directions ((l))',
          );

          // The server names the version the replacement must carry, because
          // the client cannot read a row it cannot verify.
          expect(
            accepted['nextListVersion'],
            int.parse(authVersionBefore!) + 1,
            reason: 'the replacement must ADVANCE past the surviving version',
          );

          // The replacement itself: a FRESH DAK, signed by the NEW identity,
          // naming the freshly allocated id. In the app this is driven by
          // ConnectionProvider off the rebind ack; here the harness plays that
          // part so the SERVER half is proven end to end.
          final replacement = DeviceAuthorityEngine();
          final replaced = await replacement.enroll(
            userId: carol.userId,
            identity: IdentityKeyPair.fromSerialized(
              base64Decode(await recovering!.exportIdentityPair()),
            ),
            send: recovering!.enrollDeviceAuthority,
            deviceId: newDeviceId,
            version: accepted['nextListVersion'] as int,
          );
          expect(replaced.accepted, isTrue, reason: '${replaced.error}');

          // ...and now a peer can address the account again.
          final repaired = DeviceListCache().adopt(
            userId: carol.userId,
            authorization:
                (await recovering!.fetchDeviceList(
                      carol.userId,
                    ))['authorization']
                    as Map<String, dynamic>?,
            tofuIdentityKeyBase64: freshIdentity,
          );
          expect(
            repaired.liveDeviceIds,
            [newDeviceId],
            reason:
                'the peer-visible list must name the recovering device; naming '
                'the revoked ones loses every message in both directions',
          );
          expect(repaired.isLiveDevice(newDeviceId), isTrue);

          // (f)(iv): the allocator only ever moves forward.
          expect(
            int.parse(
              (await scalar(
                'SELECT "nextDeviceId" FROM users WHERE id = ${carol.userId};',
              ))!,
            ),
            greaterThan(nextDeviceIdBefore),
          );
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );
    },
    skip: _enabled ? false : 'set --dart-define=RESET_PROBE=true',
  );

  // ---------------------------------------------------------------------
  // The shape the harness above never builds, and that is exactly why this
  // exists. The probe above LINKS a device before it resets, because
  // falsification 12 needs two partitions to be non-vacuous — so every reset
  // this suite has ever run happened on an ENROLLED account. A single-device
  // account is the majority shape — and since (lxxiii) made enrolment OPT-IN
  // it is the DEFAULT shape, every user who never linked a second device.
  //
  // Under (lxxiii) the §6.1 lock is not armed for such an account, so a fresh
  // install replaces the identity on credentials alone (`via=unlocked`) under
  // device 1, and a peer that synthesizes device 1 for a non-enrolled account
  // is addressing the device that EXISTS. A §6.2 ceremony could therefore only
  // HARM it: its completion teardown revokes device 1 and allocates id >= 2
  // while the account stays un-enrolled, so every peer keeps synthesizing
  // device 1 and the only live device is unaddressable until it re-enrols
  // ((xlv) clause 2 keeps the server silent, fail-closed, forever). Ruling
  // 2026-09-05: the ceremony is REFUSED for an un-enrolled account, before the
  // phrase is examined. This probe pins that refusal AND the addressability it
  // protects.
  // ---------------------------------------------------------------------
  group(
    '§6.2 reset on a NEVER-ENROLLED account: refused, because the unlocked '
    'remint under device 1 is what keeps it addressable ((lxxiii), (xlv))',
    () {
      final baseUrl = e2eBaseUrl();
      final runTag = DateTime.now().millisecondsSinceEpoch.toString();

      late E2eClient solo;
      E2eClient? recovering;

      Future<String?> scalar(String sql) async {
        final rows = await e2eSql(sql);
        if (rows.isEmpty || rows.first.isEmpty) return null;
        return rows.first.first;
      }

      setUpAll(() async {
        await requireBackendUp(baseUrl);
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        // ONE device, and deliberately NO `enrollDeviceAuthority` and NO link
        // ceremony. `enrollDeviceAuthority` is emitted only by the linking
        // controller (`link_ceremony_controller.dart`), so an account that
        // never links a second device never enrolls — which is every user who
        // owns one phone.
        solo = E2eClient('nre', baseUrl);
        await solo.registerFresh();
        await solo.connectSocket();
        await solo.initializeAndUploadKeys();
      });

      tearDownAll(() {
        solo.dispose();
        recovering?.dispose();
      });

      test(
        'a fresh install remints unlocked under device 1, the ceremony is '
        'refused without spending the phrase, and a peer synthesizing device 1 '
        'addresses the device that exists',
        () async {
          expect(
            await scalar(
              'SELECT count(*) FROM account_authorizations '
              'WHERE "userId" = ${solo.userId};',
            ),
            '0',
            reason: 'the whole point: this account never enrolled',
          );

          // ---- the "I lost my only device" shape: a reinstall ---------------
          recovering = E2eClient('nrer', baseUrl)..adoptAccountFrom(solo);
          await recovering!.connectSocket();
          FlutterSecureStorage.setMockInitialValues({});
          final freshKeys = await recovering!.initializeKeys();
          final freshIdentity =
              (freshKeys['keyBundle'] as Map)['identityPublicKey'] as String;

          // (lxxiii) clause 1: accepted on credentials alone. No roster
          // teardown ran, so the answer carries no re-homed device id — the
          // material stays under device 1, which is the id peers synthesize.
          final accepted = await recovering!.uploadKeyBundleRaw(freshKeys);
          expect(accepted['success'], isTrue, reason: '$accepted');
          expect(
            accepted.containsKey('deviceId'),
            isFalse,
            reason: 'an unlocked remint must not re-home the device',
          );
          expect(
            await scalar(
              'SELECT "identityPublicKey" FROM key_bundles '
              'WHERE "userId" = ${solo.userId} AND "deviceId" = 1;',
            ),
            freshIdentity,
          );
          expect(
            await scalar(
              'SELECT count(*) FROM devices WHERE "userId" = ${solo.userId} '
              'AND "revokedAt" IS NOT NULL;',
            ),
            '0',
            reason: 'nothing was revoked: device 1 is still the live device',
          );

          // ---- the ceremony is refused, and the phrase is untouched ---------
          expect(await solo.setRecoveryKey('nre-phrase-$runTag'), isTrue);
          final requested = await solo.requestIdentityReset(
            recoveryPhrase: 'nre-phrase-$runTag',
          );
          expect(requested['status'], 'not_enrolled', reason: '$requested');
          expect(requested['deadlineAt'], isNull);
          expect(
            await scalar(
              'SELECT count(*) FROM identity_reset_requests '
              'WHERE "userId" = ${solo.userId};',
            ),
            '0',
            reason: 'a refusal writes no ceremony row',
          );
          // The refusal is about the account, not the phrase: a correct phrase
          // presented to a refused ceremony is neither spent nor counted.
          expect(
            await scalar(
              'SELECT "usedAt" IS NULL AND "failedAttempts" = 0 '
              'FROM recovery_keys WHERE "userId" = ${solo.userId};',
            ),
            't',
            reason: 'the phrase must survive for a future enrolled ceremony',
          );

          // ---- and a peer can reach the account, both directions -----------
          // A non-enrolled account is answered `authorization: null` (the
          // fail-closed §8 shape) and the peer synthesizes device 1 — which,
          // because nothing was torn down, is exactly the device that holds
          // the fresh material.
          final roster = await recovering!.fetchDeviceList(solo.userId);
          expect(roster['authorization'], isNull);
          final verified = DeviceListCache().adopt(
            userId: solo.userId,
            authorization: null,
            tofuIdentityKeyBase64: freshIdentity,
          );

          // Peer -> user: the fan-out addresses `liveDeviceIds`
          // (`messaging_provider.send.dart`).
          expect(
            verified.liveDeviceIds,
            [1],
            reason:
                'a peer must fan out to the device that EXISTS; for an '
                'un-enrolled account that is the synthesized device 1',
          );

          // User -> peer: `_originDeviceIsLive`
          // (`messaging_provider.decrypt.dart`) refuses an origin the list does
          // not contain, so the peer would withhold every message otherwise.
          expect(
            verified.isLiveDevice(1),
            isTrue,
            reason:
                'a peer must accept device 1 as a live origin, or it withholds '
                'as DECRYPT_REFUSED_REVOKED_ORIGIN forever',
          );

          // And the served bundle is the fresh one under device 1, so the
          // session a peer builds is one the recovering install can decrypt.
          final served = await recovering!.fetchBundleFor(
            solo.userId,
            deviceId: 1,
          );
          expect(served['identityPublicKey'], freshIdentity);
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    },
    skip: _enabled ? false : 'set --dart-define=RESET_PROBE=true',
  );
}
