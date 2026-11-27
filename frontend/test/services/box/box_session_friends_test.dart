import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friend_gate.dart';
import 'package:fireplace/services/box/box_friend_handoff.dart'
    show kFriendLookupInterval;
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_signer.dart';
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

/// A queue this device holds, as its record would store it: every field a
/// real one carries, so the box session can prove it when it deletes it.
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
          if (refuseSendsTo.contains(f.frame['sid'])) {
            return {'ok': false, 'code': 'queue_full'};
          }
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
          return deleteRefusal ?? {'ok': true};
        default:
          return {'ok': true};
      }
    };
  }

  final FakeBoxSockets sockets = FakeBoxSockets();
  final Map<String, String> _ridOfSid = {};

  /// Answers every `deleteQueue` instead, while set.
  Map<String, Object?>? deleteRefusal;
  final Map<String, FakeBoxSocket> _reader = {};
  int _queues = 0;
  int _messages = 0;
  Map<String, Object?>? createRefusal;

  /// Answers every `subscribe` from [subscribeRefusedOn] instead, while set.
  Map<String, Object?>? subscribeRefusal;
  FakeBoxSocket? subscribeRefusedOn;

  /// Sids whose `send` is refused (`queue_full`), while named.
  final Set<String> refuseSendsTo = {};

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
  late BoxSession session;
  late FakeBoxSocket socket;
  bool started = false;

  /// What the friend's VERIFIED list names live; null = not known now.
  Set<int>? friendLive;

  /// What the friend's verified list names REVOKED (slice (e)).
  Set<int> friendRevoked = {};

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
    FriendPermit? permit,
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

  /// Every list a friend's frame carried outside Signal (decision 50).
  final List<String> carried = [];

  /// Every `list_update` a friend device sent here (E50d/E50f).
  final List<Map<String, dynamic>> listUpdates = [];

  /// What `MessagingProvider.consumeBoxEntry` does with a friend's entry
  /// once decrypted: the reaction itself is the box's own
  /// [BoxSession.takeFriendHandoff] / [BoxSession.friendAcked].
  Future<bool> read(BoxInboxEntry entry) async {
    if (deaf || entry.peerUserId != friendId) return true;
    if (entry.carriedList case final list?) carried.add(list);
    final json = utf8.decode(base64Decode(entry.signal!.split(':')[1]));
    final handoff = E2eEnvelope.parseQueueHandoff(json);
    if (handoff != null) {
      final taken = await session.takeFriendHandoff(
        entry.peerUserId,
        entry.senderDeviceId,
        sid: handoff.sid,
        sealPub: handoff.sealPub,
        learnedUnder: null,
      );
      return taken != FriendWrite.retryLater;
    }
    // Only a handoff is read from the request queue.
    if (entry.viaRequestQueue) return true;
    if (E2eEnvelope.carriedDeviceList(json) case final auth?) {
      listUpdates.add(auth);
      return true;
    }
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

  /// The friend's devices, as a handle lookup of the friend names them.
  final List<_Device> peers = [];

  /// Every friend id this device's handle lookup was asked for, in order.
  final List<int> lookups = [];

  /// What a lookup serves. Null: the request queue of every started device
  /// in [peers], what the box hands a searcher (E114b). Set it to serve
  /// nothing (a friend still on an old app, which published none) or a
  /// different set.
  List<ContactOutbound> Function()? serves;

  /// The pinned-identity mirror handed to the session; null: none wired.
  String? Function(int)? anchorOf;

  /// Every lookup throws, as a spent or unanswered one does.
  bool lookupFails = false;

  /// Every lookup answers "not ready yet" (`MessagingProvider.
  /// lookupFriendAddresses` while E2E is not ready): it asks and serves
  /// nothing.
  bool lookupNotReady = false;

  List<ContactOutbound> _served() => [
    for (final peer in peers)
      if (peer.started && peer.store.requestQueue != null)
        ContactOutbound(
          peerDeviceId: peer.deviceId,
          sid: peer.store.requestQueue!.sid,
          sealPub: peer.store.requestQueue!.sealPub,
          idk: null,
        ),
  ];

  /// `MessagingProvider.lookupFriendAddresses` as the box session sees it:
  /// the answer reaches [BoxSession.takeServedAddresses] before it completes.
  Future<bool> _lookup(int userId) async {
    lookups.add(userId);
    // A real lookup is a round trip: a caller that does not await it has
    // not got the answer yet.
    await Future<void>.delayed(Duration.zero);
    if (lookupNotReady) return false;
    if (lookupFails) throw StateError('box peer $userId: lookup spent');
    session.takeServedAddresses(userId, serves?.call() ?? _served());
    return true;
  }

  /// Opens the store and connects. The handle lookup is wired once the
  /// connect's own pass has run, unless [lookupAtStart]: a pass that finds a
  /// lookup spends this process's one ask of the friend, and the friend's
  /// device may not be up yet.
  Future<void> start({bool lookupAtStart = false}) async {
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(userId);
    final state = friendState;
    if (state != null) await store.update(friendId, (_) => recordAs(state));
    await _connect(lookupAtStart);
  }

  /// A new process on the same storage: nothing in RAM survives (the served
  /// addresses, the lookups already made, what was handed this connect).
  Future<void> restart({bool lookupAtStart = false}) async {
    session.dispose();
    await _connect(lookupAtStart);
  }

  Future<void> _connect(bool lookupAtStart) async {
    session = BoxSession(
      box: BoxClient(
        baseUrl: 'http://box.test',
        socketFactory: box.sockets.call,
      ),
      store: store,
      emit: (event, _) => emitted.add(event),
      seal: QueueSeal(cipher: PointyGcmSealer()),
      now: () => clock,
      anchorOf: anchorOf,
    )..start();
    socket = box.sockets.last;
    session
      ..consumer = read
      ..encryptForFriend = encrypt
      ..friendLiveDevices = ((user) async =>
          user == friendId ? friendLive : null)
      ..friendRevokedDevices = ((user) async =>
          user == friendId ? friendRevoked : null)
      ..e2eReady();
    if (lookupAtStart) session.friendAddressLookup = _lookup;
    started = true;
    socket.serverConnect('S$userId.$deviceId');
    await settle();
    session.accountReady(deviceId);
    await settle();
    session.friendAddressLookup = _lookup;
  }

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

extension on BoxSession {
  /// Asks for a handoff pass the way production does after the connect's own:
  /// `e2eReady()` runs one (every other gate is open by then). A pass that
  /// finds one running makes another after it.
  void runPass() => e2eReady();
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
    a.peers.add(b);
    b.peers.add(a);
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
      a.session.runPass();
      b.session.runPass();
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
        ..e2eReady();
      await settle();
      expect(box.sent, hasLength(sends), reason: 'b already acked our queue');
      expect(a.friend.queues, hasLength(1));
    },
  );

  test(
    'a friend device that said it relays (rl, decision 101 A) keeps the mark '
    'on its address — even said before its handoff was stored — and the '
    'contact backup never carries it',
    () async {
      await a.start();
      await b.start();
      // No address yet: kept for the handoff to come.
      await a.session.friendRelays(5, 3, relays: true);
      a.session.runPass();
      b.session.runPass();
      await settle();

      expect(a.outboundOf(3)?.relays, isTrue);
      expect(b.outboundOf(2)?.relays, isFalse, reason: 'a said nothing yet');
      expect(a.friend.toJson()['outbound'], [containsPair('rl', true)]);
      final backedUp = a.friend.toBackupJson()['outbound'] as List<dynamic>;
      expect(backedUp.single, isNot(contains('rl')));

      // An address already held: written to the record.
      await b.session.friendRelays(1, 2, relays: true);
      await settle();
      expect(b.outboundOf(2)?.relays, isTrue);
    },
  );

  test(
    'a friend still on an old app gets nothing and costs no queue; once it '
    'updates, its handoff reaches us and we hand ours back with no reconnect',
    () async {
      await a.start();
      await b.start();
      // The lookup serves no request queue for it: an old app publishes none.
      a.serves = () => const [];
      a.session.runPass();
      await settle();
      expect(a.lookups, [5]);
      expect(a.friend.queues, isEmpty);
      expect(box.normalCreates(a.socket), 1, reason: 'the self-queue only');
      expect(box.sent, isEmpty);

      // b updates and looks a up: a's request queue is served, and a hears
      // nothing new from the box.
      b.session.runPass();
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
      a.session.runPass();
      await settle();

      expect(a.friend.queues, isEmpty);
      expect(box.normalCreates(a.socket), 1, reason: 'the self-queue only');
      expect(b.outboundOf(2), isNull);
    });
  }

  test(
    "a device the friend's verified list does not name live is handed "
    'nothing and costs no lookup, whatever a lookup would serve',
    () async {
      a.friendLive = {};
      await a.start();
      await b.start();
      a.session.runPass();
      await settle();

      expect(a.lookups, isEmpty);
      expect(b.outboundOf(2), isNull);
      expect(box.sent, isEmpty);
      expect(a.friend.queues, isEmpty, reason: 'nobody to hand one to');
    },
  );

  test(
    'a device that has not acknowledged yet is handed our queue once per '
    'connect, however many passes are asked for meanwhile',
    () async {
      await a.start();
      await b.start();
      b.deaf = true;
      a.session.runPass();
      await settle();
      a.session.runPass();
      await settle();

      final toB = b.store.requestQueue!.sid;
      expect(box.sent.where((sid) => sid == toB), hasLength(1));
    },
  );

  test(
    'a friend whose handoff could not be read for want of an anchor is '
    'handed our queue at once, not on the next connect or pass: our '
    'session build pins the anchor, so the pair converges in this pass (E20c)',
    () async {
      a.encryptFails = true;
      await a.start();
      await b.start();
      a.session.runPass();
      await settle();
      final toB = b.store.requestQueue!.sid;
      expect(box.sent.where((sid) => sid == toB), isEmpty);

      a.encryptFails = false;
      a.session.handOffTo(5);
      await settle();

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
      a.session.runPass();
      await settle();
      final toB = b.store.requestQueue!.sid;
      int handoffs() => box.sent.where((sid) => sid == toB).length;
      expect(handoffs(), 1);

      Future<void> reconnect() async {
        a.session
          ..accountLost()
          ..accountReady(2)
          ..e2eReady();
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
      a.session.runPass();
      await settle();
      final toB = b.store.requestQueue!.sid;
      int handoffs() => box.sent.where((sid) => sid == toB).length;
      expect(handoffs(), 1);

      Future<void> reconnect() async {
        a.session
          ..accountLost()
          ..accountReady(2)
          ..e2eReady();
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

  // Mutation: `friendHeard` checks only that a record exists, not that it is
  // a friend's.
  for (final state in [ContactState.blocked, ContactState.former]) {
    test(
      'a ${state.name} contact that still holds our queue and is heard from '
      'is not handed it again: its handoff stamp stays',
      () async {
        await a.start();
        await b.start();
        b.deaf = true;
        a.session.runPass();
        await settle();
        final toB = b.store.requestQueue!.sid;
        int handoffs() => box.sent.where((sid) => sid == toB).length;
        expect(handoffs(), 1);

        // A later connect that handed nothing: a friend heard now would be
        // handed the queue again at once.
        a.clock = a.clock.add(const Duration(hours: 1));
        a.session
          ..accountLost()
          ..accountReady(2)
          ..e2eReady();
        await settle();
        expect(handoffs(), 1);
        final handed = a.friend.queues.single.handedAt[3];
        expect(handed, isNotNull);

        await a.store.update(5, (c) => c!.copyWith(state: state));
        a.session.friendHeard(5, 3);
        await settle();

        expect(a.friend.state, state);
        expect(a.friend.queues.single.handedAt[3], handed);
        expect(handoffs(), 1);

        // The control: nothing but the state held it back.
        await a.store.update(
          5,
          (c) => c!.copyWith(state: ContactState.friend),
        );
        a.session.friendHeard(5, 3);
        await settle();
        expect(handoffs(), 2);
      },
    );
  }

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
      a.session.runPass();
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
      a.session.runPass();
      await settle();
      expect(a.friend.queues, hasLength(1));
      expect(box.sent, isEmpty);

      box.subscribeRefusal = null;
      a.session.runPass();
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
      a.session.runPass();
      await settle();
      a.session.handOffTo(5);
      await settle();
      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady();
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
      // What a handle lookup of each friend serves: its one request queue.
      final served = <int, ContactOutbound>{};
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
        served[f] = ContactOutbound(
          peerDeviceId: 1,
          // Nothing the fake box hands out (its sids fill 0x80 + n).
          sid: boxB64(
            Uint8List(32)
              ..[0] = 0xEE
              ..[1] = f,
          ),
          sealPub: boxB64(
            Uint8List(32)
              ..[0] = 0xEE
              ..[1] = f,
          ),
          idk: null,
        );
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
        ..encryptForFriend = ((user, device, json, {fresh = false, permit}) async =>
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
      session.friendAddressLookup = (user) async {
        session.takeServedAddresses(user, [served[user]!]);
        return true;
      };
      final before = socket.emitted.where((f) => f.event == 'subscribe').length;

      session.runPass();
      for (var i = 0; i < 10; i++) {
        await settle();
      }

      final rids = {
        for (final f in served.keys) store.byUserId(f)!.queues.single.rid,
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

  // Mutation: `rekeyFriend` emits `getFriends` again, or does not await the
  // lookup (no re-key goes out from what it named).
  test(
    'a re-key owed to a device this device has no address for awaits ONE '
    'handle lookup, however often it is provoked, and goes out from the '
    'request queue that lookup named — never a getFriends '
    '(found live: a friend whose app updated after our list was fetched)',
    () async {
      await a.start();
      await b.start();
      a.emitted.clear();

      await a.session.rekeyFriend(5, 3);
      await a.session.rekeyFriend(5, 3);
      await settle();

      expect(a.lookups, [5]);
      expect(a.emitted, isNot(contains('getFriends')));
      expect(a.freshFor, [3]);
      expect(
        box.sent,
        contains(b.store.requestQueue!.sid),
        reason: 'the re-key went to the request queue the lookup named',
      );
      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
    },
  );

  // Mutation: `rekeyFriend` drops the `_friendAddressAsked` guard: the
  // second call looks the friend up again.
  for (final spent in [false, true]) {
    test(
      'a re-key whose lookup names no address for the device '
      '(${spent ? 'a spent lookup' : 'nothing served'}) is given up for the '
      'session: no second lookup, however often it is provoked, and no '
      'getFriends (review: a stranger could otherwise loop)',
      () async {
        await a.start();
        await b.start();
        if (spent) {
          a.lookupFails = true;
        } else {
          a.serves = () => const [];
        }
        a.emitted.clear();

        await a.session.rekeyFriend(5, 3);
        a.session.runPass();
        await settle();
        await a.session.rekeyFriend(5, 3);
        a.session.runPass();
        await settle();

        expect(a.lookups, [5]);
        expect(a.emitted, isNot(contains('getFriends')));
        expect(a.freshFor, isEmpty);
        expect(a.friend.queues, isEmpty, reason: 'nothing was made or handed');
        expect(box.sent, isEmpty);
      },
    );
  }

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
      a.session.runPass();
      await settle();
      expect(a.friend.queues, isEmpty);
      expect(box.sent, isEmpty);

      box.createRefusal = null;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await settle();

      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
    },
  );

  /// A reconnect of [device]: the socket drops and comes back, a pass runs.
  Future<void> reconnect(_Device device) async {
    device.session
      ..accountLost()
      ..accountReady(device.deviceId)
      ..e2eReady();
    await settle();
  }

  // Mutation: `_pass` candidates back to "only friends holding an address":
  // nothing is looked up, nothing handed, neither side converges.
  test(
    'a connect that runs no further pass looks an unrouted friend up once '
    'and hands our queue to the request queue that lookup named: both sides '
    'converge (E114c)',
    () async {
      await b.start();
      await a.start(lookupAtStart: true);
      await settle();

      expect(a.lookups, [5]);
      expect(box.sent, contains(b.store.requestQueue!.sid));
      final aQueue = a.friend.queues.single;
      final bQueue = b.friend.queues.single;
      expect(b.outboundOf(2)?.sid, aQueue.sid);
      expect(a.outboundOf(3)?.sid, bQueue.sid);
      expect(aQueue.ackedBy, [3]);
      expect(bQueue.ackedBy, [2]);
    },
  );

  // Mutation: `_pass` looks a friend up whenever a handoff is due, without
  // asking whether that device has a target (drop `!targets.containsKey(d)`).
  test(
    'a friend whose every live device already has a held address costs ZERO '
    'lookups, across reconnects and passes',
    () async {
      await a.start();
      final held = ContactOutbound(
        peerDeviceId: 3,
        sid: boxB64(_bytes(32, 0xEE)),
        sealPub: boxB64(_bytes(32, 0xEF)),
        idk: null,
      );
      await a.store.update(5, (c) => c!.copyWith(outbound: [held]));

      for (var i = 0; i < 3; i++) {
        await reconnect(a);
        a.session.runPass();
        await settle();
      }

      expect(a.lookups, isEmpty);
      expect(
        box.sent.where((sid) => sid == held.sid),
        hasLength(1),
        reason: 'the handoff WAS due once: a lookup would have been allowed',
      );
    },
  );

  // Issue #208: a re-linked (or newly linked) device restores the friend's
  // address from the contact backup — the queue the friend made for ANOTHER
  // device of this account. A handoff there is a PreKey message (no session,
  // or one this device opened unanswered — the box connect's prebuild) the
  // friend refuses unasked (prod/dev 11-03, `prekey_unasked`), so the friend
  // never learned the new device and its messages never reached it.
  // Mutation: `_handoffTargets` keeps the held address whatever the answer.
  test(
    'a device of an enrolled account the friend device never answered hands '
    "off through that friend device's REQUEST queue, never the held "
    'address, and the friend takes it',
    () async {
      await b.start();
      await a.start();
      final held = ContactOutbound(
        peerDeviceId: 3,
        sid: boxB64(_bytes(32, 0xEE)),
        sealPub: boxB64(_bytes(32, 0xEF)),
        idk: null,
      );
      await a.store.update(5, (c) => c!.copyWith(outbound: [held]));
      a.session
        ..ownDeviceList = (() async => {'listVersion': 7})
        ..friendAnswered = ((_, _) async => false);

      a.session.runPass();
      await settle();

      expect(box.sent, isNot(contains(held.sid)));
      expect(box.sent, contains(b.store.requestQueue!.sid));
      expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
    },
  );

  // Mutation: `_handoffTargets` sends every held address to the request
  // queue (drops the answer check).
  test(
    'with a session the friend device answered behind the held address, the '
    'handoff takes that address and costs no lookup',
    () async {
      await b.start();
      await a.start();
      final held = ContactOutbound(
        peerDeviceId: 3,
        sid: boxB64(_bytes(32, 0xEE)),
        sealPub: boxB64(_bytes(32, 0xEF)),
        idk: null,
      );
      await a.store.update(5, (c) => c!.copyWith(outbound: [held]));
      a.session
        ..ownDeviceList = (() async => {'listVersion': 7})
        ..friendAnswered = ((_, _) async => true);

      a.session.runPass();
      await settle();

      expect(box.sent, contains(held.sid));
      expect(a.lookups, isEmpty);
    },
  );

  // Mutation: `_pass` drops the `_addressesAsked` guard
  // (`!_addressesAsked.contains(userId)`): every pass asks again.
  test(
    'however many passes and reconnects, a friend is looked up at '
    'most once per process — a spent lookup included',
    () async {
      await a.start();
      await b.start();
      a.lookupFails = true;

      for (var i = 0; i < 3; i++) {
        await reconnect(a);
        a.session.runPass();
        await settle();
      }
      expect(a.lookups, [5]);
      expect(box.sent, isEmpty);
    },
  );

  // Mutation: `_pass` drops `_lookupDue` (the persisted stamp is never read),
  // or neither `lookupAddresses` nor `takeServedAddresses` writes it.
  test(
    'a friend whose live device never gets a handoff is looked up once per '
    '24 h across processes, not once per process (decision 120, E114n)',
    () async {
      await a.start();
      await b.start();
      // A friend still on an app that published no request queue: nothing is
      // ever handed, so `handedAt` stays null and the handoff stays due.
      a.serves = () => const [];
      a.session.runPass();
      await settle();
      expect(a.lookups, [5]);

      for (var i = 0; i < 3; i++) {
        a.clock = a.clock.add(const Duration(hours: 1));
        await a.restart(lookupAtStart: true);
        await reconnect(a);
        expect(a.lookups, [5], reason: 'a new process inside the 24 h');
      }

      a.clock = a.clock.add(const Duration(hours: 24));
      await a.restart(lookupAtStart: true);
      await reconnect(a);
      expect(a.lookups, [5, 5], reason: 'a day on: asked once more');

      await a.restart(lookupAtStart: true);
      await reconnect(a);
      expect(a.lookups, [5, 5], reason: 'and that one restarts the 24 h');
    },
  );

  // Mutation: `lookupAddresses` writes the stamp only on an answer (drop the
  // write in its `catch`): an unanswered lookup is asked again at once.
  test(
    'a lookup that was made and failed counts toward the 24 h as well',
    () async {
      await a.start();
      await b.start();
      a.lookupFails = true;
      a.session.runPass();
      await settle();
      expect(a.lookups, [5]);

      await a.restart(lookupAtStart: true);
      await reconnect(a);
      expect(a.lookups, [5]);
    },
  );

  // Mutation: `takeServedAddresses` writes no stamp (only the pass's own
  // lookups count).
  test('a handle lookup that served the friend\'s addresses counts toward the '
      '24 h, whoever made it (the list fetch, an event)', () async {
    await a.start();
    await b.start();
    a.session.takeServedAddresses(5, const []);
    await settle();
    expect(a.store.friendLookedUpAt(5), isNotNull);

    a.clock = a.clock.add(const Duration(hours: 2));
    await a.restart(lookupAtStart: true);
    await reconnect(a);
    expect(a.lookups, isEmpty);
  });

  // Mutation: the stamp is compared without the clock-skew guard (a stamp in
  // the future blocks the lookup until the clock catches up), or
  // `noteFriendLookup` keeps a stamp later than the lookup's own (second
  // review: the future stamp stayed, so every start found the friend due).
  test('a stamp from the future (the clock went back) does not block the '
      'lookup', () async {
    await a.start();
    await b.start();
    a.serves = () => const [];
    a.session.runPass();
    await settle();
    expect(a.lookups, [5]);

    a.clock = a.clock.subtract(const Duration(days: 3));
    await a.restart(lookupAtStart: true);
    await reconnect(a);
    expect(a.lookups, [5, 5]);

    // The lookup the future stamp allowed replaced it: the next start at the
    // same clock is inside its own 24 h, one extra lookup and no more.
    await a.restart(lookupAtStart: true);
    await reconnect(a);
    expect(a.lookups, [5, 5]);
  });

  // Mutation: `_pass` does not prune (`pruneFriendLookups`), or the stamp is
  // kept per friend list instead of per friend.
  test('the stamp of an account that is no friend any more is dropped, and '
      'a friend\'s stamp is its own', () async {
    await a.start();
    await b.start();
    await a.store.noteFriendLookup(77, a.clock);
    expect(a.store.friendLookedUpAt(77), isNotNull);

    a.serves = () => const [];
    a.session.runPass();
    await settle();

    expect(a.store.friendLookedUpAt(77), isNull, reason: '77 is no friend');
    expect(a.store.friendLookedUpAt(5), isNotNull);
  });

  // Mutation: `lookupAddresses` keeps the friend in `_addressesAsked` when
  // the lookup answers false (drop the `remove`): the connect that found
  // E2E not ready never asks that friend again this process.
  test(
    'a lookup that could not be made yet (E2E not ready) spends nothing: the '
    'next pass asks again and the handoff then converges',
    () async {
      await b.start();
      a.lookupNotReady = true;
      await a.start(lookupAtStart: true);
      await settle();

      expect(a.lookups, [5]);
      expect(box.sent, isEmpty);
      expect(a.friend.queues, isEmpty);

      a.lookupNotReady = false;
      await reconnect(a);
      await settle();

      expect(a.lookups, [5, 5]);
      expect(box.sent, contains(b.store.requestQueue!.sid));
      expect(a.outboundOf(3)?.sid, b.friend.queues.single.sid);
    },
  );

  // Mutation (BOX-03): `rekeyFriend` keeps `_friendRekeyed` when it had no
  // queue to hand: that device is never re-keyed again this process, though
  // nothing was built or sent.
  test(
    'a re-key that had no queue to hand (the box made none) is made again by '
    'the next one',
    () async {
      box.createRefusal = {'ok': false, 'code': 'rate_limited'};
      await a.start();
      await b.start();
      expect(a.friend.queues, isEmpty);

      await a.session.rekeyFriend(5, 3);
      await settle();
      expect(a.freshFor, isEmpty);

      box.createRefusal = null;
      await a.session.rekeyFriend(5, 3);

      expect(a.freshFor, [3]);
      expect(box.sent, contains(b.store.requestQueue!.sid));
    },
  );

  // Mutation: `rekeyFriend` releases `_friendRekeyed` when the send was
  // refused, or `accountLost` clears it: whoever can forge a request-queue
  // frame and refuse a send, or drop the account socket, times a bundle
  // fetch per frame.
  test(
    'a re-key the box refused, and a reconnect, do not re-key that friend '
    'device again: one fresh session per friend device per session '
    '(decision 70)',
    () async {
      await a.start();
      await b.start();
      box.refuseSendsTo.add(b.store.requestQueue!.sid);
      await a.session.rekeyFriend(5, 3);
      await settle();
      expect(a.freshFor, [3]);

      box.refuseSendsTo.clear();
      await a.session.rekeyFriend(5, 3);
      a.session
        ..accountLost()
        ..accountReady(2)
        ..e2eReady();
      await settle();
      await a.session.rekeyFriend(5, 3);

      expect(a.freshFor, [3]);
    },
  );

  // Mutation: `rekeyFriend` sets the once-per-session `_friendRekeyed` mark
  // BEFORE it asks the gate: a re-key refused while the gate was closed is
  // then given up for the whole session.
  test(
    'a re-key during the closed gate is not sent and not marked: it goes '
    'out, once, when the gate opens',
    () async {
      await a.start();
      await b.start();
      var held = true;
      a.session.calmHeld = (_) => held;

      await a.session.rekeyFriend(5, 3);
      await settle();
      expect(a.freshFor, isEmpty, reason: 'nothing sealed while closed');

      held = false;
      await a.session.rekeyFriend(5, 3);
      await settle();
      expect(a.freshFor, [3], reason: 'not marked while closed');

      await a.session.rekeyFriend(5, 3);
      await settle();
      expect(a.freshFor, [3], reason: 'once per session after that');
    },
  );

  // Mutation: `rekeyFriend` keeps `_friendAddressAsked` when the lookup
  // answers false (drop the `remove`): a re-key provoked while E2E was not
  // ready is given up for the session.
  test(
    'a re-key whose lookup could not be made yet is asked again by the next '
    'one and goes out from what that lookup named',
    () async {
      await a.start();
      await b.start();
      a.lookupNotReady = true;

      await a.session.rekeyFriend(5, 3);
      expect(a.lookups, [5]);
      expect(a.freshFor, isEmpty);

      a.lookupNotReady = false;
      await a.session.rekeyFriend(5, 3);
      await settle();

      expect(a.lookups, [5, 5]);
      expect(a.freshFor, [3]);
      expect(box.sent, contains(b.store.requestQueue!.sid));
    },
  );

  // Mutation: `lookupAddresses` swallows the error again (no `_failed`), or
  // logs durably on every repeat.
  test(
    'a spent or unanswered address lookup is written to the durable log once '
    'per friend, however often it repeats',
    () async {
      await a.start();
      await b.start();
      a.lookupFails = true;

      await reconnect(a);
      await a.session.rekeyFriend(5, 3);
      await settle();

      final failed = E2ePersistentDiag.entries
          .where((e) => e.contains('BOX_FRIEND_HANDOFF_FAILED'))
          .where((e) => e.contains('stage: lookup'))
          .toList();
      expect(a.lookups.length, greaterThan(1));
      expect(failed, hasLength(1));
      expect(failed.single, contains('code: StateError'));
    },
  );

  // Mutation: `_pass` ignores `_handoffDue` when it decides to look up: the
  // connect an hour after a handoff asks again.
  test(
    'a live device with no address whose handoff is NOT due (handed an hour '
    'ago, not acknowledged) costs no lookup on the next connect; once a day '
    'has passed it costs exactly one',
    () async {
      await a.start();
      await b.start();
      b.deaf = true;
      a.session.runPass();
      await settle();
      final toB = b.store.requestQueue!.sid;
      int handoffs() => box.sent.where((sid) => sid == toB).length;
      expect(handoffs(), 1);
      expect(a.friend.queues.single.handedAt, contains(3));
      a.lookups.clear();

      // A new process, an hour on: the record says handed, not acked, and
      // the address the last lookup served is gone from RAM.
      a.clock = a.clock.add(const Duration(hours: 1));
      await a.restart(lookupAtStart: true);
      await reconnect(a);
      expect(a.lookups, isEmpty);
      expect(handoffs(), 1);
      expect(a.outboundOf(3), isNull);

      a.clock = a.clock.add(const Duration(hours: 24));
      await reconnect(a);
      await reconnect(a);
      expect(a.lookups, [5]);
      expect(handoffs(), 2, reason: 'handed again, to the address served');
    },
  );

  // Mutation: `_pass` drops `if (targets.isEmpty) continue` (a queue is made
  // and handed for a device nothing is known about) or looks up again.
  test(
    'a lookup that serves nothing for a device (an old app) leaves no queue '
    'made and nothing sent, and costs no further lookup in that process',
    () async {
      await a.start();
      await b.start();
      a.serves = () => const [];

      await reconnect(a);
      await reconnect(a);
      a.session.runPass();
      await settle();

      expect(a.lookups, [5]);
      expect(a.friend.queues, isEmpty);
      expect(box.normalCreates(a.socket), 1, reason: 'the self-queue only');
      expect(box.sent, isEmpty);
      expect(a.outboundOf(3), isNull);
    },
  );

  // Mutation: `noteRoutes()` dropped from `_pass` (no line after the pass) or
  // from `_takeHandoff` (no line when a handoff is taken), or its
  // `now == _routesLogged` check dropped (a second line for the same numbers).
  test(
    'BOX_ROUTES is written to the durable log after the pass and again when '
    "a friend's handoff is taken, with the right counts, and never twice for "
    'the same numbers',
    () async {
      List<String> routes() => [
        for (final e in E2ePersistentDiag.entries)
          if (e.contains(' BOX_ROUTES | ')) e.split(' | ').last,
      ];

      await a.start();
      expect(routes(), ['{friends: 1, routed: 0, owed: 1}']);

      // A second friend, no device of it known live.
      await a.store.update(
        7,
        (_) => const ContactRecord(
          userId: 7,
          username: 'friend7',
          tag: '0007',
          state: ContactState.friend,
        ),
      );
      a.session.runPass();
      await settle();
      a.session.runPass();
      await settle();
      expect(routes(), [
        '{friends: 1, routed: 0, owed: 1}',
        '{friends: 2, routed: 0, owed: 2}',
      ]);

      final handoff = (
        sid: boxB64(_bytes(32, 0xEE)),
        sealPub: boxB64(_bytes(32, 0xEF)),
      );
      expect(
        await a.session.takeFriendHandoff(
          5,
          3,
          sid: handoff.sid,
          sealPub: handoff.sealPub,
          learnedUnder: null,
        ),
        FriendWrite.stored,
      );
      await settle();
      expect(routes().last, '{friends: 2, routed: 1, owed: 1}');
      expect(routes(), hasLength(3));

      // The same handoff again, and another pass: the numbers did not move.
      await a.session.takeFriendHandoff(
        5,
        3,
        sid: handoff.sid,
        sealPub: handoff.sealPub,
        learnedUnder: null,
      );
      a.session.runPass();
      await settle();
      expect(routes(), hasLength(3));
    },
  );

  // Mutation: `retireAccountQueues` skips its loop over the contacts'
  // queues (or over the retiring self-queues, or the own two).
  test(
    'retireAccountQueues deletes every queue this device holds from the box '
    '— request queue, self-queue, a retiring self-queue, and every contact '
    "queue, a friend's retired one too — and its contacts keep none",
    () async {
      await a.start();
      final request = a.store.requestQueue!;
      final self = a.store.selfQueue!;
      final friendQueue = _queue(0x10);
      final friendRetired = _queue(0x20).retired(a.clock);
      final otherFriendQueue = _queue(0x30);
      await a.store.update(
        5,
        (c) => c!.copyWith(queues: [friendQueue, friendRetired]),
      );
      await a.store.update(
        7,
        (_) => ContactRecord(
          userId: 7,
          username: 'friend7',
          tag: '0007',
          state: ContactState.friend,
          queues: [otherFriendQueue],
        ),
      );
      // The self-queue rotated: `self` retires, `current` leads.
      final current = _queue(0x40);
      expect(
        await a.store.rotateSelfQueue(
          current,
          replaces: self.rid,
          live: const {},
          now: a.clock,
        ),
        isNotNull,
      );
      expect(a.store.retiringSelfQueues, hasLength(1));

      await a.session.retireAccountQueues();

      final deleted = [
        for (final f in a.socket.emitted)
          if (f.event == 'deleteQueue') f.frame['rid'],
      ];
      expect(
        deleted,
        unorderedEquals([
          for (final q in [
            request,
            self,
            current,
            friendQueue,
            friendRetired,
            otherFriendQueue,
          ])
            q.rid,
        ]),
      );
      expect(a.store.byUserId(5)!.queues, isEmpty);
      expect(a.store.byUserId(7)!.queues, isEmpty);
      expect(a.store.retiringSelfQueues, isEmpty);
    },
  );

  // Mutation: drop the deadline from `retireRevokedDevice`'s `keepGoing`.
  test(
    'retireRevokedDevice deletes nothing more once its wait is spent, even '
    'with the box reached in time: the rest stays owed in boxgone_v1',
    () async {
      await a.start();
      await a.store.update(
        5,
        (c) => c!.copyWith(queues: [_queue(0x10), _queue(0x20)]),
      );
      // Every delete takes longer than the whole wait.
      final route = box.sockets.respond!;
      box.sockets.respond = (socket, f) {
        if (f.event == 'deleteQueue') {
          a.clock = a.clock.add(const Duration(seconds: 20));
        }
        return route(socket, f);
      };

      await a.session.retireRevokedDevice(proceed: Future.value(true));

      expect(
        a.socket.emitted.where((f) => f.event == 'deleteQueue'),
        hasLength(1),
      );
    },
  );

  // Mutation: await each delete without the deadline in `_retireQueues`.
  test(
    'retireRevokedDevice stops waiting on a delete the box never answers '
    'once its wait is spent (issue #208: the link waits on it)',
    () async {
      await a.start();
      await a.store.update(
        5,
        (c) => c!.copyWith(queues: [_queue(0x10), _queue(0x20)]),
      );
      final route = box.sockets.respond!;
      box.sockets.respond = (socket, f) =>
          f.event == 'deleteQueue' ? null : route(socket, f);

      final watch = Stopwatch()..start();
      await a.session
          .retireRevokedDevice(
            proceed: Future.value(true),
            wait: const Duration(milliseconds: 200),
          )
          .timeout(const Duration(seconds: 5));

      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(
        a.socket.emitted.where((f) => f.event == 'deleteQueue'),
        hasLength(1),
      );
    },
  );

  // Issue #208. Mutations: drop `_oweDeletes` from `retireRevokedDevice`;
  // drop `_deleteOwedQueues` from the ready box.
  test(
    'a delete the box did not confirm in the wait stays owed, and the next '
    "session's ready box deletes it instead of leaving it to the reaper",
    () async {
      await a.start();
      final first = _queue(0x10);
      final second = _queue(0x20);
      await a.store.update(
        5,
        (c) => c!.copyWith(queues: [first, second]),
      );
      final route = box.sockets.respond!;
      box.sockets.respond = (socket, f) =>
          f.event == 'deleteQueue' ? null : route(socket, f);

      await a.session.retireRevokedDevice(
        proceed: Future.value(true),
        wait: const Duration(milliseconds: 200),
      );
      expect(
        (await a.store.owedQueueDeletes()).map((q) => q.rid),
        containsAll([first.rid, second.rid]),
      );

      box.sockets.respond = route;
      await a.restart();

      expect(
        a.socket.emitted
            .where((f) => f.event == 'deleteQueue')
            .map((f) => f.frame['rid']),
        containsAll([first.rid, second.rid]),
      );
      expect(await a.store.owedQueueDeletes(), isEmpty);
    },
  );

  group('slice (e): device announcements', () {
    test(
      "a handoff into a friend's REQUEST queue carries this account's list "
      'outside Signal; a hand-back into the queue the friend handed us '
      'carries none (decision 50)',
      () async {
        await a.start();
        await b.start();
        a.session.ownDeviceList = () async => {'listVersion': 7};
        b.session.ownDeviceList = () async => {'listVersion': 9};

        a.session.runPass();
        await settle();

        expect(b.carried, [
          jsonEncode({'listVersion': 7}),
        ]);
        expect(a.carried, isEmpty, reason: "b's hand-back rode a's queue");
        expect(b.outboundOf(2)?.sid, a.friend.queues.single.sid);
      },
    );

    group('with a friend on two devices', () {
      late _Device b2;

      setUp(() async {
        b2 = _Device(5, 4, 1, box)..friendLive = {2};
        a.peers.add(b2);
        b2.peers.add(a);
        a.friendLive = {3, 4};
        await a.start();
        await b.start();
        await b2.start();
        a.session.runPass();
        await settle();
        expect(a.friend.queues.single.ackedBy, unorderedEquals([3, 4]));
      });

      tearDown(() => b2.session.dispose());

      test(
        'a device the held list merely does not name — another tab may hold '
        'a newer list — keeps its address and our queue (E50e names only '
        'REVOKED devices)',
        () async {
          final old = a.friend.queues.single;
          a.friendLive = {4};
          a.session.friendDevicesChanged(5);
          await settle();

          expect(a.friend.queues.single.sid, old.sid);
          expect(a.outboundOf(3), isNotNull);
        },
      );

      test(
        'a revoke drops the revoked address and ROTATES our queue: the new '
        'one goes to the surviving device only, the old one retires, still '
        'read, and is deleted once the box TTL has passed (E50e)',
        () async {
          final old = a.friend.queues.single;
          a
            ..friendLive = {4}
            ..friendRevoked = {3};
          a.session.friendDevicesChanged(5);
          await settle();

          final queues = a.friend.queues;
          expect(queues, hasLength(2));
          expect(queues.first.sid, isNot(old.sid));
          expect(queues.first.retiredAt, isNull);
          expect(queues.first.ackedBy, [4]);
          expect(queues.last.rid, old.rid);
          expect(queues.last.retiredAt, a.clock);
          expect(b2.outboundOf(2)?.sid, queues.first.sid);
          expect(
            b.outboundOf(2)?.sid,
            old.sid,
            reason: 'the revoked device never learns the new queue',
          );
          expect(a.outboundOf(3), isNull);
          expect(a.outboundOf(4), isNotNull);

          // Once rotated, a later pass leaves it be.
          a.session.friendDevicesChanged(5);
          await settle();
          expect(a.friend.queues, hasLength(2));

          a.clock = a.clock.add(kBoxRedeliveryWindow);
          a.session.friendDevicesChanged(5);
          await settle();
          expect(a.friend.queues, hasLength(2), reason: 'not past it yet');

          // The box already reaped it: a delete answers `auth_failed`
          // ("gone", decision 10), which still counts as deleted.
          box.deleteRefusal = {'ok': false, 'code': 'auth_failed'};
          a.clock = a.clock.add(const Duration(minutes: 1));
          a.session.friendDevicesChanged(5);
          await settle();
          expect(a.friend.queues.single.sid, queues.first.sid);
          expect(
            a.socket.emitted.where((f) => f.event == 'deleteQueue'),
            hasLength(1),
          );
        },
      );

      test(
        'our list goes as a list_update to every live device of the friend '
        'we hold an address for, and only a box that took every frame '
        'counts as announced (E50d)',
        () async {
          expect(await a.session.announceOwnList({'listVersion': 4}), isTrue);
          await settle();
          expect(b.listUpdates, [
            {'listVersion': 4},
          ]);
          expect(b2.listUpdates, [
            {'listVersion': 4},
          ]);

          a.friendLive = {3};
          expect(await a.session.announceOwnList({'listVersion': 5}), isTrue);
          await settle();
          expect(b2.listUpdates, hasLength(1), reason: 'no longer live');

          a.encryptFails = true;
          expect(await a.session.announceOwnList({'listVersion': 6}), isFalse);
        },
      );

      test(
        'a retried announcement goes only to the devices that did not take '
        'it: one unreachable friend device costs the others no second blob',
        () async {
          final b2Sid = a.outboundOf(4)!.sid;
          box.refuseSendsTo.add(b2Sid);
          expect(await a.session.announceOwnList({'listVersion': 4}), isFalse);
          await settle();
          expect(b.listUpdates, hasLength(1));
          expect(b2.listUpdates, isEmpty);

          box.refuseSendsTo.clear();
          expect(await a.session.announceOwnList({'listVersion': 4}), isTrue);
          await settle();
          expect(b.listUpdates, hasLength(1));
          expect(b2.listUpdates, hasLength(1));
        },
      );

      test(
        'an own list too long for the frame never stops a handoff: it goes '
        'out without the list',
        () async {
          final b3 = _Device(5, 6, 1, box)..friendLive = {2};
          await b3.start();
          addTearDown(b3.session.dispose);
          // A device that published its request queue after this process
          // looked the friend up is learned by a later process — one a day on,
          // since a lookup of this friend inside 24 h is not repeated (E114n).
          a
            ..peers.add(b3)
            ..friendLive = {3, 4, 6}
            ..clock = a.clock.add(kFriendLookupInterval);
          b3.peers.add(a);
          await a.restart();
          a.session.ownDeviceList = () async => {'pad': 'x' * 20000};
          a.session.runPass();
          await settle();

          expect(b3.outboundOf(2)?.sid, a.friend.queues.single.sid);
          expect(b3.carried, isEmpty);
        },
      );

      test(
        'a stale-view answer goes only into the queue that device handed '
        'us, never its request queue (E50f)',
        () async {
          expect(
            await a.session.sendListUpdate(5, 4, {'listVersion': 2}),
            isTrue,
          );
          await settle();
          expect(b2.listUpdates, [
            {'listVersion': 2},
          ]);

          // Device 4's queue forgotten: only its request queue is known.
          await a.store.update(
            5,
            (current) => current!.copyWith(
              outbound: [
                for (final o in current.outbound)
                  if (o.peerDeviceId != 4) o,
              ],
            ),
          );
          expect(
            await a.session.sendListUpdate(5, 4, {'listVersion': 3}),
            isFalse,
          );
          await settle();
          expect(b2.listUpdates, hasLength(1));
        },
      );
    });
  });

  group('the friend write gate (slice 2)', () {
    /// A second session on [a]'s store whose pinned identity is [anchor].
    BoxSession gated(String? Function(int) anchor, {bool wired = true}) {
      final s = BoxSession(
        box: BoxClient(
          baseUrl: 'http://box.test',
          socketFactory: box.sockets.call,
        ),
        store: a.store,
        emit: (event, _) {},
        seal: QueueSeal(cipher: PointyGcmSealer()),
        now: () => a.clock,
        anchorOf: anchor,
      )..start();
      if (wired) {
        s
          ..consumer = ((_) async => true)
          ..e2eReady();
      }
      return s;
    }

    Future<ContactOutbound> tagged(String idk) async {
      await a.store.update(
        5,
        (c) => c!.copyWith(
          outbound: [for (final o in c.outbound) o.copyWith(idk: idk)],
        ),
      );
      return a.friend.outbound.single;
    }

    Future<void> met() async {
      await a.start();
      await b.start();
      a.session.runPass();
      b.session.runPass();
      await settle();
    }

    test('deliver without permit is refused', () async {
      await met();
      final to = a.friend.outbound.single;
      expect(
        await a.session.deliver(to, Uint8List.fromList([1, 2, 3])),
        BoxSendOutcome.failed,
      );
      final permit = a.session.permitFor(5, to: [to]);
      expect(permit, isNotNull);
      expect(
        await a.session.deliverFriend(
          to,
          Uint8List.fromList([1, 2, 3]),
          permit: permit,
        ),
        BoxSendOutcome.taken,
      );
    });

    test('send between E2E ready and the first journal drain waits; the '
        'empty journal opens the gate', () async {
      await met();
      final to = await tagged('A');
      final s = gated((_) => 'A', wired: false)..e2eReady();
      expect(s.permitFor(5, to: [to]), isNull, reason: 'no reader wired yet');
      s.consumer = (_) async => true;
      await settle();
      expect(s.permitFor(5, to: [to]), isNotNull, reason: 'empty journal');
      s.dispose();
    });

    test('an address tagged with another identity than the pin is refused, '
        'and a permit sealed before the pin moved is not written', () async {
      await met();
      final to = await tagged('A');
      var anchor = 'A';
      final s = gated((_) => anchor);
      await settle();
      final permit = s.permitFor(5, to: [to])!;
      anchor = 'B';
      expect(s.permitFor(5, to: [to]), isNull, reason: 'old address is stale');
      expect(
        await s.deliverFriend(to, Uint8List.fromList([9]), permit: permit),
        BoxSendOutcome.failed,
        reason: 'sealed under A, written after the move to B',
      );
      s.dispose();
    });

    test('first message to a friend with no anchor goes out', () async {
      a.anchorOf = (_) => null;
      await met();
      final to = a.friend.outbound.single;
      final permit = a.session.permitFor(5, to: [to])!;
      expect(permit.firstPin, isTrue);
      expect(
        await a.session.deliverFriend(
          to,
          Uint8List.fromList([9]),
          permit: permit,
        ),
        BoxSendOutcome.taken,
      );
    });

    test('a write to a sibling or own queue is never gated', () async {
      await met();
      final other = ContactOutbound(
        peerDeviceId: 9,
        sid: a.friend.outbound.single.sid,
        sealPub: a.friend.outbound.single.sealPub,
        idk: null,
      );
      // Not a stored friend address of anyone else: an unknown sid with no
      // owner is the sibling/self lane, which the gate leaves alone.
      final foreign = ContactOutbound(
        peerDeviceId: 9,
        sid: boxB64(Uint8List(32)),
        sealPub: other.sealPub,
        idk: null,
      );
      final s = gated((_) => 'A', wired: false);
      expect(
        await s.deliver(foreign, Uint8List.fromList([1])),
        isNot(equals(null)),
      );
      s.dispose();
    });

    /// The connected session of [a], with the friend's pin read from
    /// [anchor].
    Future<void> metWithAnchor(String Function() anchor) async {
      a.anchorOf = (_) => anchor();
      await met();
    }

    Future<BoxSendOutcome> write(ContactOutbound to, FriendPermit? permit) =>
        a.session.deliverFriend(
          to,
          Uint8List.fromList([9]),
          permit: permit,
        );

    test('a permit sealed under the old pin is not written once the SAME '
        'address is re-tagged under the new one', () async {
      var pin = 'A';
      await metWithAnchor(() => pin);
      var to = await tagged('A');
      final permit = a.session.permitFor(5, to: [to])!;
      expect(
        await write(to, permit),
        BoxSendOutcome.taken,
        reason: 'the session writes while nothing moved',
      );
      // The friend kept its queue and announced it again under B (the
      // re-tag): the address is current for B, only the permit is old.
      pin = 'B';
      to = await tagged('B');
      expect(a.session.permitFor(5, to: [to]), isNotNull, reason: 'current');
      expect(
        await write(to, permit),
        BoxSendOutcome.failed,
        reason: 'sealed under A, written after the pin moved to B',
      );
    });

    test('a calm hold closes the gate, and a permit taken before it is not '
        'written during it', () async {
      await metWithAnchor(() => 'A');
      final to = await tagged('A');
      var held = false;
      a.session.calmHeld = (_) => held;
      final permit = a.session.permitFor(5, to: [to])!;
      held = true;
      expect(a.session.permitFor(5, to: [to]), isNull, reason: 'none held');
      expect(
        await write(to, permit),
        BoxSendOutcome.failed,
        reason: 'sealed before the hold, written during it',
      );
      held = false;
      expect(
        await write(to, permit),
        BoxSendOutcome.taken,
        reason: 'the hold ended',
      );
    });

    test('an address the friend no longer holds gets no permit and no '
        'write, though it was current when the permit was taken', () async {
      await metWithAnchor(() => 'A');
      final to = await tagged('A');
      final permit = a.session.permitFor(5, to: [to])!;
      // The friend's handoff replaced the address: the old sid is nobody's
      // now.
      final replaced = ContactOutbound(
        peerDeviceId: to.peerDeviceId,
        sid: boxB64(Uint8List(32)..fillRange(0, 32, 7)),
        sealPub: to.sealPub,
        idk: 'A',
      );
      await a.store.update(5, (c) => c!.copyWith(outbound: [replaced]));
      expect(a.session.permitFor(5, to: [to]), isNull, reason: 'not held');
      expect(
        await write(to, permit),
        BoxSendOutcome.failed,
        reason: "the old queue is no longer the friend's",
      );
      final framed = Uint8List.fromList(List.filled(kBoxMediaLadder.first, 1));
      expect(
        await a.session.uploadMediaFriend(to, framed, permit: permit),
        isA<BoxRefused>(),
        reason: 'nor is a media upload charged to it',
      );
    });

    test('with the gate closed for a friend, a write and an upload to the '
        'own queue (a sibling lane) still go through', () async {
      await metWithAnchor(() => 'A');
      final friendTo = await tagged('A');
      a.session.calmHeld = (_) => true;
      expect(a.session.permitFor(5, to: [friendTo]), isNull, reason: 'closed');
      expect(
        await write(friendTo, null),
        BoxSendOutcome.failed,
        reason: 'a friend write is refused',
      );
      final self = a.store.selfQueue!;
      final own = ContactOutbound(
        peerDeviceId: 9,
        sid: self.sid,
        sealPub: self.sealPub,
        idk: null,
      );
      expect(
        await a.session.deliver(own, Uint8List.fromList([1])),
        BoxSendOutcome.taken,
      );
      final framed = Uint8List.fromList(List.filled(kBoxMediaLadder.first, 1));
      // The fake box has no media route (an unknown answer): what matters is
      // that the gate did not refuse it.
      expect(
        await a.session.uploadMedia(own, framed),
        isNot(isA<BoxRefused>()),
        reason: 'an own-queue upload is never gated',
      );
    });
  });
}
