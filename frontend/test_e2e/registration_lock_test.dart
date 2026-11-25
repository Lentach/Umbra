// Phase 0b registration lock + reset ceremony (multi-device spec §6.1/§6.2),
// wire-level against a real backend and a real Postgres.
//
// The mechanism under test is a REFUSAL, and a refusal is exactly what unit
// tests can assert while the deployed server happily accepts everything (wrong
// DTO field name, handler never registered, entity missing from the DataSource
// — the last one shipped in 0a and only the live harness caught it). So this
// drives the real socket wire and then reads the server's own view back to
// confirm nothing moved.
//
// Since amendment (lxxiii) clause 1 the lock is OPT-IN: enrolling a DAK (spec
// §3, `enrollDeviceAuthority`) is what arms it. So the two halves below are
// ordered by enrolment state — first the un-enrolled account, whose identity
// moves on credentials alone but LOUDLY; then the same account enrolled, where
// the identical upload is refused before any write. The §6.1 nonce single-spend
// is no longer observable on the wire (un-enrolled falls through to `unlocked`,
// enrolled refuses the signature path outright per (liv)); it stays pinned by
// the backend unit suite (`chat-key-exchange.service.spec.ts`).

import 'dart:convert';

import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  group('registration lock (Phase 0b §6.1)', () {
    final baseUrl = e2eBaseUrl();
    late E2eClient owner;
    E2eClient? replacement;
    // A third installation with its own fresh keys, tried against the account
    // once it is enrolled — the shape of a password-only takeover.
    E2eClient? intruder;
    // Third authenticated session, minted by the carve-out test's re-login —
    // same account, so it costs nothing against the register throttle.
    E2eClient? relogin;

    setUpAll(() async {
      await requireBackendUp(baseUrl);
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({});
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});

      owner = E2eClient('lockown', baseUrl);
      await owner.registerFresh();
      await owner.connectSocket();
      await owner.initializeAndUploadKeys();
    });

    tearDownAll(() {
      owner.dispose();
      replacement?.dispose();
      intruder?.dispose();
      relogin?.dispose();
    });

    test(
      'an UN-ENROLLED account replaces its identity on credentials alone, and '
      'every other session is told ((lxxiii) clause 1)',
      () async {
        final storedBefore = await owner.fetchBundleFor(owner.userId);
        final originalIdentity = storedBefore['identityPublicKey'] as String;

        // A second installation on the same account with brand-new keys: the
        // shape of both a legitimate reinstall AND a password-only takeover.
        // Un-enrolled, the server cannot tell them apart and must not strand
        // the reinstall — so it accepts, and the churn stays loud.
        // ignore: invalid_use_of_visible_for_testing_member
        FlutterSecureStorage.setMockInitialValues({});
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        replacement = E2eClient('lockrpl', baseUrl)..adoptAccountFrom(owner);
        await replacement!.connectSocket();
        final freshKeys = await replacement!.initializeKeys();
        final freshIdentity =
            (freshKeys['keyBundle'] as Map)['identityPublicKey'] as String;
        expect(
          freshIdentity,
          isNot(originalIdentity),
          reason: 'the test is meaningless unless the identity really differs',
        );

        owner.events.discard('ownIdentityReplaced');
        final answer = await replacement!.uploadKeyBundleRaw(freshKeys);
        expect(answer['success'], isTrue, reason: 'error=${answer['error']}');

        final storedAfter = await owner.fetchBundleFor(owner.userId);
        expect(storedAfter['identityPublicKey'], freshIdentity);

        // The §6.0 alarm is the only protection an un-enrolled account has
        // against a takeover, so the OTHER session must hear about it.
        await owner.events.next(
          'ownIdentityReplaced',
          reason: 'the owner session must be alarmed by the unlocked replacement',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'once ENROLLED, an unauthorized identity replacement is refused and '
      'changes nothing',
      () async {
        // Arm the lock: enroll a DAK under the identity the account now
        // publishes (the replacement's — it owns the stored bundle).
        final holder = IdentityKeyPair.fromSerialized(
          base64Decode(await replacement!.exportIdentityPair()),
        );
        final enrolled = await DeviceAuthorityEngine().enroll(
          userId: owner.userId,
          identity: holder,
          send: replacement!.enrollDeviceAuthority,
        );
        expect(enrolled.accepted, isTrue, reason: 'error=${enrolled.error}');

        final storedBefore = await owner.fetchBundleFor(owner.userId);
        final originalIdentity = storedBefore['identityPublicKey'] as String;

        // ignore: invalid_use_of_visible_for_testing_member
        FlutterSecureStorage.setMockInitialValues({});
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        intruder = E2eClient('lockint', baseUrl)..adoptAccountFrom(owner);
        await intruder!.connectSocket();
        final freshKeys = await intruder!.initializeKeys();
        final freshIdentity =
            (freshKeys['keyBundle'] as Map)['identityPublicKey'] as String;
        expect(
          freshIdentity,
          isNot(originalIdentity),
          reason: 'the test is meaningless unless the identity really differs',
        );

        owner.events.discard('ownIdentityReplaced');
        final answer = await intruder!.uploadKeyBundleRaw(freshKeys);

        expect(answer['success'], isFalse);
        expect(answer['error'], 'identity_locked');

        // The stored bundle must be identical afterwards: a refusal that still
        // wrote would silently redirect every future conversation.
        final storedAfter = await owner.fetchBundleFor(owner.userId);
        expect(storedAfter['identityPublicKey'], originalIdentity);

        // Nothing changed, so nothing may be announced — a false alarm here
        // would train users to ignore the real one.
        await owner.events.none(
          'ownIdentityReplaced',
          within: const Duration(seconds: 3),
          reason: 'a refused replacement must not alarm the account',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    // /auth/register is throttled to 10/hour per IP and the rest of the
    // harness already spends 9, so a fresh account per group would push the
    // suite over the ceiling. `replacement` is already a second authenticated
    // session of this account, which is what the broadcast assertions need.
    //
    // This drives the RECOVERY-KEY path because it exercises strictly more
    // machinery than a bare request (verifier + shortening + the same
    // notify/cancel/cooldown plumbing). The 6 h default and the Argon2id
    // parameters are pinned by the backend unit suite, which can assert them
    // without spending an account.
    test('a recovery key shortens the window, still notifies every session, '
        'and the ceremony cancels', () async {
      final user = owner;
      final secondSession = replacement!;
      const phrase =
          'legal winner thank year wave sausage worth useful legal winner '
          'thank yellow';

      expect(await user.setRecoveryKey(phrase), isTrue);

      // §12 (xlii): a phrase enrolled less than the full reset delay ago may
      // NOT shorten. Without that gate a password thief simply enrols a fresh
      // recovery key and skips the very 6 h wait the key is an exception to.
      //
      // §12 (xliv): and the refusal must SAY so. The phrase is right, so a
      // silent full-length wait reads as "rejected" and walks the owner into
      // retyping it until the five-attempt lockout. Proven here on the wire
      // because the flag has to survive real JSON, not just a mocked service.
      user.events.discard('identityResetPending');
      secondSession.events.discard('identityResetPending');
      final tooNew = await user.requestIdentityReset(recoveryPhrase: phrase);
      expect(tooNew['status'], 'pending');
      expect(tooNew['shortened'], isFalse);
      expect(
        tooNew['phraseTooNew'],
        isTrue,
        reason: 'a correct-but-young phrase must be reported as such',
      );
      final fullWait = DateTime.parse(
        tooNew['deadlineAt'] as String,
      ).difference(DateTime.now().toUtc());
      // The full delay is 6 h since (lxxxii) clause 1; the shortened one is
      // 1 h, so anything past 5 h is the full wait and not the shortcut.
      expect(
        fullWait.inMinutes,
        inInclusiveRange(5 * 60, 6 * 60),
        reason: 'the ceremony still starts, at the FULL delay',
      );

      // Clear that ceremony by DELETING the row rather than cancelling it.
      // Cancelling is what used to make this case untestable here: it arms the
      // 24 h cooldown the rest of this flow would then inherit. The phrase was
      // never spent (that is (xlii)'s own rule), so nothing else needs undoing.
      await e2eSql(
        'DELETE FROM identity_reset_requests '
        'WHERE "userId" = ${user.userId} AND status = \'pending\';',
      );

      // Now the LEGITIMATE case — an owner whose phrase long predates the
      // theft — by ageing the row in seconds rather than waiting three days.
      await e2eSql(
        'UPDATE recovery_keys SET "createdAt" = NOW() - INTERVAL \'4 days\' '
        'WHERE "userId" = ${user.userId};',
      );

      // A wrong phrase must authorize nothing at all — no ceremony, no
      // deadline, nothing for the caller to act on.
      final wrong = await user.requestIdentityReset(
        recoveryPhrase: 'wrong wrong wrong wrong wrong wrong',
      );
      expect(wrong['status'], 'invalid_phrase');
      expect(wrong['deadlineAt'], isNull);

      // Plan B7 tail (0.2.104): the plaintext field of clients up to 0.2.89
      // is refused like a wrong phrase even though the enrolled phrase IS
      // this one — and neither door spends an attempt or changes the key.
      final plaintext = await user.requestIdentityReset(
        legacyPlaintextPhrase: phrase,
      );
      expect(plaintext['status'], 'invalid_phrase');
      expect(plaintext['deadlineAt'], isNull);
      expect(
        await user.setRecoveryKeyLegacyPlaintext('some other twelve words'),
        isFalse,
        reason: 'a plaintext enrolment must store nothing',
      );

      secondSession.events.discard('identityResetPending');
      final started = await user.requestIdentityReset(recoveryPhrase: phrase);
      expect(started['status'], 'pending');
      expect(started['shortened'], isTrue);
      final deadline = DateTime.parse(started['deadlineAt'] as String);
      final minutes = deadline.difference(DateTime.now().toUtc()).inMinutes;
      expect(minutes, lessThanOrEqualTo(60));
      expect(
        minutes,
        greaterThan(50),
        reason: 'the phrase shortens the wait to an hour, never to zero',
      );

      // The OTHER session learns without asking — shortened still rings
      // every bell, which is the whole rule of §6.2.1.
      final broadcast =
          await secondSession.events.next(
                'identityResetPending',
                reason: 'the shortened path must still notify every session',
              )
              as Map;
      expect(broadcast['deadlineAt'], started['deadlineAt']);
      expect(broadcast['shortened'], isTrue);

      // Asking again must not restart the clock.
      final again = await user.requestIdentityReset();
      expect(again['status'], 'existing');
      expect(again['deadlineAt'], started['deadlineAt']);

      // Connect-time state, for a session that was offline when it started.
      final status = await secondSession.checkOwnKeyBundle();
      expect((status['identityReset'] as Map)['status'], 'pending');

      // Any session can stop it, with no key.
      secondSession.events.discard('identityResetCancelled');
      expect(await user.cancelIdentityReset(), isTrue);
      await secondSession.events.next(
        'identityResetCancelled',
        reason: 'every session must be told it was cancelled',
      );

      // Cancelling twice is a no-op, never a rollback of something else.
      expect(await user.cancelIdentityReset(), isFalse);

      // The cooldown now blocks a retry, and the spent phrase must not buy a
      // way around it either.
      final blocked = await user.requestIdentityReset();
      expect(blocked['status'], 'cooldown');
      final reuse = await user.requestIdentityReset(recoveryPhrase: phrase);
      expect(reuse['status'], anyOf('cooldown', 'invalid_phrase'));
      expect(reuse['shortened'], isFalse);

      final cleared = await secondSession.checkOwnKeyBundle();
      expect(cleared['identityReset'], isNull);
    }, timeout: const Timeout(Duration(minutes: 4)));

    // Inherits its precondition from the previous test: the cancel up there
    // just armed the 24 h cooldown. Spec §12 amendment 2026-08-19: a password
    // change VOIDS a cooldown armed before it — the refusal copy tells the
    // user whose ceremony an intruder cancelled to change their password, so
    // once they have, the attacker-authored cancel must not keep the owner
    // locked out. Runs LAST in this file because it retires the account's
    // original password.
    test(
      'a password change voids the cooldown a cancel armed before it',
      () async {
        const newPassword = 'E2eHarness2y';
        final user = owner;

        // The cooldown binds right up to the password change.
        final still = await user.requestIdentityReset();
        expect(still['status'], 'cooldown');

        // The production REST route: revokes every refresh token, stamps
        // passwordChangedAt, invalidates every earlier JWT.
        await user.api.resetPassword(
          user.accessToken,
          E2eClient.password,
          newPassword,
        );
        // JwtStrategy rejects iat <= passwordChangedAt at one-second
        // granularity; a login inside the same second would be refused.
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        // A real client logs back in; the old token is dead. New session,
        // same account — no register-throttle spend.
        final fresh = await user.api.login(
          '${user.username}#${user.tag}',
          newPassword,
        );
        relogin = E2eClient('lockrelog', user.baseUrl)
          ..adoptAccountFrom(user)
          ..accessToken = fresh['access_token'] as String;
        await relogin!.connectSocket();

        // The cooldown armed BEFORE the change is void: a request now starts
        // a real ceremony instead of bouncing.
        final started = await relogin!.requestIdentityReset();
        expect(started['status'], 'pending');
        expect(started['deadlineAt'], isNotNull);

        // Leave nothing pending behind the suite. The cancel arms a fresh
        // cooldown — armed AFTER the change, so it must bind again, which
        // also proves the carve-out is not "password change disables
        // cooldowns forever".
        expect(await relogin!.cancelIdentityReset(), isTrue);
        final rearmed = await relogin!.requestIdentityReset();
        expect(rearmed['status'], 'cooldown');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
