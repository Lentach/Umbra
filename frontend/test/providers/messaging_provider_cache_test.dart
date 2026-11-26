import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/chat_seed.dart';

MessageModel _msg(int id, int convId, {DateTime? at}) => MessageModel(
      id: id,
      content: 'hello',
      senderId: 1,
      senderUsername: 'alice',
      conversationId: convId,
      createdAt: at ?? DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessagingProvider cache', () {
    late MessagingProvider provider;

    setUp(() {
      provider = MessagingProvider();
      provider.setIncomingMessageSoundEnabledForTest(false);
      // onConnect signature is: void onConnect(bool isReconnect)
      // userId and token are set separately via dedicated setters.
      provider.onConnect(false);
      provider.setCurrentUserId(1);
      provider.setToken('tok');
    });

    test('hasCachedMessages returns false when no cache', () {
      expect(provider.hasCachedMessages(42), isFalse);
    });

    test('loadCachedMessages returns false when no cache', () {
      final result = provider.loadCachedMessages(42);
      expect(result, isFalse);
      expect(provider.messages, isEmpty);
    });

    test('loadCachedMessages returns true and sets messages when cache exists', () {
      provider.seedCacheForTest(10, [_msg(1, 10), _msg(2, 10)]);

      final result = provider.loadCachedMessages(10);
      expect(result, isTrue);
      expect(provider.messages.length, 2);
      expect(provider.messages.first.id, 1);
    });

    test('loadCachedMessages returns a copy — provider messages are independent of cache', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.loadCachedMessages(10);

      // The messages getter exposes the live loaded list. Mutating it in place
      // must NOT touch the cache — loadCachedMessages hands back a distinct copy
      // (`_messages = List.from(cached...)`), not an alias of the cache list.
      // If the impl regressed to `_messages = cached`, this add would leak into
      // _conversationCache[10] and the assertions below would fail.
      provider.messages.add(_msg(2, 10));

      expect(provider.cacheMessageForTest(10, 2), isNull);
      expect(provider.cachedMessagesFor(10).length, 1);
      expect(provider.cachedMessagesFor(10).first.id, 1);
      expect(provider.hasCachedMessages(10), isTrue);
    });

    test('clearAll clears the cache', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.clearAll();
      expect(provider.hasCachedMessages(10), isFalse);
    });

    test('clearMessages does NOT clear the cache', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.clearMessages();
      // Cache survives back-navigation (clearMessages is called on back button)
      expect(provider.hasCachedMessages(10), isTrue);
    });

    test('onConnect does NOT clear the cache', () {
      // Cache is session-scoped — a fresh socket connect (same session, same user)
      // must NOT evict cache entries.
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.onConnect(false);
      expect(provider.hasCachedMessages(10), isTrue);
    });

    test('a chat shows its own rows only, oldest first', () {
      provider.setActiveConversationIdForTest(10);
      provider.seedMessagesForTest(10, [
        _msg(2, 10, at: DateTime.utc(2026, 1, 1, 1)),
        _msg(1, 10),
        _msg(3, 99),
      ]);

      expect(provider.messages.map((m) => m.id), [1, 2]);
      expect(provider.hasCachedMessages(99), isFalse);
    });

    test('clearChatHistory removes cache entry', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.clearChatHistory(10);
      expect(provider.hasCachedMessages(10), isFalse);
    });

    test('a removed conversation loses its cache entry', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.onConversationsRemovedForUser([10]);
      expect(provider.hasCachedMessages(10), isFalse);
    });

    test('deleting a message here updates cache and reflects removal', () {
      provider.seedCacheForTest(10, [
        _msg(kFirstLocalMessageId + 1, 10),
        _msg(kFirstLocalMessageId + 2, 10),
      ]);
      provider.setActiveConversationIdForTest(10);
      provider.loadCachedMessages(10);

      provider.deleteMessage(kFirstLocalMessageId + 1, forEveryone: false);

      expect(provider.hasCachedMessages(10), isTrue);
      expect(provider.messages.length, 1);
      expect(provider.messages.first.id, kFirstLocalMessageId + 2);
    });

    test('deleting the last message removes the cache entry', () {
      provider.seedCacheForTest(10, [_msg(kFirstLocalMessageId + 1, 10)]);
      provider.setActiveConversationIdForTest(10);
      provider.loadCachedMessages(10);

      provider.deleteMessage(kFirstLocalMessageId + 1, forEveryone: false);

      // Empty list → cache entry removed so hasCachedMessages is false
      expect(provider.hasCachedMessages(10), isFalse);
    });

    // X2: "delete all local messages" destroyed the stored plaintext but the
    // open chat's rows, the chat cache and the list previews stayed on
    // screen until a restart.
    test('wiping all local history empties the open chat and the previews', () {
      final conversations = ConversationsProvider();
      provider
        ..setConversationsProvider(conversations)
        ..setActiveConversationIdForTest(10)
        ..seedMessagesForTest(10, [_msg(1, 10), _msg(2, 10)])
        ..seedCacheForTest(11, [_msg(3, 11)]);
      conversations.updateLastMessage(10, _msg(2, 10));
      var notified = 0;
      provider
        ..addListener(() => notified++)
        ..onLocalHistoryWiped();

      expect(provider.messages, isEmpty);
      expect(provider.hasCachedMessages(10), isFalse);
      expect(provider.hasCachedMessages(11), isFalse);
      expect(conversations.lastMessages, isEmpty);
      expect(notified, 1);
    });

    test('a wipe also drops the reply and edit in progress, the pinned '
        'preview and the unread counts of the wiped chats', () {
      final conversations = ConversationsProvider()..onConnect(false);
      seedConversations(conversations, [
        {
          'id': 10,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'unreadCount': 3,
        },
      ]);
      conversations.applyBoxPin(
        10,
        BoxPin(at: DateTime.utc(2026, 2), senderId: 1, wireId: 'w1'),
        shown: _msg(kFirstLocalMessageId + 1, 10),
      );
      provider
        ..setConversationsProvider(conversations)
        ..setReplyingTo(_msg(1, 10))
        ..beginEditMessage(_msg(2, 10));
      expect(conversations.conversations.single.pinnedMessagePreview, isNotNull);
      expect(conversations.getUnreadCount(10), 3);

      provider.onLocalHistoryWiped();

      expect(provider.replyingToMessage, isNull);
      expect(provider.editingMessage, isNull);
      expect(conversations.conversations.single.pinnedMessagePreview, isNull);
      expect(conversations.conversations.single.pinnedMessageId, isNull);
      expect(conversations.getUnreadCount(10), 0);
    });
  });

  group('MessagingProvider composer focus on reply', () {
    test('setReplyingTo invokes registered composer focus request', () {
      final provider = MessagingProvider();
      var focusCalls = 0;
      provider.setComposerFocusRequest(() => focusCalls++);

      provider.setReplyingTo(
        MessageModel(
          id: 1,
          content: 'hello',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      expect(focusCalls, 1);
      expect(provider.replyingToMessage?.id, 1);

      provider.setReplyingTo(null);
      expect(focusCalls, 1);
    });
  });

  group('MessagingProvider reply quote enrichment', () {
    test('incoming message enriches encrypted reply quote from decrypt cache', () {
      final provider = MessagingProvider();
      provider.setIncomingMessageSoundEnabledForTest(false);
      final encryption = EncryptionProvider();
      provider.setEncryptionProvider(encryption);
      provider.setCurrentUserId(1);
      provider.onConnect(false);
      provider.setActiveConversationIdForTest(10);

      encryption.cacheDecryption(
        99,
        MessageModel(
          id: 99,
          content: 'secret reply body',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

      provider.seedMessagesForTest(10, [
        MessageModel(
          id: 100,
          content: 'hello',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
          replyTo: ReplyToPreview(
            id: 99,
            content: 'Encrypted message',
            senderUsername: 'bob',
            messageType: MessageType.text,
          ),
        ),
      ]);

      final stored = provider.messages.single;
      expect(stored.replyTo?.content, 'secret reply body');
    });
  });

  group('MessagingProvider.sendVoiceMessage', () {
    late MessagingProvider provider;

    setUp(() {
      provider = MessagingProvider();
    });

    test('throws when not authenticated', () async {
      await expectLater(
        provider.sendVoiceMessage(
          recipientId: 2,
          duration: 1,
          localAudioBytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when no active conversation', () async {
      provider.setCurrentUserId(1);
      await expectLater(
        provider.sendVoiceMessage(
          recipientId: 2,
          duration: 1,
          localAudioBytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
