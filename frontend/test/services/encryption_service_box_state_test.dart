// A3-SVC-C-3, C-4, C-8 — the box's tombstones, parked actions and seen marks.
//
// C-8: the tombstone row keeps a delete for 30 days and 5000 entries; a flipped
// prune comparison would drop every tombstone and bring deleted messages back.
// C-4: both content backends answer `false` to a refused write instead of
// throwing, so a lost tombstone or seen mark must be reported, not assumed.
// C-3: a parked edit holds the edited words, so "delete all local history" and
// a delete-for-everyone of its target must remove it.

import 'dart:convert';

import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [inner] that answers `false` to every string write while [refuse] is set,
/// as the native and sealed-web stores do when a write is refused.
class _RefusingKv implements ContentKv {
  _RefusingKv(this.inner);

  final ContentKv inner;
  bool refuse = false;

  @override
  Future<void> reload() => inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      inner.authoritativeSnapshot();

  @override
  String? getString(String key) => inner.getString(key);

  @override
  int? getInt(String key) => inner.getInt(key);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async =>
      refuse ? false : inner.setString(key, value);

  @override
  Future<bool> setInt(String key, int value) => inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

const _day = Duration(days: 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EncryptionService service;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    await E2ePersistentDiag.init();
    service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
  });

  Future<Map<String, dynamic>> tombstoneRow() async {
    final raw = (await service.contentKv).getString('e2e_1_boxdel_v1');
    return jsonDecode(raw!) as Map<String, dynamic>;
  }

  int msAgo(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

  group('A3-SVC-C-8: the tombstone row keeps 30 days and 5000 entries', () {
    test('an entry older than 30 days goes, a younger one stays', () async {
      await (await service.contentKv).setString(
        'e2e_1_boxdel_v1',
        jsonEncode({
          '2:too-old': msAgo(_day * 31),
          '2:still-young': msAgo(_day * 29),
        }),
      );

      await service.addBoxTombstone((senderId: 2, wireId: 'fresh'));

      expect(await service.boxTombstoned((senderId: 2, wireId: 'too-old')),
          isFalse);
      expect(await service.boxTombstoned((senderId: 2, wireId: 'still-young')),
          isTrue);
      expect(await service.boxTombstoned((senderId: 2, wireId: 'fresh')),
          isTrue);
    });

    test('past the cap the OLDEST entry goes and the newest 5000 stay',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await (await service.contentKv).setString(
        'e2e_1_boxdel_v1',
        jsonEncode({
          // 5000 entries, `e0` the oldest, all inside the 30 days.
          for (var i = 0; i < 5000; i++) '2:e$i': now - 10 * _day.inMilliseconds + i,
        }),
      );

      await service.addBoxTombstone((senderId: 2, wireId: 'fresh'));

      final row = await tombstoneRow();
      expect(row, hasLength(5000));
      expect(row.containsKey('2:fresh'), isTrue);
      expect(row.containsKey('2:e0'), isFalse, reason: 'the oldest is evicted');
      expect(row.containsKey('2:e1'), isTrue);
    });
  });

  group('A3-SVC-C-4: a refused write is reported, not assumed', () {
    late _RefusingKv kv;

    setUp(() async {
      kv = _RefusingKv(await service.contentKv);
      service.debugSetContentKv(kv);
    });

    bool diagHas(String marker) =>
        E2ePersistentDiag.entries.any((e) => e.contains(marker));

    test('a tombstone the store refuses leaves a diagnostic', () async {
      kv.refuse = true;

      await service.addBoxTombstone((senderId: 2, wireId: 'lost'));

      expect(diagHas('BOX_TOMBSTONE_WRITE_FAILED'), isTrue);
    });

    test('a base seen mark the store refuses is not handed out as saved',
        () async {
      kv.refuse = true;

      expect(await service.boxSeenMarks(), isNull);
      expect(diagHas('BOX_SEEN_WRITE_FAILED'), isTrue);

      // Once the store accepts writes again the base is fixed then, not lost.
      kv.refuse = false;
      expect(await service.boxSeenMarks(), isNotNull);
    });

    test('a parked action the store refuses leaves a diagnostic', () async {
      kv.refuse = true;

      await service.parkBoxAction(
        10,
        (senderId: 2, wireId: 'target'),
        {'e': 'x'},
        receivedAt: DateTime.now(),
      );

      expect(diagHas('BOX_PARKED_WRITE_FAILED'), isTrue);
    });
  });

  group('A3-SVC-C-3: parked edits do not outlive what deletes them', () {
    const target = (senderId: 2, wireId: 'edited-target');

    Future<void> parkEdit() => service.parkBoxAction(
      10,
      target,
      {'c': 'the edited words'},
      receivedAt: DateTime.now(),
    );

    test('"delete all local history" removes the parked actions', () async {
      await parkEdit();
      expect(await service.parkedBoxActions(10, target), isNotEmpty);

      final result = await service.clearDecryptedContentCache();

      expect(result.failedKeys, isEmpty);
      expect(await service.parkedBoxActions(10, target), isEmpty);
      expect(
        (await service.contentKv).containsKey('e2e_1_boxact_v1'),
        isFalse,
        reason: 'the edited words must not stay on disk',
      );
    });

    test('a delete-for-everyone drops what was parked for its target',
        () async {
      await parkEdit();
      await service.parkBoxAction(
        10,
        (senderId: 2, wireId: 'other-target'),
        {'c': 'unrelated'},
        receivedAt: DateTime.now(),
      );

      await service.addBoxTombstone(target);

      expect(await service.parkedBoxActions(10, target), isEmpty);
      expect(
        await service.parkedBoxActions(10, (senderId: 2, wireId: 'other-target')),
        isNotEmpty,
      );
    });
  });
}
