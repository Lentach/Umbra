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
import 'package:fireplace/utils/message_ids.dart';
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

/// Every write queued on `s` (default: the shared store) has settled.
late ContactStore store;
Future<void> _settle([ContactStore? s]) => (s ?? store).settled;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    selfProfile: () => UserModel(id: 1, username: 'me', tag: '0001'),
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
  });

  FriendsProvider friendsOver(ContactStore s) => FriendsProvider()
    ..contactStore = s
    ..setCurrentUserId(1);

  ConversationsProvider convsOver(ContactStore s) => ConversationsProvider()
    ..contactStore = s
    ..setCurrentUserId(1);

  ContactRecord record(
    int id,
    String name,
    ContactState state, {
    ContactLegacy legacy = const ContactLegacy(),
    ContactSettings settings = const ContactSettings(),
    bool box = false,
  }) => ContactRecord(
    userId: id,
    username: name,
    tag: '000$id',
    state: state,
    legacy: legacy,
    settings: settings,
    boxOrigin: box
        ? ContactBoxOrigin(
            at: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          )
        : null,
  );

  /// One account (1) with friends bob(2, a pre-box chat 10, timer 300,
  /// muted) + carol(3), an incoming box request from dave(4), erin(5)
  /// blocked.
  Future<void> seedSession() async {
    await store.open(1);
    final records = [
      record(
        2,
        'bob',
        ContactState.friend,
        legacy: ContactLegacy(
          conversationId: 10,
          conversationCreatedAt: DateTime.utc(2026),
        ),
        settings: const ContactSettings(disappearingTimer: 300, muted: true),
      ),
      record(3, 'carol', ContactState.friend),
      record(4, 'dave', ContactState.pendingIn, box: true),
      record(5, 'erin', ContactState.blocked),
    ];
    for (final r in records) {
      await store.update(r.userId, (_) => r);
    }
    await _settle();
  }

  group('hydration', () {
    test('a fresh session lists contacts from the store', () async {
      await seedSession();

      final friends = FriendsProvider()..contactStore = newStore();
      final convs = ConversationsProvider()
        ..contactStore = friends.contactStore;
      await friends.contactStore!.open(1);
      friends
        ..onConnect(false)
        ..setCurrentUserId(1)
        ..onContactsChanged();
      convs
        ..onConnect(false)
        ..setCurrentUserId(1)
        ..hydrateFromStore();

      expect(convs.hasLoadedConversations, isTrue);
      expect(
        friends.friends.map((u) => u.username),
        unorderedEquals(['bob', 'carol']),
      );
      expect(friends.friendRequests.single.id, -4);
      expect(friends.friendRequests.single.sender.username, 'dave');
      expect(friends.friendRequests.single.receiver.id, 1);
      expect(friends.blockedUsers.single.username, 'erin');
      final chat = convs.conversations.single;
      expect(chat.id, 10);
      expect(convs.getOtherUser(chat)?.username, 'bob');
      expect(chat.disappearingTimer, 300);
      expect(chat.muted, isTrue);
    });

    test('requests show for an account that never had a chat', () async {
      // Brand-new account: pending requests and no chat, so `self` can only
      // come from the auth profile handed to the store.
      await store.open(1);
      await store.update(4, (_) => record(4, 'dave', ContactState.pendingIn, box: true));
      await _settle();

      final friends = friendsOver(store);

      expect(friends.friendRequests.single.receiver.username, 'me');
    });
  });

  group('write-through', () {
    test(
      'a timer set on a pre-box chat the box carries goes over the box and '
      'onto the record',
      () async {
        await seedSession();
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
        final convs = convsOver(store)
          ..hydrateFromStore()
          ..onLocalChatTimerChanged = (peer, seconds, _) =>
              sent.add((peer, seconds));

        convs.setDisappearingTimer(10, 3600);
        await _settle();

        expect(sent, [(2, 3600)]);
        final bob = store.byUserId(2)!;
        expect(bob.settings.disappearingTimer, 3600);
        expect(bob.settings.timerAt, isNotNull);
      },
    );
  });

  test('connect() lists stored contacts with no socket at all', () async {
    await seedSession();
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
    expect(convs.hasLoadedConversations, isTrue);
    expect(connection.contactStoreUnavailableStage, isNull);
  });

  test(
    'a passcode re-lock forgets the graph; the unlock re-opens the store',
    () async {
      await seedSession();
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
      await friends.unfriend(2);
      await _settle(contacts);

      await encryption.onPasscodeLockRestore!();
      expect(contacts.isOpen, isTrue);
      expect(
        contacts.byUserId(2)?.state,
        ContactState.friend,
        reason: 'the revoked-window write touched nothing on disk',
      );
      await friends.unfriend(3);
      await _settle(contacts);
      expect(
        contacts.byUserId(3),
        isNull,
        reason: 'write-through resumes after the unlock',
      );
    },
  );

  group('a session that booted locked', () {
    /// Account 1 with the [seedSession] graph plus frank (6), a friend
    /// made over the box. The contact store is locked through `connect`.
    Future<(FriendsProvider, ConversationsProvider)> bootLockedThenUnlock() async {
      await seedSession();
      await store.update(
        6,
        (_) => ContactRecord(
          userId: 6,
          username: 'frank',
          tag: '0006',
          state: ContactState.friend,
          boxOrigin: ContactBoxOrigin(at: DateTime.utc(2026, 10)),
        ),
      );
      await _settle();
      var locked = true;
      final friends = FriendsProvider();
      final convs = ConversationsProvider();
      final encryption = EncryptionProvider();
      final connection = ConnectionProvider(socketService: _SilentSocket())
        ..setProviders(
          encryption: encryption,
          friends: friends,
          conversations: convs,
          messaging: MessagingProvider()..setConversationsProvider(convs),
          contactStore: ContactStore(
            open: () async {
              if (locked) {
                throw const ContentStoreUnavailable('locked', locked: true);
              }
              return kv;
            },
            lock: <T>(_, action) => action(),
            accepts: (_) => true,
          ),
        );
      addTearDown(connection.disconnect);

      await connection.connect(1, 'token', 'http://localhost:3000');
      expect(friends.friends, isEmpty);
      expect(convs.conversations, isEmpty);

      locked = false;
      await encryption.onPasscodeLockRestore!();
      return (friends, convs);
    }

    final frankChat = localConversationIdFor(6);

    test('lists the stored contacts after the unlock', () async {
      final (friends, convs) = await bootLockedThenUnlock();

      expect(
        friends.friends.map((u) => u.username),
        unorderedEquals(['bob', 'carol', 'frank']),
      );
      expect(
        convs.conversations.map((c) => c.id),
        unorderedEquals([10, frankChat]),
      );
    });
  });

  test(
    'a store that cannot open is diagnosed and the session goes on',
    () async {
      final friends = FriendsProvider();
      final convs = ConversationsProvider();
      final connection = ConnectionProvider(socketService: _SilentSocket())
        ..setProviders(
          encryption: EncryptionProvider(),
          friends: friends,
          conversations: convs,
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
      // Nothing to list, but nothing to wait for either.
      expect(friends.friends, isEmpty);
      expect(convs.hasLoadedConversations, isTrue);
    },
  );
}
