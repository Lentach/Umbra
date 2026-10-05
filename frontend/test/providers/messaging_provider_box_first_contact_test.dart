import 'dart:async';
import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/box_fakes.dart';

/// Metadata-privacy slice (f), first contact, on REAL Signal and the real
/// client chain: two strangers' `BoxSession`s over one routing box, each
/// read by the shipped `MessagingProvider` over a real
/// `EncryptionProvider`. Nothing is stood in but the box server (it routes
/// a `send` to whoever subscribed the sid) and the account socket (it
/// answers the own-list lookup and records every other emit — the
/// server must never hear of the pair).
class _Enc extends EncryptionProvider {
  bool ready = true;

  @override
  bool get isE2EReady => ready;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  bool get ownDeviceIdConfirmed => true;

  List<int>? ownLive;
  int? ownId;
  final Set<int> extraChanged = {};
  VerifiedDeviceList? servedList;

  @override
  Future<VerifiedDeviceList> adoptServedAccount(
    int userId, {
    required String identityKey,
    required Map<String, dynamic>? authorization,
  }) async {
    final real = await super.adoptServedAccount(
      userId,
      identityKey: identityKey,
      authorization: authorization,
    );
    return servedList ?? real;
  }

  @override
  Set<int> get peersWithChangedIdentity => {
    ...super.peersWithChangedIdentity,
    ...extraChanged,
  };

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) =>
      ownLive != null && userId == ownId
      ? VerifiedDeviceList.enrolled(
          version: 1,
          listHash: 'H' * 44,
          devices: [
            for (final d in ownLive!)
              DeviceListEntry(deviceId: d, platform: 'test', addedAtMs: 0),
          ],
        )
      : super.cachedDeviceList(userId);
}

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

/// A box that routes a `send` to whichever socket subscribed that sid.
class _RoutingBox {
  _RoutingBox() {
    sockets.respond = (socket, f) {
      switch (f.event) {
        case 'createQueue':
          final n = ++_queues;
          final rid = boxB64(_bytes(n));
          final sid = boxB64(_bytes(0x80 + n));
          _ridOfSid[sid] = rid;
          return {
            'ok': true,
            'rid': rid,
            'sid': sid,
            'nid': boxB64(_bytes(0x40 + n).sublist(0, 16)),
          };
        case 'subscribe':
          for (final s in f.frame['subs']! as List<Object?>) {
            _reader[(s! as Map)['rid']! as String] = socket;
          }
          return {'ok': true, 'refused': <Object?>[]};
        case 'send':
          final rid = _ridOfSid[f.frame['sid']];
          final reader = rid == null ? null : _reader[rid];
          if (reader != null) {
            final id = boxB64(_bytes(++_messages).sublist(0, 16));
            final blob = f.frame['blob'];
            Timer.run(() => reader.push({'rid': rid, 'id': id, 'blob': blob}));
          }
          return {'ok': true};
        default:
          return {'ok': true};
      }
    };
  }

  static List<int> _bytes(int n) => List.generate(32, (i) => (n + i) & 0xff);

  final FakeBoxSockets sockets = FakeBoxSockets();
  final Map<String, String> _ridOfSid = {};
  final Map<String, FakeBoxSocket> _reader = {};
  int _queues = 0;
  int _messages = 0;
}

/// One account with one device (device 1, never enrolled: the default
/// population), its store, box session and reader.
class _Side {
  _Side(this.userId, this.name, this.box);

  final int userId;
  final String name;
  final _RoutingBox box;
  final _Enc enc = _Enc();
  late final ContactStore store;
  late final BoxSession session;
  late final MessagingProvider reader;
  final ConversationsProvider chats = ConversationsProvider();

  /// Every account-socket event this device emitted, with its payload.
  final List<(String, Object?)> emitted = [];

  /// Every handle this device looked up (the accept-time check).
  final List<String> lookups = [];

  /// What a lookup of [lookups] answers.
  List<Object?>? Function(String handle)? answer;

  int _otp = 0;

  String get tag => '000$userId';

  Future<void> start() async {
    enc.setEmitCallback((event, data) {
      emitted.add((event, data));
      if (event == 'checkOwnKeyBundle') {
        enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'getDeviceList' && data is Map && data['userId'] == userId) {
        Timer.run(
          () => enc.onDeviceList({'userId': userId, 'authorization': null}),
        );
      }
    });
    await enc.initializeE2E(userId);
    store = ContactStore(
      open: () async => _MemKv(),
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(userId);
    await store.setSelf(UserModel(id: userId, username: name, tag: tag));
    enc
      ..keepsDeviceListFor = ((peer) => store.byUserId(peer) != null)
      ..isBoxOnlyPeer = ((peer) => store.byUserId(peer)?.boxOrigin != null)
      ..servedBundleFor = ((peer, device) =>
          store.byUserId(peer)?.boxOrigin?.bundles[device]);
    session = BoxSession(
      box: BoxClient(
        baseUrl: 'http://box.test',
        socketFactory: box.sockets.call,
      ),
      store: store,
      emit: (event, data) {
        emitted.add((event, data));
        if (event == 'setRequestQueue') {
          Timer.run(() => session.onRequestQueueSet({'success': true}));
        }
      },
      seal: QueueSeal(cipher: PointyGcmSealer()),
    )..start();
    chats
      ..contactStore = store
      ..setCurrentUserId(userId);
    reader = MessagingProvider()
      ..setConversationsProvider(chats)
      ..setEncryptionProvider(enc)
      ..setCurrentUserId(userId)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback((event, data) => emitted.add((event, data)))
      ..boxOutbox = session
      ..boxSiblings = session
      ..boxFriends = session
      ..boxFirstContact = session
      ..lookupHandle = (handle) async {
        lookups.add(handle);
        return answer?.call(handle);
      }
      // What `FriendsProvider.onBoxFriendshipEnded` reaches through
      // `ConnectionProvider`: the chat goes, and its history with it.
      ..onBoxFriendshipEnded = removeChatWith;
    enc.lookupBoxPeerList = reader.lookupBoxPeerList;
    session
      ..consumer = ((entry) =>
          reader.consumeBoxEntry(entry, store.byUserId(entry.peerUserId)))
      ..encryptForOwnDevice = reader.encryptForOwnDevice
      ..ownLiveDevices = reader.ownLiveDevices
      ..encryptForFriend = reader.encryptForFriend
      ..friendLiveDevices = reader.friendLiveDevices
      ..ownDeviceList = reader.ownDeviceList
      ..friendRevokedDevices = reader.friendRevokedDevices
      ..e2eReady();
    box.sockets.last.serverConnect('S$userId');
    await settle();
    session.accountReady(1);
    await settle();
    expect(session.onBox, isTrue, reason: '$name publishes its request queue');
  }

  /// `ConnectionProvider`'s `onRemoveConversationsForUser` for [peer].
  void removeChatWith(int peer) => reader.onConversationsRemovedForUser(
    chats.removeConversationsForUser(peer),
  );

  /// `FriendsProvider.unfriend` / `blockUser` for a friend made over the box.
  Future<void> endWith(int peer, {required bool block}) async {
    await reader.endBoxFriendship(peer, block: block);
    removeChatWith(peer);
  }

  /// This account as `searchUsersResult` serves it: its one device with a
  /// claimed bundle (a fresh one-time pre-key per search) and its request
  /// queue; never enrolled, so no `authorization`.
  Map<String, dynamic> get searchEntry {
    final upload = enc.encryptionService.getKeysForUpload()!;
    final otp = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>()[_otp++];
    return {
      'id': userId,
      'username': name,
      'tag': tag,
      'authorization': null,
      'devices': [
        {
          'deviceId': 1,
          'bundle': {
            ...(upload['keyBundle'] as Map).cast<String, dynamic>(),
            'oneTimePreKeyId': otp['keyId'],
            'oneTimePreKeyPublic': otp['publicKey'],
          },
          'requestSid': store.requestQueue!.sid,
          'sealPub': store.requestQueue!.sealPub,
        },
      ],
    };
  }

  ContactRecord? recordOf(int peer) => store.byUserId(peer);

  /// Any event that would tell the server this device knows [peer].
  List<String> namedToServer(int peer) => [
    for (final (event, data) in emitted)
      if (event != 'setRequestQueue' &&
          event != 'checkOwnKeyBundle' &&
          event != 'uploadKeyBundle' &&
          event != 'uploadOneTimePreKeys' &&
          (jsonEncode(data).contains('$peer') ||
              event.contains('Friend') ||
              event == 'fetchPreKeyBundle'))
        event,
  ];

  /// A chat message from this device to [peer] over the box, the way a
  /// box send frames it (the routing is under test here, not the composer).
  Future<void> sendText(int peer, String text) async {
    final to = store.byUserId(peer)!.outbound.single;
    final frame = await reader.encryptForFriend(
      peer,
      to.peerDeviceId,
      jsonEncode(
        E2eEnvelope.build(
          text,
          msgId: 'wire${text.hashCode.abs()}',
          sentAt: DateTime.now().toUtc(),
        ),
      ),
    );
    expect(frame, isNotNull, reason: '$name encrypts to $peer');
    expect(await session.deliver(to, frame!.encode()), BoxSendOutcome.taken);
  }

  /// The texts [peer] sent this device, as their stored records hold them,
  /// oldest first.
  Future<List<String>> textsFrom(int peer) async {
    final records = await enc.localMessageRecords(localConversationIdFor(peer));
    final ids = records.keys.toList()..sort();
    return [
      for (final id in ids)
        if (records[id]!['senderId'] == peer) records[id]!['content'] as String,
    ];
  }
}

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RoutingBox box;
  late _Side alice;
  late _Side bob;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    box = _RoutingBox();
    alice = _Side(1, 'alice', box);
    bob = _Side(5, 'bob', box);
    await alice.start();
    await bob.start();
  });

  // Every test's last step may leave a delivery in flight (an accept's
  // handoff into the requester's queue): it must be read before the next
  // setUp resets the secure-storage mock under its decrypt.
  tearDown(() async {
    await settle();
    alice.session.dispose();
    bob.session.dispose();
    await settle();
  });

  /// Alice asks, Bob accepts: both friends over the box.
  Future<void> befriend() async {
    await alice.reader.sendBoxFriendRequest(bob.searchEntry);
    await settle();
    bob.answer = (_) => [alice.searchEntry];
    await bob.reader.acceptBoxFriendRequest(1);
    await settle();
    expect(alice.recordOf(5)?.state, ContactState.friend);
    expect(bob.recordOf(1)?.state, ContactState.friend);
  }

  test(
    "an unfriend over the box says goodbye: the friend's record goes on "
    'both sides and our queue for it is deleted, with no server event',
    () async {
      await befriend();
      final bobQueue = bob.recordOf(1)!.queues.single.rid;
      await alice.sendText(5, 'before');
      await bob.sendText(1, 'before too');
      await settle();
      expect(await bob.textsFrom(1), ['before']);

      await alice.endWith(5, block: false);
      await settle();

      expect(alice.recordOf(5), isNull);
      expect(bob.recordOf(1), isNull);
      // The chat goes with its history on both sides: a later friendship
      // keyed by the same local chat id must not show it again.
      expect(
        await alice.enc.localMessageRecords(localConversationIdFor(5)),
        isEmpty,
      );
      expect(
        await bob.enc.localMessageRecords(localConversationIdFor(1)),
        isEmpty,
      );
      expect(
        box.sockets.sockets
            .expand((s) => s.emitted)
            .where((f) => f.event == 'deleteQueue')
            .map((f) => f.frame['rid']),
        contains(bobQueue),
        reason: 'bob deletes his queue for alice on her goodbye',
      );
      expect(alice.namedToServer(5), isEmpty);
      expect(bob.namedToServer(1), isEmpty);
    },
  );

  test(
    'a block over the box keeps the account blocked, so its next request '
    'is dropped unread',
    () async {
      await befriend();
      await alice.sendText(5, 'kept?');
      await settle();
      await bob.endWith(1, block: true);
      await settle();
      expect(bob.recordOf(1)?.state, ContactState.blocked);
      expect(alice.recordOf(5), isNull);
      expect(
        await bob.enc.localMessageRecords(localConversationIdFor(1)),
        isEmpty,
      );

      await alice.reader.sendBoxFriendRequest(bob.searchEntry);
      await settle();
      expect(bob.recordOf(1)?.state, ContactState.blocked);
      expect(bob.recordOf(1)?.boxOrigin?.kept, isEmpty);
    },
  );

  test(
    'a chat timer set on one side reaches the other, and an older setting '
    'arriving later does not undo a newer one (E15k)',
    () async {
      await befriend();
      final at = DateTime.now().toUtc();

      await alice.reader.sendBoxChatTimer(5, 3600, at);
      await settle();
      expect(bob.recordOf(1)!.settings.disappearingTimer, 3600);

      await alice.reader.sendBoxChatTimer(
        5,
        60,
        at.subtract(const Duration(minutes: 1)),
      );
      await settle();
      expect(bob.recordOf(1)!.settings.disappearingTimer, 3600);

      await alice.reader.sendBoxChatTimer(
        5,
        null,
        at.add(const Duration(minutes: 1)),
      );
      await settle();
      expect(bob.recordOf(1)!.settings.disappearingTimer, isNull);
      expect(alice.namedToServer(5), isEmpty);
    },
  );

  test(
    'a request is kept undecrypted, the accept looks the handle up once and '
    'verifies the key before decrypting, and both become friends on local '
    'chats with a message each way — the server never hears of the pair',
    () async {
      expect(
        await alice.reader.sendBoxFriendRequest(bob.searchEntry),
        FirstContactSend.sent,
      );
      expect(alice.recordOf(5)?.state, ContactState.pendingOut);
      await settle();

      // Kept, not read: libsignal would have pinned whatever key it carries.
      final kept = bob.recordOf(1)!;
      expect(kept.state, ContactState.pendingIn);
      expect(kept.boxOrigin!.kept, hasLength(1));
      expect(kept.username, 'alice');
      expect(await bob.enc.hasSessionWith(1), isFalse);
      expect(bob.lookups, isEmpty, reason: 'no lookup before the accept');

      bob.answer = (_) => [alice.searchEntry];
      expect(
        await bob.reader.acceptBoxFriendRequest(1),
        FirstContactAccept.accepted,
      );
      expect(bob.lookups, ['alice#0001']);
      await settle();

      for (final (side, peer) in [(alice, 5), (bob, 1)]) {
        final record = side.recordOf(peer)!;
        expect(record.state, ContactState.friend, reason: side.name);
        expect(record.legacy.conversationId, localConversationIdFor(peer));
        expect(record.outbound, hasLength(1), reason: '${side.name} address');
      }

      await alice.sendText(5, 'hi bob');
      await bob.sendText(1, 'hi alice');
      await settle();
      expect(await bob.textsFrom(1), ['hi bob']);
      expect(await alice.textsFrom(5), ['hi alice']);

      expect(alice.namedToServer(5), isEmpty);
      expect(bob.namedToServer(1), isEmpty);
    },
  );

  test(
    'an accept whose lookup serves another key drops the request unread',
    () async {
      expect(
        await alice.reader.sendBoxFriendRequest(bob.searchEntry),
        FirstContactSend.sent,
      );
      await settle();

      // The server (or whoever answers the handle) serves a different
      // identity for alice's account: the kept frame is not hers to open.
      final mallory = _Side(9, 'alice', _RoutingBox());
      await mallory.start();
      bob.answer = (_) => [
        {...mallory.searchEntry, 'id': 1, 'tag': alice.tag},
      ];

      expect(
        await bob.reader.acceptBoxFriendRequest(1),
        FirstContactAccept.unverified,
      );
      expect(bob.recordOf(1), isNull);
      expect(await bob.enc.hasSessionWith(1), isFalse);
      expect(alice.recordOf(5)?.state, ContactState.pendingOut);
    },
  );

  test(
    'an accept whose lookup answers nothing keeps the request and decrypts '
    'nothing, so the next accept still can',
    () async {
      await alice.reader.sendBoxFriendRequest(bob.searchEntry);
      await settle();

      bob.answer = (_) => [];
      expect(
        await bob.reader.acceptBoxFriendRequest(1),
        FirstContactAccept.failed,
      );
      expect(bob.recordOf(1)?.state, ContactState.pendingIn);
      expect(await bob.enc.hasSessionWith(1), isFalse);

      bob.answer = (_) => [alice.searchEntry];
      expect(
        await bob.reader.acceptBoxFriendRequest(1),
        FirstContactAccept.accepted,
      );
    },
  );

  test(
    'a request naming a former contact is not kept: its queue material '
    'stays, and nothing is decrypted',
    () async {
      await bob.store.update(
        1,
        (_) => const ContactRecord(
          userId: 1,
          username: 'alice',
          tag: '0001',
          state: ContactState.former,
        ),
      );
      await alice.reader.sendBoxFriendRequest(bob.searchEntry);
      await settle();
      expect(bob.recordOf(1)?.state, ContactState.former);
      expect(bob.recordOf(1)?.boxOrigin, isNull);
      expect(await bob.enc.hasSessionWith(1), isFalse);
    },
  );

  test(
    'both asking at once is an accept on each side (E15f): the sessions '
    'cross, each side reads the other, and three messages each way read',
    () async {
      final toBob = bob.searchEntry;
      final toAlice = alice.searchEntry;
      expect(
        await alice.reader.sendBoxFriendRequest(toBob),
        FirstContactSend.sent,
      );
      expect(
        await bob.reader.sendBoxFriendRequest(toAlice),
        FirstContactSend.sent,
      );
      await settle();

      for (final (side, peer) in [(alice, 5), (bob, 1)]) {
        expect(
          side.recordOf(peer)?.state,
          ContactState.friend,
          reason: side.name,
        );
        expect(side.lookups, isEmpty, reason: 'its own search pinned the key');
      }
      for (var i = 0; i < 3; i++) {
        await alice.sendText(5, 'a$i');
        await bob.sendText(1, 'b$i');
        await settle();
      }
      expect(await bob.textsFrom(1), ['a0', 'a1', 'a2']);
      expect(await alice.textsFrom(5), ['b0', 'b1', 'b2']);
      expect(alice.namedToServer(5), isEmpty);
      expect(bob.namedToServer(1), isEmpty);
    },
  );

  test('an accept whose lookup names another account drops the request '
      'undecrypted', () async {
    await alice.reader.sendBoxFriendRequest(bob.searchEntry);
    await settle();
    bob.answer = (_) => [
      {...alice.searchEntry, 'id': 9},
    ];
    expect(
      await bob.reader.acceptBoxFriendRequest(1),
      FirstContactAccept.unverified,
    );
    expect(bob.recordOf(1), isNull);
    expect(await bob.enc.hasSessionWith(1), isFalse);
  });

  test('an accept whose lookup serves a key other than the one already pinned '
      'for that account drops the request', () async {
    final real = alice.searchEntry;
    final key =
        (((real['devices'] as List).first as Map)['bundle']
                as Map)['identityPublicKey']
            as String;
    await bob.enc.adoptServedAccount(1, identityKey: key, authorization: null);
    await alice.reader.sendBoxFriendRequest(bob.searchEntry);
    await settle();
    final mallory = _Side(9, 'alice', _RoutingBox());
    await mallory.start();
    bob.answer = (_) => [
      {...mallory.searchEntry, 'id': 1, 'tag': alice.tag},
    ];
    expect(
      await bob.reader.acceptBoxFriendRequest(1),
      FirstContactAccept.unverified,
    );
    expect(bob.recordOf(1), isNull);
  });

  test('a request to an account one of whose devices publishes no request '
      'address takes the old path (E15a)', () async {
    final entry = bob.searchEntry;
    final d1 = (entry['devices'] as List).first as Map<String, dynamic>;
    final partial = {
      ...entry,
      'devices': [
        d1,
        {'deviceId': 2, 'bundle': d1['bundle']},
      ],
    };
    expect(
      await alice.reader.sendBoxFriendRequest(partial),
      FirstContactSend.oldPath,
    );
    await settle();
    expect(alice.recordOf(5), isNull);
    expect(bob.recordOf(1), isNull);
  });

  test('with E2E not ready, a request to an account not all on the box takes '
      'the old path, which needs no E2E; one the box would carry fails', () async {
    final entry = bob.searchEntry;
    final d1 = (entry['devices'] as List).first as Map<String, dynamic>;
    final partial = {
      ...entry,
      'devices': [
        d1,
        {'deviceId': 2, 'bundle': d1['bundle']},
      ],
    };
    alice.enc.ready = false;
    expect(
      await alice.reader.sendBoxFriendRequest(partial),
      FirstContactSend.oldPath,
    );
    expect(
      await alice.reader.sendBoxFriendRequest(bob.searchEntry),
      FirstContactSend.failed,
    );
    await settle();
    expect(alice.recordOf(5), isNull);
    expect(bob.recordOf(1), isNull);
  });

  test('a request from an account with a live sibling this device holds no '
      'self-queue address for takes the old path (E15a)', () async {
    alice.enc
      ..ownId = 1
      ..ownLive = [1, 2];
    expect(
      await alice.reader.sendBoxFriendRequest(bob.searchEntry),
      FirstContactSend.oldPath,
    );
    await settle();
    expect(alice.recordOf(5), isNull);
    expect(bob.recordOf(1), isNull);
  });

  test('a first contact whose queue the box would not delete keeps its '
      'record until a later retire deletes it', () async {
    await alice.reader.sendBoxFriendRequest(bob.searchEntry);
    await settle();
    final queue = alice.recordOf(5)!.queues.single;
    final inner = box.sockets.respond!;
    box.sockets.respond = (s, f) => f.event == 'deleteQueue'
        ? {'ok': false, 'code': 'internal'}
        : inner(s, f);
    await alice.session.retireFirstContact(5);
    expect(alice.recordOf(5)?.queues.map((q) => q.rid), [queue.rid]);
    box.sockets.respond = inner;
    await alice.session.retireFirstContact(5);
    expect(alice.recordOf(5), isNull);
  });

  test('one undeleted queue among several keeps the record', () async {
    await alice.reader.sendBoxFriendRequest(bob.searchEntry);
    await settle();
    final real = alice.recordOf(5)!.queues.single;
    final other = ContactQueue.fromJson({
      ...real.toJson(),
      'rid': boxB64(List.filled(32, 7)),
    });
    await alice.store.update(5, (r) => r!.copyWith(queues: [real, other]));
    final inner = box.sockets.respond!;
    box.sockets.respond = (s, f) =>
        f.event == 'deleteQueue' && f.frame['rid'] == real.rid
        ? {'ok': false, 'code': 'internal'}
        : inner(s, f);
    await alice.session.retireFirstContact(5);
    expect(alice.recordOf(5), isNotNull);
  });

  test("a box friend's list refresh is one handle lookup, never "
      'getDeviceList (E15h)', () async {
    await befriend();
    alice.answer = (_) => [bob.searchEntry];
    try {
      await alice.enc.getVerifiedDeviceList(
        5,
        forceRefresh: true,
        timeout: const Duration(seconds: 1),
      );
    } on Object catch (_) {}
    expect(alice.lookups, ['bob#0005']);
    expect(alice.namedToServer(5), isEmpty);
  });

  test(
    "a box friend's identity dialog never fetches a pre-key bundle",
    () async {
      await befriend();
      alice.answer = (_) => [bob.searchEntry];
      alice.enc.extraChanged.add(5);
      await alice.enc.loadPeerIdentityVerification(
        5,
        timeout: const Duration(seconds: 1),
      );
      expect(alice.namedToServer(5), isEmpty);
    },
  );

  test('a lost session with a box friend is rebuilt from the served bundle, '
      'never fetchPreKeyBundle', () async {
    await befriend();
    await alice.enc.encryptionService.deleteSession(5);
    expect(await alice.enc.hasSessionWith(5), isFalse);
    await alice.enc.ensureSession(5);
    expect(await alice.enc.hasSessionWith(5), isTrue);
    expect(alice.namedToServer(5), isEmpty);
  });

  test('a request whose verified list names a live device the answer did not '
      'serve takes the old path (E15a)', () async {
    alice.enc.servedList = VerifiedDeviceList.enrolled(
      version: 1,
      listHash: 'H' * 44,
      devices: const [
        DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
        DeviceListEntry(deviceId: 2, platform: 'test', addedAtMs: 0),
      ],
    );
    expect(
      await alice.reader.sendBoxFriendRequest(bob.searchEntry),
      FirstContactSend.oldPath,
    );
    await settle();
    expect(alice.recordOf(5), isNull);
    expect(bob.recordOf(1), isNull);
  });

  test('an unfriend whose sibling copy cannot go throws before any goodbye: '
      'both sides stay friends', () async {
    await befriend();
    alice.enc
      ..ownId = 1
      ..ownLive = [1, 2];
    await expectLater(
      alice.reader.endBoxFriendship(5, block: false),
      throwsStateError,
    );
    await settle();
    expect(alice.recordOf(5)?.state, ContactState.friend);
    expect(bob.recordOf(1)?.state, ContactState.friend);
  });

  test('an unfriend whose queue the box would not delete keeps the record as '
      'former with that queue', () async {
    await befriend();
    final rid = alice.recordOf(5)!.queues.single.rid;
    final inner = box.sockets.respond!;
    box.sockets.respond = (s, f) =>
        f.event == 'deleteQueue' && f.frame['rid'] == rid
        ? {'ok': false, 'code': 'internal'}
        : inner(s, f);
    await alice.endWith(5, block: false);
    await settle();
    final record = alice.recordOf(5);
    expect(record?.state, ContactState.former);
    expect(record?.queues.map((q) => q.rid), [rid]);
  });

  test('a block whose queue the box would not delete keeps the record blocked '
      'with that queue', () async {
    await befriend();
    final rid = alice.recordOf(5)!.queues.single.rid;
    final inner = box.sockets.respond!;
    box.sockets.respond = (s, f) =>
        f.event == 'deleteQueue' && f.frame['rid'] == rid
        ? {'ok': false, 'code': 'internal'}
        : inner(s, f);
    await alice.endWith(5, block: true);
    await settle();
    final record = alice.recordOf(5);
    expect(record?.state, ContactState.blocked);
    expect(record?.queues.map((q) => q.rid), [rid]);
  });
}
