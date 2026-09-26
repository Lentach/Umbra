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
    if (toUser != friendId || live == null || !live.contains(toDevice)) {
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
    )..start();
    socket = box.sockets.last;
    session
      ..consumer = read
      ..encryptForFriend = encrypt
      ..friendLiveDevices = ((user) async => user == friendId ? friendLive : null)
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

  setUp(() {
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
