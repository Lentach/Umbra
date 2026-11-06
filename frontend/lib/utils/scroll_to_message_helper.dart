// reverse:true → visual bottom = offset 0 = newest.
// msgIndex (oldest-first) → listIndex = messages.length - 1 - msgIndex.
// This file does NOT call Scrollable.ensureVisible — caller owns GlobalKey lifecycle.

import '../models/message_model.dart';

/// With [ListView.reverse: true], builder index 0 = newest (last in oldest-first list).
int? listIndexForMessageId({
  required int messageId,
  required List<MessageModel> messages,
}) {
  final msgIndex = messages.indexWhere((m) => m.id == messageId);
  if (msgIndex < 0) return null;
  return messages.length - 1 - msgIndex;
}
