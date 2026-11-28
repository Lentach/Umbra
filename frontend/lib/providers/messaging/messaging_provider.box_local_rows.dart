part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The payload key of a box message's record holding when its countdown
/// started, whole ms (item 3, decision 41): the send for our own copies,
/// the first time this device showed it for a received one. Absent = not
/// started, so only the 1-day unread cap runs.
const String _boxCountdownFromKey = 'ttlFrom';

/// The payload key of a box message's record holding its tick (slice (g)):
/// OUR message's `delivered` or `read`, as a peer's receipt moved it (E61f;
/// absent = sent); a PEER's `read` once this device's read receipt was
/// taken (E61d; absent = delivered).
const String _boxTickKey = 'tick';

/// A box chat's rows as this device's own store holds them, out of
/// [MessagingBox]: stored messages merged into the open chat, sends kept
/// until they go out, the chat list's last messages and the seen mark.
extension MessagingBoxLocalRows on MessagingProvider {
  /// Adds [conversationId]'s stored box messages to the open chat once its
  /// first history page has landed, with the ones that did not go out
  /// (decision 104). A separate step on purpose: the page's own merge stays
  /// the single synchronous install it is on a warm entry.
  Future<void> _mergeLocalBoxRows(int conversationId) async {
    final rows = await _localBoxRows(conversationId);
    final unsent = await _unsentBoxRows(conversationId);
    if ((rows.isEmpty && unsent.isEmpty) || _isDisposed) return;
    final viewing = _effectiveActiveConversationId ?? _openConversationId;
    if (viewing != conversationId) return;
    final held = {for (final m in _messages) m.id};
    final heldTempIds = {for (final m in _messages) ?m.tempId};
    final user = _currentUserId;
    // The app died between storing a sent record and dropping its kept copy
    // (decision 104): the stored message wins, and the copy goes, or a retry
    // would store it twice here.
    final sentWires = {
      for (final row in rows)
        if (row.senderId == user) ?row.wireId,
    };
    final stillUnsent = <MessageModel>[];
    for (final row in unsent) {
      final tempId = row.tempId!;
      if (heldTempIds.contains(tempId) ||
          _boxInFlight.contains(tempId) ||
          !sentWires.contains(_sendTokenByTempId[tempId])) {
        stillUnsent.add(row);
        continue;
      }
      _boxUnsentTempIds.remove(tempId);
      _boxTempIds.remove(tempId);
      _sendTokenByTempId.remove(tempId);
      if (user != null) {
        _encryptionProvider?.dropBoxUnsent(user, tempId).ignore();
      }
    }
    final now = DateTime.now();
    final live = [
      for (final row in rows)
        if (!_deletedMessageIds.contains(row.id) && !isMessageExpired(row, now))
          row,
    ];
    // An attachment whose download never finished (the app closed first)
    // is fetched again (E17c); its copy's presence is checked, not read.
    final media = boxMedia;
    if (user != null && media != null) {
      for (final row in live) {
        final id = boxMediaIdOf(row.mediaUrl);
        if (id == null) continue;
        unawaited(media.prefetchIfMissing(user, id, receivedAt: row.createdAt));
      }
    }
    final missing = [
      for (final row in live)
        if (!held.contains(row.id)) row,
      for (final row in stillUnsent)
        if (!heldTempIds.contains(row.tempId)) row,
    ];
    if (missing.isNotEmpty) {
      _messages = [..._messages, ...missing]..sort(_byTimeThenId);
      if (_conversationCache.containsKey(conversationId)) {
        _updateCache(conversationId);
      }
      _reEnrichAllReplyQuotes();
      notifyListeners();
    }
    if (rows.isEmpty) return;
    // Shown now: what it holds of the peer's is read (slice (g), E61d), and
    // seen here across a restart (decision 73).
    _sendBoxReadReceipt(conversationId);
    _markBoxChatSeen(conversationId);
    // Shown now: a disappearing one not started yet starts (decision 41).
    _startBoxCountdowns(conversationId);
    // The chat's E2E pin names one of these (item 4, E19f).
    await _resolveBoxPin(conversationId);
  }

  /// Every box message this device stores for [conversationId], rebuilt from
  /// its record. No server page will ever name one (decision 14), so the
  /// first page of a history load brings them in; without this a box
  /// message would vanish from its chat at the next launch.
  Future<List<MessageModel>> _localBoxRows(int conversationId) async {
    final records = await _encryptionProvider?.localMessageRecords(
      conversationId,
    );
    if (records == null || records.isEmpty) return const [];
    final conversation = _conversationsProvider?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    return [
      for (final MapEntry(key: id, value: record) in records.entries)
        if (isLocalMessageId(id))
          ?_boxRowFrom(id, conversationId, record, conversation),
    ];
  }

  /// Keeps box send [tempId] of account [owner] on the device until it goes
  /// out or the user deletes it (decision 104): its row's words, time,
  /// timer, quote and an uploaded attachment, with the wire id every retry
  /// re-seals under. Never the words of a quoted message that itself
  /// disappears (E18a). Nothing once [owner] is no longer the signed-in
  /// account: sign-out destroyed that family, and a send still running
  /// then must not write its words back, nor into the next account's.
  Future<void> _keepBoxUnsent(
    String tempId, {
    required int? owner,
    required int conversationId,
    required DateTime createdAt,
    required String content,
    required String messageType,
    required int? ttl,
    required int? replyToId,
    required ReplyToPreview? replyTo,
    String? mediaUrl,
    String? mediaKey,
    String? mediaIv,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
  }) async {
    // A send that outlived its sign-out writes nothing: its words must not
    // come back after the sweep, nor land in the next account's session.
    if (owner == null || owner != _currentUserId) return;
    _boxUnsentTempIds.add(tempId);
    final quote = replyTo == null
        ? null
        : (replyTo.quotedDisappears
                  ? ReplyToPreview(
                      id: replyTo.id,
                      content: '',
                      senderUsername: replyTo.senderUsername,
                      messageType: replyTo.messageType,
                      wireId: replyTo.wireId,
                      senderId: replyTo.senderId,
                      quotedDisappears: true,
                    )
                  : replyTo)
              .toJson();
    await _encryptionProvider?.saveBoxUnsent(owner, tempId, {
      'c': conversationId,
      'at': createdAt.millisecondsSinceEpoch,
      'w': _sendTokenFor(tempId),
      'type': messageType,
      'content': content,
      'ttl': ?ttl,
      'replyId': ?replyToId,
      'reply': ?quote,
      'mediaUrl': ?mediaUrl,
      'mediaKey': ?mediaKey,
      'mediaIv': ?mediaIv,
      'mediaDuration': ?mediaDuration,
      'mediaWidth': ?mediaWidth,
      'mediaHeight': ?mediaHeight,
      'mediaThumbHash': ?mediaThumbHash,
    });
  }

  /// The box sends of [conversationId] that did not go out (decision 104),
  /// as the red rows they were — `sending` while this session's attempt is
  /// still running — each with its wire id restored and pinned to the box,
  /// so a retry re-seals under it and never takes the old path: a device
  /// may already hold it, and only the box reader drops a repeated wire id.
  Future<List<MessageModel>> _unsentBoxRows(int conversationId) async {
    final own = _currentUserId;
    if (own == null) return const [];
    final entries = await _encryptionProvider?.boxUnsent(own, conversationId);
    if (entries == null || entries.isEmpty || own != _currentUserId) {
      return const [];
    }
    return [
      for (final MapEntry(key: tempId, value: entry) in entries.entries)
        ?_unsentRow(own, conversationId, tempId, entry),
    ];
  }

  MessageModel? _unsentRow(
    int own,
    int conversationId,
    String tempId,
    Map<String, dynamic> e,
  ) {
    if (e case {
      'at': final int at,
      'w': final String wire,
      'content': final String content,
      'type': final String type,
    }) {
      final messageType = _parseMessageTypeString(type);
      if (messageType == null) return null;
      _sendTokenByTempId[tempId] = wire;
      _boxTempIds.add(tempId);
      _boxUnsentTempIds.add(tempId);
      final createdAt = DateTime.fromMillisecondsSinceEpoch(at);
      final ttl = e['ttl'] is int ? e['ttl'] as int : null;
      final reply = e['reply'];
      return MessageModel(
        id: -++MessagingProvider._tempIdSeq,
        content: content,
        senderId: own,
        senderUsername: '',
        conversationId: conversationId,
        createdAt: createdAt,
        deliveryStatus: _boxInFlight.contains(tempId)
            ? MessageDeliveryStatus.sending
            : MessageDeliveryStatus.failed,
        waitingToSend:
            EncryptionService.boxUnsentWaits(e) && !_boxInFlight.contains(tempId),
        messageType: messageType,
        disappearAfterSeconds: ttl,
        expiresAt: ttl == null ? null : createdAt.add(Duration(seconds: ttl)),
        tempId: tempId,
        replyToMessageId: e['replyId'] is int ? e['replyId'] as int : null,
        replyTo: reply is Map<String, dynamic>
            ? ReplyToPreview.fromJson(reply)
            : null,
        mediaUrl: e['mediaUrl'] as String?,
        mediaKey: e['mediaKey'] as String?,
        mediaIv: e['mediaIv'] as String?,
        mediaDuration: e['mediaDuration'] as int?,
        mediaWidth: e['mediaWidth'] as int?,
        mediaHeight: e['mediaHeight'] as int?,
        mediaThumbHash: e['mediaThumbHash'] as String?,
      );
    }
    return null;
  }

  MessageModel? _boxRowFrom(
    int id,
    int conversationId,
    Map<String, dynamic> record,
    ConversationModel? conversation,
  ) {
    final senderId = record['senderId'];
    final createdAtMs = record[PlaintextRecordCodec.createdAtKey];
    if (senderId is! int || createdAtMs is! int) return null;
    final sender = conversation == null
        ? null
        : conversation.userOne.id == senderId
        ? conversation.userOne
        : conversation.userTwo;
    // Its own timer (item 3), and its deadline once the countdown started;
    // an unstarted one runs on the 1-day cap until shown (decision 41).
    final storedTtl = record[PlaintextRecordCodec.disappearAfterKey];
    final ttl =
        storedTtl is int &&
            storedTtl >= kDisappearingMinSeconds &&
            storedTtl <= kDisappearingMaxSeconds
        ? storedTtl
        : null;
    final countdownFrom = record[_boxCountdownFromKey];
    final row = _restoreFromPersistedPayload(
      MessageModel(
        id: id,
        content: '',
        senderId: senderId,
        senderUsername: sender?.id == senderId ? sender!.username : '',
        conversationId: conversationId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          createdAtMs,
          isUtc: true,
        ),
        // Ours went out when the box took every frame (decision 20), and
        // is as far on as a peer's receipt moved it (slice (g), E61f); the
        // peer's is `read` once this device's read receipt was taken (E61d).
        deliveryStatus: switch ((
          senderId == _currentUserId,
          record[_boxTickKey],
        )) {
          (true, 'delivered') => MessageDeliveryStatus.delivered,
          (_, 'read') => MessageDeliveryStatus.read,
          (true, _) => MessageDeliveryStatus.sent,
          (false, _) => MessageDeliveryStatus.delivered,
        },
        disappearAfterSeconds: ttl,
        expiresAt: ttl != null && countdownFrom is int
            ? DateTime.fromMillisecondsSinceEpoch(
                countdownFrom + ttl * 1000,
                isUtc: true,
              )
            : null,
      ),
      record,
    );
    return _hasUsableDecryptedContent(row) ? row : null;
  }

  /// Hands the chat list what no `conversationsList` can name (decision
  /// 14): each chat's newest box message this device stores, and the
  /// peer's box messages this device has not shown yet (decision 73).
  /// Without the first, a chat moved onto the box shows its last SERVER row
  /// after a launch, and sorts by it, and a chat made over the box shows
  /// none; without the second, an unopened box message loses its badge at
  /// every restart. Never a message deleted for everyone here (its
  /// tombstone, should its record outlive the delete) or on this device,
  /// nor an expired one. The list keeps whichever last message is newer
  /// ([ConversationsProvider.applyNewerLastMessages]); unread is a peer
  /// row sent after its chat's seen mark ([EncryptionService.boxSeenMarks]).
  ///
  /// Run at E2E ready, but reads the records ONCE per session (the first
  /// E2E ready after a launch or a sign-in,
  /// [ConversationsProvider.claimStoredBoxPass]): a reconnect keeps the
  /// list's state, which live messages maintain, and on web every record
  /// read is an unseal.
  Future<void> applyStoredBoxLastMessages() async {
    final enc = _encryptionProvider;
    final user = _currentUserId;
    final convs = _conversationsProvider;
    if (enc == null || user == null || convs == null) return;
    if (!convs.claimStoredBoxPass()) return;
    // First, even with nothing stored: this install's first pass fixes
    // what a chat never shown here counts from.
    final seen = await enc.boxSeenMarks();
    final records = await enc.allLocalMessageRecords();
    if (records.isEmpty) return;
    final tombstoned = await enc.boxTombstoneSnapshot();
    if (_isDisposed ||
        convs != _conversationsProvider ||
        user != _currentUserId) {
      return;
    }
    final now = DateTime.now();
    final newest = <int, MessageModel>{};
    final unread = <int, Set<int>>{};
    for (final MapEntry(key: id, value: record) in records.entries) {
      // Only a box message: an old-path record a launch left on disk is
      // never shown (decision 99), only swept by the retention pass.
      if (!isLocalMessageId(id)) continue;
      final conversationId = record[PlaintextRecordCodec.conversationIdKey];
      if (conversationId is! int || _deletedMessageIds.contains(id)) continue;
      final row = _boxRowFrom(
        id,
        conversationId,
        record,
        convs.getConversationById(conversationId),
      );
      if (row == null || isMessageExpired(row, now)) continue;
      final wire = _wireKey(row.senderId, row.wireId);
      if (wire != null && tombstoned(wire)) continue;
      final held = newest[conversationId];
      if (held == null || row.createdAt.isAfter(held.createdAt)) {
        newest[conversationId] = row;
      }
      if (seen != null &&
          row.senderId != user &&
          row.createdAt.millisecondsSinceEpoch >
              (seen.chats[conversationId] ?? seen.base)) {
        (unread[conversationId] ??= {}).add(id);
      }
    }
    convs
      ..applyNewerLastMessages(newest)
      ..seedBoxUnread(unread);
  }

  /// [conversationId] is on screen with the app in the foreground: the send
  /// time of the newest peer box message it shows becomes this device's
  /// seen mark for it, so a restart counts only what was sent later
  /// (decision 73, E73a). Never `tick: read`: that is receipt state, set
  /// only once a peer took our `rcpt r` (E61d). Written when it moves on.
  void _markBoxChatSeen(int conversationId) {
    final own = _currentUserId;
    if (own == null || _conversationsProvider?.isClientVisible == false) {
      return;
    }
    final viewing = _effectiveActiveConversationId ?? _openConversationId;
    if (conversationId != viewing) return;
    DateTime? upTo;
    for (final m in _messages) {
      if (m.conversationId != conversationId ||
          !isLocalMessageId(m.id) ||
          m.senderId == own) {
        continue;
      }
      if (upTo == null || m.createdAt.isAfter(upTo)) upTo = m.createdAt;
    }
    if (upTo == null) return;
    final ms = upTo.millisecondsSinceEpoch;
    if ((_boxSeenMarked[conversationId] ?? -1) >= ms) return;
    _boxSeenMarked[conversationId] = ms;
    unawaited(_encryptionProvider?.markBoxChatSeen(conversationId, upTo));
  }
}
