import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';

/// The decrypt ledger answers "did this id's plaintext ever exist?".
///
/// Without it a record lost to quota, eviction or a purge bug is
/// indistinguishable from a message that was never decrypted, so the app
/// re-runs Signal decrypt against a consumed ratchet key, hits
/// DuplicateMessage, and burns the row into a permanent "[Decryption failed]".
///
/// Because the ledger is allowed to VETO decryption, every one of its failure
/// modes has to fall open. A false "yes, decrypted before" is not a cosmetic
/// bug: it permanently refuses the one decrypt that would still have worked.
/// Most of what follows pins those directions rather than the happy path.
class _RefusingStore extends SharedPreferencesStorePlatform {
  _RefusingStore() : _inner = InMemorySharedPreferencesStore.empty();

  final InMemorySharedPreferencesStore _inner;

  /// Keys matching this prefix fail their commit, the way a quota-exhausted
  /// backend does — `setString` reports false rather than throwing.
  String? refusePrefix;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final refuse = refusePrefix;
    if (refuse != null && key.contains(refuse)) return Future.value(false);
    return _inner.setValue(valueType, key, value);
  }

  @override
  Future<bool> clear() => _inner.clear();

  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();

  @override
  Future<bool> remove(String key) => _inner.remove(key);

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      _inner.clearWithPrefix(prefix);

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _inner.clearWithParameters(parameters);

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      _inner.getAllWithPrefix(prefix);

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => _inner.getAllWithParameters(parameters);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RefusingStore store;
  late EncryptionService service;

  setUp(() async {
    store = _RefusingStore();
    // `flutter test` runs on the Dart VM with kIsWeb false, where the prefs
    // backend keeps reads on its cache. Force the web branch so these exercise
    // the same path production does.
    PrefsContentKv.debugForceAuthoritative = true;
    addTearDown(() => PrefsContentKv.debugForceAuthoritative = false);
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    FlutterSecureStorage.setMockInitialValues({});
    service = EncryptionService();
    await service.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
  });

  test('a persisted decrypt is recorded once flushed', () async {
    await service.saveDecryptedContent(18597, {'content': 'hello'});
    await service.flushDecryptedLedger();

    expect(await service.decryptedLedgerIds(), contains(18597));
  });

  test('the ledger survives a fresh service on the same store', () async {
    await service.saveDecryptedContent(18598, {'content': 'persisted'});
    await service.flushDecryptedLedger();

    final reopened = EncryptionService();
    await reopened.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));

    expect(await reopened.decryptedLedgerIds(), contains(18598));
  });

  test('a failed plaintext commit is NEVER recorded', () async {
    // The dangerous direction. Recording an id whose plaintext never landed
    // would make a later pass refuse the decrypt that still would have worked,
    // converting a recoverable write failure into permanent loss.
    store.refusePrefix = '_decrypted_';

    await service.saveDecryptedContent(18599, {'content': 'never landed'});
    await service.flushDecryptedLedger();

    expect(await service.decryptedLedgerIds(), isNot(contains(18599)));
  });

  test('the failure label is NEVER recorded', () async {
    // The terminal-failure write goes through the same persist path. Recording
    // it would claim a row was decrypted when it never was.
    await service.saveDecryptedContent(18600, {
      'content': '[Decryption failed]',
    });
    await service.flushDecryptedLedger();

    expect(await service.decryptedLedgerIds(), isNot(contains(18600)));
  });

  test('an edit forgets the id so new ciphertext can be decrypted', () async {
    // An edit puts NEW ciphertext under the SAME id. Leaving the entry would
    // veto a payload that has genuinely never been decrypted, and the edit
    // would render "no longer stored" forever.
    await service.saveDecryptedContent(18601, {'content': 'before edit'});
    await service.flushDecryptedLedger();
    expect(await service.decryptedLedgerIds(), contains(18601));

    await service.forgetDecrypted(18601);

    expect(await service.decryptedLedgerIds(), isNot(contains(18601)));
  });

  test('recordExists distinguishes present from definitely absent', () async {
    await service.saveDecryptedContent(18602, {'content': 'here'});

    expect(await service.recordExists(18602), isTrue);
    expect(await service.recordExists(18603), isFalse);
  });

  test('recordExists reports unknown rather than absent without a user', () async {
    // `null` must never be read as "gone": the caller retires on absence, and
    // retiring is permanent. An unbound user is not evidence of loss.
    final unbound = EncryptionService();

    expect(await unbound.recordExists(18604), isNull);
  });

  test('a buffered id is visible before it is flushed', () async {
    // Otherwise a second decrypt inside the same pass would not see the first
    // one and could re-enter the ratchet for a row already handled.
    await service.saveDecryptedContent(18605, {'content': 'buffered'});

    expect(await service.decryptedLedgerIds(), contains(18605));
  });

  test('the PERSISTED ledger is bounded and keeps the newest ids', () async {
    // Ids ascend with age, so eviction drops the oldest. A dropped entry only
    // restores the old behaviour (attempt the decrypt) — never a false
    // "unavailable" — which is why a bound is acceptable at all.
    //
    // Asserted on a reopened service: the live one also reports ids still
    // buffered in memory (pinned by the "buffered id is visible" test above),
    // and the cap governs what reaches storage, not that in-flight view.
    const cap = 3000;
    final ids = [for (var i = 0; i < cap + 50; i++) 1000 + i];
    for (final id in ids) {
      await service.saveDecryptedContent(id, {'content': 'm$id'});
    }
    await service.flushDecryptedLedger();

    final reopened = EncryptionService();
    await reopened.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
    final ledger = await reopened.decryptedLedgerIds();

    expect(ledger.length, lessThanOrEqualTo(cap));
    expect(ledger, contains(ids.last));
    expect(ledger, isNot(contains(ids.first)));
  });

  group('backfill for accounts that predate the ledger', () {
    test('seeds from records already on disk', () async {
      // Without this the ledger only ever covers messages decrypted AFTER it
      // ships, so existing conversations stay exactly as fragile as before —
      // which is nearly all of the value, missing.
      await service.saveDecryptedContent(18700, {'content': 'old message'});
      await service.saveDecryptedContent(18701, {'content': 'older message'});

      // A fresh service on the same store: no ledger key has ever been written.
      final upgraded = EncryptionService();
      await upgraded.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      await upgraded.backfillLedgerFromStore();

      expect(
        await upgraded.decryptedLedgerIds(),
        containsAll(<int>[18700, 18701]),
      );
    });

    test('never seeds an id that recordExists cannot confirm', () async {
      // storedMessageIds() unions the raw `_decrypt_raw_v1_` cache, which
      // recordExists cannot see. Seeding from that union would let an id whose
      // plaintext commit FAILED — but whose raw entry landed — probe as
      // definitely-absent and be permanently retired, destroying access to a
      // row the raw cache could still serve. The seed must stay a SUBSET of
      // what recordExists can confirm.
      store.refusePrefix = '_decrypted_';
      await service.saveDecryptedContent(18702, {'content': 'plaintext lost'});
      store.refusePrefix = null;

      final upgraded = EncryptionService();
      await upgraded.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      await upgraded.backfillLedgerFromStore();

      final ledger = await upgraded.decryptedLedgerIds();
      for (final id in ledger) {
        expect(
          await upgraded.recordExists(id),
          isTrue,
          reason: 'seeded id $id cannot be confirmed by recordExists, so the '
              'gate would retire it permanently',
        );
      }
      expect(ledger, isNot(contains(18702)));
    });

    test('an empty result is retried, never marked done', () async {
      // The backfill runs once per account and that single run is the only one
      // that matters. If the authoritative read came back empty on that
      // attempt — a transient hiccup — persisting the marker anyway would
      // disable the ledger for that account FOREVER, silently, while the docs
      // claim it is covered. An empty seed must therefore leave no marker.
      final fresh = EncryptionService();
      await fresh.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      await fresh.backfillLedgerFromStore(); // store is empty: no marker

      // Records appear afterwards (or the earlier read was simply wrong).
      await fresh.saveDecryptedContent(18800, {'content': 'appeared later'});

      final next = EncryptionService();
      await next.initialize(37, checkServerIdentity: () async => const ServerIdentityGuard(exists: false));
      await next.backfillLedgerFromStore();

      expect(
        await next.decryptedLedgerIds(),
        contains(18800),
        reason: 'an empty first attempt must not permanently disable the '
            'backfill for this account',
      );
    });

    test('runs once, then leaves the ledger alone', () async {
      // The marker stops a whole-store re-enumeration at every launch, and
      // stops a later backfill resurrecting an id that an edit forgot.
      await service.saveDecryptedContent(18703, {'content': 'seeded'});
      await service.flushDecryptedLedger();
      await service.forgetDecrypted(18703);

      await service.backfillLedgerFromStore();

      expect(await service.decryptedLedgerIds(), isNot(contains(18703)));
    });
  });

  group('deliberate destruction is ledger-hygienic (2026-08-02 field bug)', () {
    test('forgetDecryptedMany drops every id in one call', () async {
      await service.saveDecryptedContent(18900, {'content': 'a'});
      await service.saveDecryptedContent(18901, {'content': 'b'});
      await service.saveDecryptedContent(18902, {'content': 'c'});
      await service.flushDecryptedLedger();

      await service.forgetDecryptedMany([18900, 18902]);

      final ledger = await service.decryptedLedgerIds();
      expect(ledger, isNot(contains(18900)));
      expect(ledger, contains(18901));
      expect(ledger, isNot(contains(18902)));
    });

    test('the full wipe reports wiped ids and forgets their ledger entries',
        () async {
      // Fail-before (memory-sync half lives in the provider test): the wipe
      // used to leave ledger entries for records it destroyed, so a row the
      // server still served re-read as UNEXPECTED loss — LEDGER_RECORD_LOST
      // for a deletion the user ordered.
      await service.saveDecryptedContent(18910, {'content': 'wiped'});
      await service.flushDecryptedLedger();

      final result = await service.clearDecryptedContentCache();

      expect(result.wipedIds, contains(18910));
      expect(await service.decryptedLedgerIds(), isNot(contains(18910)));
      expect(await service.retiredMessageIds(), contains(18910));
    });
  });

  group('purge-backlog amnesty (pre-fix obligation replay)', () {
    test('drops obligations for live UNSTAMPED records, keeps the rest',
        () async {
      // Builds <= 0.1.3 could durably enqueue a fallback-expired UNSTAMPED id
      // whose purge then failed; replaying it after the sweep fix would
      // destroy a record the new rule refuses to condemn. Fail-before: without
      // the amnesty, the drained backlog still names 19301.
      await service.saveDecryptedContent(19301, {'content': 'unstamped'});
      await service.saveDecryptedContent(
        19302,
        {'content': 'stamped'},
        expiresAt: DateTime.utc(2026, 8, 1),
      );
      // 19303 has no record — a completed purge whose resolve was lost.
      await service.enqueuePurge([19301, 19302, 19303], ['2:ct-a']);

      await service.amnestyUnstampedPurgeObligations();

      final backlog = await service.purgeBacklog();
      expect(backlog.ids, isNot(contains(19301)),
          reason: 'a live unstamped record must never be replay-destroyed');
      expect(backlog.ids, contains(19302),
          reason: 'a REAL stamp would be re-condemned by the new sweep anyway');
      expect(backlog.ids, contains(19303),
          reason: 'no record left: replay is a harmless backlog cleanup');
      expect(backlog.ciphertexts, contains('2:ct-a'),
          reason: 'the expiry sweep never enqueued ciphertexts');
    });

    test('runs once: later obligations are untouched', () async {
      await service.amnestyUnstampedPurgeObligations(); // writes the marker

      await service.saveDecryptedContent(19311, {'content': 'unstamped'});
      await service.enqueuePurge([19311], []);
      await service.amnestyUnstampedPurgeObligations();

      final backlog = await service.purgeBacklog();
      expect(backlog.ids, contains(19311),
          reason: 'post-fix obligations are all legitimate delete-flow work');
    });
  });
}
