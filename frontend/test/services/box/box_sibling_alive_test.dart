import 'dart:convert';

import 'package:fireplace/services/box/box_sibling_alive.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decisions 101 B and 103 over the real `boxalive_v1` row: the daily
/// `alive`, the heard marks and the primary's 30-day question.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  late DateTime now;
  late BoxSiblingAlive alive;

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
    now = DateTime.utc(2026, 10, 16, 12);
    alive = BoxSiblingAlive(store: store, now: () => now);
  });

  /// This install, reopened: what is on disk, not in RAM.
  Future<BoxSiblingAlive> reopened() async {
    final again = newStore();
    await again.open(1);
    return BoxSiblingAlive(store: again, now: () => now);
  }

  group('alive', () {
    test('is owed to each sibling at most once per 24 h, each on its own '
        'clock, and the clock survives a restart', () async {
      expect(alive.aliveDue([3, 4]), [3, 4]);
      expect(await alive.aliveSent(3), isTrue);
      expect(alive.aliveDue([3, 4]), [4]);

      now = now.add(const Duration(hours: 23, minutes: 59));
      expect(alive.aliveDue([3, 4]), [4]);
      expect((await reopened()).aliveDue([3, 4]), [4]);

      now = now.add(const Duration(minutes: 1));
      expect(alive.aliveDue([3, 4]), [3, 4]);
    });

    test('a pass is single-flight', () {
      expect(alive.beginPass(), isTrue);
      expect(alive.beginPass(), isFalse);
      alive.endPass();
      expect(alive.beginPass(), isTrue);
    });
  });

  group('heard', () {
    test('a sibling with no mark is first known at the pass, a held mark '
        'stays, and a device that left the live list is dropped', () async {
      expect(await alive.heard(4), isTrue);
      final heard4 = now;
      now = now.add(const Duration(days: 2));
      expect(await alive.known({3, 4}), isTrue);

      expect(alive.heardAt(3), now, reason: 'first known now');
      expect(alive.heardAt(4), heard4, reason: 'a held mark is not reset');

      expect(await alive.known({3}), isTrue);
      final disk = await reopened();
      expect(disk.heardAt(4), isNull);
      expect(disk.heardAt(3), now);
    });

    test('moves forward only, in steps of at least an hour', () async {
      expect(await alive.heard(3), isTrue);
      final first = now;

      now = now.add(const Duration(minutes: 59));
      expect(await alive.heard(3), isFalse, reason: 'within the step');
      expect(alive.heardAt(3), first);

      now = now.add(const Duration(minutes: 1));
      expect(await alive.heard(3), isTrue);
      expect(alive.heardAt(3), now);

      expect(
        await store.markSiblingHeard(3, first),
        isTrue,
        reason: 'an older mark is a no-op, not a failure',
      );
      expect(alive.heardAt(3), now);
    });
  });

  group('unlink question', () {
    test('siblingUnlinkDue: primary, silent MORE than 30 d, not kept', () {
      final heard = now.subtract(const Duration(days: 30));
      bool due({
        bool primary = true,
        DateTime? heardAt,
        DateTime? keptUntil,
        Duration after = const Duration(seconds: 1),
      }) => siblingUnlinkDue(
        primary: primary,
        heardAt: heardAt ?? heard,
        keptUntil: keptUntil,
        now: now.add(after),
      );

      expect(due(), isTrue);
      expect(due(after: Duration.zero), isFalse, reason: 'exactly 30 d');
      expect(due(primary: false), isFalse);
      expect(
        due(keptUntil: now.add(const Duration(days: 1))),
        isFalse,
        reason: 'kept',
      );
      expect(due(keptUntil: now), isTrue, reason: 'the keep ran out');
      expect(
        siblingUnlinkDue(
          primary: true,
          heardAt: null,
          keptUntil: null,
          now: now,
        ),
        isFalse,
        reason: 'never heard nor known: nothing to measure',
      );
    });

    test('is asked only on the primary (lowest live id), of the lowest '
        'silent sibling', () async {
      await alive.known({2, 3, 4});
      now = now.add(const Duration(days: 31));
      await alive.heard(3);

      expect(alive.unlinkDue(self: 1, live: [1, 2, 3, 4]), 2);
      expect(alive.unlinkDue(self: 2, live: [1, 2, 3, 4]), isNull);
      expect(primaryDeviceOf([4, 2, 7]), 2);
      expect(primaryDeviceOf(const []), isNull);
    });

    test('a fresh link or the upgrade to this build is never asked about '
        'before 30 days', () async {
      await alive.known({2});
      now = now.add(const Duration(days: 30));
      expect(alive.unlinkDue(self: 1, live: [1, 2]), isNull);
      now = now.add(const Duration(seconds: 1));
      expect(alive.unlinkDue(self: 1, live: [1, 2]), 2);
    });

    test('Keep silences that device for 30 days, persisted; hearing it ends '
        'the question too', () async {
      await alive.known({2, 3});
      now = now.add(const Duration(days: 40));
      expect(alive.unlinkDue(self: 1, live: [1, 2, 3]), 2);

      expect(await alive.keep(2), isTrue);
      expect(alive.unlinkDue(self: 1, live: [1, 2, 3]), 3);
      expect((await reopened()).unlinkDue(self: 1, live: [1, 2, 3]), 3);

      await alive.heard(3);
      expect(alive.unlinkDue(self: 1, live: [1, 2, 3]), isNull);

      now = now.add(kSiblingKeepFor);
      expect(alive.unlinkDue(self: 1, live: [1, 2, 3]), 2);
    });
  });

  test("a newer build's row is never overwritten", () async {
    final key = ContactStore.siblingAliveKey(1);
    final newer = jsonEncode({
      'v': ContactStore.siblingAliveVersion + 1,
      'd': <String, Object?>{},
    });
    expect(await kv.setString(key, newer), isTrue);
    await store.open(1);

    expect(store.siblingAliveUnsupported, isTrue);
    expect(await alive.known({2}), isFalse);
    expect(await alive.keep(2), isFalse);
    expect(kv.getString(key), newer);
  });

  test('an unreadable row reads empty and is replaced', () async {
    final key = ContactStore.siblingAliveKey(1);
    expect(await kv.setString(key, 'fps1:not-json'), isTrue);
    await store.open(1);

    expect(alive.heardAt(2), isNull);
    expect(await alive.known({2}), isTrue);
    expect((await reopened()).heardAt(2), now);
  });
}
