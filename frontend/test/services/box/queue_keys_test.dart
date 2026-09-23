import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_keys.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  late FakeBoxSockets sockets;
  late BoxClient box;
  late QueueKeys keys;

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  final address = {
    'rid': boxB64(_bytes(32, 0x11)),
    'sid': boxB64(_bytes(32, 0x22)),
    'nid': boxB64(_bytes(16, 0x33)),
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
    await store.open(1);
    await store.update(
      42,
      (_) => const ContactRecord(
        userId: 42,
        username: 'bob',
        tag: '0042',
        state: ContactState.friend,
      ),
    );
    sockets = FakeBoxSockets()
      ..respond = (_, f) => switch (f.event) {
        'createQueue' => {'ok': true, ...address},
        'subscribe' => {'ok': true, 'refused': <Object?>[]},
        _ => {'ok': true},
      };
    box = BoxClient(baseUrl: 'http://box.test', socketFactory: sockets.call)
      ..connect();
    sockets.last.serverConnect('S1');
    await pumpEventQueue();
    keys = QueueKeys(box: box, store: store);
  });

  test(
    'a created queue is stored whole on the peer record, survives a re-open, '
    'is subscribed, and its stored keys are the ones the box saw',
    () async {
      final result = await keys.createInbound(42);
      expect(result, isA<InboundQueueCreated>());
      await store.settled;

      final reopened = newStore();
      await reopened.open(1);
      final queue = reopened.byUserId(42)!.queues.single;
      expect(queue.rid, address['rid']);
      expect(queue.sid, address['sid']);
      expect(queue.nid, address['nid']);

      final frames = sockets.last.emitted;
      final create = frames.firstWhere((f) => f.event == 'createQueue').frame;
      final auth = QueueKeys.authOf(queue)!;
      expect(boxB64(auth.key.publicKey), create['authPub']);
      expect(
        ed.newKeyFromSeed(auth.key.seed).bytes,
        auth.key.bytes,
        reason: "the stored public half is the seed's own",
      );
      final subscribe = frames.lastWhere((f) => f.event == 'subscribe').frame;
      final entry = (subscribe['subs']! as List<Object?>).single! as Map;
      expect(entry['rid'], queue.rid);
      expect(box.subscribed.map(boxB64), [queue.rid]);

      // The stored seal pair opens what a peer seals to the stored public half.
      final seal = QueueSeal(cipher: PointyGcmSealer());
      final pair = QueueKeys.sealOf(queue)!;
      final body = Uint8List.fromList([1, 2, 3]);
      final blob = (await seal.seal(pair.publicKey, body))!;
      expect(await seal.open(pair.privateKey, pair.publicKey, blob), body);

      keys = QueueKeys(box: box, store: reopened);
      expect(keys.inbound().map((q) => boxB64(q.rid)), [queue.rid]);
    },
  );

  test(
    'a peer with no record gets no queue: the fresh one is deleted again',
    () async {
      final result = await keys.createInbound(77);
      expect(result, isA<InboundQueueNotStored>());
      expect(store.byUserId(77), isNull);
      final delete = sockets.last.emitted.lastWhere(
        (f) => f.event == 'deleteQueue',
      );
      expect(delete.frame['rid'], address['rid']);
      expect(box.subscribed, isEmpty);
    },
  );

  test('a refused create leaves the record untouched', () async {
    sockets.respond = (_, f) => {'ok': false, 'code': 'rate_limited'};
    final result = await keys.createInbound(42);
    expect(
      result,
      isA<InboundQueueNotCreated>().having(
        (r) => r.answer,
        'answer',
        isA<BoxRefused<QueueAddress>>(),
      ),
    );
    await store.settled;
    expect(store.byUserId(42)!.queues, isEmpty);
  });

  test("a former record's queues are still subscribed at connect", () async {
    await keys.createInbound(42);
    await store.settled;
    await store.update(
      42,
      (r) => r!.copyWith(state: ContactState.former),
    );
    expect(keys.inbound(), hasLength(1));
  });
}
