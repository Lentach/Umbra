import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_seed.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  group('MessagingProvider media reply', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;

    setUp(() {
      provider = MessagingProvider();
      conversations = ConversationsProvider();
      seedConversations(conversations, [
        {
          'id': 10,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
      ]);
      provider.setConversationsProvider(conversations);
      provider.setCurrentUserId(1);
      provider.setToken('tok');
      provider.onConnect(false);
      conversations.openConversation(10);
      provider.setReplyingTo(
        MessageModel(
          id: 42,
          content: 'quoted text',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
    });

    test('sendImageMessage includes replyToMessageId in optimistic message', () async {
      await provider.sendImageMessage(
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'test.jpg'),
        2,
      );

      final optimistic = provider.messages.last;
      expect(optimistic.replyToMessageId, 42);
      expect(optimistic.replyTo?.id, 42);
      expect(optimistic.replyTo?.content, 'quoted text');
      expect(provider.replyingToMessage, isNull);
    });
  });
}
