import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';

/// Phase 0b client contract (multi-device spec §6.1/§6.2).
///
/// The server is authoritative for the ceremony; this pins that the client
/// mirrors it faithfully, keeps the 0.1.10 UNKNOWN invariant intact, and never
/// resurrects an alarm the user already dismissed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EncryptionProvider provider;
  late List<({String event, dynamic data})> emitted;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    provider = EncryptionProvider(service: EncryptionService());
    emitted = [];
    provider.setEmitCallback((event, data) {
      emitted.add((event: event, data: data));
    });
  });

  group('reset ceremony state', () {
    test('a pending broadcast raises the countdown on every session', () {
      final deadline = DateTime.now().toUtc().add(const Duration(hours: 72));

      provider.onIdentityResetPending({
        'deadlineAt': deadline.toIso8601String(),
        'shortened': false,
        'occurredAt': DateTime.now().toUtc().toIso8601String(),
      });

      expect(provider.identityResetDeadline, isNotNull);
      expect(provider.identityResetShortened, isFalse);
    });

    test(
      'a shortened ceremony is still surfaced, just with a nearer deadline',
      () {
        final deadline = DateTime.now().toUtc().add(const Duration(hours: 1));

        provider.onIdentityResetPending({
          'deadlineAt': deadline.toIso8601String(),
          'shortened': true,
          'occurredAt': DateTime.now().toUtc().toIso8601String(),
        });

        expect(provider.identityResetDeadline, isNotNull);
        expect(
          provider.identityResetShortened,
          isTrue,
          reason: 'a recovery key shortens the wait; it never silences it',
        );
      },
    );

    test('the cancelled broadcast clears the countdown', () {
      provider.onIdentityResetPending({
        'deadlineAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 72))
            .toIso8601String(),
        'shortened': false,
      });

      provider.onIdentityResetCancelled({'occurredAt': 'now'});

      expect(provider.identityResetDeadline, isNull);
    });

    test('cancelling emits the server event', () {
      provider.cancelIdentityReset();

      expect(emitted.single.event, 'resetIdentityCancel');
    });

    test('requesting without a phrase sends no phrase field', () {
      provider.requestIdentityReset();

      expect(emitted.single.event, 'resetIdentityRequest');
      expect(
        (emitted.single.data as Map).containsKey('recoveryPhrase'),
        isFalse,
      );
    });

    test('requesting with a phrase forwards it once', () {
      provider.requestIdentityReset(recoveryPhrase: 'twelve words here');

      expect(emitted.single.data, {'recoveryPhrase': 'twelve words here'});
    });

    test('a malformed payload changes nothing', () {
      provider.onIdentityResetPending({'deadlineAt': 'not-a-date'});
      expect(provider.identityResetDeadline, isNull);

      provider.onIdentityResetPending('garbage');
      expect(provider.identityResetDeadline, isNull);
    });

    test('refusal statuses are reported without inventing a deadline', () {
      for (final status in ['cooldown', 'invalid_phrase', 'locked']) {
        provider.onIdentityResetStatus({'status': status});
        expect(provider.identityResetRequestStatus, status);
        expect(provider.identityResetDeadline, isNull);
      }
    });

    // Amendment (xlii), UX half.
    test('a too-young phrase still raises the countdown it started', () {
      final deadline = DateTime.now().toUtc().add(const Duration(hours: 72));
      provider.onIdentityResetStatus({
        'status': 'pending',
        'deadlineAt': deadline.toIso8601String(),
        'shortened': false,
        'phraseTooNew': true,
      });

      // The substitution is for the MESSAGE only. A ceremony is running, and
      // losing the deadline would take the cancel button with it — the one
      // affordance the whole 72 h delay exists to provide.
      expect(
        provider.identityResetRequestStatus,
        EncryptionProvider.identityResetPhraseTooNewStatus,
      );
      expect(provider.identityResetDeadline, isNotNull);
      expect(provider.identityResetShortened, isFalse);
    });

    test('a plain start is untouched, and so is an older server', () {
      final deadline = DateTime.now().toUtc().add(const Duration(hours: 72));

      provider.onIdentityResetStatus({
        'status': 'pending',
        'deadlineAt': deadline.toIso8601String(),
        'shortened': false,
        'phraseTooNew': false,
      });
      expect(provider.identityResetRequestStatus, 'pending');

      // A server that predates the flag omits it entirely; the client must
      // read that as an ordinary start, never as a phrase verdict.
      provider.onIdentityResetStatus({
        'status': 'pending',
        'deadlineAt': deadline.toIso8601String(),
        'shortened': false,
      });
      expect(provider.identityResetRequestStatus, 'pending');
    });

    test('the flag never rewrites an answer that is not a fresh start', () {
      // `existing` reports somebody else's ceremony; a phrase verdict there
      // would be about a phrase this request never got to present.
      provider.onIdentityResetStatus({
        'status': 'existing',
        'deadlineAt': DateTime.now().toUtc().toIso8601String(),
        'shortened': false,
        'phraseTooNew': true,
      });
      expect(provider.identityResetRequestStatus, 'existing');
    });
  });

  group('registration lock refusal', () {
    test('an identity_locked answer is terminal, not a retry signal', () {
      provider.onKeyBundleUploaded({
        'success': false,
        'error': 'identity_locked',
      });

      expect(provider.identityUploadLocked, isTrue);
    });

    // Ordering contract (2026-08-19): one-time pre-keys are material FOR an
    // identity, so they are emitted only after the server confirms that
    // identity is published. Emitting both back to back raced them, the keys
    // usually arrived first, and the server then had to judge key material
    // against an identity that was still the OLD one.
    test('stashed pre-keys are released only by a successful bundle ack', () {
      provider.stashOneTimePreKeysForTest([
        {'keyId': 0, 'publicKey': 'pk-0'},
      ], 'epoch-2-identity');

      expect(
        emitted.where((e) => e.event == 'uploadOneTimePreKeys'),
        isEmpty,
        reason: 'nothing may be uploaded before the identity is published',
      );

      provider.onKeyBundleUploaded({'success': true});

      final uploads = emitted
          .where((e) => e.event == 'uploadOneTimePreKeys')
          .toList();
      expect(uploads, hasLength(1));
      expect(
        (uploads.single.data as Map)['identityPublicKey'],
        'epoch-2-identity',
      );

      // Consumed exactly once — a later ack must not re-upload a spent batch.
      provider.onKeyBundleUploaded({'success': true});
      expect(
        emitted.where((e) => e.event == 'uploadOneTimePreKeys'),
        hasLength(1),
      );
    });

    test('a refused bundle DROPS its pre-keys instead of depositing them', () {
      provider.stashOneTimePreKeysForTest([
        {'keyId': 0, 'publicKey': 'pk-0'},
      ], 'unpublished-identity');

      provider.onKeyBundleUploaded({
        'success': false,
        'error': 'identity_locked',
      });

      expect(
        emitted.where((e) => e.event == 'uploadOneTimePreKeys'),
        isEmpty,
        reason:
            'the account does not publish this identity, so its keys would '
            'overwrite the pool the live identity is served from',
      );

      // And they are gone, not merely deferred: the next successful ack belongs
      // to a different (published) identity.
      provider.onKeyBundleUploaded({'success': true});
      expect(emitted.where((e) => e.event == 'uploadOneTimePreKeys'), isEmpty);
    });

    test('publishing a REPLACED identity refills its empty pool', () async {
      // The epoch purge empties the pool, and the reconnect re-upload that
      // spends a completed ceremony carries no keys — so without this the
      // recovered device publishes an identity nobody can open a session to
      // with a one-time pre-key until the first peer fetch says `preKeysLow`.
      final service = EncryptionService();
      await service.initialize(31, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      final recovered = EncryptionProvider(service: service);
      final sent = <({String event, dynamic data})>[];
      recovered.setEmitCallback((event, data) {
        sent.add((event: event, data: data));
      });

      recovered.onKeyBundleUploaded({'success': true, 'identityChanged': true});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final uploads = sent.where((e) => e.event == 'uploadOneTimePreKeys');
      expect(
        uploads,
        hasLength(1),
        reason: 'a freshly published identity must get its own pool',
      );
      expect((uploads.single.data as Map)['keys'], isNotEmpty);
    });

    test('a routine same-identity re-upload mints nothing', () async {
      final service = EncryptionService();
      await service.initialize(32, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      final steady = EncryptionProvider(service: service);
      final sent = <({String event, dynamic data})>[];
      steady.setEmitCallback((event, data) {
        sent.add((event: event, data: data));
      });

      steady.onKeyBundleUploaded({'success': true, 'identityChanged': false});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        sent.where((e) => e.event == 'uploadOneTimePreKeys'),
        isEmpty,
        reason: 'every connect re-uploads the bundle; that is not a new epoch',
      );
    });

    test('a successful upload clears the locked state', () {
      provider.onKeyBundleUploaded({
        'success': false,
        'error': 'identity_locked',
      });
      provider.onKeyBundleUploaded({'success': true});

      expect(provider.identityUploadLocked, isFalse);
    });

    test(
      'the upload that REPLACED the identity is marked as our own work',
      () async {
        final service = EncryptionService();
        final own = EncryptionProvider(service: service);

        // The designed recovery path: the immediate self-publish is refused, the
        // ceremony runs, and the upload that finally lands is a later routine
        // re-upload. The server says that one changed the identity, which is the
        // only signal tying the audit row to this device.
        own.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});
        own.onKeyBundleUploaded({'success': true, 'identityChanged': true});
        await Future<void>.delayed(Duration.zero);

        await service.recordOwnIdentityReplacedFromServer(
          DateTime.now().toUtc().toIso8601String(),
        );

        expect(
          service.ownIdentityReplacedAt,
          isNull,
          reason:
              'warning a user about the recovery they just performed trains '
              'them to dismiss the alarm that catches a real takeover',
        );
      },
    );

    test('a routine same-identity re-upload claims nothing', () async {
      final service = EncryptionService();
      final own = EncryptionProvider(service: service);

      // Stamping a watermark on every connect would keep a fresh one alive at
      // all times and mute a genuine replacement by someone else.
      own.onKeyBundleUploaded({'success': true, 'identityChanged': false});
      await Future<void>.delayed(Duration.zero);

      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
      );

      expect(service.ownIdentityReplacedAt, isNotNull);
    });
  });

  group('connect-time hydration', () {
    test('a pending ceremony is restored for a session that was offline', () {
      final deadline = DateTime.now().toUtc().add(const Duration(hours: 40));

      provider.onOwnKeyBundleStatus({
        'exists': true,
        'identityReset': {
          'status': 'pending',
          'deadlineAt': deadline.toIso8601String(),
        },
        'identityReplacedAt': null,
      });

      expect(provider.identityResetDeadline, isNotNull);
    });

    test('an explicit null clears a stale local countdown', () {
      provider.onIdentityResetPending({
        'deadlineAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 72))
            .toIso8601String(),
        'shortened': false,
      });

      provider.onOwnKeyBundleStatus({
        'exists': true,
        'identityReset': null,
        'identityReplacedAt': null,
      });

      expect(provider.identityResetDeadline, isNull);
    });

    test('reconnecting into a shortened ceremony keeps that label', () {
      // The countdown is right either way (the deadline is authoritative), but
      // calling a 1 h recovery-key ceremony "72 hours" is a lie the user would
      // act on.
      provider.onOwnKeyBundleStatus({
        'exists': true,
        'identityReset': {
          'status': 'pending',
          'deadlineAt': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'shortened': true,
        },
        'identityReplacedAt': null,
      });

      expect(provider.identityResetShortened, isTrue);
    });

    test('a completed ceremony is reported as spendable', () {
      provider.onOwnKeyBundleStatus({
        'exists': true,
        'identityReset': {
          'status': 'completed',
          'deadlineAt': DateTime.now().toUtc().toIso8601String(),
        },
        'identityReplacedAt': null,
      });

      expect(provider.identityResetCompleted, isTrue);
      expect(provider.identityResetDeadline, isNull);
    });

    test(
      'an older server answer (no 0b fields) keeps the UNKNOWN invariant',
      () async {
        // Absent fields must not be read as "nothing pending" for key generation
        // purposes: `exists` still drives that decision, unchanged from 0.1.10.
        provider.onOwnKeyBundleStatus({'exists': true});

        expect(provider.identityResetDeadline, isNull);
        expect(provider.identityResetCompleted, isFalse);
      },
    );

    test('a payload that omits the field leaves a live countdown alone', () {
      provider.onIdentityResetPending({
        'deadlineAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 72))
            .toIso8601String(),
        'shortened': false,
      });

      // Absent is not the same answer as explicit null: only the latter says
      // "nothing running". Wiping the banner on a partial payload would remove
      // the cancel button while the ceremony kept running.
      provider.onOwnKeyBundleStatus({'exists': true});

      expect(provider.identityResetDeadline, isNotNull);
    });

    test('every connect re-asks the server for the ceremony state', () {
      provider.refreshOwnAccountStatus();

      // Without this the deadline — which lives in memory only — is lost on
      // restart, and the push that says "open the app and cancel" leads to a
      // screen with nothing to cancel.
      expect(emitted.map((e) => e.event), contains('checkOwnKeyBundle'));
    });
  });

  group('own-replacement hydration respects dismissal', () {
    test('a replacement reported at connect raises the banner', () async {
      final service = EncryptionService();
      await service.recordOwnIdentityReplacedFromServer(
        '2026-08-18T00:00:00.000Z',
      );

      expect(service.ownIdentityReplacedAt, '2026-08-18T00:00:00.000Z');
    });

    test('the SAME replacement never comes back after dismissal', () async {
      final service = EncryptionService();
      await service.recordOwnIdentityReplaced('2026-08-18T00:00:00.000Z');
      await service.dismissOwnIdentityReplaced();

      // Every reconnect re-reports the audit row; without a watermark this
      // would re-raise a banner the user already handled, forever.
      await service.recordOwnIdentityReplacedFromServer(
        '2026-08-18T00:00:00.000Z',
      );

      expect(service.ownIdentityReplacedAt, isNull);
    });

    test(
      'a NEWER replacement still alarms after an earlier dismissal',
      () async {
        final service = EncryptionService();
        await service.recordOwnIdentityReplaced('2026-08-18T00:00:00.000Z');
        await service.dismissOwnIdentityReplaced();

        await service.recordOwnIdentityReplacedFromServer(
          '2026-08-19T00:00:00.000Z',
        );

        expect(service.ownIdentityReplacedAt, '2026-08-19T00:00:00.000Z');
      },
    );

    test(
      'a replacement THIS device published is not replayed back at it',
      () async {
        // The recovery case: a fresh install completes a ceremony, publishes new
        // keys, and reconnects. The server dutifully reports the audit row it
        // just wrote — but warning the user about the recovery they themselves
        // performed, on an install with no dismissal history, is a false alarm.
        final service = EncryptionService();
        await service.markOwnIdentityPublished();

        await service.recordOwnIdentityReplacedFromServer(
          DateTime.now().toUtc().toIso8601String(),
        );

        expect(service.ownIdentityReplacedAt, isNull);
      },
    );

    // Amendment (li) clause 1. The value the server sends becomes the persisted
    // DISMISSAL WATERMARK the instant the user taps dismiss, and everything at
    // or below it is suppressed forever.
    test(
      'an absurd server timestamp cannot become a permanent off switch',
      () async {
        // ONE service, shared with the provider: the watermark is written by
        // the dismissal and read by the hydration, so asserting against a
        // SEPARATE instance would pass with the bug fully intact.
        final service = EncryptionService();
        final owner = EncryptionProvider(service: service);
        addTearDown(owner.dispose);

        // The alarm still raises — the EVENT is the alarm, the timestamp is
        // only metadata — but the poisoned instant must not be what is stored.
        owner.onOwnIdentityReplaced({'occurredAt': '9999-01-01T00:00:00Z'});
        expect(service.ownIdentityReplacedAt, isNotNull);
        expect(
          service.ownIdentityReplacedAt,
          isNot(startsWith('9999')),
          reason: 'the stored instant must be ours, not the forged one',
        );

        await owner.dismissOwnIdentityReplaced();

        // A genuine replacement, strictly newer than our own fallback stamp.
        await service.recordOwnIdentityReplacedFromServer(
          DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 1))
              .toIso8601String(),
        );
        expect(
          service.ownIdentityReplacedAt,
          isNotNull,
          reason: 'a forged far-future watermark must not silence §6.0',
        );
      },
    );

    test('an unparseable instant is ignored by the hydration path', () async {
      final service = EncryptionService();

      await service.recordOwnIdentityReplacedFromServer('not-a-date');

      expect(
        service.ownIdentityReplacedAt,
        isNull,
        reason: 'an unorderable value cannot be ordered against the watermark',
      );
    });

    test('the self-publish suppression is ONE report, not a time window', () async {
      final service = EncryptionService();
      await service.markOwnIdentityPublished();

      // Our own republish, reported back: suppressed.
      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
      );
      expect(service.ownIdentityReplacedAt, isNull);

      // A SECOND replacement is somebody else's, and must alarm. Under the old
      // device-clock watermark this stayed silent for ten minutes — and for the
      // whole skew on a device whose clock ran fast.
      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().add(const Duration(seconds: 1)).toIso8601String(),
      );
      expect(
        service.ownIdentityReplacedAt,
        isNotNull,
        reason: 'only the first report is ours; the next one is an alarm',
      );
    });

    // Amendment (lxxx) clause 5. A wiped-then-restored install has no
    // dismissal watermark left, so the server's audit row — which the restore
    // did NOT write and which may be the install's own earlier history —
    // greeted the user with the red own-account banner in the one flow whose
    // promise is "nothing happened to your account". Observed live on 0.2.23.
    test('a row ending at our OWN published identity is not an alarm', () async {
      final service = EncryptionService();
      await service.initialize(
        91,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;

      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
        replacedTo: own,
      );

      expect(
        service.ownIdentityReplacedAt,
        isNull,
        reason: 'the change ended at the key this device holds — nothing '
            'is pending, and no flag was spent to reach that conclusion',
      );
    });

    test('a row ending at a FOREIGN identity still alarms', () async {
      final service = EncryptionService();
      await service.initialize(
        92,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );

      // Same shape, different key: exactly what a §6.1 rotation or a spent
      // §6.2 ceremony by somebody else looks like.
      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
        replacedTo: 'BfOreignKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );

      expect(
        service.ownIdentityReplacedAt,
        isNotNull,
        reason: 'suppression must be content-based, never blanket',
      );
    });

    // Amendment (lxxxi) clause 2 — the shape the live proof of clause 5 hit.
    // The FIRST hydration reaches a wiped install BEFORE it holds any identity
    // (the connect that precedes the gate), so the row is reported; the
    // restore then brings back exactly the key the row ends at, and the second
    // hydration must RETRACT that alarm, not merely skip the row.
    test('an alarm raised with no identity is retracted when the same row '
        'turns out to end at our own key', () async {
      final at = DateTime.now().toUtc().toIso8601String();
      final service = EncryptionService();

      // Hydration 1: no keys loaded yet — reported, as it must be.
      await service.recordOwnIdentityReplacedFromServer(
        at,
        replacedTo: 'BrEstoredKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      expect(service.ownIdentityReplacedAt, isNotNull);

      // The restore adopts the identity; take the key it now publishes as
      // the row's `to` (the row is served unchanged by the server).
      await service.initialize(
        94,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      await service.recordOwnIdentityReplaced(at); // still showing

      // Hydration 2, same row, identity loaded.
      await service.recordOwnIdentityReplacedFromServer(at, replacedTo: own);

      expect(
        service.ownIdentityReplacedAt,
        isNull,
        reason: 'the row ended at the key this device now holds; the alarm '
            'it raised while the install was empty is moot',
      );
    });

    test('a showing alarm for a DIFFERENT instant is not retracted by an '
        'own-key row', () async {
      final service = EncryptionService();
      await service.initialize(
        95,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      final earlier = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String();
      await service.recordOwnIdentityReplaced(earlier);

      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
        replacedTo: own,
      );

      expect(
        service.ownIdentityReplacedAt,
        earlier,
        reason: 'only the alarm THIS row raised is retracted',
      );
    });

    test('an absent replacedTo (older server) reports exactly as before',
        () async {
      final service = EncryptionService();
      await service.initialize(
        93,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );

      await service.recordOwnIdentityReplacedFromServer(
        DateTime.now().toUtc().toIso8601String(),
      );

      expect(service.ownIdentityReplacedAt, isNotNull);
    });

    // Amendment (lxxxvii). The upload ack arms the (li) one-shot for our own
    // publish, but the (lxxx) own-key branch recognises that very report by
    // CONTENT and returned without spending it — so the flag stayed armed and
    // silently ate the next FOREIGN replacement, which an offline device only
    // ever learns at reconnect. Every re-mint and every §6.2 ceremony armed it.
    test('a takeover reported after our own re-mint still alarms', () async {
      final service = EncryptionService();
      await service.initialize(
        97,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      final ours = DateTime.now().toUtc().subtract(const Duration(hours: 1));

      await service.markOwnIdentityPublished();
      await service.recordOwnIdentityReplacedFromServer(
        ours.toIso8601String(),
        replacedTo: own,
      );
      await service.recordOwnIdentityReplacedFromServer(
        ours.add(const Duration(minutes: 30)).toIso8601String(),
        replacedTo: 'BfOreignKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );

      expect(
        service.ownIdentityReplacedAt,
        isNotNull,
        reason: 'the one-shot belonged to the report that ended at our key',
      );
    });
  });

  // Amendment (lxxxvi): the audit row that ENDS at our own key is also the
  // edge of what this install can ever decrypt; MessagingProvider hides the
  // unreadable rows before it behind the (lxxxi) divider.
  group("the instant this identity became the account's", () {
    test('is taken from a row ending at our own key, never a foreign one, '
        'and the next launch still knows it', () async {
      Future<EncryptionService> launch() async {
        final service = EncryptionService();
        await service.initialize(
          96,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );
        return service;
      }

      final at = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 5))
          .toIso8601String();
      final service = await launch();
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;

      await service.recordOwnIdentityReplacedFromServer(
        at,
        replacedTo: 'BfOreignKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
      expect(
        service.ownIdentitySince,
        isNull,
        reason: "a change that ended at somebody else's key says nothing "
            'about what THIS key can read',
      );

      await service.recordOwnIdentityReplacedFromServer(at, replacedTo: own);
      expect(service.ownIdentitySince, DateTime.parse(at));

      // A cold start renders history before any connect re-reports the row.
      final relaunched = await launch();
      expect(relaunched.ownIdentitySince, DateTime.parse(at));
    });

    test('the upload that replaced the identity asks for its audit row at '
        'once', () {
      // The minting session is the one the user reads first; the connect-time
      // status it got was answered BEFORE this upload wrote the row.
      provider.onKeyBundleUploaded({'success': true, 'identityChanged': true});

      expect(emitted.map((e) => e.event), contains('checkOwnKeyBundle'));
    });
  });

  // A ceremony leaving 'pending' has NO server event: `completeDueResets`
  // deliberately fans out nothing, and `identityResetCancelled` covers only
  // cancels. The deadline was fetched once at `socketReady`, so a session that
  // stayed connected across the transition kept counting down to a ceremony
  // that was already over — observed on a real device, cured only by a reload.
  group(
    'a live session re-reads the ceremony instead of trusting its cache',
    () {
      test('while a ceremony is held, the state is re-asked of the server', () {
        fakeAsync((async) {
          provider.onIdentityResetPending({
            'deadlineAt': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 72))
                .toIso8601String(),
            'shortened': false,
          });
          emitted.clear();

          async.elapse(const Duration(minutes: 3));

          expect(
            emitted.where((e) => e.event == 'checkOwnKeyBundle').length,
            3,
            reason: 'one re-read per backend sweep tick while a banner is up',
          );
        });
      });

      test(
        'the countdown clears once the server says the ceremony is gone',
        () {
          fakeAsync((async) {
            provider.onIdentityResetPending({
              'deadlineAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 72))
                  .toIso8601String(),
              'shortened': false,
            });
            async.elapse(const Duration(minutes: 1));
            expect(provider.identityResetDeadline, isNotNull);

            // The answer that re-read earns: the row is no longer pending.
            provider.onOwnKeyBundleStatus({
              'exists': true,
              'identityReset': null,
            });

            expect(
              provider.identityResetDeadline,
              isNull,
              reason: 'no reload should be needed to stop counting down',
            );

            emitted.clear();
            async.elapse(const Duration(minutes: 5));
            expect(
              emitted.where((e) => e.event == 'checkOwnKeyBundle'),
              isEmpty,
              reason:
                  'the re-read must stop with the ceremony, not run forever',
            );
          });
        },
      );

      test('a session with no ceremony never polls at all', () {
        fakeAsync((async) {
          emitted.clear();
          async.elapse(const Duration(minutes: 10));
          expect(
            emitted,
            isEmpty,
            reason: 'the ordinary session must pay nothing for this',
          );
        });
      });

      // Found by review: this provider is a process singleton, so ceremony
      // state left standing at logout renders over the NEXT account's session.
      test('logout takes the countdown and the re-read with it', () {
        fakeAsync((async) {
          provider.onIdentityResetPending({
            'deadlineAt': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 72))
                .toIso8601String(),
            'shortened': true,
          });
          expect(provider.identityResetDeadline, isNotNull);

          provider.clearAll();

          expect(
            provider.identityResetDeadline,
            isNull,
            reason: "user A's countdown must not render over user B's session",
          );
          expect(provider.identityResetShortened, isFalse);
          expect(provider.identityResetCompleted, isFalse);

          emitted.clear();
          async.elapse(const Duration(minutes: 5));
          expect(
            emitted.where((e) => e.event == 'checkOwnKeyBundle'),
            isEmpty,
            reason: 'a logged-out session must stop asking about a ceremony',
          );
        });
      });

      // A completed grant is unspent until an upload consumes it, and that
      // transition has no event either — so it keeps re-reading, then stops.
      test('an unspent completed grant re-reads, and stops once consumed', () {
        fakeAsync((async) {
          provider.onOwnKeyBundleStatus({
            'exists': true,
            'identityReset': {'status': 'completed'},
          });
          expect(provider.identityResetCompleted, isTrue);

          emitted.clear();
          async.elapse(const Duration(minutes: 2));
          expect(
            emitted.where((e) => e.event == 'checkOwnKeyBundle').length,
            2,
            reason: 'an unspent grant is still live state worth re-reading',
          );

          provider.onOwnKeyBundleStatus({
            'exists': true,
            'identityReset': null,
          });
          emitted.clear();
          async.elapse(const Duration(minutes: 5));
          expect(
            emitted.where((e) => e.event == 'checkOwnKeyBundle'),
            isEmpty,
            reason: 'consumed grant ends the re-read',
          );
        });
      });
    },
  );
}
