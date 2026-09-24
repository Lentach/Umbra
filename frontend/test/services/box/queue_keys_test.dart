import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_signer.dart';
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

  group("this device's REQUEST queue (design §4.4)", () {
    final request = {
      'rid': boxB64(_bytes(32, 0x44)),
      'sid': boxB64(_bytes(32, 0x55)),
      'nid': boxB64(_bytes(16, 0x66)),
    };

    ContactQueue foreignQueue() {
      final seal = QueueSeal.mintKeyPair();
      return ContactQueue(
        rid: boxB64(_bytes(32, 0x77)),
        sid: boxB64(_bytes(32, 0x78)),
        nid: boxB64(_bytes(16, 0x79)),
        authPriv: boxB64(const Ed25519BoxSigner().mint().bytes),
        sealPriv: boxB64(seal.privateKey),
        sealPub: boxB64(seal.publicKey),
      );
    }

    Iterable<EmittedFrame> sent(String event) =>
        sockets.last.emitted.where((f) => f.event == event);

    setUp(() {
      sockets.respond = (_, f) => switch (f.event) {
        'createQueue' => {'ok': true, ...request},
        'subscribe' => {'ok': true, 'refused': <Object?>[]},
        _ => {'ok': true},
      };
    });

    test(
      'is created as a request queue, subscribed, kept out of the contact '
      'rows, and the same queue comes back after a re-open',
      () async {
        final queue = (await keys.ensureRequest())!;
        expect(queue.sid, request['sid']);
        final create = sent('createQueue').single.frame;
        expect(create['kind'], 'request');
        expect(boxB64(QueueKeys.authOf(queue)!.key.publicKey), create['authPub']);
        expect(box.subscribed.map(boxB64), contains(queue.rid));

        final reopened = newStore();
        await reopened.open(1);
        expect(
          reopened.undeterminedCount,
          0,
          reason: 'a contact-row key would read as an unreadable contact',
        );
        expect(reopened.all.map((r) => r.userId), [42]);

        final again = (await QueueKeys(
          box: box,
          store: reopened,
        ).ensureRequest())!;
        expect(again.rid, queue.rid);
        expect(again.authPriv, queue.authPriv);
        expect(again.sealPriv, queue.sealPriv);
        expect(sent('createQueue'), hasLength(1));
      },
    );

    test(
      'a queue another tab stored first wins; the one just created is '
      'deleted again',
      () async {
        final theirs = foreignQueue();
        sockets.respond = (_, f) {
          if (f.event == 'createQueue') {
            unawaited(
              kv.setString(
                ContactStore.requestQueueKey(1),
                jsonEncode({'v': 1, 'queue': theirs.toJson()}),
              ),
            );
            return {'ok': true, ...request};
          }
          if (f.event == 'subscribe') {
            return {'ok': true, 'refused': <Object?>[]};
          }
          return {'ok': true};
        };
        final kept = (await keys.ensureRequest())!;
        expect(kept.rid, theirs.rid);
        expect(kept.authPriv, theirs.authPriv);
        expect(sent('deleteQueue').single.frame['rid'], request['rid']);
        expect(box.subscribed.map(boxB64), [theirs.rid]);
        final reopened = newStore();
        await reopened.open(1);
        expect(
          reopened.requestQueue?.rid,
          theirs.rid,
          reason: 'a restart must publish the queue that was kept',
        );
      },
    );

    test(
      'a stored queue the box no longer knows (reaped) is replaced',
      () async {
        final first = (await keys.ensureRequest())!;
        final fresh = {
          'rid': boxB64(_bytes(32, 0x88)),
          'sid': boxB64(_bytes(32, 0x99)),
          'nid': boxB64(_bytes(16, 0xaa)),
        };
        sockets.respond = (_, f) => switch (f.event) {
          'createQueue' => {'ok': true, ...fresh},
          'subscribe' => {
            'ok': true,
            'refused': [
              for (final s in (f.frame['subs']! as List<Object?>))
                if ((s! as Map)['rid'] == first.rid)
                  {'rid': first.rid, 'code': 'auth_failed'},
            ],
          },
          _ => {'ok': true},
        };
        final reopened = newStore();
        await reopened.open(1);

        final replaced = (await QueueKeys(
          box: box,
          store: reopened,
        ).ensureRequest())!;
        expect(replaced.sid, fresh['sid']);
        final stored = newStore();
        await stored.open(1);
        expect(stored.requestQueue?.rid, fresh['rid']);
      },
    );

    test(
      'only a refusal of THIS rid drops the stored queue: a rate-limited '
      'subscribe, or a refusal of another rid, keeps the keys and creates '
      'nothing',
      () async {
        final first = (await keys.ensureRequest())!;
        final row = kv.getString(ContactStore.requestQueueKey(1));
        final creates = sent('createQueue').length;

        for (final answer in <Object? Function(EmittedFrame)>[
          (_) => {'ok': false, 'code': 'rate_limited', 'retryAfterMs': 1000},
          (_) => {
            'ok': true,
            'refused': [
              {'rid': boxB64(_bytes(32, 0x5a)), 'code': 'auth_failed'},
            ],
          },
        ]) {
          sockets.respond = (_, f) =>
              f.event == 'subscribe' ? answer(f) : {'ok': true};
          final reopened = newStore();
          await reopened.open(1);
          final kept = await QueueKeys(
            box: box,
            store: reopened,
          ).ensureRequest();
          expect(kept?.rid, first.rid);
          expect(kv.getString(ContactStore.requestQueueKey(1)), row);
        }
        expect(sent('createQueue'), hasLength(creates));
      },
    );

    test('a row a newer build wrote is left alone; nothing is created', () async {
      final future = jsonEncode({'v': 2, 'queue': foreignQueue().toJson()});
      await kv.setString(ContactStore.requestQueueKey(1), future);
      final reopened = newStore();
      await reopened.open(1);

      expect(await QueueKeys(box: box, store: reopened).ensureRequest(), isNull);
      expect(sent('createQueue'), isEmpty);
      expect(kv.getString(ContactStore.requestQueueKey(1)), future);
    });

    test('an unreadable row (garbage, lost seal key) is replaced', () async {
      await kv.setString(ContactStore.requestQueueKey(1), 'fps1:lost:garbage');
      final reopened = newStore();
      await reopened.open(1);

      final queue = (await QueueKeys(
        box: box,
        store: reopened,
      ).ensureRequest())!;
      expect(queue.rid, request['rid']);
      expect(reopened.requestQueue?.rid, request['rid']);
    });

    test('a closed store creates nothing', () async {
      store.close();
      expect(await keys.ensureRequest(), isNull);
      expect(sent('createQueue'), isEmpty);
    });
  });
}
