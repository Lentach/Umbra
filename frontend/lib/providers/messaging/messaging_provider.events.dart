part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Inbound indicators from stale clients' account sockets, and the local
/// removal of messages and chats from this device.
extension MessagingEvents on MessagingProvider {
  void onPartnerTyping(dynamic data) {
    _handlePartnerTyping(data);
  }

  void onPartnerRecordingVoice(dynamic data) {
    _handlePartnerRecordingVoice(data);
  }

  /// This device's copy of [conversationId] is gone: its stored plaintext,
  /// its rows and its last-message preview.
  void _clearChatLocally(int conversationId) {
    _purgeConversationsLocally([conversationId]);

    _messages.removeWhere((m) => m.conversationId == conversationId);
    _conversationsProvider?.updateLastMessage(conversationId, null);

    notifyListeners();
    _conversationCache.remove(conversationId);
  }

  /// Unfriend / block: destroy the local plaintext for [conversationIds] and
  /// drop their rows.
  ///
  /// Removing a contact must not leave their decrypted history in memory or
  /// on disk indefinitely.
  void onConversationsRemovedForUser(Iterable<int> conversationIds) {
    final targets = conversationIds.toSet();
    if (targets.isEmpty) return;
    _purgeConversationsLocally(targets);
    _messages.removeWhere((m) => targets.contains(m.conversationId));
    for (final id in targets) {
      _conversationCache.remove(id);
    }
    notifyListeners();
  }

  /// Destroy every persisted plaintext record this device holds for
  /// [conversationIds] — including messages this session never loaded.
  ///
  /// The ids come from a scan of the store, keyed on the `_cid` stamped into
  /// each record, NOT from `_messages`: up to 2000 records persist across
  /// sessions, so purging only the loaded rows would strand the rest
  /// permanently — a cleared or unfriended message has no expiry, so no later
  /// sweep would find it either.
  void _purgeConversationsLocally(Iterable<int> conversationIds) {
    final targets = conversationIds.toSet();
    if (targets.isEmpty) return;
    final encryption = _encryptionProvider;
    if (encryption == null) return;
    // Safe to fire and forget: purgeConversations routes through
    // purgeLocalPlaintext, which writes a durable backlog entry before it
    // touches anything, so an interrupted purge is retried on the next launch.
    _firePurge(encryption.purgeConversations(targets));
  }

  /// Start a purge without awaiting it, and without letting a failure escape as
  /// an unhandled async error.
  ///
  /// These run from synchronous handlers, so there is nobody to await them. A
  /// throw here would abandon the rest of the handler and surface as an
  /// unhandled zone error rather than as a retry. Correctness does not depend
  /// on this completing: the durable purge backlog is written before any store
  /// is touched, so whatever fails is retried on the next `socketReady`.
  void _firePurge(Future<void> purge) {
    unawaited(
      purge.catchError((Object error) {
        E2ePersistentDiag.record('PLAINTEXT_PURGE_THREW', {'error': '$error'});
      }),
    );
  }

  /// One message gone from this device: delete-for-me, or a delete-for-
  /// everyone that reached it (E19c). Its stored record is destroyed — the
  /// only copy of its words and, for a box message, its attachment's key —
  /// and its row leaves the chat, the cache and the chat list.
  void _deleteMessageLocally(int messageId, int conversationId) {
    _deletedMessageIds.add(messageId);

    // Fire-and-forget is safe only because purgeLocalPlaintext writes a
    // durable backlog entry first; an interrupted purge is retried on the next
    // launch instead of leaving plaintext nothing will ever look at again.
    final encryption = _encryptionProvider;
    if (encryption != null) {
      _firePurge(encryption.purgeLocalPlaintext([messageId]));
    }

    _messages.removeWhere((msg) => msg.id == messageId);

    // Update last message preview for conversation list
    final lastMessages = _conversationsProvider?.lastMessages;
    if (lastMessages != null && lastMessages[conversationId]?.id == messageId) {
      final remaining = _messages
          .where((msg) => msg.conversationId == conversationId)
          .toList();
      if (remaining.isNotEmpty) {
        remaining.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _conversationsProvider?.updateLastMessage(
          conversationId,
          remaining.last,
        );
      } else {
        _conversationsProvider?.updateLastMessage(conversationId, null);
      }
    }

    notifyListeners();
    // Reflect deletion in cache; remove entry entirely if the conversation is now empty.
    if (_conversationCache.containsKey(conversationId)) {
      final remaining = _messages
          .where((m) => m.conversationId == conversationId)
          .toList();
      if (remaining.isEmpty) {
        _conversationCache.remove(conversationId);
      } else {
        _updateCache(conversationId);
      }
    }
  }

  void _maybeUpdateLastEdited(
    int conversationId,
    int messageId,
    MessageModel updated,
  ) {
    final lastMessages = _conversationsProvider?.lastMessages;
    if (lastMessages != null && lastMessages[conversationId]?.id == messageId) {
      _conversationsProvider?.updateLastMessage(conversationId, updated);
    }
  }

  void _handlePartnerTyping(dynamic data) {
    final map = data as Map<String, dynamic>;
    final conversationId = map['conversationId'] as int;
    _typingStatus[conversationId] = true;
    _typingTimers[conversationId]?.cancel();
    _typingTimers[conversationId] = Timer(const Duration(seconds: 3), () {
      _typingStatus[conversationId] = false;
      _typingTimers.remove(conversationId);
      notifyListeners();
    });
    notifyListeners();
  }

  void _handlePartnerRecordingVoice(dynamic data) {
    final map = data as Map<String, dynamic>;
    final conversationId = map['conversationId'] as int;
    final isRecording = map['isRecording'] as bool? ?? false;
    if (isRecording) {
      _partnerRecordingVoice[conversationId] = true;
    } else {
      _partnerRecordingVoice.remove(conversationId);
    }
    notifyListeners();
  }
}
