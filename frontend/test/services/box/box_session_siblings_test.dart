import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

/// One device's own storage: two devices of an account never share one.
class _MemKv implements ContentKv {
  final Map<String, Object> _rows = {};

  @override
  Future<void> reload() async {}

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async => null;

  @override
  String? getString(String key) => _rows[key] as String?;

  @override
  int? getInt(String key) => _rows[key] as int?;

  @override
  bool containsKey(String key) => _rows.containsKey(key);

  @override
  Set<String> getKeys() => _rows.keys.toSet();

  @override
  Future<bool> setString(String key, String value) async {
    _rows[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _rows[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _rows.remove(key);
    return true;
  }
}

/// A box that routes: a `send` to a sid is pushed to whichever socket
/// subscribed that sid's queue. A rid it never created is refused on
/// subscribe, as a reaped queue is.
class _RoutingBox {
  _RoutingBox() {
    sockets.respond = (socket, f) {
      switch (f.event) {
        case 'createQueue':
          final n = ++_queues;
          final rid = boxB64(_bytes(32, n));
          final sid = boxB64(_bytes(32, 0x80 + n));
          _ridOfSid[sid] = rid;
          return {
            'ok': true,
            'rid': rid,
            'sid': sid,
            'nid': boxB64(_bytes(16, 0x40 + n)),
          };
        case 'subscribe':
          final refused = <Object?>[];
          for (final s in f.frame['subs']! as List<Object?>) {
            final rid = (s! as Map)['rid']! as String;
            if (_ridOfSid.containsValue(rid)) {
              _reader[rid] = socket;
            } else {
              refused.add({'rid': rid, 'code': 'auth_failed'});
            }
          }
          return {'ok': true, 'refused': refused};
        case 'send':
          sent.add(f.frame['sid']! as String);
          final rid = _ridOfSid[f.frame['sid']];
          final reader = rid == null ? null : _reader[rid];
          if (reader != null) {
            final id = boxB64(_bytes(16, ++_messages));
            final blob = f.frame['blob'];
            Timer.run(() => reader.push({'rid': rid, 'id': id, 'blob': blob}));
          }
          return {'ok': true};
        case 'deleteQueue':
          final rid = f.frame['rid']! as String;
          deleted.add(rid);
          _ridOfSid.removeWhere((_, r) => r == rid);
          return {'ok': true};
        default:
          return {'ok': true};
      }
    };
  }

  final FakeBoxSockets sockets = FakeBoxSockets();
  final Map<String, String> _ridOfSid = {};
  final Map<String, FakeBoxSocket> _reader = {};
  int _queues = 0;
  int _messages = 0;

  /// Every sid a `send` went to, in order.
  final List<String> sent = [];

  /// Every rid a `deleteQueue` named, in order.
  final List<String> deleted = [];

  /// Every rid a `subscribe` named, in order.
  List<String> subscribedBy(FakeBoxSocket socket) => [
    for (final f in socket.emitted)
      if (f.event == 'subscribe')
        for (final s in f.frame['subs']! as List<Object?>)
          (s! as Map)['rid']! as String,
  ];
}

/// One linked device of account 1: its own storage, box connection and
/// [BoxSession]. Signal is faked as the identity (a "ciphertext" is the JSON
/// itself); what is under test is who is told what, and when.
class _Device {
  _Device(this.deviceId, this.box, {ContentKv? kv, this.clock})
    : kv = kv ?? _MemKv();

  /// What the own VERIFIED list names live; null = not known now.
  Set<int>? live;

  /// Every delivery this device read.
  final List<BoxInboxEntry> reads = [];

  final DateTime Function()? clock;

  final int deviceId;
  final _RoutingBox box;
  final ContentKv kv;
  late final ContactStore store;
  late final BoxSession session;
  late final FakeBoxSocket socket;
  final List<String> emitted = [];
  bool started = false;

  /// Every device a FRESH encrypt (a re-key's handoff) was asked for.
  final List<int> freshFor = [];

  /// The Signal side cannot encrypt now (E2E not ready, not live).
  bool encryptFails = false;

  Future<BoxFrame?> encrypt(
    int toDevice,
    String json, {
    bool fresh = false,
  }) async {
    if (encryptFails) return null;
    if (fresh) freshFor.add(toDevice);
    return BoxFrame(
      kind: BoxFrameKind.whisper,
      senderDeviceId: deviceId,
      signal: Uint8List.fromList(utf8.encode(json)),
    );
  }

  /// What `MessagingProvider.consumeBoxEntry` does with a sibling entry once
  /// decrypted: the handoff reaction itself is the box's own
  /// [BoxSession.takeSiblingHandoff], the code under test.
  Future<bool> read(BoxInboxEntry entry) async {
    reads.add(entry);
    if (entry.peerUserId != 1) return true;
    final json = utf8.decode(base64Decode(entry.signal!.split(':')[1]));
    final handoff = E2eEnvelope.parseQueueHandoff(json);
    if (handoff != null) {
      final taken = await session.takeSiblingHandoff(
        entry.senderDeviceId,
        sid: handoff.sid,
        sealPub: handoff.sealPub,
      );
      return taken != SiblingWrite.retryLater;
    }
    final acked = E2eEnvelope.parseQueueHandoffAck(json);
    if (acked != null) {
      return await session.siblingAcked(entry.senderDeviceId, acked) !=
          SiblingWrite.retryLater;
    }
    return true;
  }

  Future<void> start({bool wireEncrypt = true, bool e2e = true}) async {
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    session = BoxSession(
      box: BoxClient(
        baseUrl: 'http://box.test',
        socketFactory: box.sockets.call,
      ),
      store: store,
      emit: (event, _) => emitted.add(event),
      seal: QueueSeal(cipher: PointyGcmSealer()),
      now: clock,
    )..start();
    socket = box.sockets.last;
    session.consumer = read;
    if (wireEncrypt) session.encryptForOwnDevice = encrypt;
    session.ownLiveDevices = () async {
      final ids = live;
      return ids == null ? null : (self: deviceId, live: ids);
    };
    if (e2e) session.e2eReady();
    started = true;
    socket.serverConnect('S$deviceId');
    await settle();
  }

  int get asks => emitted.where((e) => e == 'getOwnRequestQueues').length;

  /// This device as `ownRequestQueues` names it to a sibling.
  Map<String, Object?> get published => {
    'deviceId': deviceId,
    'requestSid': store.requestQueue?.sid,
    'sealPub': store.requestQueue?.sealPub,
  };

  void answer(List<_Device> siblings) => session.onOwnRequestQueues({
    'success': true,
    'devices': [for (final s in siblings) s.published],
  });

  SiblingAddress? sibling(int id) =>
      store.siblings.where((s) => s.deviceId == id).firstOrNull;
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RoutingBox box;
  late _Device a;
  late _Device b;

  setUp(() {
    box = _RoutingBox();
    a = _Device(2, box);
    b = _Device(3, box);
  });

  tearDown(() {
    for (final device in [a, b]) {
      if (device.started) device.session.dispose();
    }
  });

  test(
    'each device mints ONE self-queue — a normal queue, subscribed with its '
    'other queues — beside its request queue',
    () async {
      await a.start();
      await b.start();
      final self = a.store.selfQueue!;
      expect(self.rid, isNot(a.store.requestQueue!.rid));
      final creates = [
        for (final f in a.socket.emitted)
          if (f.event == 'createQueue') f.frame['kind'],
      ];
      expect(creates, unorderedEquals(['request', 'normal']));
    },
  );

  test(
    "two siblings converge: each learns the other's self-queue and each "
    'records that the other acknowledged its own — and a reconnect after '
    'that hands nothing off again',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      expect(a.asks, 1);
      expect(b.asks, 1);

      a.answer([b]);
      b.answer([a]);
      await settle();

      expect(a.sibling(3)?.sid, b.store.selfQueue!.sid);
      expect(a.sibling(3)?.sealPub, b.store.selfQueue!.sealPub);
      expect(a.sibling(3)?.ackedSelfSid, a.store.selfQueue!.sid);
      expect(b.sibling(2)?.sid, a.store.selfQueue!.sid);
      expect(b.sibling(2)?.ackedSelfSid, b.store.selfQueue!.sid);

      final sends = box.sent.length;
      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady();
      await settle();
      expect(a.asks, 2, reason: 'every connect asks again');
      a.answer([b]);
      await settle();
      expect(box.sent, hasLength(sends), reason: "b already acked a's sid");
    },
  );

  test(
    "a pair converges when one side's ask raced the other's publish: the "
    'side that got the handoff acks it and hands its own back, with no '
    'reconnect, and the exchange then stops (found live 2026-09-25)',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      final before = box.sent.length;
      // a asked before b had published: the server named no sibling.
      a.answer([]);
      b.answer([a]);
      await settle();

      expect(a.sibling(3)?.sid, b.store.selfQueue!.sid);
      expect(a.sibling(3)?.ackedSelfSid, a.store.selfQueue!.sid);
      expect(b.sibling(2)?.sid, a.store.selfQueue!.sid);
      expect(b.sibling(2)?.ackedSelfSid, b.store.selfQueue!.sid);
      expect(a.asks, 1, reason: 'no second ask was needed');

      // b's handoff, a's ack, a's handoff back, b's ack — and nothing more:
      // the ack goes BEFORE the hand-back, so b has recorded a's ack of its
      // queue by the time it reads a's handoff and does not answer it again.
      expect(box.sent.length - before, 4);
      final sends = box.sent.length;
      await settle();
      expect(box.sent, hasLength(sends), reason: 'no handoff ping-pong');
    },
  );

  test(
    'a handoff from a sibling that already acknowledged OUR current '
    'self-queue is acked again but gets nothing handed back',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      a.answer([b]);
      b.answer([a]);
      await settle();
      expect(a.sibling(3)?.ackedSelfSid, a.store.selfQueue!.sid);

      final before = box.sent.length;
      final self = b.store.selfQueue!;
      expect(
        await a.session.takeSiblingHandoff(
          3,
          sid: self.sid,
          sealPub: self.sealPub,
        ),
        SiblingWrite.stored,
      );
      await settle();
      expect(box.sent.sublist(before), [self.sid], reason: 'the ack alone');
    },
  );

  test(
    'a handoff the store cannot take (closed by a re-lock) sends nothing — '
    'no ack, no hand-back — and is kept for the next offer',
    () async {
      await a.start();
      a.session.accountReady(2);
      await settle();
      final before = box.sent.length;
      a.store.close();

      expect(
        await a.session.takeSiblingHandoff(
          3,
          sid: boxB64(_bytes(32, 0xA1)),
          sealPub: boxB64(_bytes(32, 0xA2)),
        ),
        SiblingWrite.retryLater,
      );
      await settle();
      expect(box.sent, hasLength(before));
    },
  );

  test(
    'a sibling the server lists under OUR OWN request queue is skipped: '
    'our handoff would come straight back to us (a device on the link gate '
    "once published its queue as the primary's, found live 2026-09-25)",
    () async {
      await a.start();
      a.session.accountReady(2);
      await settle();
      final mine = a.store.requestQueue!;
      a.session.onOwnRequestQueues({
        'success': true,
        'devices': [
          {'deviceId': 3, 'requestSid': mine.sid, 'sealPub': mine.sealPub},
        ],
      });
      await settle();
      expect(box.sent, isEmpty);
    },
  );

  test(
    'the handoff is an account-bearing frame naming this account, sealed to '
    "the sibling's REQUEST key and sent to its request sid",
    () async {
      await a.start();
      await b.start();
      // b reads nothing: this test opens what a sent by hand.
      b.session.consumer = null;
      a.session.accountReady(2);
      await settle();
      a.answer([b]);
      await settle();

      final send = a.socket.emitted.lastWhere((f) => f.event == 'send').frame;
      final request = b.store.requestQueue!;
      expect(send['sid'], request.sid);
      final body = await QueueSeal(cipher: PointyGcmSealer()).open(
        boxB64Decode(request.sealPriv, 32)!,
        boxB64Decode(request.sealPub, 32)!,
        boxB64Decode(send['blob'], kBoxBlobBytes)!,
      );
      final frame = BoxFrame.decode(body!)!;
      expect(frame.senderUserId, 1);
      expect(frame.senderDeviceId, 2);
      expect(
        E2eEnvelope.parseQueueHandoff(utf8.decode(frame.signal)),
        (sid: a.store.selfQueue!.sid, sealPub: a.store.selfQueue!.sealPub),
      );
    },
  );

  test(
    'a sibling that has not published its request queue gets nothing yet; '
    'the next connect tries again',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      await settle();
      a.session.onOwnRequestQueues({
        'success': true,
        'devices': [
          {'deviceId': 3, 'requestSid': null, 'sealPub': null},
        ],
      });
      await settle();
      expect(box.sent, isEmpty);

      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady();
      await settle();
      a.answer([b]);
      await settle();
      expect(b.sibling(2)?.sid, a.store.selfQueue!.sid);
    },
  );

  test(
    'nothing is asked before E2E is ready, before the Signal side is wired, '
    'or from a server that names no device id',
    () async {
      await a.start(e2e: false, wireEncrypt: false);
      a.session.accountReady(null);
      await settle();
      a.session.e2eReady();
      a.session.encryptForOwnDevice = a.encrypt;
      await settle();
      expect(a.asks, 0, reason: 'no confirmed device id');

      a.session.accountReady(2);
      await settle();
      expect(a.asks, 1);
    },
  );

  test('a rate-limited ask is repeated after retryAfterMs', () async {
    await a.start();
    a.session.accountReady(2);
    await settle();
    a.session.onOwnRequestQueues({
      'success': false,
      'error': 'rate_limited',
      'retryAfterMs': 5,
    });
    expect(a.asks, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await settle();
    expect(a.asks, 2);
  });

  test(
    'an internal refusal waits for the next connect; a change of the own '
    'device list asks again at once',
    () async {
      await a.start();
      a.session.accountReady(2);
      await settle();
      a.session.onOwnRequestQueues({'success': false, 'error': 'internal'});
      a.session.storeOpened();
      await settle();
      expect(a.asks, 1);

      a.session.ownDevicesChanged();
      await settle();
      expect(a.asks, 2);
    },
  );

  test(
    'a self-queue the box no longer knows is replaced, and a sibling that '
    'acknowledged the OLD one is handed the new one',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      a.answer([b]);
      b.answer([a]);
      await settle();
      final old = a.store.selfQueue!;
      expect(a.sibling(3)?.ackedSelfSid, old.sid);

      // Device a restarts against a box that reaped its self-queue.
      a.session.dispose();
      final restarted = _Device(2, box, kv: a.kv);
      box._ridOfSid.removeWhere((_, rid) => rid == old.rid);
      a = restarted;
      await a.start();
      a.session.accountReady(2);
      await settle();
      expect(a.store.selfQueue!.sid, isNot(old.sid));
      a.answer([b]);
      await settle();
      expect(b.sibling(2)?.sid, a.store.selfQueue!.sid);
      expect(a.sibling(3)?.ackedSelfSid, a.store.selfQueue!.sid);
    },
  );

  group('a revoked sibling (E6, E7)', () {
    late _Device c;
    var now = DateTime.utc(2026, 9, 25);

    setUp(() {
      now = DateTime.utc(2026, 9, 25);
      a = _Device(2, box, clock: () => now);
      c = _Device(4, box);
    });

    tearDown(() {
      if (c.started) c.session.dispose();
    });

    Future<void> converge(List<_Device> devices) async {
      for (final d in devices) {
        await d.start();
      }
      for (final d in devices) {
        d.session.accountReady(d.deviceId);
      }
      await settle();
      for (final d in devices) {
        d.answer([
          for (final other in devices)
            if (other != d) other,
        ]);
      }
      await settle();
    }

    /// The own list now names [live]; the E2E layer says it changed.
    Future<void> ownListIs(_Device d, Set<int> live) async {
      d
        ..live = live
        ..session.ownDevicesChanged();
      await settle();
    }

    test(
      'a survivor drops it, rotates its self-queue, hands the new one to '
      'each remaining sibling through THAT sibling self-queue, and keeps the '
      'old one retiring — an ack of the new one proves nothing about what '
      'is still on its way into the old one',
      () async {
        await converge([a, b, c]);
        final old = a.store.selfQueue!;
        expect(a.sibling(4)?.ackedSelfSid, old.sid);
        final sendsBefore = box.sent.length;

        await ownListIs(a, {2, 3});

        final next = a.store.selfQueue!;
        expect(next.sid, isNot(old.sid));
        expect(a.sibling(4), isNull);
        // The swap's new ask is left unanswered: b learned it from a's
        // handoff into b's self-queue.
        expect(b.sibling(2)?.sid, next.sid);
        expect(a.sibling(3)?.ackedSelfSid, next.sid);
        expect(box.deleted, isEmpty);
        expect(a.store.retiringSelfQueues.single.queue.rid, old.rid);
        expect(
          box.sent.sublist(sendsBefore),
          isNot(contains(c.store.selfQueue!.sid)),
          reason: 'the revoked device learns nothing',
        );
      },
    );

    test(
      'the old queue stays subscribed and read after the sibling acked the '
      'new one: a copy it built before it learned the new address still '
      'lands, and is read as a self-queue delivery',
      () async {
        await converge([a, b, c]);
        final old = a.store.selfQueue!;
        await ownListIs(a, {2, 3});
        expect(a.sibling(3)?.ackedSelfSid, a.store.selfQueue!.sid);

        final readsBefore = a.reads.length;
        expect(
          await b.session.deliver(
            ContactOutbound(peerDeviceId: 2, sid: old.sid, sealPub: old.sealPub),
            BoxFrame(
              kind: BoxFrameKind.whisper,
              senderDeviceId: 3,
              signal: Uint8List.fromList(utf8.encode('{"t":"msg"}')),
            ).encode(),
          ),
          isTrue,
        );
        await settle();
        expect(
          a.reads.sublist(readsBefore),
          [
            isA<BoxInboxEntry>()
                .having((e) => e.rid, 'rid', old.rid)
                .having((e) => e.peerUserId, 'peerUserId', 1)
                .having((e) => e.senderDeviceId, 'senderDeviceId', 3)
                .having(
                  (e) => e.viaSelfQueue,
                  'viaSelfQueue',
                  isTrue,
                  // Journaled as a self-queue delivery: still read as one
                  // once this queue has retired and left the sibling row.
                ),
          ],
        );
        expect(box.deleted, isEmpty);
      },
    );

    test(
      'the old queue goes once the box TTL has passed since the rotation, '
      'and is subscribed again after a restart until then',
      () async {
        await converge([a, b, c]);
        final old = a.store.selfQueue!;
        b.session.consumer = null;
        await ownListIs(a, {2, 3});

        a.session.dispose();
        a = _Device(2, box, kv: a.kv, clock: () => now)..live = {2, 3};
        await a.start();
        expect(box.subscribedBy(a.socket), contains(old.rid));
        expect(box.deleted, isEmpty);

        now = now.add(const Duration(days: 31));
        a.session.storeOpened();
        await settle();
        expect(box.deleted, [old.rid]);
        expect(a.store.retiringSelfQueues, isEmpty);
      },
    );

    test(
      'nothing rotates while this device is not live in its own list, or '
      'while every sibling it knows still is',
      () async {
        await converge([a, b, c]);
        final old = a.store.selfQueue!;

        // Not live itself, and device 4 gone too: still nothing moves.
        await ownListIs(a, {3});
        await ownListIs(a, {2, 3, 4});

        expect(a.store.selfQueue!.sid, old.sid);
        expect(a.sibling(4), isNotNull);
        expect(box.deleted, isEmpty);
      },
    );

    test(
      'a rotation another tab of this device made first is adopted: that '
      'tab never hands a sibling the retiring sid',
      () async {
        await converge([a, b, c]);
        final tab = _Device(2, box, kv: a.kv, clock: () => now);
        addTearDown(() => tab.session.dispose());
        await tab.start();
        tab.session.accountReady(2);
        await settle();

        await ownListIs(a, {2, 3});
        final next = a.store.selfQueue!;
        expect(b.sibling(2)?.sid, next.sid);

        await ownListIs(tab, {2, 3});
        tab.answer([b]);
        await settle();

        expect(tab.store.selfQueue?.rid, next.rid);
        expect(b.sibling(2)?.sid, next.sid);
      },
    );

    test(
      'a sibling the swap handed our self-queue to is noted BEFORE the '
      'handoff, so revoking it before it ever answered still rotates',
      () async {
        await a.start();
        await b.start();
        b.session.consumer = null;
        a.session.accountReady(2);
        await settle();
        a.answer([b]);
        await settle();
        final old = a.store.selfQueue!;
        expect(a.sibling(3), isA<SiblingAddress>().having((s) => s.sid, 'sid', isNull));
        expect(a.session.siblingAddresses(), isEmpty, reason: 'no address yet');

        await ownListIs(a, {2});

        expect(a.store.selfQueue!.sid, isNot(old.sid));
        expect(a.store.retiringSelfQueues.single.queue.rid, old.rid);
      },
    );

    test(
      "a sibling that learns the OLD sid after the new one — the swap's "
      'request-queue handoff overtaken by the rotation — is handed the '
      'current one again, and its copies never go to a deleted queue',
      () async {
        await converge([a, b, c]);
        final old = a.store.selfQueue!;
        await ownListIs(a, {2, 3});
        final next = a.store.selfQueue!;
        expect(a.store.retiringSelfQueues.single.queue.rid, old.rid);
        // The rotation's own ask, answered: b already acked the new sid.
        a.answer([b]);
        await settle();
        final asks = a.asks;

        // The late one: b re-learns a's retired address.
        await b.session.takeSiblingHandoff(
          2,
          sid: old.sid,
          sealPub: old.sealPub,
        );
        await settle();
        expect(a.sibling(3)?.ackedSelfSid, isNull, reason: 'handed again');
        expect(a.asks, asks + 1, reason: 'the swap is asked again now');
        a.answer([b]);
        await settle();

        expect(b.sibling(2)?.sid, next.sid);
        expect(a.sibling(3)?.ackedSelfSid, next.sid);
      },
    );
  });

  test(
    "re-keying a sibling hands our self-queue into that sibling's "
    'self-queue, once per session (E8)',
    () async {
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      a.answer([b]);
      b.answer([a]);
      await settle();
      final before = box.sent.length;

      await a.session.rekeySibling(3);
      await a.session.rekeySibling(3);
      await settle();

      expect(
        box.sent.sublist(before).where((sid) => sid == b.store.selfQueue!.sid),
        hasLength(1),
      );
      expect(a.session.siblingAddresses().keys, [3]);
    },
  );

  group('the re-key this device asked for (decision 37, E37b)', () {
    var now = DateTime.utc(2026, 9, 25, 12);

    Future<void> linked() async {
      now = DateTime.utc(2026, 9, 25, 12);
      a = _Device(2, box, clock: () => now);
      await a.start();
      await b.start();
      a.session.accountReady(2);
      b.session.accountReady(3);
      await settle();
      a.answer([b]);
      b.answer([a]);
      await settle();
    }

    test(
      'a re-key builds its handoff on a FRESH session and marks that sibling '
      'awaited; nothing is marked when no handoff could be built or the '
      'address is unknown',
      () async {
        await linked();
        expect(a.session.awaitingRekeyFrom(3), isFalse);

        await a.session.rekeySibling(9);
        expect(a.session.awaitingRekeyFrom(9), isFalse);

        await a.session.rekeySibling(3);
        expect(a.freshFor, [3]);
        expect(a.session.awaitingRekeyFrom(3), isTrue);
        expect(b.session.awaitingRekeyFrom(2), isFalse);
      },
    );

    test('a re-key whose handoff cannot be built marks nothing', () async {
      await linked();
      a.encryptFails = true;
      await a.session.rekeySibling(3);
      expect(a.session.awaitingRekeyFrom(3), isFalse);
    });

    test(
      'the mark is cleared once that sibling answers, and a second loss in '
      'the same session re-keys nothing (the once-per-session guard)',
      () async {
        await linked();
        await a.session.rekeySibling(3);
        a.session.rekeyAnswered(3);
        expect(a.session.awaitingRekeyFrom(3), isFalse);

        await a.session.rekeySibling(3);
        expect(a.freshFor, [3]);
        expect(a.session.awaitingRekeyFrom(3), isFalse);
      },
    );

    test('the mark lapses 10 minutes after the re-key', () async {
      await linked();
      await a.session.rekeySibling(3);
      now = now.add(const Duration(minutes: 10));
      expect(a.session.awaitingRekeyFrom(3), isTrue);
      now = now.add(const Duration(seconds: 1));
      expect(a.session.awaitingRekeyFrom(3), isFalse);
    });
  });
}
