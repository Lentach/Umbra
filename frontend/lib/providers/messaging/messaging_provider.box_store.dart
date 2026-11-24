part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// What a read box message becomes, out of [MessagingBox]: its own timer and
/// quote, its countdown, the failure policy of one that could not be
/// decrypted, the stored record and the shown row.
extension MessagingBoxStore on MessagingProvider {
  /// What only a box message carries (item 3), on [row]: its own timer and
  /// a reply's quote. Never read for a server row, whose timer and quote the
  /// server holds.
  ///
  /// Decision 41: our own copy — a sibling's sent copy — counts from the
  /// send, like the sender's; a received one only from the first time this
  /// device shows it ([_startBoxCountdowns]), with the 1-day unread cap
  /// until then.
  Future<MessageModel> _withBoxExtras(
    MessageModel row,
    E2eEnvelopeFields parsed,
  ) async {
    final ttl = parsed.ttl;
    final quote = parsed.replyQuote;
    return row.copyWith(
      disappearAfterSeconds: ttl,
      expiresAt: ttl != null && row.senderId == _currentUserId
          ? row.createdAt.add(Duration(seconds: ttl))
          : null,
      replyTo: quote == null
          ? null
          : await _boxReplyTo(quote, row.conversationId),
    );
  }

  /// A box reply's [quote] as the row's preview (E18a). When this device
  /// holds the quoted message from that sender under that wire id in this
  /// chat, the preview is OUR copy — its id, type and words (none for a
  /// message that disappears or is not a text) — and the peer's snippet is
  /// never read, so a forged one shows only for a message we never had;
  /// otherwise it points at no row (id 0), and the snippet shows.
  Future<ReplyToPreview> _boxReplyTo(
    E2eReplyQuote quote,
    int conversationId,
  ) async {
    final conversation = _conversationsProvider?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final sender = [
      ?conversation?.userOne,
      ?conversation?.userTwo,
    ].where((u) => u.id == quote.senderId).firstOrNull;
    final held = await _heldQuote(quote, conversationId);
    if (held == null) {
      return ReplyToPreview(
        id: 0,
        content: quote.snippet,
        senderUsername: sender?.username ?? '',
        messageType: _parseMessageTypeString(quote.type) ?? MessageType.text,
        wireId: quote.wireId,
        senderId: quote.senderId,
      );
    }
    final disappears =
        held.disappearAfterSeconds != null || held.expiresAt != null;
    const labels = kReplyPreviewLabels;
    return ReplyToPreview(
      id: held.id,
      content: disappears || held.messageType != MessageType.text
          ? ''
          : replyPreviewForMessageModel(
              held,
              encryption: _encryptionProvider,
              encryptedMessageLabel: labels.encryptedMessageLabel,
              voiceMessageLabel: labels.voiceMessageLabel,
              imageLabel: labels.imageLabel,
              gifLabel: labels.gifLabel,
              documentLabel: labels.documentLabel,
              pingLabel: labels.pingLabel,
              videoLabel: labels.videoLabel,
            ),
      senderUsername: sender?.username ?? '',
      messageType: held.messageType,
      wireId: quote.wireId,
      senderId: quote.senderId,
      quotedDisappears: disappears,
    );
  }

  /// The message [quote] names, held in [conversationId] — in the open
  /// chat, else rebuilt from its record: by sender AND wire id, since a
  /// wire id is unique per sender only. Null when there is no wire id, or
  /// no such message here.
  Future<MessageModel?> _heldQuote(
    E2eReplyQuote quote,
    int conversationId,
  ) async {
    final wireId = quote.wireId;
    if (wireId == null) return null;
    for (final m in _messages) {
      if (m.conversationId == conversationId &&
          m.senderId == quote.senderId &&
          m.wireId == wireId) {
        return m;
      }
    }
    final enc = _encryptionProvider;
    if (enc == null) return null;
    final id = await enc.wireHolder((senderId: quote.senderId, wireId: wireId));
    if (id == null) return null;
    final record = await enc.getDecryptedContent(id);
    // Another chat's message is never this one's quote.
    if (record == null ||
        record[PlaintextRecordCodec.conversationIdKey] != conversationId) {
      return null;
    }
    final createdAtMs = record[PlaintextRecordCodec.createdAtKey];
    final ttl = record[PlaintextRecordCodec.disappearAfterKey];
    final expiresAtMs = record[PlaintextRecordCodec.expiresAtKey];
    return _restoreFromPersistedPayload(
      MessageModel(
        id: id,
        content: '',
        senderId: quote.senderId,
        senderUsername: '',
        conversationId: conversationId,
        createdAt: createdAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
            : DateTime.now().toUtc(),
        disappearAfterSeconds: ttl is int ? ttl : null,
        expiresAt: expiresAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true)
            : null,
      ),
      record,
    );
  }

  /// The destruction stamp of box message [msg]'s record (decision 41): its
  /// deadline once its countdown runs, else — a received one not shown yet
  /// — 1 day after the send, the unread cap. The stamp is what the
  /// destruction gate honours (`EncryptionService._recordExpiryDeadlineMs`).
  DateTime? _boxRecordExpiry(MessageModel msg) {
    if (msg.expiresAt != null || msg.disappearAfterSeconds == null) {
      return msg.expiresAt;
    }
    return msg.createdAt.add(
      const Duration(seconds: kNeverReadRetentionSeconds),
    );
  }

  /// Starts the countdown of every received box message in
  /// [conversationId] that has a timer and has not started one (decision
  /// 41): the first time this device SHOWS it — the chat open and the app
  /// in the foreground, the moments an old-path read mark is sent. The row
  /// then goes at now + its timer, and its record is re-stamped with that
  /// deadline and when it started, so a restart keeps counting.
  void _startBoxCountdowns(int conversationId) {
    if (_conversationsProvider?.isClientVisible == false) return;
    final viewing = _effectiveActiveConversationId ?? _openConversationId;
    if (conversationId != viewing) return;
    final own = _currentUserId;
    // Whole ms: the stored start and the row's deadline must agree.
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );
    var started = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final ttl = m.disappearAfterSeconds;
      if (m.conversationId != conversationId ||
          !isLocalMessageId(m.id) ||
          m.senderId == own ||
          ttl == null ||
          m.expiresAt != null ||
          isMessageExpired(m, now)) {
        continue;
      }
      final shown = m.copyWith(expiresAt: now.add(Duration(seconds: ttl)));
      _messages[i] = shown;
      started = true;
      _encryptionProvider?.cacheDecryption(shown.id, shown);
      // An unsaved row's next store must not undo the start.
      if (_boxUnsaved.containsKey(shown.id)) _boxUnsaved[shown.id] = shown;
      unawaited(_persistDecryptedContent(shown));
    }
    if (!started) return;
    if (_conversationCache.containsKey(conversationId)) {
      _updateCache(conversationId);
    }
    notifyListeners();
  }

  /// The server path's failure policy ([decideDecryptionFailure]) applied to
  /// a box delivery: the peer is asked to re-key when the policy says so,
  /// and a message that will never decrypt shows as `[Decryption failed]`
  /// (in RAM — the journal entry is finished with, so it is not re-read).
  /// No session yet also asks the peer to re-key: a box whisper message has
  /// no server history to wait for, so only the peer's next PreKey message
  /// can heal the session. Anything that may heal is offered again.
  bool _boxDecryptFailed(MessageModel msg, Object e) {
    final kind = _classifyDecryptError(e);
    final decision = decideDecryptionFailure(
      kind,
      hadIdentityReset: _encryptionProvider?.hadIdentityReset == true,
      isHistory: false,
    );
    _logDecryptionFailure(decision.rule, msg, e);
    _e2eFlowLog('BOX_DECRYPT_FAILED', {
      'msgId': msg.id,
      'senderId': msg.senderId,
      'rule': decision.rule.name,
    });
    // A friend made over the box has no server to carry a re-key request
    // (decision 52): this device re-keys that device itself, over the box —
    // once per box session; the device's own refusal of our fresh session
    // re-keys us back, and the pair converges (decision 49).
    final friendLink = boxFriends;
    if (friendLink != null &&
        _boxOnlyPeer(msg.senderId) &&
        (decision.rule == DecryptionFailureRule.noSession ||
            decision.rule == DecryptionFailureRule.badMac)) {
      unawaited(friendLink.rekeyFriend(msg.senderId, msg.originDeviceId ?? 1));
    }
    _askPeerToRekey(decision, msg.senderId);
    if (decision.rule == DecryptionFailureRule.noSession) {
      _requestSessionRebuildForPeer(msg.senderId, trigger: 'boxNoSession');
    }
    if (decision.retryAction != DecryptionRetryAction.none) return false;
    // A duplicate is a ciphertext this device already read another way.
    if (decision.rule != DecryptionFailureRule.duplicate) {
      _showBoxMessage(msg.copyWith(content: kDecryptionFailedLabel));
    }
    return true;
  }

  /// Stores and shows [decrypted] unless it is a copy already held, deleted
  /// for everyone, or empty. [relay] runs once it is shown here for the
  /// first time — never for a duplicate — whether or not its store is
  /// proven yet (a re-store is never re-read): a friend's message goes on
  /// to the siblings it could not reach (decision 101 A).
  Future<bool> _consumeBoxMessage(
    MessageModel decrypted, {
    required DateTime receivedAt,
    void Function()? relay,
  }) async {
    final enc = _encryptionProvider!;
    final wire = _wireKey(decrypted.senderId, decrypted.wireId);
    if (wire != null) {
      // Deleted for everyone before this copy came (item 4, E19c/E19g).
      if (await enc.boxTombstoned(wire)) {
        _e2eFlowLog('BOX_TOMBSTONED', {'msgId': decrypted.id});
        return true;
      }
      final held = await enc.wireHeldByOther(wire, decrypted.id);
      if (held == null) return false;
      if (held) {
        _e2eFlowLog('BOX_DUPLICATE', {'msgId': decrypted.id});
        return true;
      }
    }
    if (decrypted.content.isEmpty &&
        decrypted.mediaUrl == null &&
        decrypted.messageType == MessageType.text) {
      return true;
    }
    final stored = await _storeBoxMessage(
      decrypted,
      alreadyShown: false,
      receivedAt: receivedAt,
    );
    relay?.call();
    return stored;
  }

  /// True inside a box read queued before the last `clearAll` or fresh
  /// connect ([_runDecryptSerialized]): local ids restart at the same base
  /// per account, so its result must not land in the session now running.
  bool get _boxReadStale {
    final queuedIn = Zone.current[_boxReadEpochKey];
    return queuedIn != null && queuedIn != _boxSessionEpoch;
  }

  /// Stores [msg]'s plaintext and shows it. True only once the record is
  /// PROVEN on disk (read back from the store, not the write's word — the
  /// save path swallows a refused commit): the entry leaves the journal only
  /// then, because its ciphertext's ratchet key is already spent. Until
  /// then the message is shown from RAM and the next offer retries the
  /// store alone.
  ///
  /// Once stored, its attachment starts downloading ([receivedAt]: when the
  /// box delivered it), off the read chain (E17c, decision 40), and the
  /// actions read before it land on it (item 4, E19k).
  Future<bool> _storeBoxMessage(
    MessageModel msg, {
    required bool alreadyShown,
    required DateTime receivedAt,
  }) async {
    if (_boxReadStale) return false;
    final enc = _encryptionProvider!..cacheDecryption(msg.id, msg);
    await _persistDecryptedContent(msg);
    final stored = await enc.recordExists(msg.id) == true;
    // Signed out (or another account signed in) while it was stored: shown
    // nowhere, and not finished, so the old account's next offer re-reads it.
    if (_boxReadStale) return false;
    // Held BEFORE it is shown: showing starts its countdown
    // ([_startBoxCountdowns]), which updates the held row, so the next
    // store keeps the start instead of resetting it to the unread cap.
    if (!stored) _boxUnsaved[msg.id] = msg;
    if (!alreadyShown) {
      _showBoxMessage(msg);
      // H1 (decision R81, ER81b): the NATIVE app's card, posted only off
      // web (on web the page's card in [_showBoxMessage] is the only one).
      // Shown for the first time, only here — a re-store (`alreadyShown`)
      // is the same message. A sibling's sent copy is ours, and a muted chat
      // stays silent exactly as it was on the old path.
      final muted =
          _conversationsProvider?.isChatMuted(msg.conversationId) ?? false;
      if (msg.senderId != _currentUserId && !muted) {
        boxHiddenNotifier.notifyIfHidden().ignore();
      }
    }
    if (stored) {
      _boxUnsaved.remove(msg.id);
      _owedBoxDelivered(msg);
      _prefetchBoxMedia(msg, receivedAt);
      try {
        await _applyParkedBoxActions(msg);
      } on Object catch (e) {
        // Stored all the same: the message is finished, its actions lost.
        _e2eFlowLog('BOX_PARKED_APPLY_FAILED', {'error': e.runtimeType});
      }
      return true;
    }
    E2ePersistentDiag.record('BOX_STORE_UNPROVEN', {'msgId': msg.id});
    return false;
  }

  /// Queues [msg]'s box attachment for download; never awaited.
  void _prefetchBoxMedia(MessageModel msg, DateTime receivedAt) {
    final id = boxMediaIdOf(msg.mediaUrl);
    final user = _currentUserId;
    if (id == null || user == null) return;
    boxMedia?.prefetch(user, id, receivedAt: receivedAt);
  }

  void _showBoxMessage(MessageModel msg) {
    final viewing = _effectiveActiveConversationId ?? _openConversationId;
    final inView = msg.conversationId == viewing;
    // A chat that was deleted here comes back with its next message
    // (owner decision 52).
    _conversationsProvider?.revealChat(msg.conversationId);
    // A sibling's sent ping is ours: nothing arrived.
    if (inView &&
        msg.messageType == MessageType.ping &&
        msg.senderId != _currentUserId &&
        _pingEffectFiredIds.add(msg.id)) {
      _showPingEffect = true;
    }
    _addMessageToState(msg);
    // A peer's message that reached a HIDDEN page (owner decision 76): its
    // socket was alive, so the box sent no push; the page asks for the card
    // itself. Not a sibling's sent copy, which is ours.
    if (msg.senderId != _currentUserId) {
      _conversationsProvider?.postHiddenArrivalCard(msg.conversationId);
    }
    // Shown: a disappearing one starts counting now (decision 41).
    if (inView) _startBoxCountdowns(msg.conversationId);
    if (inView && _conversationCache.containsKey(msg.conversationId)) {
      _updateCache(msg.conversationId);
    }
    // Owner decision 11: a sound only for the chat on screen; any other
    // chat gets its badge and nothing else. A sibling's sent copy is ours:
    // nothing arrived.
    if (inView &&
        msg.messageType != MessageType.ping &&
        msg.senderId != _currentUserId) {
      _incomingSound.play().ignore();
    }
  }
}
