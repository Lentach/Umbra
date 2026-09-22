import '../providers/conversations_provider.dart';
import '../providers/messaging_provider.dart';

/// Re-asserts [conversationId] as the active conversation and reloads it.
///
/// Called from `ChatDetailScreen` on app resume. On iOS PWA, a background→resume
/// can dispose the chat widget and/or reconnect the socket while the chat is still
/// on screen; `ChatDetailScreen.dispose()` → `closeConversation()` + `clearMessages()`
/// then null `activeConversationId` / `_paginationConversationId`. Incoming messages
/// arriving in that window are dropped by `_addMessageToState`'s active-id gate
/// (diagnosed via `E2eDiagLog` `ADD_TO_STATE appendedToOpenChat:false`), and recovery
/// otherwise depends on a race in `_onSocketReady`. Re-asserting + refetching on
/// resume restores the open chat deterministically instead of waiting for a manual
/// reopen, and re-tells the push SW which chat is open. The server's visibility
/// state is re-sent by the resume lifecycle / `socketReady`, never per chat.
void reassertOpenConversationOnResume(
  ConversationsProvider conversations,
  MessagingProvider messaging,
  int conversationId,
) {
  conversations.openConversation(conversationId);
  messaging.loadCachedMessages(conversationId);
  messaging.getMessages(conversationId);
}
