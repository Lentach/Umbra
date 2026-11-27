import 'dart:typed_data';

import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `ContactStore.reannounceOwn` (decision B): the one-shot's two guards, each
/// killed on its own. The outer one keeps a record the one-shot already did
/// from costing a store lock at every start; the inner one, which reads the
/// row INSIDE the lock, keeps a second run that decided on an older
/// snapshot from clearing what was acknowledged since.
Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

ContactQueue _queue() => ContactQueue(
  rid: boxB64(_bytes(32, 1)),
  sid: boxB64(_bytes(32, 2)),
  nid: boxB64(_bytes(16, 3)),
  authPriv: boxB64(_bytes(64, 4)),
  sealPriv: boxB64(_bytes(32, 5)),
  sealPub: boxB64(_bytes(32, 6)),
  ackedBy: const [3],
);

ContactRecord _friend({required bool reannounced}) => ContactRecord(
  userId: 42,
  username: 'peer',
  tag: '0001',
  state: ContactState.friend,
  queues: [_queue()],
  reannounced: reannounced,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContactStore store;
  var locks = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final kv = await PrefsContentKv.open();
    locks = 0;
    // A real lock: one action at a time, in order (the store's own serial
    // order is what the race test relies on).
    var tail = Future<void>.value();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) {
        locks++;
        final run = tail.then((_) => action());
        tail = run.then((_) {}, onError: (_) {});
        return run;
      },
      accepts: (_) => true,
    );
    await store.open(7);
    await store.update(42, (_) => _friend(reannounced: false));
    locks = 0;
  });

  test('the one-shot clears once; a record already done costs no store lock '
      'at a later start (outer guard)', () async {
    final first = await store.reannounceOwn(everyone: false);
    expect(first.changed, [42]);
    expect(store.byUserId(42)!.queues.first.ackedBy, isEmpty);
    expect(store.byUserId(42)!.reannounced, isTrue);

    locks = 0;
    final second = await store.reannounceOwn(everyone: false);
    expect(second.changed, isEmpty);
    expect(second.complete, isTrue);
    expect(locks, 0, reason: 'a flagged record is not even looked at');
  });

  test('a second one-shot that decided on an older snapshot does not clear '
      'what was acknowledged since the first one ran (inner guard)', () async {
    final first = store.reannounceOwn(everyone: false);
    final acked = store.update(
      42,
      (c) => c!.copyWith(queues: [c.queues.first.withAck(3)]),
    );
    // Decides now, while the first one has not committed: the record still
    // reads as not re-announced.
    final second = store.reannounceOwn(everyone: false);
    final results = await Future.wait([first, acked, second]);

    expect((results[0] as dynamic).changed, [42]);
    expect(
      (results[2] as dynamic).changed,
      isEmpty,
      reason: 'the row read inside the lock is flagged already',
    );
    expect(
      store.byUserId(42)!.queues.first.ackedBy,
      [3],
      reason: 'the ack since the first run stays',
    );
  });

  test('a re-mint clears every record, flagged or not', () async {
    await store.reannounceOwn(everyone: false);
    await store.update(
      42,
      (c) => c!.copyWith(queues: [c.queues.first.withAck(3)]),
    );
    final remint = await store.reannounceOwn(everyone: true);
    expect(remint.changed, [42]);
    expect(store.byUserId(42)!.queues.first.ackedBy, isEmpty);
  });
}
