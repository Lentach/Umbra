import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/utils/message_ids.dart';

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

    test('seeding a chat populates its cache and rows', () {
      provider.setActiveConversationIdForTest(10);
      provider.seedMessagesForTest(10, [_msg(1, 10)]);

      expect(provider.hasCachedMessages(10), isTrue);
      expect(provider.messages.length, 1);
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

    test('a row with no local id cannot be deleted', () {
      provider.seedCacheForTest(10, [_msg(1, 10)]);
      provider.setActiveConversationIdForTest(10);
      provider.loadCachedMessages(10);

      provider.deleteMessage(1, forEveryone: false);

      expect(provider.messages.map((m) => m.id), [1]);
    });
  });
}
