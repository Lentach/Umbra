part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Timeline state: `_messages`, the RAM cache, pagination, and history merge.
extension MessagingHistory on MessagingProvider {
  /// Whether a warm message cache exists for [conversationId].
  bool hasCachedMessages(int conversationId) =>
      _conversationCache.containsKey(conversationId);

  /// Read-only snapshot of the RAM cache for [conversationId] (empty when
  /// cold). Unlike [loadCachedMessages] this NEVER touches [_messages] or
  /// pagination state, so passive consumers (user-card shared media) can't
  /// disturb the active chat.
  List<MessageModel> cachedMessagesFor(int conversationId) =>
      List.unmodifiable(_conversationCache[conversationId] ?? const []);

  /// Immediately populates [_messages] from RAM cache if available and calls notifyListeners().
  /// Returns true if cache was used — caller can then skip expensive initial scroll setup.
  /// Always follow this with getMessages() to sync new messages from server.
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
      return;
    }
    final existing = _conversationCache[conversationId];
    if (existing == null || existing.isEmpty) {
      _conversationCache[conversationId] = filtered;
    } else {
      _conversationCache[conversationId] = _mergeHistorySnapshot(
        existingForConv: existing,
        serverSnapshot: filtered,
      );
    }
  }

  void _trackHistoryFetch(int conversationId) {
    final seq = ++_historyFetchSeq;
    _pendingHistoryFetchSeq.putIfAbsent(conversationId, () => <int>[]).add(seq);
  }

  void _acknowledgeHistoryFetch(int? conversationId) {
    if (conversationId == null) return;
    final pending = _pendingHistoryFetchSeq[conversationId];
    if (pending != null && pending.isNotEmpty) {
      pending.removeAt(0);
      if (pending.isEmpty) {
        _pendingHistoryFetchSeq.remove(conversationId);
      }
    }
  }

  /// True when a newer [getMessages] was issued before this response arrived.
  bool _isStaleHistoryFetch(int conversationId) {
    final pending = _pendingHistoryFetchSeq[conversationId];
    return pending != null && pending.length > 1;
  }

  /// Self-hosted `/media/msgs/*.bin` blobs are AES-GCM encrypted; keys live only in the E2E envelope.
  bool _requiresEncryptedMediaKeys(MessageModel msg) {
    final url = msg.mediaUrl;
    if (url == null || url.isEmpty || !url.contains('/media/msgs/')) {
      return false;
    }
    switch (msg.messageType) {
      case MessageType.image:
      case MessageType.gif:
      case MessageType.voice:
      case MessageType.file:
      case MessageType.video:
        return true;
      default:
        return false;
    }
  }

  bool _missingEncryptedMediaKeys(MessageModel msg) =>
      _requiresEncryptedMediaKeys(msg) &&
      (msg.mediaKey == null || msg.mediaIv == null);

  /// Prefer higher delivery status, non-null expiry fields, and local decrypted text.
  MessageModel _mergeMessagePreferNewer(
    MessageModel local,
    MessageModel server,
  ) {
    final localRank = _deliveryStatusRank(local.deliveryStatus);
    final serverRank = _deliveryStatusRank(server.deliveryStatus);
    final deliveryStatus = serverRank >= localRank
        ? server.deliveryStatus
        : local.deliveryStatus;

    DateTime? expiresAt = server.expiresAt ?? local.expiresAt;
    if (server.expiresAt != null && local.expiresAt != null) {
      expiresAt = server.expiresAt!.isAfter(local.expiresAt!)
          ? server.expiresAt
          : local.expiresAt;
    }

    final disappearAfterSeconds =
        server.disappearAfterSeconds ?? local.disappearAfterSeconds;

    // Remote edit detected on reconnect: a newer server editedAt invalidates the
    // local plaintext, so the new ciphertext must re-decrypt. Drop the stale RAM
    // cache entry too (the cache-first shortcut would otherwise re-serve it).
    final editStale = _isEditStale(server.editedAt, local.editedAt);
    if (editStale) _encryptionProvider?.invalidateDecryptionCache(server.id);

    var content = local.content;
    // Keep failure label over server "[encrypted]" on reload; successful decrypt wins.
    if (editStale) {
      content = server.content;
    } else if (local.content == kDecryptionFailedLabel) {
      if (!server.displayAsEncryptedPlaceholder &&
          server.content.isNotEmpty &&
          server.content != kDecryptionFailedLabel) {
        content = server.content;
      } else {
        content = kDecryptionFailedLabel;
      }
    } else if (!server.displayAsEncryptedPlaceholder &&
        (local.displayAsEncryptedPlaceholder ||
            local.content == kEncryptedPlaceholderLabel ||
            local.content.isEmpty) &&
        (server.content.isNotEmpty ||
            server.messageType != MessageType.text ||
            server.mediaUrl != null ||
            server.mediaKey != null)) {
      content = server.content;
    } else if (server.content.isNotEmpty &&
        !server.displayAsEncryptedPlaceholder &&
        local.content == kEncryptedPlaceholderLabel) {
      content = server.content;
    }

    final messageType =
        local.messageType != MessageType.text &&
            server.messageType == MessageType.text
        ? local.messageType
        : server.messageType;

    return server.copyWith(
      deliveryStatus: deliveryStatus,
      expiresAt: expiresAt,
      disappearAfterSeconds: disappearAfterSeconds,
      content: content,
      messageType: messageType,
      mediaUrl: local.mediaUrl ?? server.mediaUrl,
      mediaDuration: local.mediaDuration ?? server.mediaDuration,
      mediaKey: local.mediaKey ?? server.mediaKey,
      mediaIv: local.mediaIv ?? server.mediaIv,
      mediaWidth: local.mediaWidth ?? server.mediaWidth,
      mediaHeight: local.mediaHeight ?? server.mediaHeight,
      mediaThumbHash: local.mediaThumbHash ?? server.mediaThumbHash,
      linkPreviewUrl: local.linkPreviewUrl ?? server.linkPreviewUrl,
      linkPreviewTitle: local.linkPreviewTitle ?? server.linkPreviewTitle,
      linkPreviewImageUrl:
          local.linkPreviewImageUrl ?? server.linkPreviewImageUrl,
      // A server snapshot never carries a PEER row's wire id; only the local
      // copy learned it at decrypt, so the local one survives the merge.
      wireId: local.wireId ?? server.wireId,
    );
  }

  /// Merges [decrypted] into the open chat row when present; returns the row used.
  MessageModel _mergeDecryptedIntoState(MessageModel decrypted) {
    final idx = _messages.indexWhere((m) => m.id == decrypted.id);
    if (idx == -1) return decrypted;
    final merged = _mergeMessagePreferNewer(_messages[idx], decrypted);
    _messages[idx] = merged;
    return merged;
  }

  List<MessageModel> _mergeHistorySnapshot({
    required List<MessageModel> existingForConv,
    required List<MessageModel> serverSnapshot,
  }) {
    final serverTempIds = <String>{
      for (final m in serverSnapshot)
        if (m.tempId != null) m.tempId!,
    };

    final mergedById = <int, MessageModel>{};

    // Pre-seed ALL local rows so overlapping ids go through
    // _mergeMessagePreferNewer below. The old `!serverIds.contains(m.id)`
    // exclusion made the server snapshot replace local rows wholesale: every
    // reconnect resurrected decrypted/terminal rows as "[encrypted]"
    // placeholders, which re-armed the decrypt-retry machinery on every pass
    // (the Bad-MAC → session-reset loop).
    for (final m in existingForConv) {
      if (m.id > 0) {
        mergedById[m.id] = m;
      }
    }

    for (final m in serverSnapshot) {
      if (m.id <= 0) continue;
      final prev = mergedById[m.id];
      mergedById[m.id] = prev != null ? _mergeMessagePreferNewer(prev, m) : m;
    }

    final optimistic = <MessageModel>[];
    for (final m in existingForConv) {
      if (m.id > 0) continue;
      if (m.tempId != null && serverTempIds.contains(m.tempId)) continue;
      optimistic.add(m);
    }

    final merged = <MessageModel>[...mergedById.values, ...optimistic];
    merged.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
    return merged;
  }

  void _mergeServerSnapshotIntoCache(
    int conversationId,
    List<MessageModel> serverSnapshot,
  ) {
    final existing = _conversationCache[conversationId] ?? [];
    _conversationCache[conversationId] = _mergeHistorySnapshot(
      existingForConv: existing,
      serverSnapshot: serverSnapshot,
    );
  }

  void _finishHistoryDecryptPass(
    int generation, {
    required int? conversationId,
    required bool updateCache,
  }) {
    if (_decryptHistoryGeneration != generation) return;
    _decryptingHistory = false;
    if (updateCache && conversationId != null) {
      _updateCache(conversationId);
    }
    _reEnrichAllReplyQuotes();
    notifyListeners();
    _processIncomingMessageQueue();
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

  Future<void> onMessageHistory(dynamic data) async {
    final effectiveActive = _effectiveActiveConversationId;

    int? responseConversationId;
    List<dynamic> list;
    if (data is Map<String, dynamic> &&
        data.containsKey('conversationId') &&
        data.containsKey('messages')) {
      responseConversationId = (data['conversationId'] as num).toInt();
      list = data['messages'] as List<dynamic>;
    } else if (data is List<dynamic>) {
      list = data;
    } else {
      _e2eFlowLog('HISTORY_DROP', {'reason': 'badPayload'});
      return;
    }
    _e2eFlowLog('HISTORY_RESP', {
      'convId': responseConversationId ?? -1,
      'count': list.length,
      'activeId': effectiveActive ?? -1,
      'paginationId': _paginationConversationId,
    });
    bool droppedForConversationMismatch(int? activeNow) {
      if (responseConversationId == null ||
          activeNow == null ||
          responseConversationId == activeNow) {
        return false;
      }
      if (_isPaginationLoad &&
          responseConversationId == _paginationConversationId) {
        _finishPaginationLoad();
        notifyListeners();
      }
      _e2eFlowLog('HISTORY_DROP', {
        'reason': 'convMismatch',
        'convId': responseConversationId,
        'activeId': activeNow,
      });
      return true;
    }

    if (droppedForConversationMismatch(effectiveActive)) return;
    final newMessages = list.map((m) {
      final row = _withRenderableReactions(
        _enrichReplyPreview(MessageModel.fromJson(m as Map<String, dynamic>)),
      );
      // The server says this device has no ciphertext for this row by
      // design — it predates this device's link (spec §12 amendment
      // (viii)). Stamp the honest placeholder HERE, at ingestion: such a
      // row carries no ciphertext, so it never enters the decrypt pass
      // where the other placeholder states are resolved, and it would
      // otherwise sit on '[encrypted]' forever.
      return row.envelopeStatus == 'none_for_device'
          ? row.copyWith(content: kNotLinkedYetMessageLabel)
          : row;
    }).toList();

    // Fill in plaintext we already hold BEFORE this snapshot reaches _messages.
    // Every E2E row arrives as content "[encrypted]" (the server never sees
    // plaintext), so painting the snapshot first and decrypting afterwards is
    // what made a long history flash placeholders on entry. This touches the
    // caller-local list only; the merge into _messages and the notifyListeners
    // below stay a single atomic step, as they were.
    //
    // The RAM half is synchronous and returns null, so a warm re-entry keeps
    // the whole handler suspension-free. Only a cold entry that has to read
    // storage yields — and everything below branches on mutable pagination
    // state, so in that case snapshot the inputs and refuse to evaluate this
    // payload against state a concurrent getMessages / loadOlderMessages moved
    // underneath us.
    final hydration = _hydrateSnapshotFromCaches(newMessages);
    if (hydration != null) {
      final paginationAtEntry = _isPaginationLoad;
      final paginationIdAtEntry = _paginationConversationId;
      final fetchSeqAtEntry = _historyFetchSeq;
      await hydration;
      if (droppedForConversationMismatch(_effectiveActiveConversationId)) {
        return;
      }
      if (_isPaginationLoad != paginationAtEntry ||
          _paginationConversationId != paginationIdAtEntry ||
          _historyFetchSeq != fetchSeqAtEntry) {
        // Superseded mid-hydrate. Same treatment as the stale-sequence path
        // below: keep the payload's plaintext in the conversation cache,
        // release this fetch's slot, and let the newer request own the UI.
        final supersededConvId =
            responseConversationId ?? _effectiveActiveConversationId;
        _acknowledgeHistoryFetch(supersededConvId);
        if (supersededConvId != null) {
          _mergeServerSnapshotIntoCache(supersededConvId, newMessages);
        }
        _e2eFlowLog('HISTORY_DROP', {
          'reason': 'supersededDuringHydrate',
          'convId': supersededConvId ?? -1,
          'mergedToCache': supersededConvId != null,
        });
        return;
      }
    }

    if (_isPaginationLoad) {
      if (responseConversationId != null &&
          responseConversationId != _paginationConversationId) {
        _finishPaginationLoad();
        notifyListeners();
        return;
      }

      _messages = [...newMessages, ..._messages];
      // Same relaunch race as the first-page path below: the key can land while
      // these rows are still caller-local, so re-resolve after the install.
      if (_paginationConversationId >= 0) {
        _reRenderReactions(_paginationConversationId);
      }
      _paginationOffset += newMessages.length;
      _hasMore = newMessages.length == _pageSize;
      _finishPaginationLoad();
      notifyListeners();

      _decryptHistoryGeneration++;
      final myGeneration = _decryptHistoryGeneration;
      final cacheId = _paginationConversationId;
      _decryptingHistory = true;
      _decryptMessageHistory(myGeneration).whenComplete(() {
        _finishHistoryDecryptPass(
          myGeneration,
          conversationId: cacheId,
          updateCache: true,
        );
      });
      return;
    }

    if (responseConversationId != null &&
        responseConversationId != _paginationConversationId) {
      final matchesActive =
          effectiveActive != null && responseConversationId == effectiveActive;
      final paginationUnset = _paginationConversationId < 0;
      if (!matchesActive && !paginationUnset) {
        _e2eFlowLog('HISTORY_DROP', {
          'reason': 'notActiveNotPagination',
          'convId': responseConversationId,
          'paginationId': _paginationConversationId,
        });
        return;
      }
      _paginationConversationId = responseConversationId;
      _paginationOffset = 0;
    }

    final convIdForMerge =
        responseConversationId ?? _effectiveActiveConversationId;
    final staleHistory =
        convIdForMerge != null && _isStaleHistoryFetch(convIdForMerge);
    _acknowledgeHistoryFetch(convIdForMerge);

    if (staleHistory) {
      _mergeServerSnapshotIntoCache(convIdForMerge, newMessages);
      _e2eFlowLog('HISTORY_DROP', {
        'reason': 'staleSeq',
        'convId': convIdForMerge,
        'mergedToCache': true,
      });
      // A newer getMessages owns _decryptingHistory — do not release the hold here.
      return;
    }

    final existingForConv = List<MessageModel>.from(
      _messages.where(
        (m) => convIdForMerge == null || m.conversationId == convIdForMerge,
      ),
    );
    _messages = _mergeHistorySnapshot(
      existingForConv: existingForConv,
      serverSnapshot: newMessages,
    );
    _hasMore = newMessages.length == _pageSize;
    _paginationOffset = newMessages.length;

    // Cancel any in-flight decrypt so we process the latest messages
    _decryptHistoryGeneration++;

    // Don't re-add messages we already received as deleted
    _messages.removeWhere((m) => _deletedMessageIds.contains(m.id));

    // Immediately remove any already-expired messages
    final now = DateTime.now();
    _messages.removeWhere((m) => isMessageExpired(m, now));
    // The reaction-key acquisition started by `_withRenderableReactions` above
    // (line 318) reads the LOCAL key store, so on a relaunch it finishes during
    // the `await hydration` above — while these rows are still caller-local.
    // `_reRenderReactions` therefore found nothing in `_messages` to repair and
    // spent its one latched attempt, so without this every chip whose key this
    // device already holds stays the unreadable placeholder for the rest of the
    // session (falsification R7, observed on a real Chrome relaunch 2026-09-18).
    // Idempotent: rows whose keys are already emoji are skipped.
    if (convIdForMerge != null) _reRenderReactions(convIdForMerge);
    notifyListeners();
    // Snapshot to cache immediately (may include encrypted placeholders for E2E messages).
    // A second snapshot runs after _decryptMessageHistory completes with decrypted content.
    // Note: legacy bare-array payloads (responseConversationId == null) skip this first snapshot;
    // only the post-decrypt snapshot via myConversationId runs for them. This is acceptable
    // because the bare-array path is not used by the current protocol.
    if (responseConversationId != null) {
      _updateCache(responseConversationId);
    }

    if (effectiveActive != null) {
      markConversationRead(effectiveActive);
    }

    // Decrypt history first so no live message advances the session before
    // we decrypt in order. Queue any incoming messages until done.
    final myConversationId =
        responseConversationId ?? _effectiveActiveConversationId;
    final myGeneration = _decryptHistoryGeneration;
    _decryptingHistory = true;
    _decryptMessageHistory(myGeneration).whenComplete(() {
      _finishHistoryDecryptPass(
        myGeneration,
        conversationId: myConversationId,
        updateCache: true,
      );
    });
  }

  void getMessages(int conversationId) {
    _finishPaginationLoad();
    _paginationConversationId = conversationId;
    _paginationOffset = 0;
    _hasMore = false;
    _trackHistoryFetch(conversationId);
    _e2eFlowLog('HISTORY_REQ', {
      'convId': conversationId,
      'seq': _historyFetchSeq,
      'emitWired': _emit != null,
    });
    _emit?.call('getMessages', {
      'conversationId': conversationId,
      'limit': _pageSize,
      'offset': 0,
    });
  }

  Future<void> loadOlderMessages(int conversationId) {
    if (!_hasMore) return Future<void>.value();
    if (_isLoadingMore) {
      return _paginationCompleter?.future ?? Future<void>.value();
    }
    _isLoadingMore = true;
    _isPaginationLoad = true;
    _paginationCompleter = Completer<void>();
    _emit?.call('getMessages', {
      'conversationId': conversationId,
      'limit': _pageSize,
      'offset': _paginationOffset,
    });
    return _paginationCompleter!.future;
  }

  void _finishPaginationLoad() {
    _isLoadingMore = false;
    _isPaginationLoad = false;
    final completer = _paginationCompleter;
    _paginationCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _addMessageToState(MessageModel msg) {
    final activeConversationId = _effectiveActiveConversationId;

    // If this is our own message (messageSent), replace temp optimistic message
    // and keep plaintext for display (server stores "[encrypted]" as content).
    //
    // Origin-scoped twice over (amendment (xi)): a `tempId` exists only on the
    // device that minted it, so a self-sync copy from another of our devices
    // could never match one — and `!_isSelfSyncRow` states that intent instead
    // of leaving it to luck, because everything in this branch (consuming
    // `_pendingSendContent`, removing the optimistic row, consuming the
    // pending-send record below) belongs to a genuinely in-flight LOCAL send.
    if (msg.senderId == _currentUserId &&
        msg.tempId != null &&
        !_isSelfSyncRow(msg)) {
      final savedData = _pendingSendContent.remove(msg.tempId);
      final savedContent = savedData?['content'];
      final tempIndex = _messages.indexWhere((m) => m.tempId == msg.tempId);
      final tempContent = tempIndex != -1 ? _messages[tempIndex].content : null;
      if (tempIndex != -1) _messages.removeAt(tempIndex);
      final plaintextContent = savedContent ?? tempContent ?? '';
      if (msg.content == '[encrypted]') {
        final restoredType = _parseMessageTypeString(
          savedData?['messageType'] as String?,
        );
        msg = msg.copyWith(
          content: plaintextContent.isNotEmpty ? plaintextContent : null,
          messageType: restoredType,
          mediaUrl: savedData?['mediaUrl'] as String?,
          mediaDuration: savedData?['mediaDuration'] as int?,
          mediaKey: savedData?['mediaKey'] as String?,
          mediaIv: savedData?['mediaIv'] as String?,
          mediaWidth: savedData?['mediaWidth'] as int?,
          mediaHeight: savedData?['mediaHeight'] as int?,
          mediaThumbHash: savedData?['mediaThumbHash'] as String?,
          linkPreviewUrl: savedData?['linkPreviewUrl'] as String?,
          linkPreviewTitle: savedData?['linkPreviewTitle'] as String?,
          linkPreviewImageUrl: savedData?['linkPreviewImageUrl'] as String?,
        );
        final persistData = <String, dynamic>{
          'content': plaintextContent,
          if (savedData?['messageType'] != null)
            'messageType': savedData!['messageType'],
          if (savedData?['mediaUrl'] != null)
            'mediaUrl': savedData!['mediaUrl'],
          if (savedData?['mediaDuration'] != null)
            'mediaDuration': savedData!['mediaDuration'],
          if (savedData?['mediaKey'] != null)
            'mediaKey': savedData!['mediaKey'],
          if (savedData?['mediaIv'] != null) 'mediaIv': savedData!['mediaIv'],
          if (savedData?['mediaWidth'] != null)
            'mediaWidth': savedData!['mediaWidth'],
          if (savedData?['mediaHeight'] != null)
            'mediaHeight': savedData!['mediaHeight'],
          if (savedData?['mediaThumbHash'] != null)
            'mediaThumbHash': savedData!['mediaThumbHash'],
          if (savedData?['linkPreviewUrl'] != null)
            'linkPreviewUrl': savedData!['linkPreviewUrl'],
          if (savedData?['linkPreviewTitle'] != null)
            'linkPreviewTitle': savedData!['linkPreviewTitle'],
          if (savedData?['linkPreviewImageUrl'] != null)
            'linkPreviewImageUrl': savedData!['linkPreviewImageUrl'],
        };
        _encryptionProvider
            ?.saveDecryptedContent(
              msg.id,
              persistData,
              // Our own token, echoed on the ack (`MessageModel.fromJson`).
              wireId: msg.wireId,
            )
            .ignore();
      }
      // Ack arrived — the pending-send record served its purpose; consume it
      // so normal sends keep the reconcile store self-cleaning. Same
      // precedence as the lost-ack reconcile, and for the same reason: the
      // record was saved under the ciphertext for a legacy send and under the
      // send token for a fan-out (whose origin copy has a NULL ciphertext), so
      // consuming by the wrong one would leave it on disk forever.
      final ackRecordKey = msg.encryptedContent ?? msg.sendToken;
      if (ackRecordKey != null) {
        _encryptionProvider?.takePendingSendRecord(ackRecordKey).ignore();
      }
    }

    // Add or update in the open chat (active id may lag openConversation briefly).
    final viewingConversationId =
        activeConversationId ?? _paginationConversationId;
    if (msg.conversationId == viewingConversationId) {
      final existingById = _messages.indexWhere(
        (m) => m.id == msg.id && msg.id > 0,
      );
      if (existingById != -1) {
        _messages[existingById] = _mergeMessagePreferNewer(
          _messages[existingById],
          msg,
        );
      } else if (msg.tempId != null) {
        final tempIdx = _messages.indexWhere((m) => m.tempId == msg.tempId);
        if (tempIdx != -1) {
          _messages[tempIdx] = msg;
        } else {
          _messages.add(msg);
        }
      } else {
        _messages.add(msg);
      }
    }

    // DIAGNOSTIC (iOS-PWA live-receive drop): records whether this incoming message
    // was appended to the open chat, and the active/pagination id state at decision time.
    // Remove once the active-conversation desync root cause is confirmed & fixed.
    _e2eFlowLog('ADD_TO_STATE', {
      'msgId': msg.id,
      'senderId': msg.senderId,
      'msgConvId': msg.conversationId,
      'activeId': activeConversationId,
      'paginationConvId': _paginationConversationId,
      'appendedToOpenChat': msg.conversationId == viewingConversationId,
    });

    _conversationsProvider?.updateLastMessage(msg.conversationId, msg);
    if (msg.senderId != _currentUserId) {
      if (msg.conversationId != activeConversationId) {
        _conversationsProvider?.incrementUnreadCount(msg.conversationId);
      }
      _emit?.call('messageDelivered', {'messageId': msg.id});
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
    notifyListeners();
  }
}
