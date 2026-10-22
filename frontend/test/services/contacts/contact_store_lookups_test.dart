import 'dart:convert';

import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
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
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
    await store.open(1);
  });

  // Mutation: `open` does not decode the row (`_lookupBook` stays empty).
  test('a stamp survives a new process, per friend, and only moves forward',
      () async {
    expect(store.friendLookedUpAt(42), isNull);
    expect(await store.noteFriendLookup(42, t0), isTrue);
    expect(await store.noteFriendLookup(43, t0.add(const Duration(hours: 1))),
        isTrue);
    expect(await store.noteFriendLookup(42, t0.subtract(const Duration(days: 1))),
        isTrue);

    final again = newStore();
    await again.open(1);
    expect(again.friendLookedUpAt(42), t0);
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

  // Mutation: the row is `contact_v1_`-prefixed (a backup would carry it) or
  // lives outside `e2e_<uid>_` (account deletion would not sweep it).
  test('the row is outside the contact family and inside the account prefix',
      () {
    final key = ContactStore.friendLookupKey(1);
    expect(key, 'e2e_1_boxlook_v1');
    expect(key.startsWith(ContactStore.keyPrefix(1)), isFalse);
    expect(key.startsWith('e2e_1_'), isTrue);
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
