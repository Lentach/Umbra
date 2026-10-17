import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionProvider — decrypted content delegation', () {
    late EncryptionProvider provider;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      provider = EncryptionProvider();
      // The identity guard needs an explicit server "no bundle" before it
      // will generate keys; every other socket event is silently ignored.
      provider.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await provider.initializeE2E(42);
    });

    test('saveDecryptedContent + getDecryptedContent round-trip', () async {
      await provider.saveDecryptedContent(1001, {'content': 'Hello world'});
      final result = await provider.getDecryptedContent(1001);
      expect(result, isNotNull);
      expect(result!['content'], 'Hello world');
    });

    test('getDecryptedContent returns null for unknown id', () async {
      final result = await provider.getDecryptedContent(9999);
      expect(result, isNull);
    });

    test('saveDecryptedContent before initializeE2E does not throw', () async {
      // Provider without initializeE2E — _userId is null.
      // Documented contract: silent no-op, never throws.
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final uninitializedProvider = EncryptionProvider();
      await expectLater(
        uninitializedProvider.saveDecryptedContent(1, {'content': 'test'}),
        completes,
      );
      final result = await uninitializedProvider.getDecryptedContent(1);
      expect(result, isNull);
    });

    test('saveDecryptedContent persists all envelope fields', () async {
      await provider.saveDecryptedContent(1002, {
        'content': 'Check this',
        'messageType': 'TEXT',
        'linkPreviewUrl': 'https://example.com',
        'linkPreviewTitle': 'Example',
      });
      final result = await provider.getDecryptedContent(1002);
      expect(result!['content'], 'Check this');
      expect(result['messageType'], 'TEXT');
      expect(result['linkPreviewUrl'], 'https://example.com');
      expect(result['linkPreviewTitle'], 'Example');
    });

    test(
      'clearLocalDecryptedContentCache removes persisted plaintext cache only',
      () async {
        await provider.saveDecryptedContent(1003, {
          'content': 'Cached message',
        });

        final result = await provider.clearLocalDecryptedContentCache();

        expect(result.removed, 1);
        expect(result.isComplete, isTrue);
        expect(await provider.getDecryptedContent(1003), isNull);
        expect(provider.isE2EReady, isTrue);
        expect(await provider.getIdentityFingerprint(), isNotNull);
      },
    );

    test(
      'purgeLocalPlaintext forgets the ledger entries of confirmed purges',
      () async {
        // Fail-before: a deliberately purged id kept its ledger entry, so the
        // next time the server served that row the gate read the absence as
        // UNEXPECTED loss — LEDGER_RECORD_LOST plus a permanent retire, for an
        // ordered deletion (the 2026-08-02 dump's exact ambiguity).
        await provider.saveDecryptedContent(1101, {'content': 'doomed'});
        await provider.flushDecryptedLedger();
        expect(provider.wasDecryptedBefore(1101), isFalse,
            reason: 'in-memory ledger fills via loadDecryptedLedger');
        await provider.loadDecryptedLedger();
        expect(provider.wasDecryptedBefore(1101), isTrue);

        final result = await provider.purgeLocalPlaintext([1101]);

        // NOT asserting isComplete: on the test VM path_provider is absent,
        // so AudioCacheStore.remove fails the directory resolve and reports
        // every id — by design ("cannot say whether audio is on disk").
        // Ledger hygiene deliberately keys on the TEXT-record removal alone,
        // which did confirm: the record must be gone and the entry dropped.
        expect(await provider.getDecryptedContent(1101), isNull);
        expect(result.removed, 1);
        expect(provider.wasDecryptedBefore(1101), isFalse,
            reason: 'RAM ledger must drop the id in the same session');
        final sets = await provider.diagStorageSets();
        expect(sets.ledger, isNot(contains(1101)),
            reason: 'persisted ledger must drop the id');
      },
    );

    test(
      'the wipe mirrors wiped ids into the in-memory retired set',
      () async {
        // Fail-before: markRetired persists to DISK only. In the SAME session
        // isRetired() read the stale RAM set, missed every wiped id, and the
        // ledger gate reported the user's own wipe as LEDGER_RECORD_LOST
        // (five false alarms in the 2026-08-02 field dump).
        await provider.saveDecryptedContent(1102, {'content': 'wiped'});
        await provider.flushDecryptedLedger();
        await provider.loadDecryptedLedger();

        final result = await provider.clearLocalDecryptedContentCache();

        expect(result.wipedIds, contains(1102));
        expect(provider.isRetired(1102), isTrue,
            reason: 'same-session retired check must already cover the wipe');
        expect(provider.wasDecryptedBefore(1102), isFalse);
      },
    );
  });

  group('EncryptionProvider — race and idempotency guards', () {
    late EncryptionProvider provider;
    late List<Map<String, dynamic>> emitted;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      emitted = <Map<String, dynamic>>[];
      provider = EncryptionProvider();
      provider.setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await provider.initializeE2E(7);
    });

    test(
      'duplicate preKeyBundleResponse is ignored after first completion',
      () async {
        final future = provider.ensureSession(99);
        await Future<void>.delayed(Duration.zero);
        provider.onPreKeyBundleResponse({'userId': 99, 'bundle': null});
        provider.onPreKeyBundleResponse({'userId': 99, 'bundle': null});
        await expectLater(future, throwsStateError);
        expect(provider.pendingPreKeyFetches.containsKey((99, 1)), isFalse);
        final fetchEvents = emitted.where(
          (e) => e['event'] == 'fetchPreKeyBundle',
        );
        expect(fetchEvents.length, 1);
      },
    );

    test('a session build that JOINS an unanswered bundle fetch fails with it '
        '— never waits forever', () {
      fakeAsync((fake) {
        Object? ownerOutcome;
        Object? joinerOutcome;
        unawaited(provider.ensureSession(99).then<void>(
          (_) => ownerOutcome = 'built',
          onError: (Object e) => ownerOutcome = e,
        ));
        fake.flushMicrotasks();
        unawaited(provider.ensureSession(99).then<void>(
          (_) => joinerOutcome = 'built',
          onError: (Object e) => joinerOutcome = e,
        ));
        fake.flushMicrotasks();
        expect(
          emitted.where((e) => e['event'] == 'fetchPreKeyBundle').length,
          1,
          reason: 'the second build joins the first fetch',
        );

        fake.elapse(const Duration(seconds: 11));
        fake.flushMicrotasks();
        expect(ownerOutcome, isA<TimeoutException>());
        expect(
          joinerOutcome,
          isA<TimeoutException>(),
          reason: 'the joiner must fail with the shared fetch, not hang',
        );
      });
    });

    test('preKeysLow handler is reentrant-safe', () async {
      final initialUploads = emitted
          .where((e) => e['event'] == 'uploadOneTimePreKeys')
          .length;
      provider.onPreKeysLow({'remaining': 1});
      provider.onPreKeysLow({'remaining': 1});
      await Future<void>.delayed(Duration.zero);
      final uploads = emitted.where(
        (e) => e['event'] == 'uploadOneTimePreKeys',
      );
      expect(uploads.length - initialUploads, 1);
    });
    test(
      'null identity defers without upload and later initialized identity uploads tagged OTPs',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final deferredEmits = <Map<String, dynamic>>[];
        final deferred = EncryptionProvider()
          ..setEmitCallback((event, data) {
            deferredEmits.add({'event': event, 'data': data});
          });
        deferred.onPreKeysLow({'remaining': 0});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          deferredEmits.where((e) => e['event'] == 'uploadOneTimePreKeys'),
          isEmpty,
        );
        expect(
          E2ePersistentDiag.entries.any(
            (e) => e.contains('OTP_REPLENISH_DEFERRED'),
          ),
          isTrue,
        );

        final taggedEmits = <Map<String, dynamic>>[];
        final ready = EncryptionProvider();
        ready.setEmitCallback((event, data) {
          taggedEmits.add({'event': event, 'data': data});
          if (event == 'checkOwnKeyBundle') {
            ready.onOwnKeyBundleStatus({'exists': false});
          }
        });
        await ready.initializeE2E(8);
        ready.onPreKeysLow({'remaining': 0});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final uploads = taggedEmits
            .where((e) => e['event'] == 'uploadOneTimePreKeys')
            .map((e) => e['data'] as Map<String, dynamic>);
      expect(uploads, isNotEmpty);
      expect(uploads.last['identityPublicKey'], isA<String>());
      expect((uploads.last['identityPublicKey'] as String), isNotEmpty);
      },
    );
  });
}
