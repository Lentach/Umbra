import '../../models/message_model.dart';
import '../../utils/anti_quantum_note_link.dart';

/// Fixed height of the long-press menu's placeholder copy of a media bubble.
/// Same value as `MediaPreviewFrame.legacyHeight`, the fallback for media
/// without dimensions; live bubbles size from the media's aspect ratio.
const kMessageMediaBubbleHeight = 220.0;

/// Whether delivery time sits inline on the right vs stacked below.
/// Text stacks only for explicit line breaks or richer message chrome.
/// Shared by [ChatMessageBubble] and [MessageContextMenuBubbleHighlight] so overlay
/// highlight height matches the anchored bubble.
bool messageBubbleUsesInlineTime({
  required MessageModel message,
  required String displayContent,
}) {
  if (message.replyTo != null || message.linkPreviewUrl != null) return false;
  // Anti-Quantum Note links render as a banner card; time stacks below it
  // like link-preview bubbles, never inline beside the card. Own-origin
  // (this build OR production) mirrors the card gate in TextMessageContent —
  // a dev build receiving a production link still renders the card.
  if (isOwnOriginNoteUrl(displayContent)) return false;
  switch (message.messageType) {
    case MessageType.text:
      return !displayContent.contains('\n');
    case MessageType.ping:
      return true;
    case MessageType.image:
    case MessageType.file:
      return false;
    default:
      return false;
  }
}
