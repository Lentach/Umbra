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

  group('write-through', () {
    test(
      'unfriend removes the record; a non-empty list prunes the missing',
      () async {
        await seedOnlineSession();
        final friends = friendsOver(store)..onUnfriended({'userId': 2});
        await _settle();
        expect(store.byUserId(2), isNull);
        expect(store.byUserId(3)?.state, ContactState.friend);

        friends.onFriendsList([_user(6, 'frank')]);
        await _settle();
        expect(
          store.byUserId(3),
          isNull,
          reason: 'carol left the server list: removed elsewhere',
        );
        expect(store.byUserId(6)?.state, ContactState.friend);
        expect(
          store.byUserId(5)?.state,
          ContactState.blocked,
          reason: 'a friends list never touches a blocked record',
        );
      },
    );

    test(
      'a friend the list omits is KEPT as former while it holds queue '
      'material, and the next list that names it restores it',
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
        await store.update(3, (r) => r!.copyWith(queues: const [queue]));
        final friends = friendsOver(store)..onFriendsList([_user(2, 'bob')]);
        await _settle();

        final carol = store.byUserId(3)!;
        expect(carol.state, ContactState.former);
        expect(carol.queues.single.rid, 'RID');
        expect(
          (friendsOver(store)..hydrateFromStore()).friends.map((u) => u.id),
          [2],
          reason: "a former record hydrates as nobody's friend",
        );

        friends.onFriendsList([_user(2, 'bob'), _user(3, 'carol')]);
        await _settle();
        expect(store.byUserId(3)?.state, ContactState.friend);
        expect(store.byUserId(3)?.queues.single.rid, 'RID');
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
