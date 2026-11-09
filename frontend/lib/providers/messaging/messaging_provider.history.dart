part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Timeline state: `_messages`, the RAM cache, and what a chat shows when it
/// opens. Every message a chat holds is a box message (or an optimistic row
/// of this session): its words are read from this device's records, never
/// fetched (decision 99).
extension MessagingHistory on MessagingProvider {
  /// Whether a warm message cache exists for [conversationId].
  bool hasCachedMessages(int conversationId) =>
      _conversationCache.containsKey(conversationId);

  /// Read-only snapshot of the RAM cache for [conversationId] (empty when
  /// cold). Unlike [loadCachedMessages] this NEVER touches [_messages], so
  /// passive consumers (user-card shared media) can't disturb the active chat.
  List<MessageModel> cachedMessagesFor(int conversationId) =>
      List.unmodifiable(_conversationCache[conversationId] ?? const []);

  /// Immediately populates [_messages] from RAM cache if available and calls notifyListeners().
  /// Returns true if cache was used — caller can then skip expensive initial scroll setup.
  /// Always follow this with getMessages() to pick up what the records hold.
  bool loadCachedMessages(int conversationId) {
    final cached = _conversationCache[conversationId];
    if (cached == null || cached.isEmpty) return false;
    final now = DateTime.now();
    _messages = List.from(cached.where((m) => !isMessageExpired(m, now)));
    notifyListeners();
    return true;
  }

  /// Snapshots messages for [conversationId] into cache.
  /// Filters by conversationId so async paths are safe if _messages holds another conversation.
  /// Removes the cache entry if the filtered list is empty (keeps hasCachedMessages consistent).
  void _updateCache(int conversationId) {
    final now = DateTime.now();
    final filtered = List<MessageModel>.from(
      _messages.where(
        (m) => m.conversationId == conversationId && !isMessageExpired(m, now),
      ),
    );
    if (filtered.isEmpty) {
      _conversationCache.remove(conversationId);
    } else {
      _conversationCache[conversationId] = filtered;
    }
  }

  void _patchMessageInCache(
    int conversationId,
    int messageId,
    MessageModel Function(MessageModel current) patch,
  ) {
    final cache = _conversationCache[conversationId];
    if (cache == null) return;
    final idx = cache.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    cache[idx] = patch(cache[idx]);
  }

  /// Opens [conversationId]: [_messages] keeps this chat's rows alone, then
  /// the messages this device stores for it are read from their records
  /// ([_mergeLocalBoxRows]), with the sends that did not go out. Nothing is
  /// asked of the server: an old-path message is never shown (decision 99),
  /// whatever plaintext of it is still on disk.
  void getMessages(int conversationId) {
    _installChat(conversationId, _messages);
    final active = _effectiveActiveConversationId;
    if (active != null) markConversationRead(active);
    unawaited(_mergeLocalBoxRows(conversationId));
  }

  /// E2E is ready (every connect): the chat on screen reads its stored
  /// messages again. A launch with no network opens its chat while the
  /// record store has no signed-in user, which answers "none stored"
  /// ([EncryptionService.localMessageRecords]); the first connect's
  /// initialize sets the user, and without this only a resume read the chat
  /// again. The narrow merge ([_mergeLocalBoxRows], as a history import
  /// does): rows the chat holds stay, scroll and the open chat's state are
  /// not reset, and the read receipt, seen mark and countdowns go once as on
  /// entry. Nothing when no chat is open.
  Future<void> rereadOpenChat() async {
    final open = _effectiveActiveConversationId;
    if (open == null) return;
    await _mergeLocalBoxRows(open);
  }

  /// Makes [rows] — those of [conversationId] — the open chat's rows, oldest
  /// first, without the ones deleted here or expired.
  void _installChat(int conversationId, Iterable<MessageModel> rows) {
    _openConversationId = conversationId;
    final now = DateTime.now();
    _messages = [
      for (final m in rows)
        if (m.conversationId == conversationId &&
            !_deletedMessageIds.contains(m.id) &&
            !isMessageExpired(m, now))
          m,
    ]..sort(_byTimeThenId);
    _reEnrichAllReplyQuotes();
    notifyListeners();
    _updateCache(conversationId);
  }

  /// Test-only: [rows] of [conversationId] stand as that chat opened, as the
  /// records read by [getMessages] would leave them.
  @visibleForTesting
  void seedMessagesForTest(int conversationId, List<MessageModel> rows) =>
      _installChat(conversationId, rows);

  int _byTimeThenId(MessageModel a, MessageModel b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  void _addMessageToState(MessageModel msg) {
    final activeConversationId = _effectiveActiveConversationId;

    // Our own message shown by its send: it replaces the optimistic row of
    // that tempId. A `tempId` exists only on the device that minted it, so a
    // sibling's sent copy never matches one.
    if (msg.senderId == _currentUserId && msg.tempId != null) {
      _messages.removeWhere((m) => m.tempId == msg.tempId);
    }

    // Add or update in the open chat (active id may lag openConversation briefly).
    final viewingConversationId = activeConversationId ?? _openConversationId;
    if (msg.conversationId == viewingConversationId) {
      final existingById = _messages.indexWhere(
        (m) => m.id == msg.id && msg.id > 0,
      );
      if (existingById != -1) {
        _messages[existingById] = msg;
      } else {
        _messages.add(msg);
      }
    }

    _conversationsProvider?.updateLastMessage(msg.conversationId, msg);
    if (msg.senderId != _currentUserId) {
      if (msg.conversationId != activeConversationId) {
        _conversationsProvider?.incrementUnreadCount(
          msg.conversationId,
          boxId: isLocalMessageId(msg.id) ? msg.id : null,
        );
      }
      if (msg.conversationId == activeConversationId) {
        markConversationRead(msg.conversationId);
      }
    }
    // Clear typing and recording indicators when message arrives
    if (_typingStatus[msg.conversationId] == true) {
      _typingTimers[msg.conversationId]?.cancel();
      _typingTimers.remove(msg.conversationId);
      _typingStatus[msg.conversationId] = false;
    }
    _partnerRecordingVoice.remove(msg.conversationId);
    _boxVoiceTimers.remove(msg.conversationId)?.cancel();
    notifyListeners();
  }
}
