import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real plaintext store; Signal is faked: an inbound frame decrypts to
/// [inbound]. [recordReads] counts reads of every chat's box records.
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  String inbound = '{}';
  int recordReads = 0;

  @override
  Future<Map<int, Map<String, dynamic>>> allLocalMessageRecords() {
    recordReads++;
    return super.allLocalMessageRecords();
  }

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => inbound;
}

const _me = 1;
const _bobId = 2;
const _bobChat = 10;
const _carolChat = 11;

const _bob = ContactRecord(
  userId: _bobId,
  username: 'bob',
  tag: '0002',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: _bobChat),
);

Map<String, dynamic> _user(int id, String name) => {
  'id': id,
  'username': name,
  'tag': '000$id',
};

/// A server chat as `conversationsList` serves it: its last SERVER row
/// ([lastId] at [lastAt], an E2E row's `[encrypted]`) and the server's
/// unread count. No box message is ever named here (decision 14).
Map<String, dynamic> _conv(
  int id,
  int peer,
  String name, {
  required int lastId,
  required DateTime lastAt,
  int unread = 0,
}) => {
  'id': id,
  'userOne': _user(_me, 'alice'),
  'userTwo': _user(peer, name),
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': unread,
  'lastMessage': {
    'id': lastId,
    'content': '[encrypted]',
    'senderId': peer,
    'senderUsername': name,
    'conversationId': id,
    'createdAt': lastAt.toUtc().toIso8601String(),
  },
};

/// The chat list's last message and order across reconnects and cold
/// starts: Bob (2) and Alice (1) have server chat 10 made on the old path,
/// then talk over the box — local ids, no server row, so no
/// `conversationsList` ever names a box message. Carol (3), server chat
/// 11, is the chat Bob's must stay above while its real last message is
/// newer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late ContactStore store;
  late DateTime now;
  var nextLocal = kFirstLocalMessageId;

  Future<void> pump([int turns = 60]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Bob's last server row 10 minutes ago, Carol's 5 minutes ago.
  List<Map<String, dynamic>> snapshot({
    int bobUnread = 0,
    DateTime? bobLastAt,
  }) => [
    _conv(
      _bobChat,
      _bobId,
      'bob',
      lastId: 900,
      lastAt: bobLastAt ?? now.subtract(const Duration(minutes: 10)),
      unread: bobUnread,
    ),
    _conv(
      _carolChat,
      3,
      'carol',
      lastId: 901,
      lastAt: now.subtract(const Duration(minutes: 5)),
    ),
  ];

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(_me)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false);

  ConversationsProvider newConversations() => ConversationsProvider()
    ..contactStore = store
    ..setCurrentUserId(_me)
    ..onConnect(false);

  Future<EncryptionService> openService() async {
    final service = EncryptionService();
    await service.initialize(
      _me,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    return service;
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    now = DateTime.now().toUtc();
    encryption = _Encryption(await openService());
    final kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(_me);
    conversations = newConversations()..onConversationsList(snapshot());
    await store.settled;
    provider = newProvider();
    await pump();
  });

  tearDown(() => provider.dispose());

  /// Bob's box message [text], sent [ago]; its local id.
  Future<int> fromBob(
    String text, {
    required String wire,
    Duration ago = const Duration(minutes: 1),
  }) async {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(text, msgId: wire, sentAt: now.subtract(ago)),
    );
    final localId = nextLocal++;
    final entry = BoxInboxEntry(
      rid: 'rid',
      id: 'm$localId',
      localId: localId,
      peerUserId: _bobId,
      senderDeviceId: 1,
      signal: '2:AQID',
      receivedAt: DateTime.now().toUtc(),
      acked: true,
    );
    expect(await provider.consumeBoxEntry(entry, _bob), isTrue);
    await pump();
    return localId;
  }

  /// A box message's record as the receive path writes it, straight to the
  /// store: [from]'s (Bob's by default) [text] in [conversationId], sent
  /// [ago].
  Future<int> storedFromBob(
    String text, {
    required String wire,
    required Duration ago,
    int conversationId = _bobChat,
    int from = _bobId,
    Map<String, dynamic> extra = const {},
    int? disappearAfterSeconds,
  }) async {
    final id = nextLocal++;
    await encryption.store.saveDecryptedContent(
      id,
      {'content': text, 'senderId': from, ...extra},
      conversationId: conversationId,
      createdAt: now.subtract(ago),
      disappearAfterSeconds: disappearAfterSeconds,
      wire: (senderId: from, wireId: wire),
    );
    return id;
  }

  /// A reconnect of the same account: the server's list again.
  void reconnect({int bobUnread = 0, DateTime? bobLastAt}) {
    conversations
      ..onConnect(true)
      ..onConversationsList(
        snapshot(bobUnread: bobUnread, bobLastAt: bobLastAt),
      );
  }

  /// A fresh app on the same disk, E2E up after the server's list came.
  Future<void> coldStart({int bobUnread = 0}) async {
    provider.dispose();
    encryption = _Encryption(await openService());
    conversations = newConversations()
      ..onConversationsList(snapshot(bobUnread: bobUnread));
    await store.settled;
    provider = newProvider();
    await provider.applyStoredBoxLastMessages();
    await pump();
  }

  /// Shows [chat] as the chat screen does: open, then its first page, whose
  /// merge brings in its stored box messages.
  Future<void> show(int chat) async {
    conversations.openConversation(chat);
    provider.setActiveConversationIdForTest(chat);
    await provider.onMessageHistory({
      'conversationId': chat,
      'messages': <Object>[],
    });
    await pump();
  }

  /// Leaves the chat on screen for the list, as the chat screen's teardown
  /// does.
  void leave() {
    conversations.closeConversation();
    provider
      ..setActiveConversationIdForTest(null)
      ..clearMessages();
  }

  List<int> listOrder() => [
    for (final c in conversations.sortedConversations) c.id,
  ];

  group('reconnect', () {
    test('a newer box message stays the last message and keeps its place '
        'above a chat with an older real last message', () async {
      final boxId = await fromBob('after the flip', wire: 'wire-1');
      expect(conversations.lastMessages[_bobChat]?.id, boxId);

      reconnect();

      expect(conversations.lastMessages[_bobChat]?.id, boxId);
      expect(listOrder(), [_bobChat, _carolChat]);
    });

    test('a server row newer than the held box message wins', () async {
      await fromBob('before', wire: 'wire-1');

      reconnect(bobLastAt: now);

      expect(conversations.lastMessages[_bobChat]?.id, 900);
    });

    test('a held SERVER row the snapshot no longer names as last gives way '
        '(deleted for everyone while this device was away)', () async {
      conversations.updateLastMessage(
        _bobChat,
        MessageModel(
          id: 950,
          content: 'gone on the server',
          senderId: _bobId,
          senderUsername: 'bob',
          conversationId: _bobChat,
          createdAt: now.subtract(const Duration(minutes: 1)),
        ),
      );

      reconnect();

      expect(conversations.lastMessages[_bobChat]?.id, 900);
    });

    test("box messages still unread in a server chat survive the server's "
        'count and are cleared by opening the chat', () async {
      conversations.closeConversation();
      await fromBob('one', wire: 'wire-1');
      await fromBob('two', wire: 'wire-2');
      expect(conversations.getUnreadCount(_bobChat), 2);

      reconnect(bobUnread: 1);
      expect(
        conversations.getUnreadCount(_bobChat),
        3,
        reason: 'the server counts its own rows, never a box message',
      );

      conversations
        ..openConversation(_bobChat)
        ..closeConversation();
      reconnect();
      expect(conversations.getUnreadCount(_bobChat), 0);
    });
  });

  group('stored box messages at E2E ready (cold start)', () {
    test('the newest stored box message is the last message, shown from '
        'its plaintext, and orders the list', () async {
      await fromBob('older box', wire: 'wire-1', ago: const Duration(minutes: 3));
      final newest = await fromBob('newest box', wire: 'wire-2');

      await coldStart();

      final last = conversations.lastMessages[_bobChat];
      expect(last?.id, newest);
      expect(
        provider.listPreviewFor(last!, unreadCount: 0)?.content,
        'newest box',
      );
      expect(listOrder(), [_bobChat, _carolChat]);
    });

    test('the newest by send time wins, not the last to arrive', () async {
      final newest = await storedFromBob(
        'sent last',
        wire: 'wire-1',
        ago: const Duration(minutes: 1),
      );
      // Arrived later (a higher local id), sent earlier.
      await storedFromBob(
        'sent first',
        wire: 'wire-2',
        ago: const Duration(minutes: 4),
      );

      await coldStart();

      expect(conversations.lastMessages[_bobChat]?.id, newest);
    });

    test('a box message deleted here is never the last message, even '
        'before its record is gone', () async {
      // Delete is offered from the open chat.
      conversations.openConversation(_bobChat);
      provider.setActiveConversationIdForTest(_bobChat);
      final older = await fromBob(
        'older',
        wire: 'wire-1',
        ago: const Duration(minutes: 3),
      );
      final deleted = await fromBob('deleted', wire: 'wire-2');
      provider.deleteMessage(deleted, forEveryone: false);

      await provider.applyStoredBoxLastMessages();

      expect(conversations.lastMessages[_bobChat]?.id, older);
    });

    test('a server row newer than every stored box message wins', () async {
      await fromBob('box', wire: 'wire-1', ago: const Duration(minutes: 20));

      await coldStart();

      expect(conversations.lastMessages[_bobChat]?.id, 900);
      expect(listOrder(), [_carolChat, _bobChat]);
    });

    test('a chat made over the box gets its last message too', () async {
      final chat = localConversationIdFor(5);
      final id = await storedFromBob(
        'hi erin',
        wire: 'wire-e',
        ago: const Duration(minutes: 2),
        conversationId: chat,
      );

      await coldStart();

      expect(conversations.lastMessages[chat]?.id, id);
    });

    test('a box message deleted for everyone is never the last message, '
        'even while its record survives', () async {
      final live = await storedFromBob(
        'still here',
        wire: 'wire-1',
        ago: const Duration(minutes: 8),
      );
      await storedFromBob(
        'deleted',
        wire: 'wire-2',
        ago: const Duration(minutes: 1),
      );
      await encryption.store.addBoxTombstone((
        senderId: _bobId,
        wireId: 'wire-2',
      ));

      await coldStart();

      expect(conversations.lastMessages[_bobChat]?.id, live);
    });

    test('an expired box message is never the last message', () async {
      final live = await storedFromBob(
        'still here',
        wire: 'wire-1',
        ago: const Duration(minutes: 8),
      );
      // A 60 s timer whose countdown started 2 minutes ago.
      await storedFromBob(
        'gone',
        wire: 'wire-2',
        ago: const Duration(minutes: 2),
        disappearAfterSeconds: 60,
        extra: {
          'ttlFrom': now
              .subtract(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
        },
      );

      await coldStart();

      expect(conversations.lastMessages[_bobChat]?.id, live);
    });

    test('the server list arriving after the stored box messages keeps the '
        'newer box message', () async {
      final newest = await fromBob('newest box', wire: 'wire-1');
      provider.dispose();
      encryption = _Encryption(await openService());
      conversations = newConversations();
      provider = newProvider();
      await provider.applyStoredBoxLastMessages();

      conversations.onConversationsList(snapshot());

      expect(conversations.lastMessages[_bobChat]?.id, newest);
    });
  });

  /// Decision 73 (E73a): a box message this device has not shown keeps its
  /// badge across an app restart. Each chat's seen mark is device-local; a
  /// chat never shown here reads as seen up to when this device first kept
  /// marks, which the group's first E2E ready fixes (a first launch).
  group('box unread across a restart (decision 73)', () {
    setUp(() async {
      await provider.applyStoredBoxLastMessages();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      now = DateTime.now().toUtc();
    });

    test('an unopened peer box message in a server chat keeps its badge, '
        "on top of the server's count", () async {
      await fromBob('unread', wire: 'wire-1', ago: Duration.zero);

      await coldStart(bobUnread: 2);

      expect(conversations.getUnreadCount(_bobChat), 3);
      reconnect(bobUnread: 2);
      expect(conversations.getUnreadCount(_bobChat), 3);
      expect(conversations.getUnreadCount(_carolChat), 0);
    });

    test('the server list arriving after the stored rows adds its count to '
        'theirs', () async {
      await fromBob('unread', wire: 'wire-1', ago: Duration.zero);
      provider.dispose();
      encryption = _Encryption(await openService());
      conversations = newConversations();
      provider = newProvider();
      await provider.applyStoredBoxLastMessages();

      conversations.onConversationsList(snapshot(bobUnread: 2));

      expect(conversations.getUnreadCount(_bobChat), 3);
    });

    test('an unopened box message in a chat made over the box keeps its '
        'badge', () async {
      final chat = localConversationIdFor(5);
      await storedFromBob(
        'hi erin',
        wire: 'wire-e',
        ago: Duration.zero,
        conversationId: chat,
        from: 5,
      );

      await coldStart();

      expect(conversations.getUnreadCount(chat), 1);
    });

    test('a chat made over the box that was deleted here gets no badge',
        () async {
      final chat = localConversationIdFor(5);
      await store.update(
        5,
        (_) => ContactRecord(
          userId: 5,
          username: 'erin',
          tag: '0005',
          state: ContactState.friend,
          boxOrigin: ContactBoxOrigin(at: DateTime.utc(2026, 9, 27)),
          settings: const ContactSettings(chatHidden: true),
        ),
      );
      await store.settled;
      await storedFromBob(
        'hi erin',
        wire: 'wire-e',
        ago: Duration.zero,
        conversationId: chat,
        from: 5,
      );

      await coldStart();

      expect(conversations.getUnreadCount(chat), 0);
    });

    test('a chat shown before the restart has no badge after it', () async {
      await fromBob('read here', wire: 'wire-1', ago: Duration.zero);
      await show(_bobChat);
      leave();

      await coldStart();

      expect(conversations.getUnreadCount(_bobChat), 0);
    });

    test('a message that arrives in the chat on screen has no badge after '
        'a restart', () async {
      await show(_bobChat);
      await fromBob('arrived on screen', wire: 'wire-1', ago: Duration.zero);
      leave();

      await coldStart();

      expect(conversations.getUnreadCount(_bobChat), 0);
    });

    test('only what arrived after the chat was last shown counts', () async {
      await fromBob('read here', wire: 'wire-1', ago: Duration.zero);
      await show(_bobChat);
      leave();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      now = DateTime.now().toUtc();
      await fromBob('after', wire: 'wire-2', ago: Duration.zero);

      await coldStart();

      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('our own box messages, an expired one and one deleted for everyone '
        'never count', () async {
      await storedFromBob('still here', wire: 'wire-1', ago: Duration.zero);
      await storedFromBob(
        'mine',
        wire: 'wire-2',
        ago: Duration.zero,
        from: _me,
      );
      // A 60 s timer whose countdown started 2 minutes ago.
      await storedFromBob(
        'gone',
        wire: 'wire-3',
        ago: Duration.zero,
        disappearAfterSeconds: 60,
        extra: {
          'ttlFrom': now
              .subtract(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
        },
      );
      await storedFromBob('deleted', wire: 'wire-4', ago: Duration.zero);
      await encryption.store.addBoxTombstone((
        senderId: _bobId,
        wireId: 'wire-4',
      ));

      await coldStart();

      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('a chat loaded while the app is hidden is not seen: its badge '
        'survives a restart', () async {
      await storedFromBob('unread', wire: 'wire-1', ago: Duration.zero);
      conversations.setClientVisible(false);
      await show(_bobChat);
      leave();
      conversations.setClientVisible(true);

      await coldStart();

      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('the chat on screen when the stored rows are read gets no badge',
        () async {
      await storedFromBob('unread', wire: 'wire-1', ago: Duration.zero);
      provider.dispose();
      encryption = _Encryption(await openService());
      conversations = newConversations()
        ..onConversationsList(snapshot())
        ..openConversation(_bobChat);
      await store.settled;
      provider = newProvider();

      await provider.applyStoredBoxLastMessages();

      expect(conversations.getUnreadCount(_bobChat), 0);
    });

    test('a later reconnect keeps the live state and reads no record '
        'again', () async {
      await coldStart();
      expect(encryption.recordReads, 1);
      await fromBob('live', wire: 'wire-1', ago: Duration.zero);

      reconnect();
      await provider.applyStoredBoxLastMessages();

      expect(encryption.recordReads, 1);
      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('a message counted live before the stored rows are read counts '
        'once', () async {
      provider.dispose();
      encryption = _Encryption(await openService());
      conversations = newConversations()..onConversationsList(snapshot());
      await store.settled;
      provider = newProvider();
      await fromBob('live', wire: 'wire-1', ago: Duration.zero);
      expect(conversations.getUnreadCount(_bobChat), 1);

      await provider.applyStoredBoxLastMessages();

      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('in a chat made over the box, a message counted live and then found '
        'stored counts once, a snapshot in between', () {
      final chat = localConversationIdFor(5);
      const id = kFirstLocalMessageId + 99;

      conversations
        ..incrementUnreadCount(chat, boxId: id)
        ..onConversationsList(snapshot())
        ..seedBoxUnread({
          chat: {id},
        });

      expect(conversations.getUnreadCount(chat), 1);
    });

    test('a message found stored and then shown live in the list counts '
        'once (the pass read its record before it was shown)', () {
      const id = kFirstLocalMessageId + 99;

      conversations
        ..seedBoxUnread({
          _bobChat: {id},
        })
        ..incrementUnreadCount(_bobChat, boxId: id);

      expect(conversations.getUnreadCount(_bobChat), 1);
    });

    test('a logout clears the badge; the next sign-in and a fresh connect '
        'each read the stored rows again', () async {
      await fromBob('unread', wire: 'wire-1', ago: Duration.zero);
      await coldStart();
      expect(conversations.getUnreadCount(_bobChat), 1);

      conversations.clearAll();
      provider.clearAll();
      expect(conversations.getUnreadCount(_bobChat), 0);
      conversations
        ..setCurrentUserId(_me)
        ..onConversationsList(snapshot());
      provider.setCurrentUserId(_me);
      await provider.applyStoredBoxLastMessages();
      expect(encryption.recordReads, 2);
      expect(conversations.getUnreadCount(_bobChat), 1);

      conversations
        ..onConnect(false)
        ..onConversationsList(snapshot());
      await provider.applyStoredBoxLastMessages();
      expect(encryption.recordReads, 3);
      expect(conversations.getUnreadCount(_bobChat), 1);
    });
  });
}
