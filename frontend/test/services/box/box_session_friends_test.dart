import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

/// One device's own storage.
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
/// subscribed that sid's queue. [createRefusal] answers `createQueue` for
/// NORMAL queues instead, while set.
class _RoutingBox {
  _RoutingBox() {
    sockets.respond = (socket, f) {
      switch (f.event) {
        case 'createQueue':
          final refusal = createRefusal;
          if (refusal != null && f.frame['kind'] == 'normal') return refusal;
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
          final refused = subscribeRefusal;
          if (refused != null && identical(socket, subscribeRefusedOn)) {
            return refused;
          }
          for (final s in f.frame['subs']! as List<Object?>) {
            _reader[(s! as Map)['rid']! as String] = socket;
          }
          return {'ok': true, 'refused': <Object?>[]};
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
  Map<String, Object?>? createRefusal;

  /// Answers every `subscribe` from [subscribeRefusedOn] instead, while set.
  Map<String, Object?>? subscribeRefusal;
  FakeBoxSocket? subscribeRefusedOn;

  /// Every sid a `send` went to, in order.
  final List<String> sent = [];

  /// How many NORMAL queues [socket] asked for.
  int normalCreates(FakeBoxSocket socket) => socket.emitted
      .where((f) => f.event == 'createQueue' && f.frame['kind'] == 'normal')
      .length;
}

/// One device of account [userId], friends with [friendId]: its own
/// storage, box connection and [BoxSession]. Signal is faked as the identity
/// (a "ciphertext" is the JSON itself); what is under test is who is handed
/// what, and when.
class _Device {
  _Device(this.userId, this.deviceId, this.friendId, this.box);

  final int userId;
  final int deviceId;
  final int friendId;
  final _RoutingBox box;
  final ContentKv kv = _MemKv();
  late final ContactStore store;
  late final BoxSession session;
  late final FakeBoxSocket socket;
  bool started = false;

  /// What the friend's VERIFIED list names live; null = not known now.
  Set<int>? friendLive;

  /// The friend's state on this device's record; null = no record yet.
  ContactState? friendState = ContactState.friend;

  /// Reads nothing: a device that has not answered yet.
  bool deaf = false;

  /// Every encrypt fails: no session could be built.
  bool encryptFails = false;

  /// This device's clock.
  DateTime clock = DateTime.utc(2026, 9, 26, 12);

  /// Every account-socket event this device's session emitted.
  final List<String> emitted = [];

  /// Every friend device a FRESH encrypt (a re-key) was asked for.
  final List<int> freshFor = [];

  Future<BoxFrame?> encrypt(
    int toUser,
    int toDevice,
    String json, {
    bool fresh = false,
  }) async {
    final live = friendLive;
    if (encryptFails ||
        toUser != friendId ||
        live == null ||
        !live.contains(toDevice)) {
      return null;
    }
    if (fresh) freshFor.add(toDevice);
    return BoxFrame(
      kind: BoxFrameKind.whisper,
      senderDeviceId: deviceId,
      signal: Uint8List.fromList(utf8.encode(json)),
    );
  }

  /// What `MessagingProvider.consumeBoxEntry` does with a friend's entry
  /// once decrypted: the reaction itself is the box's own
  /// [BoxSession.takeFriendHandoff] / [BoxSession.friendAcked].
  Future<bool> read(BoxInboxEntry entry) async {
    if (deaf || entry.peerUserId != friendId) return true;
    final json = utf8.decode(base64Decode(entry.signal!.split(':')[1]));
    final handoff = E2eEnvelope.parseQueueHandoff(json);
    if (handoff != null) {
      final taken = await session.takeFriendHandoff(
        entry.peerUserId,
        entry.senderDeviceId,
        sid: handoff.sid,
        sealPub: handoff.sealPub,
      );
      return taken != FriendWrite.retryLater;
    }
    // Only a handoff is read from the request queue.
    if (entry.viaRequestQueue) return true;
    final acked = E2eEnvelope.parseQueueHandoffAck(json);
    if (acked != null) {
      return await session.friendAcked(
            entry.peerUserId,
            entry.senderDeviceId,
            acked,
          ) !=
          FriendWrite.retryLater;
    }
    return true;
  }

  ContactRecord recordAs(ContactState state) => ContactRecord(
    userId: friendId,
    username: 'friend$friendId',
    tag: '000$friendId',
    state: state,
  );

  /// What `ConnectionProvider` does with a `friendsList` that names the
  /// friend for the first time: `FriendsProvider` queues the record's write
  /// (not awaited), then the box session is handed the list.
  void befriendAndList(List<Map<String, Object?>> list) {
    unawaited(store.update(friendId, (_) => recordAs(ContactState.friend)));
    session.onFriendsList(list);
  }

  Future<void> start() async {
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(userId);
    final state = friendState;
    if (state != null) await store.update(friendId, (_) => recordAs(state));
    session = BoxSession(
      box: BoxClient(
        baseUrl: 'http://box.test',
        socketFactory: box.sockets.call,
      ),
      store: store,
      emit: (event, _) => emitted.add(event),
      seal: QueueSeal(cipher: PointyGcmSealer()),
      now: () => clock,
    )..start();
    socket = box.sockets.last;
    session
      ..consumer = read
      ..encryptForFriend = encrypt
      ..friendLiveDevices = ((user) async =>
          user == friendId ? friendLive : null)
      ..e2eReady();
    started = true;
    socket.serverConnect('S$userId.$deviceId');
    await settle();
    session.accountReady(deviceId);
    await settle();
  }

  /// This device as the friend's `friendsList` names it.
  Map<String, Object?> get listed => {
    'id': userId,
    'devices': [
      {
        'deviceId': deviceId,
        'requestSid': store.requestQueue?.sid,
        'sealPub': store.requestQueue?.sealPub,
      },
    ],
  };

  /// This device as an app that predates the box: listed, no request queue.
  Map<String, Object?> get listedOld => {
    'id': userId,
    'devices': [
      {'deviceId': deviceId, 'requestSid': null, 'sealPub': null},
    ],
  };

  ContactRecord get friend => store.byUserId(friendId)!;

  ContactOutbound? outboundOf(int device) =>
      friend.outbound.where((o) => o.peerDeviceId == device).firstOrNull;
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RoutingBox box;
  late _Device a;
  late _Device b;

  setUp(() async {
    await E2ePersistentDiag.clear();
    box = _RoutingBox();
    a = _Device(1, 2, 5, box)..friendLive = {3};
    b = _Device(5, 3, 1, box)..friendLive = {2};
  });

  tearDown(() {
    for (final device in [a, b]) {
      if (device.started) device.session.dispose();
    }
  });

  test(
    'two friends on the box converge: each holds the queue the other made '
    'for it, each queue is acknowledged, and a reconnect hands nothing off '
    'again',
    () async {
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listed]);
      b.session.onFriendsList([a.listed]);
      await settle();

      final aQueue = a.friend.queues.single;
      final bQueue = b.friend.queues.single;
      expect(a.outboundOf(3)?.sid, bQueue.sid);
      expect(a.outboundOf(3)?.sealPub, bQueue.sealPub);
      expect(b.outboundOf(2)?.sid, aQueue.sid);
      expect(aQueue.ackedBy, [3]);
      expect(bQueue.ackedBy, [2]);

      final sends = box.sent.length;
      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady()
        ..onFriendsList([b.listed]);
      await settle();
      expect(box.sent, hasLength(sends), reason: 'b already acked our queue');
      expect(a.friend.queues, hasLength(1));
    },
  );

  test(
    'a friend still on an old app gets nothing and costs no queue; once it '
    'updates, its handoff reaches us and we hand ours back with no reconnect',
    () async {
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listedOld]);
      await settle();
      expect(a.friend.queues, isEmpty);
      expect(box.normalCreates(a.socket), 1, reason: 'the self-queue only');
      expect(box.sent, isEmpty);

      // b updates: its list names a's request queue; a hears nothing new.
      b.session.onFriendsList([a.listed]);
      await settle();

      expect(a.outboundOf(3)?.sid, b.friend.queues.single.sid);
      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
      expect(a.friend.queues.single.ackedBy, [3]);
      expect(b.friend.queues.single.ackedBy, [2]);
    },
  );

  for (final state in [ContactState.blocked, ContactState.former]) {
    test('a ${state.name} contact is handed nothing', () async {
      a.friendState = state;
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listed]);
      await settle();

      expect(a.friend.queues, isEmpty);
      expect(box.normalCreates(a.socket), 1, reason: 'the self-queue only');
      expect(b.outboundOf(2), isNull);
    });
  }

  test(
    "a device the friend's verified list does not name live is handed "
    'nothing, whatever the server lists',
    () async {
      a.friendLive = {};
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listed]);
      await settle();

      expect(b.outboundOf(2), isNull);
      expect(box.sent, isEmpty);
      expect(a.friend.queues, isEmpty, reason: 'nobody to hand one to');
    },
  );

  test(
    'a friend the list names for the first time — its record still being '
    'written when the list reaches the box — is handed our queue at once '
    '(found live: befriended while this device was away)',
    () async {
      a.friendState = null;
      await a.start();
      await b.start();

      a.befriendAndList([b.listed]);
      await settle();

      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
      expect(a.outboundOf(3)?.sid, b.friend.queues.single.sid);
    },
  );

  test(
    'a device that has not acknowledged yet is handed our queue once per '
    'connect, however many friends lists arrive meanwhile',
    () async {
      await a.start();
      await b.start();
      b.deaf = true;
      a.session.onFriendsList([b.listed]);
      await settle();
      a.session.onFriendsList([b.listed]);
      await settle();

      final toB = b.store.requestQueue!.sid;
      expect(box.sent.where((sid) => sid == toB), hasLength(1));
    },
  );

  test(
    'a device that never acknowledges is handed our queue again only after '
    'a day, however often this device reconnects — each handoff is one more '
    "blob in that device's request queue (review)",
    () async {
      await a.start();
      await b.start();
      b.deaf = true;
      a.session.onFriendsList([b.listed]);
      await settle();
      final toB = b.store.requestQueue!.sid;
      int handoffs() => box.sent.where((sid) => sid == toB).length;
      expect(handoffs(), 1);

      Future<void> reconnect() async {
        a.session
          ..accountLost()
          ..accountReady(2)
          ..e2eReady()
          ..onFriendsList([b.listed]);
        await settle();
      }

      a.clock = a.clock.add(const Duration(hours: 23));
      await reconnect();
      await reconnect();
      expect(handoffs(), 1);

      a.clock = a.clock.add(const Duration(hours: 2));
      await reconnect();
      expect(handoffs(), 2);
    },
  );

  test(
    'a device that has not acknowledged our queue but is heard from is '
    'handed it again at once, not a day later — once per device per '
    'session, and not while this connect has just handed it',
    () async {
      await a.start();
      await b.start();
      b.deaf = true;
      a.session.onFriendsList([b.listed]);
      await settle();
      final toB = b.store.requestQueue!.sid;
      int handoffs() => box.sent.where((sid) => sid == toB).length;
      expect(handoffs(), 1);

      Future<void> reconnect() async {
        a.session
          ..accountLost()
          ..accountReady(2)
          ..e2eReady()
          ..onFriendsList([b.listed]);
        await settle();
      }

      // Heard while the handoff this connect sent may still be in flight.
      a.session.friendHeard(5, 3);
      await settle();
      expect(handoffs(), 1);

      a.clock = a.clock.add(const Duration(hours: 1));
      await reconnect();
      expect(handoffs(), 1, reason: 'silent so far: the day holds');
      a.session.friendHeard(5, 3);
      await settle();
      expect(handoffs(), 2);
      expect(a.friend.queues.single.handedAt[3], a.clock);

      a.clock = a.clock.add(const Duration(hours: 1));
      await reconnect();
      a.session.friendHeard(5, 3);
      await settle();
      expect(handoffs(), 2, reason: 'once per device per session');

      // A device never handed anything, or someone who is no contact.
      a.session
        ..friendHeard(5, 9)
        ..friendHeard(7, 3);
      await settle();
      expect(handoffs(), 2);
    },
  );

  test(
    'a handoff goes out only once its new queue is subscribed: a subscribe '
    'that is rate limited holds every send, and the pass runs again after '
    'the wait — so the answer into that queue is read',
    () async {
      await a.start();
      await b.start();
      box
        ..subscribeRefusal = {
          'ok': false,
          'code': 'rate_limited',
          'retryAfterMs': 1000,
        }
        ..subscribeRefusedOn = a.socket;
      a.session.onFriendsList([b.listed]);
      await settle();
      expect(a.friend.queues, hasLength(1));
      expect(box.sent, isEmpty);

      box.subscribeRefusal = null;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await settle();

      final queue = a.friend.queues.single;
      expect(b.outboundOf(2)?.sid, queue.sid);
      expect(queue.ackedBy, [3], reason: "b's ack came into our new queue");
    },
  );

  test(
    'a subscribe the box refuses outright holds that queue back too, and the '
    'next pass subscribes it before handing it',
    () async {
      await a.start();
      await b.start();
      box
        ..subscribeRefusal = {'ok': false, 'code': 'internal'}
        ..subscribeRefusedOn = a.socket;
      a.session.onFriendsList([b.listed]);
      await settle();
      expect(a.friend.queues, hasLength(1));
      expect(box.sent, isEmpty);

      box.subscribeRefusal = null;
      a.session.onFriendsList([b.listed]);
      await settle();

      final queue = a.friend.queues.single;
      expect(b.outboundOf(2)?.sid, queue.sid);
      expect(queue.ackedBy, [3], reason: "b's ack came into our new queue");
    },
  );

  test(
    'a handoff failure is logged durably once per friend device, stage and '
    'code per session, however many passes repeat it',
    () async {
      a.encryptFails = true;
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listed]);
      await settle();
      a.session.handOffTo(5);
      await settle();
      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady()
        ..onFriendsList([b.listed]);
      await settle();

      final failed = E2ePersistentDiag.entries
          .where((e) => e.contains('BOX_FRIEND_HANDOFF_FAILED'))
          .toList();
      expect(failed, hasLength(1));
      expect(failed.single, contains('stage: encrypt'));
    },
  );

  test(
    "many friends' new queues are subscribed in ONE frame: the box allows "
    '60 subscribe frames per 15 min per IP, and one frame per queue left '
    'every friend past the 60th unsubscribed (review)',
    () async {
      const count = 70;
      final store = ContactStore(
        open: () async => _MemKv(),
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      await store.open(1);
      final list = <Map<String, Object?>>[];
      for (var f = 100; f < 100 + count; f++) {
        await store.update(
          f,
          (_) => ContactRecord(
            userId: f,
            username: 'f$f',
            tag: '0000',
            state: ContactState.friend,
          ),
        );
        list.add({
          'id': f,
          'devices': [
            {
              'deviceId': 1,
              // Nothing the fake box hands out (its sids fill 0x80 + n).
              'requestSid': boxB64(
                Uint8List(32)
                  ..[0] = 0xEE
                  ..[1] = f,
              ),
              'sealPub': boxB64(
                Uint8List(32)
                  ..[0] = 0xEE
                  ..[1] = f,
              ),
            },
          ],
        });
      }
      final session = BoxSession(
        box: BoxClient(
          baseUrl: 'http://box.test',
          socketFactory: box.sockets.call,
        ),
        store: store,
        emit: (_, _) {},
        seal: QueueSeal(cipher: PointyGcmSealer()),
      )..start();
      addTearDown(session.dispose);
      final socket = box.sockets.last;
      session
        ..consumer = ((_) async => true)
        ..encryptForFriend = ((user, device, json, {fresh = false}) async =>
            BoxFrame(
              kind: BoxFrameKind.whisper,
              senderDeviceId: 2,
              signal: Uint8List.fromList(utf8.encode(json)),
            ))
        ..friendLiveDevices = ((_) async => {1})
        ..e2eReady();
      socket.serverConnect('S1.2');
      await settle();
      session.accountReady(2);
      await settle();
      final before = socket.emitted.where((f) => f.event == 'subscribe').length;

      session.onFriendsList(list);
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      final rids = {
        for (final f in list)
          store.byUserId(f['id']! as int)!.queues.single.rid,
      };
      expect(rids, hasLength(count));
      final frames = socket.emitted
          .where((f) => f.event == 'subscribe')
          .skip(before)
          .toList();
      expect(frames, hasLength(1));
      expect(
        {
          for (final s in frames.single.frame['subs']! as List<Object?>)
            (s! as Map)['rid'],
        },
        rids,
      );
    },
  );

  test(
    'a re-key owed to a device this device has no address for asks the '
    'server for the friends list once, and goes out when the list names one '
    '(found live: a friend whose app updated after our list was fetched)',
    () async {
      await a.start();
      await b.start();
      // a's list predates b's update: nowhere to send b anything.
      a.session.onFriendsList([b.listedOld]);
      await settle();
      a.emitted.clear();

      await a.session.rekeyFriend(5, 3);
      await a.session.rekeyFriend(5, 3);
      expect(a.emitted.where((e) => e == 'getFriends'), hasLength(1));
      expect(a.freshFor, isEmpty);

      a.session.onFriendsList([b.listed]);
      await settle();

      expect(a.freshFor, [3]);
      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
    },
  );

  test(
    'a re-key whose device the fresh list STILL names no address for is '
    'given up: no second ask, however often it is provoked (review: a '
    'stranger could otherwise loop getFriends)',
    () async {
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listedOld]);
      await settle();
      a.emitted.clear();

      await a.session.rekeyFriend(5, 3);
      a.session.onFriendsList([b.listedOld]);
      await settle();
      await a.session.rekeyFriend(5, 3);
      a.session.onFriendsList([b.listedOld]);
      await settle();

      expect(a.emitted.where((e) => e == 'getFriends'), hasLength(1));
      expect(a.freshFor, isEmpty);
    },
  );

  test('an ack naming a queue we do not hold is refused', () async {
    await a.start();
    expect(
      await a.session.friendAcked(5, 3, boxB64(_bytes(32, 0x7f))),
      FriendWrite.refused,
    );
  });

  test(
    'a session this device started or re-keyed with a friend device counts '
    'as asked for that device only, for 10 min, and not once it answered — '
    'the window is all a revoked device of the friend can use (decision 49)',
    () async {
      await a.start();
      a.session.friendSessionStarted(5, 3);
      expect(a.session.awaitingFriendRekeyFrom(5, 4), isFalse);
      a.clock = a.clock.add(kFriendRekeyWindow);
      expect(a.session.awaitingFriendRekeyFrom(5, 3), isTrue);
      a.clock = a.clock.add(const Duration(milliseconds: 1));
      expect(a.session.awaitingFriendRekeyFrom(5, 3), isFalse);

      a.session
        ..friendSessionStarted(5, 3)
        ..friendRekeyAnswered(5, 3);
      expect(a.session.awaitingFriendRekeyFrom(5, 3), isFalse);
    },
  );

  test(
    'a rate-limited create stops the pass, and it runs again after the wait',
    () async {
      box.createRefusal = {
        'ok': false,
        'code': 'rate_limited',
        'retryAfterMs': 1000,
      };
      await a.start();
      await b.start();
      a.session.onFriendsList([b.listed]);
      await settle();
      expect(a.friend.queues, isEmpty);
      expect(box.sent, isEmpty);

      box.createRefusal = null;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await settle();

      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
    },
  );
}
