import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption/sealed_web_content_kv.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Commits each write a moment later, as a real backend does, so two
/// unserialized read-then-write sequences genuinely interleave.
class _SlowCommitKv implements ContentKv {
  _SlowCommitKv(this._inner);

  final ContentKv _inner;

  Future<void> _later() => Future<void>.delayed(const Duration(milliseconds: 2));

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
  Future<bool> setString(String key, String value) async {
    await _later();
    return _inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) async {
    await _later();
    return _inner.setInt(key, value);
  }

  @override
  Future<bool> remove(String key) async {
    await _later();
    return _inner.remove(key);
  }
}

/// The box delivery journal (metadata-privacy PR3.1 slice (b)): a delivery
/// is written here BEFORE its ack, under a local message id keyed on the
/// delivery itself, so a redelivered blob maps back to the same id instead
/// of re-running Signal on a key it already spent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;

  ContactStore fresh() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  final t0 = DateTime.utc(2026, 9, 24, 12);

  Future<BoxInboxEntry?> journal(
    String id, {
    String rid = 'rid-a',
    int peer = 42,
    DateTime? at,
  }) => store.journalDelivery(
    rid: rid,
    id: id,
    peerUserId: peer,
    senderDeviceId: 2,
    signal: '3:c2lnbmFs$id',
    receivedAt: at ?? t0,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = fresh();
    await store.open(7);
  });

  test('deliveries get increasing local ids from the first local id', () async {
    final a = (await journal('m1'))!;
    final b = (await journal('m2'))!;
    expect(a.localId, kFirstLocalMessageId);
    expect(b.localId, kFirstLocalMessageId + 1);
    expect(isServerMessageId(a.localId), isFalse);
  });

  test('a redelivered blob maps back to the SAME local id', () async {
    final first = (await journal('m1'))!;
    await journal('m2');
    final again = (await journal('m1'))!;
    expect(again.localId, first.localId);

    // Across a restart too: the journal is on disk, not in RAM.
    store = fresh();
    await store.open(7);
    expect((await journal('m1'))!.localId, first.localId);
    expect((await journal('m3'))!.localId, kFirstLocalMessageId + 2);
  });

  test('the counter never reuses an id a stored message already holds', () async {
    // The counter row is gone but a box message's plaintext survived: the
    // next id must land above it, or a new message overwrites that record.
    await kv.setString(
      'e2e_7_decrypted_${kFirstLocalMessageId + 40}',
      '{"content":"kept"}',
    );
    await kv.setString('e2e_7_decrypted_9000', '{"content":"server row"}');
    await kv.setString(
      'e2e_8_decrypted_${kFirstLocalMessageId + 99}',
      '{"content":"another account"}',
    );
    store = fresh();
    await store.open(7);
    expect((await journal('m1'))!.localId, kFirstLocalMessageId + 41);
  });

  test('a deleted or retired box message never gets its id reissued', () async {
    final first = (await journal('m1'))!;
    // Its record deleted: the counter alone keeps the id spent.
    store = fresh();
    await store.open(7);
    expect((await journal('m2'))!.localId, first.localId + 1);

    // Counter row lost too, but the retired set still names a later id.
    await kv.remove('e2e_7_boxlid_v1');
    await kv.setString('e2e_7_retired_v1', '[5, ${kFirstLocalMessageId + 70}]');
    await kv.setString('e2e_7_ledger_v1', '[${kFirstLocalMessageId + 60}]');
    store = fresh();
    await store.open(7);
    expect((await journal('m3'))!.localId, kFirstLocalMessageId + 71);
  });

  test(
    'two contexts journaling at once never share a local id (the web lock '
    'serializes the counter)',
    () async {
      // One lock per name shared by both instances, the way Web Locks
      // serialize two tabs of one origin.
      final tails = <String, Future<void>>{};
      Future<T> serialized<T>(String name, Future<T> Function() action) {
        final run = (tails[name] ?? Future<void>.value()).then((_) => action());
        tails[name] = run.then<void>((_) {}, onError: (_) {});
        return run;
      }
      final slow = _SlowCommitKv(kv);

      ContactStore tab() => ContactStore(
        open: () async => slow,
        lock: serialized,
        accepts: (_) => true,
      );
      final a = tab();
      final b = tab();
      await a.open(7);
      await b.open(7);
      Future<BoxInboxEntry?> put(ContactStore s, String id) => s.journalDelivery(
        rid: 'r',
        id: id,
        peerUserId: 42,
        senderDeviceId: 1,
        signal: '2:AQ==',
        receivedAt: t0,
      );
      final ids = await Future.wait([
        for (var i = 0; i < 6; i++) put(i.isEven ? a : b, 'm$i'),
      ]);
      final local = ids.map((e) => e!.localId).toSet();
      expect(local, hasLength(6));
    },
  );

  test('a pending delivery survives a restart with everything to decrypt it', () async {
    await journal('m2', rid: 'rid-b', peer: 43);
    await journal('m1');
    store = fresh();
    await store.open(7);

    final pending = store.pendingInbox;
    expect(pending.map((e) => e.id), ['m2', 'm1'], reason: 'arrival order');
    final e = pending.first;
    expect(e.rid, 'rid-b');
    expect(e.peerUserId, 43);
    expect(e.senderDeviceId, 2);
    expect(e.signal, '3:c2lnbmFsm2');
    expect(e.receivedAt, t0);
    expect(e.acked, isFalse);
  });

  test('a row goes only once it is both consumed and acked', () async {
    final e = (await journal('m1'))!;
    expect(await store.markInboxConsumed(e), isTrue);
    expect(store.pendingInbox, isEmpty, reason: 'consumed is not pending');

    // Consumed but the ack is unconfirmed: the box may push it again, and
    // that push must still find its local id.
    store = fresh();
    await store.open(7);
    final kept = (await journal('m1'))!;
    expect(kept.localId, e.localId);
    expect(kept.signal, isNull, reason: 'the ciphertext is dropped once read');

    expect(await store.markInboxAcked(kept), isTrue);
    expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
  });

  test('an acked delivery stays pending until it is consumed', () async {
    final e = (await journal('m1'))!;
    expect(await store.markInboxAcked(e), isTrue);
    store = fresh();
    await store.open(7);
    expect(store.pendingInbox.single.acked, isTrue);
    expect(store.pendingInbox.single.signal, isNotNull);
  });

  test('prune drops read rows the box can no longer push, nothing else', () async {
    final now = t0.add(const Duration(days: 31));
    final oldRead = (await journal('old-read'))!;
    await store.markInboxConsumed(oldRead);
    await journal('old-unread');
    final newRead = (await journal('new-read', at: now))!;
    await store.markInboxConsumed(newRead);

    await store.pruneInbox(now);
    store = fresh();
    await store.open(7);

    expect(store.pendingInbox.map((e) => e.id), ['old-unread']);
    expect((await journal('new-read'))!.localId, newRead.localId);
    final rows = kv.getKeys().where((k) => k.contains('boxin')).toList();
    expect(rows.any((k) => k.endsWith('old-read')), isFalse);
  });

  test('rows sit in the account namespace, in a family sealed on web', () async {
    await journal('m1');
    final row = kv.getKeys().singleWhere((k) => k.contains('boxin'));
    expect(row, startsWith('e2e_7_'));
    expect(SealedWebContentKv.isSealedFamilyKey(row), isTrue);
  });

  test('a closed store journals nothing', () async {
    store.close();
    expect(await journal('m1'), isNull);
  });
}
