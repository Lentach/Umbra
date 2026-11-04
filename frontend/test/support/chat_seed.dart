import 'package:fireplace/models/conversation_model.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';

/// Installs [json] (the shape the server's `conversationsList` used to carry:
/// conversation maps with optional `unreadCount` and `lastMessage`) as the
/// provider's chat list, as a contact-store hydration would. Replaces the
/// list; a second call is a new snapshot.
void seedConversations(
  ConversationsProvider provider,
  List<Map<String, dynamic>> json,
) {
  final unread = <int, int>{};
  final lastMessages = <int, MessageModel>{};
  final conversations = <ConversationModel>[];
  for (final m in json) {
    final conversation = ConversationModel.fromJson(m);
    conversations.add(conversation);
    final count = (m['unreadCount'] as num?)?.toInt();
    if (count != null) unread[conversation.id] = count;
    final last = m['lastMessage'];
    if (last != null) {
      lastMessages[conversation.id] = MessageModel.fromJson(
        last as Map<String, dynamic>,
      );
    }
  }
  provider.debugSeed(conversations, unread: unread, lastMessages: lastMessages);
}
