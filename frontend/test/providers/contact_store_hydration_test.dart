import 'dart:convert';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SilentSocket extends SocketService {
  @override
  bool get isConnected => false;
  @override
  void connect({required String baseUrl, required String token}) {}
  @override
  void disconnect() {}
  @override
  void on(String event, void Function(dynamic) callback) {}
  @override
  void onConnect(void Function() callback) {}
  @override
  void onDisconnect(void Function(dynamic) callback) {}
}

Map<String, dynamic> _user(int id, String name) => {
  'id': id,
  'username': name,
  'tag': '000$id',
};

Map<String, dynamic> _conv(int id, int peerId, String peer) => {
  'id': id,
  'userOne': _user(1, 'me'),
  'userTwo': _user(peerId, peer),
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': 300,
  'muted': true,
  'unreadCount': 0,
};

Map<String, dynamic> _request(int id, int from, int to) => {
  'id': id,
  'sender': _user(from, 'u$from'),
  'receiver': _user(to, 'u$to'),
  'status': 'pending',
  'createdAt': '2026-01-02T00:00:00.000Z',
};

/// Every write queued on `s` (default: the shared store) has settled.
late ContactStore store;
Future<void> _settle([ContactStore? s]) => (s ?? store).settled;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
  });

  /// One online session for account 1: friends bob(2) + carol(3), a chat
  /// with bob, an incoming request from dave(4), erin(5) blocked.
  FriendsProvider friendsOver(ContactStore s) => FriendsProvider()
    ..contactStore = s
    ..setCurrentUserId(1);

  ConversationsProvider convsOver(ContactStore s) => ConversationsProvider()
    ..contactStore = s
    ..setCurrentUserId(1);

  Future<void> seedOnlineSession() async {
    await store.open(1);
    convsOver(store).onConversationsList([_conv(10, 2, 'bob')]);
    friendsOver(store)
      ..onFriendRequestsList([_request(70, 4, 1)])
      ..onFriendsList([_user(2, 'bob'), _user(3, 'carol')])
      ..onBlockedList([_user(5, 'erin')]);
    await _settle();
  }

  group('hydration', () {
    test(
      'a fresh session lists contacts from the store before any server list',
      () async {
        await seedOnlineSession();

        final friends = FriendsProvider()..contactStore = newStore();
        final convs = ConversationsProvider()
          ..contactStore = friends.contactStore;
        await friends.contactStore!.open(1);
        friends
          ..onConnect(false)
          ..setCurrentUserId(1)
          ..hydrateFromStore();
        convs
          ..onConnect(false)
          ..setCurrentUserId(1)
          ..hydrateFromStore();

        expect(
          friends.friends.map((u) => u.username),
          unorderedEquals(['bob', 'carol']),
        );
        expect(friends.friendRequests.single.id, 70);
        expect(friends.friendRequests.single.sender.username, 'u4');
        expect(friends.friendRequests.single.receiver.id, 1);
        expect(friends.blockedUsers.single.username, 'erin');
        final chat = convs.conversations.single;
        expect(chat.id, 10);
        expect(convs.getOtherUser(chat)?.username, 'bob');
        expect(chat.disappearingTimer, 300);
        expect(chat.muted, isTrue);
      },
    );

    test(
      'the server list replaces hydration and hydrate is then a no-op',
      () async {
        await seedOnlineSession();
        final friends = FriendsProvider()..contactStore = newStore();
        await friends.contactStore!.open(1);
        friends
          ..onConnect(false)
          ..setCurrentUserId(1)
          ..hydrateFromStore()
          ..onFriendsList([_user(3, 'carol')])
          ..hydrateFromStore();

        expect(friends.friends.map((u) => u.username), ['carol']);
      },
    );

    test('an EMPTY first server list wins over hydration', () async {
      // The last friend was removed from another device: the empty list is
      // the truth, and the reconnect-only guard must not preserve the ghost.
      await seedOnlineSession();
      final friends = FriendsProvider()..contactStore = newStore();
      await friends.contactStore!.open(1);
      friends
        ..onConnect(false)
        ..setCurrentUserId(1)
        ..hydrateFromStore()
        ..onFriendsList(const []);

      expect(friends.friends, isEmpty);
    });

    test(
      'an empty list AFTER a real one is still ignored (reconnect guard)',
      () async {
        final friends = FriendsProvider()
          ..setCurrentUserId(1)
          ..onFriendsList([_user(2, 'bob')])
          ..onFriendsList(const []);

        expect(friends.friends.single.username, 'bob');
      },
    );

    test('requests hydrate for an account that never had a chat', () async {
      // Brand-new account: pending requests, no conversationsList ever, so
      // `self` can only come from the auth profile handed to the store.
      final withProfile = ContactStore(
        open: () async => kv,
        selfProfile: () => UserModel(id: 1, username: 'me', tag: '0001'),
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      await withProfile.open(1);
      (FriendsProvider()
            ..contactStore = withProfile
            ..setCurrentUserId(1))
          .onFriendRequestsList([_request(70, 4, 1)]);
      await _settle(withProfile);

      final friends = FriendsProvider()..contactStore = newStore();
      await friends.contactStore!.open(1);
      friends
        ..setCurrentUserId(1)
        ..hydrateFromStore();

      expect(friends.friendRequests.single.receiver.username, 'me');
    });
  });

  group('the bounded wait for the first conversation list (decision 121)', () {
    /// A new session over the seeded store: chats and friends hydrated from
    /// it, no server list yet.
    Future<({ConversationsProvider convs, FriendsProvider friends})>
    freshSession() async {
      await seedOnlineSession();
      final friends = FriendsProvider()..contactStore = newStore();
      await friends.contactStore!.open(1);
      final convs = ConversationsProvider()
        ..contactStore = friends.contactStore;
      friends
        ..onConnect(false)
        ..setCurrentUserId(1)
        ..hydrateFromStore();
      convs
        ..onConnect(false)
        ..setCurrentUserId(1)
        ..hydrateFromStore();
      return (convs: convs, friends: friends);
    }

    String held(ContactStore s) =>
        jsonEncode([for (final r in s.all) r.toJson()]);

    // Mutation: `releaseFirstSnapshotWait` runs the list handler with an
    // empty list (an empty FIRST answer is the server's truth and would wipe
    // every held chat).
    test(
      'running out of the wait releases the waits and touches nothing held',
      () async {
        final (:convs, :friends) = await freshSession();
        final chatIds = convs.conversations.map((c) => c.id).toList();
        final friendIds = friends.friends.map((u) => u.id).toList();
        final stored = held(convs.contactStore!);
        expect(convs.hasLoadedConversationsOnce, isFalse);

        convs.releaseFirstSnapshotWait();
        await _settle(convs.contactStore);

        expect(convs.hasLoadedConversationsOnce, isTrue);
        expect(chatIds, isNotEmpty);
        expect(convs.conversations.map((c) => c.id), chatIds);
        expect(friends.friends.map((u) => u.id), friendIds);
        expect(friends.hasFriendsSnapshot, isFalse, reason: 'no friends answer');
        expect(held(convs.contactStore!), stored);
      },
    );

    // Mutation: the release sets `_conversationsListReceivedOnce`, the flag a
    // real list sets (the late list then no longer counts as the first one).
    test('an EMPTY list that arrives after the wait is still the first '
        'snapshot: the server truth, applied as on time', () async {
      final (:convs, friends: _) = await freshSession();
      expect(convs.conversations, isNotEmpty);

      convs
        ..releaseFirstSnapshotWait()
        ..onConversationsList(const []);

      expect(convs.conversations, isEmpty);
    });

    test('a list that arrives after the wait replaces what was held', () async {
      final (:convs, friends: _) = await freshSession();
      convs
        ..releaseFirstSnapshotWait()
        ..onConversationsList([_conv(11, 3, 'carol')]);

      expect(convs.conversations.map((c) => c.id), [11]);
      expect(convs.hasLoadedConversationsOnce, isTrue);
    });
  });

  group('write-through', () {
    test(
      'unfriend removes the record; a list that omits a friend only hides it',
      () async {
        await seedOnlineSession();
        final friends = friendsOver(store)..onUnfriended({'userId': 2});
        await _settle();
        expect(store.byUserId(2), isNull);
        expect(store.byUserId(3)?.state, ContactState.friend);

        friends.onFriendsList([_user(6, 'frank')]);
        await _settle();
        expect(
          store.byUserId(3)?.state,
          ContactState.former,
          reason: 'absence is not an event: kept, hidden, restorable',
        );
        expect(store.byUserId(6)?.state, ContactState.friend);
        expect(
          store.byUserId(5)?.state,
          ContactState.blocked,
          reason: 'a friends list never touches a blocked record',
        );

        friends.onFriendsList([_user(3, 'carol'), _user(6, 'frank')]);
        await _settle();
        expect(store.byUserId(3)?.state, ContactState.friend);
      },
    );

    test(
      'a friend holding a box route is untouched by a list that omits it',
      () async {
        // A former friend's box frames are dropped unread (BoxInbox), so a
        // partial server list used to silence a pre-box friend for good.
        await seedOnlineSession();
        const queue = ContactQueue(
          rid: 'RID',
          sid: 'SID',
          nid: 'NID',
          authPriv: 'AUTH',
          sealPriv: 'SEALPRIV',
          sealPub: 'SEALPUB',
        );
        await store.update(3, (r) => r!.copyWith(queues: const [queue]));
        friendsOver(store).onFriendsList([_user(2, 'bob')]);
        await _settle();

        final carol = store.byUserId(3)!;
        expect(carol.state, ContactState.friend);
        expect(carol.queues.single.rid, 'RID');
      },
    );

    test('a chat the list omits keeps its id while the friend is on the box',
        () async {
      await seedOnlineSession();
      const queue = ContactQueue(
        rid: 'RID',
        sid: 'SID',
        nid: 'NID',
        authPriv: 'AUTH',
        sealPriv: 'SEALPRIV',
        sealPub: 'SEALPUB',
      );
      await store.update(2, (r) => r!.copyWith(queues: const [queue]));
      convsOver(store).onConversationsList([_conv(11, 3, 'carol')]);
      await _settle();

      expect(
        store.byUserId(2)?.chatId,
        10,
        reason: "bob's box messages live under chat 10",
      );
    });

    test('an empty blocked list after a real one unblocks nobody', () async {
      await seedOnlineSession();
      friendsOver(store)
        ..onBlockedList([_user(5, 'erin')])
        ..onBlockedList(const []);
      await _settle();

      expect(store.byUserId(5)?.state, ContactState.blocked);
    });

    test('unblocking the last blocked account empties the list at once',
        () async {
      // The server answers an unblock with its list, here empty — which the
      // empty-list guard above must not swallow for our own unblock.
      await seedOnlineSession();
      final friends = friendsOver(store)
        ..onBlockedList([_user(5, 'erin')])
        ..unblockUser(5)
        ..onBlockedList(const []);
      await _settle();

      expect(friends.blockedUsers, isEmpty);
      expect(store.byUserId(5)?.state, isNot(ContactState.blocked));
    });

    test(
      'a timer set on a pre-box chat the box carries goes over the box AND to '
      'the server',
      () async {
        await seedOnlineSession();
        const queue = ContactQueue(
          rid: 'RID',
          sid: 'SID',
          nid: 'NID',
          authPriv: 'AUTH',
          sealPriv: 'SEALPRIV',
          sealPub: 'SEALPUB',
        );
        await store.update(2, (r) => r!.copyWith(queues: const [queue]));
        final sent = <(int, int?)>[];
        final emitted = <String>[];
        final convs = convsOver(store)
          ..setEmitCallback((event, _) => emitted.add(event))
          ..onConversationsList([_conv(10, 2, 'bob')])
          ..onLocalChatTimerChanged = (peer, seconds, _) =>
              sent.add((peer, seconds));
        await _settle();

        convs.setDisappearingTimer(10, 3600);
        await _settle();

        expect(sent, [(2, 3600)]);
        expect(emitted, contains('setDisappearingTimer'));
        expect(store.byUserId(2)!.settings.timerAt, isNotNull);
      },
    );

    test('being blocked by a peer drops their record', () async {
      await seedOnlineSession();
      friendsOver(store).onYouWereBlocked({'userId': 2});
      await _settle();

      expect(store.byUserId(2), isNull);
      expect(store.byUserId(3)?.state, ContactState.friend);
    });

    test(
      'a request accepted offline survives the requests list that follows',
      () async {
        await seedOnlineSession();
        // Dave (pendingIn on disk) accepted us while this device was offline:
        // on connect the friends list names him and the requests list is
        // empty, back-to-back, before either write applied to RAM.
        friendsOver(store)
          ..onFriendsList([
            _user(2, 'bob'),
            _user(3, 'carol'),
            _user(4, 'dave'),
          ])
          ..onFriendRequestsList(const []);
        await _settle();

        expect(store.byUserId(4)?.state, ContactState.friend);
      },
    );

    test('an empty friends list changes the store not at all', () async {
      await seedOnlineSession();
      friendsOver(store).onFriendsList(const []);
      await _settle();

      expect(store.byUserId(2)?.state, ContactState.friend);
      expect(store.byUserId(3)?.state, ContactState.friend);
    });

    test(
      'accept turns a pending record into a friend with its chat id',
      () async {
        await seedOnlineSession();
        friendsOver(store).onFriendRequestAccepted({
          ..._request(70, 4, 1),
          'status': 'accepted',
          'conversationId': 11,
        });
        await _settle();

        final dave = store.byUserId(4)!;
        expect(dave.state, ContactState.friend);
        expect(dave.legacy.requestId, isNull);
        expect(dave.legacy.conversationId, 11);
      },
    );

    test('a declined request drops the pending record only', () async {
      await seedOnlineSession();
      friendsOver(
        store,
      ).onFriendRequestRejected({..._request(70, 4, 1), 'status': 'rejected'});
      await _settle();

      expect(store.byUserId(4), isNull);
      expect(store.byUserId(2)?.state, ContactState.friend);
    });

    test(
      'settings events land on the peer record; a deleted chat keeps it',
      () async {
        await seedOnlineSession();
        final convs = convsOver(store)
          ..onConversationsList([_conv(10, 2, 'bob')])
          ..onDisappearingTimerUpdated({'conversationId': 10, 'seconds': null})
          ..onConversationMuteUpdated({'conversationId': 10, 'muted': false})
          ..onMessagePinned({'conversationId': 10, 'pinnedMessageId': 500});
        await _settle();

        var bob = store.byUserId(2)!;
        expect(bob.settings.disappearingTimer, isNull);
        expect(bob.settings.muted, isFalse);
        expect(bob.settings.pinnedMessageId, 500);

        convs.onConversationDeleted({'conversationId': 10});
        await _settle();
        bob = store.byUserId(2)!;
        expect(bob.state, ContactState.friend);
        expect(bob.legacy.conversationId, isNull);
        expect(bob.settings.pinnedMessageId, isNull);
      },
    );
  });

  test('connect() lists stored contacts with no socket at all', () async {
    await seedOnlineSession();
    final friends = FriendsProvider();
    final convs = ConversationsProvider();
    final connection = ConnectionProvider(socketService: _SilentSocket())
      ..setProviders(
        encryption: EncryptionProvider(),
        friends: friends,
        conversations: convs,
        messaging: MessagingProvider()..setConversationsProvider(convs),
        contactStore: newStore(),
      );
    addTearDown(connection.disconnect);

    await connection.connect(1, 'token', 'http://localhost:3000');

    expect(
      friends.friends.map((u) => u.username),
      unorderedEquals(['bob', 'carol']),
    );
    expect(convs.conversations.single.id, 10);
    expect(connection.contactStoreUnavailableStage, isNull);
  });

  test(
    'a passcode re-lock forgets the graph; the unlock re-opens the store',
    () async {
      await seedOnlineSession();
      final friends = FriendsProvider();
      final encryption = EncryptionProvider();
      final contacts = newStore();
      final connection = ConnectionProvider(socketService: _SilentSocket())
        ..setProviders(
          encryption: encryption,
          friends: friends,
          conversations: ConversationsProvider(),
          messaging: MessagingProvider(),
          contactStore: contacts,
        );
      addTearDown(connection.disconnect);
      await connection.connect(1, 'token', 'http://localhost:3000');
      expect(contacts.all, isNotEmpty);

      encryption.onPasscodeLockRevoke!();
      expect(contacts.isOpen, isFalse);
      expect(contacts.all, isEmpty);
      // A write while revoked is refused, never silently applied.
      friends.onUnfriended({'userId': 2});
      await _settle(contacts);

      await encryption.onPasscodeLockRestore!();
      expect(contacts.isOpen, isTrue);
      expect(
        contacts.byUserId(2)?.state,
        ContactState.friend,
        reason: 'the revoked-window write touched nothing on disk',
      );
      friends.onUnfriended({'userId': 3});
      await _settle(contacts);
      expect(
        contacts.byUserId(3),
        isNull,
        reason: 'write-through resumes after the unlock',
      );
    },
  );

  test(
    'a store that cannot open is diagnosed and the session goes on',
    () async {
      final friends = FriendsProvider();
      final connection = ConnectionProvider(socketService: _SilentSocket())
        ..setProviders(
          encryption: EncryptionProvider(),
          friends: friends,
          conversations: ConversationsProvider(),
          messaging: MessagingProvider(),
          contactStore: ContactStore(
            open: () async => kv,
            lock: <T>(_, action) => action(),
            accepts: (_) => false,
          ),
        );
      addTearDown(connection.disconnect);

      await connection.connect(1, 'token', 'http://localhost:3000');

      expect(connection.contactStoreUnavailableStage, 'backend');
      expect(connection.currentUserId, 1);
      // The session still takes the server's answer.
      friends.onFriendsList([_user(2, 'bob')]);
      expect(friends.friends.single.username, 'bob');
    },
  );
}
