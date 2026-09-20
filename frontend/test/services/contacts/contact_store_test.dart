import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts commits so a test can prove an unchanged record writes nothing.
class _CountingKv implements ContentKv {
  _CountingKv(this._inner);

  final ContentKv _inner;
  int writes = 0;

  @override
  Future<void> reload() => _inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      _inner.authoritativeSnapshot();

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Set<String> getKeys() => _inner.getKeys();

  @override
  Future<bool> setString(String key, String value) {
    writes++;
    return _inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) => _inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => _inner.remove(key);
}

ContactRecord _friend(int id, {String name = 'peer'}) => ContactRecord(
  userId: id,
  username: name,
  tag: '0001',
  state: ContactState.friend,
  settings: const ContactSettings(disappearingTimer: 60, muted: true),
  legacy: const ContactLegacy(conversationId: 900),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingKv kv;
  late ContactStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = _CountingKv(await PrefsContentKv.open());
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
  });

  test('records round-trip through the store across a re-open', () async {
    await store.open(7);
    await store.update(42, (_) => _friend(42, name: 'bob'));
    await store.setSelf(UserModel(id: 7, username: 'me', tag: '0007'));

    final reopened = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await reopened.open(7);

    final bob = reopened.byUserId(42)!;
    expect(bob.username, 'bob');
    expect(bob.state, ContactState.friend);
    expect(bob.settings.disappearingTimer, 60);
    expect(bob.settings.muted, isTrue);
    expect(bob.legacy.conversationId, 900);
    expect(reopened.self?.username, 'me');
    // The namespace is the account-deletion sweep's contract.
    expect(kv.getKeys(), contains('e2e_7_contact_v1_42'));
  });

  test(
    'an unreadable row is skipped and kept, never turned into no contacts',
    () async {
      await store.open(7);
      await store.update(1, (_) => _friend(1));
      await store.update(2, (_) => _friend(2));
      // A row a newer build wrote, and a row whose seal key is gone (web).
      await kv.setString(
        'e2e_7_contact_v1_3',
        jsonEncode({'v': 2, 'userId': 3, 'future': true}),
      );
      await kv.setString('e2e_7_contact_v1_4', 'fpc1:lost-kid:garbage');

      await store.open(7);

      expect(store.all.map((r) => r.userId), unorderedEquals([1, 2]));
      expect(store.undeterminedCount, 2);
      expect(
        kv.getString('e2e_7_contact_v1_3'),
        isNotNull,
        reason: 'unreadable is not absent: the row stays on disk',
      );
      expect(kv.getString('e2e_7_contact_v1_4'), isNotNull);
    },
  );

  test('update mutates what is ON DISK, not the in-RAM view', () async {
    // The web branch: ground truth comes from `authoritativeSnapshot()`,
    // not the per-engine cache. Off web the flag is what selects it.
    PrefsContentKv.debugForceAuthoritative = true;
    addTearDown(() => PrefsContentKv.debugForceAuthoritative = false);
    await store.open(7);
    await store.update(5, (_) => _friend(5, name: 'stale'));
    // Another context rewrote the row underneath this store.
    await kv.setString(
      'e2e_7_contact_v1_5',
      jsonEncode(_friend(5, name: 'fresh').toJson()),
    );

    ContactRecord? seen;
    await store.update(5, (current) {
      seen = current;
      return current!.copyWith(state: ContactState.blocked);
    });

    expect(seen?.username, 'fresh');
    expect(store.byUserId(5)?.username, 'fresh');
    expect(store.byUserId(5)?.state, ContactState.blocked);
  });

  test('two un-awaited updates of one peer both survive', () async {
    // The cross-context lock is a pass-through off web; the store's own
    // queue is the only thing between a mute write and a concurrent timer
    // write on the same row.
    await store.open(7);
    await store.update(8, (_) => _friend(8));

    final mute = store.update(
      8,
      (c) => c!.copyWith(settings: c.settings.copyWith(muted: true)),
    );
    final timer = store.update(
      8,
      (c) => c!.copyWith(settings: c.settings.copyWith(disappearingTimer: 5)),
    );
    await Future.wait([mute, timer]);

    final onDisk = ContactRecord.fromJson(
      jsonDecode(kv.getString('e2e_7_contact_v1_8')!) as Map<String, dynamic>,
    );
    expect(onDisk.settings.muted, isTrue);
    expect(onDisk.settings.disappearingTimer, 5);
  });

  test('an unchanged record is not rewritten', () async {
    await store.open(7);
    await store.update(9, (_) => _friend(9));
    final before = kv.writes;

    await store.reconcile([9], (_, current) => current);

    expect(kv.writes, before);
  });

  test('reconcile sweeps by DISK state, not by the RAM view', () async {
    await store.open(7);
    await store.update(1, (_) => _friend(1));
    await store.update(
      2,
      (_) => _friend(2).copyWith(state: ContactState.pendingIn),
    );
    // Peer 2 accepted while this device was offline; the friends list
    // (upsert) and the now-empty requests list (sweep) land back-to-back,
    // before either write applied to RAM.
    final friends = store.reconcile(
      [1, 2],
      (_, cur) => cur!.copyWith(state: ContactState.friend),
    );
    final requests = store.reconcile(
      const [],
      (_, cur) => cur,
      sweep: (r) => r.state == ContactState.pendingIn ? null : r,
    );
    await Future.wait([friends, requests]);

    expect(
      store.byUserId(2)?.state,
      ContactState.friend,
      reason: 'the sweep saw the upsert that ran before it',
    );
    expect(store.byUserId(1)?.state, ContactState.friend);
  });

  test('a row a newer build wrote is neither rewritten nor swept', () async {
    await store.open(7);
    final future = jsonEncode({'v': 2, 'userId': 3, 'secret': 'keep'});
    await kv.setString('e2e_7_contact_v1_3', future);

    await store.reconcile(
      [3],
      (_, cur) => _friend(3),
      sweep: (_) => null,
    );

    expect(kv.getString('e2e_7_contact_v1_3'), future);
    expect(store.byUserId(3), isNull);
  });

  test('a mutation returning null leaves the row untouched', () async {
    await store.open(7);
    final before = kv.writes;

    expect(await store.update(4, (_) => null), isTrue);

    expect(kv.writes, before);
    expect(kv.containsKey('e2e_7_contact_v1_4'), isFalse);
  });

  test('a queued write from a closed session never lands', () async {
    await store.open(7);
    final late = store.update(6, (_) => _friend(6));
    store.close();
    await store.open(8);

    expect(await late, isFalse);
    expect(kv.containsKey('e2e_7_contact_v1_6'), isFalse);
    expect(store.byUserId(6), isNull);
  });

  test('remove deletes the row; removing an absent row succeeds', () async {
    await store.open(7);
    await store.update(11, (_) => _friend(11));

    expect(await store.remove(11), isTrue);
    expect(store.byUserId(11), isNull);
    expect(kv.containsKey('e2e_7_contact_v1_11'), isFalse);
    expect(await store.remove(11), isTrue);
  });

  test('a backend the platform gate refuses leaves the store closed', () async {
    final refusing = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => false,
    );

    await expectLater(
      refusing.open(7),
      throwsA(
        isA<ContactStoreUnavailable>().having(
          (e) => e.stage,
          'stage',
          'backend',
        ),
      ),
    );
    expect(refusing.isOpen, isFalse);
    expect(await refusing.update(1, (_) => _friend(1)), isFalse);
  });

  test('a locked web vault surfaces as the locked stage', () async {
    final locked = ContactStore(
      open: () async =>
          throw const ContentStoreUnavailable('locked', locked: true),
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );

    await expectLater(
      locked.open(7),
      throwsA(
        isA<ContactStoreUnavailable>().having(
          (e) => e.stage,
          'stage',
          'locked',
        ),
      ),
    );
  });

  test('records of another account are invisible', () async {
    await store.open(7);
    await store.update(1, (_) => _friend(1));

    await store.open(8);

    expect(store.all, isEmpty);
    expect(store.self, isNull);
  });

  test('onChanged fires for a real change and stays silent for a no-op', () async {
    await store.open(7);
    var fired = 0;
    store.onChanged = () => fired++;

    await store.update(42, (_) => _friend(42, name: 'bob'));
    expect(fired, 1);

    // The reconnect shape: the same server list, written through again.
    await store.reconcile([42], (_, _) => _friend(42, name: 'bob'));
    expect(
      fired,
      1,
      reason: 'an unchanged reconcile must not schedule a backup upload',
    );

    await store.update(42, (_) => _friend(42, name: 'robert'));
    expect(fired, 2);

    await store.setSelf(UserModel(id: 7, username: 'me', tag: '0007'));
    expect(fired, 3);
    await store.setSelf(UserModel(id: 7, username: 'me', tag: '0007'));
    expect(fired, 3);
  });
}
