part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// User- and timer-driven mutations: read / clear / delete / pin / react / expiry.
/// Every message a chat holds has a local id and a wire id, so each action is
/// local to this device or goes over the box; a row with neither cannot be
/// acted on.
extension MessagingActions on MessagingProvider {
  /// The chat on screen was read: its disappearing messages start counting
  /// (decision 41), the peer is told when the switch is on (slice (g), E61d),
  /// and a restart does not count them as unread again (decision 73).
  ///
  /// Do NOT run from a backgrounded client. A hidden PWA with a mounted
  /// chat route used to mark every arriving message READ while the user was
  /// away (field bug, users 48/90, Aug 2026). Fail-open on a missing provider:
  /// desktop and existing tests keep the old behavior. Recovery marking on
  /// return is guaranteed because every foreground path re-opens the chat
  /// (connection_provider._onSocketReady / _resyncAfterResume /
  /// chat_resume_reassert.dart) and that calls markConversationRead again with
  /// this gate passing.
  void markConversationRead(int conversationId) {
    if (_conversationsProvider?.isClientVisible == false) return;
    _startBoxCountdowns(conversationId);
    _sendBoxReadReceipt(conversationId);
    _markBoxChatSeen(conversationId);
  }

  /// A chat is cleared on this device alone (owner decision 52): its records
  /// and rows go.
  void clearChatHistory(int conversationId) =>
      _clearChatLocally(conversationId);

  void deleteMessage(int messageId, {required bool forEveryone}) {
    // A box message that did not go out (decision 104) has no record:
    // deleting it drops this device's kept copy, nothing else.
    final unsent = _messages
        .where((m) => m.id == messageId && m.tempId != null)
        .firstOrNull;
    final owner = _currentUserId;
    if (unsent != null &&
        owner != null &&
        unsent.deliveryStatus == MessageDeliveryStatus.failed &&
        _boxUnsentTempIds.remove(unsent.tempId)) {
      _messages.remove(unsent);
      _encryptionProvider?.dropBoxUnsent(owner, unsent.tempId!).ignore();
      if (_conversationCache.containsKey(unsent.conversationId)) {
        _updateCache(unsent.conversationId);
      }
      notifyListeners();
      return;
    }
    if (!isLocalMessageId(messageId)) return;
    // "For me" is this device's copy, "for everyone" goes over the box
    // (item 4).
    if (forEveryone) {
      _deleteOverBox(messageId).ignore();
      return;
    }
    final conversationId = messageById(messageId)?.conversationId;
    if (conversationId == null) return;
    _deleteMessageLocally(messageId, conversationId);
  }

  /// Optimistically apply a TEXT edit to a sent message, then send it over
  /// the box (item 4). Only own TEXT rows with a local id and a wire id are
  /// editable.
  void editMessage(int messageId, String newContent) {
    final trimmed = newContent.trim();
    if (trimmed.isEmpty || _currentUserId == null) return;
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null) return;

    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    final original = _messages[idx];
    if (original.senderId != _currentUserId ||
        !isLocalMessageId(messageId) ||
        original.wireId == null ||
        original.messageType != MessageType.text ||
        DateTime.now().difference(original.createdAt) >= kMessageEditWindow) {
      cancelEditMessage();
      return;
    }
    if (original.content == trimmed) {
      cancelEditMessage();
      return;
    }

    _pendingEdits[messageId] = original;
    // A box edit's time is its envelope's `ts`, in whole ms: every device
    // keeps the same `editedAt` for last-writer-wins (E19b).
    final editedAt = _wholeMsNow();
    final edited = original.copyWith(content: trimmed, editedAt: editedAt);
    _messages[idx] = edited;
    _reEnrichAllReplyQuotes();
    final lastMessages = _conversationsProvider?.lastMessages;
    if (lastMessages != null &&
        lastMessages[activeConversationId]?.id == messageId) {
      _conversationsProvider?.updateLastMessage(activeConversationId, edited);
    }
    if (_conversationCache.containsKey(activeConversationId)) {
      _updateCache(activeConversationId);
    }
    cancelEditMessage();
    notifyListeners();

    _editOverBox(original, trimmed, editedAt).ignore();
  }

  /// Restore the pre-edit row after a failure: in-memory row, the persisted
  /// plaintext record, and the conversation-list preview. Without all three a
  /// failed edit would resurrect on reopen and diverge from the peer.
  void _revertPendingEdit(int messageId) {
    final original = _pendingEdits.remove(messageId);
    if (original == null) return;
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx != -1) {
      _messages[idx] = original;
      _reEnrichAllReplyQuotes();
      if (_conversationCache.containsKey(original.conversationId)) {
        _updateCache(original.conversationId);
      }
    }
    // Roll back the persisted plaintext written with the optimistic edit.
    _persistDecryptedContent(original).ignore();
    final lastMessages = _conversationsProvider?.lastMessages;
    if (lastMessages != null &&
        lastMessages[original.conversationId]?.id == messageId) {
      _conversationsProvider?.updateLastMessage(
        original.conversationId,
        original,
      );
    }
    notifyListeners();
  }

  void pinMessage(int conversationId, int messageId) {
    if (!isLocalMessageId(messageId)) return;
    _pinOverBox(conversationId, messageId).ignore();
  }

  void unpinMessage(int conversationId) {
    // An E2E pin on show is unpinned over the box (decision 45).
    final convs = _conversationsProvider;
    final pin = convs?.boxPinOf(conversationId);
    final shown = convs?.getConversationById(conversationId)?.pinnedMessageId;
    if (pin != null && pin.pinned && shown != null && isLocalMessageId(shown)) {
      _unpinOverBox(conversationId, pin).ignore();
    }
  }

  /// Adds a reaction as a plain emoji over the box (item 4, E19d). Returns
  /// false when this device could not, in which case the caller SHOWS that —
  /// a silent no-op looks like a dead tap.
  Future<bool> addReaction(int messageId, String emoji) =>
      isLocalMessageId(messageId)
      ? _reactOverBox(messageId, emoji, on: true)
      : Future.value(false);

  /// Removes a reaction, as [addReaction] adds one. False has the same
  /// meaning.
  Future<bool> removeReaction(int messageId, String emoji) =>
      isLocalMessageId(messageId)
      ? _reactOverBox(messageId, emoji, on: false)
      : Future.value(false);

  /// Remove messages whose expiresAt has passed. Called every second by ChatDetailScreen timer.
  void removeExpiredMessages() {
    final now = DateTime.now();
    final hadExpiredInList = _messages.any((m) => isMessageExpired(m, now));
    var hadExpiredInCache = false;
    for (final cid in _conversationCache.keys.toList()) {
      final list = _conversationCache[cid];
      if (list == null) continue;
      final before = list.length;
      list.removeWhere((m) => isMessageExpired(m, now));
      if (list.length != before) hadExpiredInCache = true;
      if (list.isEmpty) _conversationCache.remove(cid);
    }
    if (!hadExpiredInList && !hadExpiredInCache) return;

    _messages.removeWhere((m) => isMessageExpired(m, now));
    _conversationsProvider?.pruneExpiredLastMessages();
    notifyListeners();
  }
}
