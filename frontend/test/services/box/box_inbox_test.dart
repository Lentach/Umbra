import 'dart:async';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_inbox.dart';
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

/// A [ContentKv] whose writes can be refused, the way a full or failing
/// backend refuses them.
class _RefusingKv implements ContentKv {
  _RefusingKv(this._inner);

  final ContentKv _inner;
  bool refuse = false;

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
  Future<bool> setString(String key, String value) async =>
      !refuse && await _inner.setString(key, value);

  @override
  Future<bool> setInt(String key, int value) async =>
      !refuse && await _inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => _inner.remove(key);
}

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

/// A queue this device owns, with real key material.
ContactQueue _queue(int fill) {
  final auth = const Ed25519BoxSigner().mint();
  final seal = QueueSeal.mintKeyPair();
  return ContactQueue(
    rid: boxB64(_bytes(32, fill)),
    sid: boxB64(_bytes(32, fill + 1)),
    nid: boxB64(_bytes(16, fill + 2)),
    authPriv: boxB64(auth.bytes),
    sealPriv: boxB64(seal.privateKey),
    sealPub: boxB64(seal.publicKey),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seal = QueueSeal(cipher: PointyGcmSealer());
  late _RefusingKv kv;
  late ContactStore store;
  late FakeBoxSockets sockets;
  late BoxClient box;
  late BoxInbox inbox;
  late ContactQueue bobQueue;
  late List<BoxInboxEntry> offered;

  /// What the consumer answers: true = finished with it.
  late bool Function(BoxInboxEntry entry) verdict;

  /// What the box answers an `ack` with.
  late Object? ackAnswer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = _RefusingKv(await PrefsContentKv.open());
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    bobQueue = _queue(0x10);
    await store.update(
      42,
      (_) => ContactRecord(
        userId: 42,
        username: 'bob',
        tag: '0001',
        state: ContactState.friend,
        queues: [bobQueue],
        legacy: const ContactLegacy(conversationId: 900),
      ),
    );
    ackAnswer = {'ok': true};
    sockets = FakeBoxSockets()
      ..respond = (_, f) => switch (f.event) {
        'subscribe' => {'ok': true, 'refused': <Object>[]},
        'ack' => ackAnswer,
        _ => {'ok': true},
      };
    box = BoxClient(baseUrl: 'http://box.test', socketFactory: sockets.call)
      ..connect();
    sockets.last.serverConnect('S1');
    await pumpEventQueue();

    offered = [];
    verdict = (_) => true;
    inbox = BoxInbox(box: box, store: store, seal: seal)
      ..consumer = (entry) async {
        offered.add(entry);
        return verdict(entry);
      }
      ..start();
  });

  tearDown(() {
    inbox.dispose();
    box.dispose();
  });

  Future<Uint8List> sealed(ContactQueue queue, Uint8List body) async =>
      (await seal.seal(boxB64Decode(queue.sealPub, 32)!, body))!;

  Future<Uint8List> signalBlob(
    ContactQueue queue, {
    int device = 3,
    List<int> signal = const [1, 2, 3, 4],
  }) => sealed(
    queue,
    BoxFrame(
      kind: BoxFrameKind.whisper,
      senderDeviceId: device,
      signal: Uint8List.fromList(signal),
    ).encode(),
  );

  Future<void> push(ContactQueue queue, int idFill, Uint8List blob) async {
    sockets.last.push({
      'rid': queue.rid,
      'id': boxB64(_bytes(16, idFill)),
      'blob': boxB64(blob),
    });
    await pumpEventQueue();
    await inbox.idle;
  }

  List<String> ackedIds() => [
    for (final f in sockets.last.emitted)
      if (f.event == 'ack') f.frame['id']! as String,
  ];

  test('a sealed Signal frame is journaled, acked and offered once', () async {
    await push(bobQueue, 1, await signalBlob(bobQueue));

    final entry = offered.single;
    expect(entry.peerUserId, 42);
    expect(entry.senderDeviceId, 3);
    expect(entry.signal, '2:AQIDBA==');
    expect(entry.rid, bobQueue.rid);
    expect(ackedIds(), [boxB64(_bytes(16, 1))]);
    expect(store.pendingInbox, isEmpty, reason: 'consumed');
    expect(
      kv.getKeys().where((k) => k.contains('boxin')),
      isEmpty,
      reason: 'consumed AND acked: nothing left to map',
    );
  });

  test(
    'a delivery the app cannot read yet is still acked — it waits in the '
    'journal, not in the socket window — and drain offers it again',
    () async {
      verdict = (_) => false;
      await push(bobQueue, 1, await signalBlob(bobQueue));
      expect(ackedIds(), hasLength(1));
      expect(store.pendingInbox, hasLength(1));

      verdict = (_) => true;
      await inbox.drain();
      await inbox.idle;
      expect(offered, hasLength(2));
      expect(offered.last.localId, offered.first.localId);
      expect(store.pendingInbox, isEmpty);
    },
  );

  test(
    'a blob pushed AGAIN after it was read (the ack answer was lost) is '
    'acked, never offered a second time',
    () async {
      ackAnswer = 'lost';
      final blob = await signalBlob(bobQueue);
      await push(bobQueue, 1, blob);
      expect(offered, hasLength(1));

      // Pushed again, and that ack's answer is lost too.
      await push(bobQueue, 1, blob);
      expect(offered, hasLength(1), reason: 'Signal must not see it again');

      ackAnswer = {'ok': true};
      await push(bobQueue, 1, blob);
      expect(offered, hasLength(1));
      expect(ackedIds(), hasLength(3));
      expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
    },
  );

  test(
    'an ack the box refused on a LIVE socket is sent again — no redelivery '
    'needed — once the refusal says it may be',
    () async {
      ackAnswer = {'ok': false, 'code': 'rate_limited', 'retryAfterMs': 20};
      await push(bobQueue, 1, await signalBlob(bobQueue));
      expect(offered, hasLength(1));
      expect(ackedIds(), hasLength(1));

      ackAnswer = {'ok': true};
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await inbox.idle;
      expect(ackedIds(), hasLength(2));
      expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
      expect(offered, hasLength(1), reason: 'a re-ack never re-reads');
    },
  );

  test('drain re-acks every journal row the box never confirmed', () async {
    ackAnswer = 'lost';
    await push(bobQueue, 1, await signalBlob(bobQueue));
    ackAnswer = {'ok': true};
    await inbox.drain();
    await inbox.idle;
    await inbox.idle;
    expect(ackedIds(), hasLength(2));
    expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
  });

  test(
    'a slow read never holds the NEXT delivery unacked: acks run ahead of '
    'the reader',
    () async {
      final gate = Completer<void>();
      inbox.consumer = (entry) async {
        offered.add(entry);
        await gate.future;
        return true;
      };
      sockets.last.push({
        'rid': bobQueue.rid,
        'id': boxB64(_bytes(16, 1)),
        'blob': boxB64(await signalBlob(bobQueue, signal: [1])),
      });
      sockets.last.push({
        'rid': bobQueue.rid,
        'id': boxB64(_bytes(16, 2)),
        'blob': boxB64(await signalBlob(bobQueue, signal: [2])),
      });
      for (var i = 0; i < 50 && ackedIds().length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ackedIds(), hasLength(2), reason: 'both acked while #1 is read');
      expect(offered, hasLength(1), reason: 'reads stay one at a time');

      gate.complete();
      await inbox.idle;
      expect(offered.map((e) => e.signal), ['2:AQ==', '2:Ag==']);
    },
  );

  test('deliveries are offered in arrival order', () async {
    await push(bobQueue, 1, await signalBlob(bobQueue, signal: [1]));
    await push(bobQueue, 2, await signalBlob(bobQueue, signal: [2]));
    expect(offered.map((e) => e.signal), ['2:AQ==', '2:Ag==']);
    expect(offered.last.localId, offered.first.localId + 1);
  });

  test(
    'a dropped blob whose ack the box refused is acked again once allowed — '
    'no journal row remembers it',
    () async {
      ackAnswer = {'ok': false, 'code': 'rate_limited', 'retryAfterMs': 20};
      await push(bobQueue, 1, _bytes(kBoxBlobBytes, 7));
      expect(ackedIds(), hasLength(1));

      ackAnswer = {'ok': true};
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await inbox.idle;
      expect(ackedIds(), hasLength(2));
      expect(offered, isEmpty);
    },
  );

  test('a blob that does not open is acked and dropped', () async {
    final other = _queue(0x40);
    await push(bobQueue, 1, await signalBlob(other));
    await push(bobQueue, 2, _bytes(kBoxBlobBytes, 7));
    expect(offered, isEmpty);
    expect(ackedIds(), hasLength(2));
    expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
  });

  test('a frame this build cannot read is acked and dropped', () async {
    final body = Uint8List.fromList([0x01, 0x10, 0x00, 0x01, 9, 9, 9]);
    await push(bobQueue, 1, await sealed(bobQueue, body));
    expect(offered, isEmpty);
    expect(ackedIds(), hasLength(1));
  });

  test(
    'a friend request on the request queue is acked, not offered — first '
    'contact is slice (f)',
    () async {
      final request = _queue(0x60);
      await store.claimRequestQueue(request);
      await push(request, 1, await signalBlob(request));
      expect(offered, isEmpty);
      expect(ackedIds(), hasLength(1));
    },
  );

  test(
    'a queue whose record is gone is acked with the key the box client '
    'holds, then no longer followed',
    () async {
      final auth = QueueKeys.authOf(bobQueue)!;
      await box.subscribe([auth]);
      await store.remove(42);
      await push(bobQueue, 1, await signalBlob(bobQueue));
      expect(offered, isEmpty);
      expect(ackedIds(), [boxB64(_bytes(16, 1))]);
      expect(box.subscribed.map(boxB64), isNot(contains(bobQueue.rid)));
    },
  );

  test('a queue neither the store nor the box knows is left alone', () async {
    final stranger = _queue(0x70);
    await push(stranger, 1, await signalBlob(stranger));
    expect(offered, isEmpty);
    expect(ackedIds(), isEmpty);
  });

  test(
    'a delivery the journal refused is NOT acked, and is taken by the next '
    'drain once the store writes again',
    () async {
      final blob = await signalBlob(bobQueue);
      kv.refuse = true;
      await push(bobQueue, 1, blob);
      expect(offered, isEmpty);
      expect(ackedIds(), isEmpty);

      kv.refuse = false;
      await inbox.drain();
      await inbox.idle;
      expect(offered, hasLength(1));
      expect(ackedIds(), hasLength(1));
    },
  );

  test(
    'deliveries landing while the store is closed (a passcode re-lock) fill '
    'the whole socket window, and all of them are journaled once it reopens',
    () async {
      store.close();
      for (var i = 1; i <= 17; i++) {
        await push(bobQueue, i, await signalBlob(bobQueue, signal: [i]));
      }
      expect(ackedIds(), isEmpty);

      await store.open(1);
      await inbox.drain();
      await inbox.idle;
      expect(ackedIds(), hasLength(17));
      expect(offered.map((e) => e.signal).toSet(), hasLength(17));
    },
  );

  test('with no consumer yet, deliveries wait in the journal', () async {
    inbox.consumer = null;
    await push(bobQueue, 1, await signalBlob(bobQueue));
    expect(ackedIds(), hasLength(1));
    expect(store.pendingInbox, hasLength(1));

    inbox.consumer = (entry) async {
      offered.add(entry);
      return true;
    };
    await inbox.drain();
    await inbox.idle;
    expect(offered, hasLength(1));
  });

  group('sibling deliveries (own account, PR3.1 sibling queues)', () {
    Future<Uint8List> accountBlob(
      ContactQueue queue, {
      required int account,
      int device = 2,
    }) => sealed(
      queue,
      BoxFrame(
        kind: BoxFrameKind.preKey,
        senderDeviceId: device,
        senderUserId: account,
        signal: Uint8List.fromList([7, 7]),
      ).encode(),
    );

    test(
      "a frame on this device's SELF-queue is journaled under the OWN "
      'account, acked and offered',
      () async {
        final self = _queue(0x80);
        await store.claimSelfQueue(self);
        await push(self, 1, await signalBlob(self, device: 2));

        final entry = offered.single;
        expect(entry.peerUserId, 1);
        expect(entry.senderDeviceId, 2);
        expect(ackedIds(), hasLength(1));
      },
    );

    test(
      'on the REQUEST queue, a frame naming THIS account is a sibling: '
      'journaled under the own account, acked and offered',
      () async {
        final request = _queue(0x60);
        await store.claimRequestQueue(request);
        await push(request, 1, await accountBlob(request, account: 1));

        final entry = offered.single;
        expect(entry.peerUserId, 1);
        expect(entry.senderDeviceId, 2);
        expect(entry.signal, '3:Bwc=');
        expect(ackedIds(), hasLength(1));
      },
    );

    test(
      "on the REQUEST queue, a stranger's account-bearing frame is still "
      'acked and dropped — first contact is slice (f)',
      () async {
        final request = _queue(0x60);
        await store.claimRequestQueue(request);
        await push(request, 1, await accountBlob(request, account: 99));
        expect(offered, isEmpty);
        expect(ackedIds(), hasLength(1));
        expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
      },
    );

    test(
      'an account-bearing frame on a normal contact queue is not a frame '
      'that queue carries: acked and dropped',
      () async {
        await push(bobQueue, 1, await accountBlob(bobQueue, account: 1));
        expect(offered, isEmpty);
        expect(ackedIds(), hasLength(1));
      },
    );

    test(
      'a sibling handoff landing while the store is closed is held unacked, '
      'and journaled under the own account once it reopens',
      () async {
        final request = _queue(0x60);
        await store.claimRequestQueue(request);
        store.close();
        await push(request, 1, await accountBlob(request, account: 1));
        expect(ackedIds(), isEmpty);

        await store.open(1);
        await inbox.drain();
        await inbox.idle;
        expect(offered.single.peerUserId, 1);
        expect(ackedIds(), hasLength(1));
      },
    );

    test(
      'a sibling row whose ack was lost is re-acked by drain with the '
      "request queue's own key",
      () async {
        final request = _queue(0x60);
        await store.claimRequestQueue(request);
        ackAnswer = 'lost';
        await push(request, 1, await accountBlob(request, account: 1));
        ackAnswer = {'ok': true};
        await inbox.drain();
        await inbox.idle;
        await inbox.idle;
        expect(offered.single.peerUserId, 1);
        expect(ackedIds(), hasLength(2));
        expect(kv.getKeys().where((k) => k.contains('boxin')), isEmpty);
      },
    );
  });
}
