import 'dart:convert';

import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/contacts/contact_backup.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The `boxlook_v1` row (decision 120, E114n): when each friend was last looked
/// up by handle, kept across processes so "once per 24 h" outlives a PWA open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  final t0 = DateTime.utc(2026, 10, 22, 12);

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
    await store.open(1);
  });

  // Mutation: `open` does not decode the row (`_lookupBook` stays empty), or
  // `noteFriendLookup` keeps a stamp that is later than the new one (the clock
  // went back: the stamp from the future then makes the friend due at every
  // start, second review).
  test('a stamp survives a new process, per friend, and the last write wins',
      () async {
    expect(store.friendLookedUpAt(42), isNull);
    expect(await store.noteFriendLookup(42, t0), isTrue);
    expect(await store.noteFriendLookup(43, t0.add(const Duration(hours: 1))),
        isTrue);
    final back = t0.subtract(const Duration(days: 1));
    expect(await store.noteFriendLookup(42, back), isTrue);

    final again = newStore();
    await again.open(1);
    expect(again.friendLookedUpAt(42), back);
    expect(again.friendLookedUpAt(43), t0.add(const Duration(hours: 1)));
  });

  // Mutation: `pruneFriendLookups` keeps every entry.
  test('the stamps of accounts that are no friend are pruned, and a prune that '
      'finds nothing writes nothing', () async {
    await store.noteFriendLookup(42, t0);
    await store.noteFriendLookup(77, t0);

    expect(await store.pruneFriendLookups({42}), isTrue);
    expect(store.friendLookedUpAt(77), isNull);
    expect(store.friendLookedUpAt(42), t0);

    final key = ContactStore.friendLookupKey(1);
    final before = kv.getString(key);
    expect(await store.pruneFriendLookups({42}), isTrue);
    expect(kv.getString(key), before);

    final fresh = newStore();
    await fresh.open(2);
    expect(await fresh.pruneFriendLookups({5}), isTrue);
    expect(
      kv.getString(ContactStore.friendLookupKey(2)),
      isNull,
      reason: 'nothing to prune: no empty row is written',
    );
  });

  // Mutation: the row is `contact_v1_`-prefixed (the history file copies
  // every row under that prefix, so it would carry which friends this device
  // looked up and when) or the store reads it back as a contact.
  test('a stamp is no contact: the history file and the contact backup, which '
      'copy contacts, never carry it', () async {
    await store.update(
      42,
      (_) => const ContactRecord(
        userId: 42,
        username: 'friend',
        tag: '0042',
        state: ContactState.friend,
      ),
    );
    await store.noteFriendLookup(42, t0);
    expect(
      kv.getKeys(),
      contains(ContactStore.friendLookupKey(1)),
      reason: 'control: the stamp row was written',
    );

    expect(
      kv.getKeys().where(
        (k) => k.startsWith(HistoryBackupService.contactPrefix(1)),
      ),
      [ContactStore.recordKey(1, 42)],
    );
    final again = newStore();
    await again.open(1);
    expect(again.all.map((c) => c.userId), [42]);
    final backup = jsonEncode(
      ContactBackupPayload(
        userId: 1,
        self: null,
        contacts: again.all.toList(),
      ).toJson(),
    );
    expect(backup, contains('friend'), reason: 'control: the contact is in it');
    expect(backup, isNot(contains('${t0.millisecondsSinceEpoch}')));
  });

  // Mutation: the row lives outside `e2e_<uid>_` (the sweep of account
  // deletion would leave which friends this account looked up).
  test('account deletion sweeps the stamps with the rest of the account',
      () async {
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    await store.noteFriendLookup(42, t0);
    expect(
      kv.getString(ContactStore.friendLookupKey(1)),
      isNotNull,
      reason: 'control: the stamp row was written',
    );

    await service.clearAllKeys();

    await kv.reload();
    expect(kv.getString(ContactStore.friendLookupKey(1)), isNull);
    final again = newStore();
    await again.open(1);
    expect(again.friendLookedUpAt(42), isNull);
  });

  // Mutation: `decode` returns the empty book for a newer version.
  test("a newer build's row is never overwritten", () async {
    final key = ContactStore.friendLookupKey(1);
    final newer = jsonEncode({
      'v': ContactStore.friendLookupVersion + 1,
      'f': {'42': t0.millisecondsSinceEpoch},
    });
    expect(await kv.setString(key, newer), isTrue);
    await store.open(1);

    expect(store.friendLookupsUnsupported, isTrue);
    expect(await store.noteFriendLookup(42, t0), isFalse);
    expect(kv.getString(key), newer);
  });

  test('an unreadable row reads as empty and the next stamp replaces it',
      () async {
    final key = ContactStore.friendLookupKey(1);
    expect(await kv.setString(key, 'not json'), isTrue);
    await store.open(1);
    expect(store.friendLookedUpAt(42), isNull);

    expect(await store.noteFriendLookup(42, t0), isTrue);
    expect(store.friendLookedUpAt(42), t0);
  });
}
