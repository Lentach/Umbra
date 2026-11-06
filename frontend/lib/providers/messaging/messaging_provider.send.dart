part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

Future<MediaPreviewMetadata?> _extractMediaPreviewMetadata(
  Uint8List bytes,
) async {
  try {
    return await MediaPreviewMetadata.fromEncodedBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// Optimistic send, send-retry and the typing signals — every send goes over
/// the box.
extension MessagingSend on MessagingProvider {
  void sendMessage(String content, {int? expiresIn, int? replyToMessageId}) {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final conversations = _conversationsProvider!.conversations;
    // firstOrNull, NOT firstWhere: a stale active id (e.g. a notification for
    // a deleted conversation) must not throw before the optimistic add — the
    // old StateError here ate typed messages silently.
    final conv = conversations
        .where((c) => c.id == activeConversationId)
        .firstOrNull;
    if (conv == null) return;
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);

    // Use conversation disappearing timer if expiresIn not provided
    final effectiveExpiresIn =
        expiresIn ?? _conversationsProvider!.conversationDisappearingTimer;
    final effectiveReplyToId = replyToMessageId ?? _replyingToMessage?.id;
    final replyPreview = _buildReplyPreviewFromReplyingTo();

    // Generate unique tempId for optimistic message matching
    final tempId = _newTempId();

    // Create optimistic message with SENDING status
    final tempMessage = MessageModel(
      id: -(++MessagingProvider._tempIdSeq), // Monotonic temporary negative ID
      content: content,
      senderId: _currentUserId!,
      senderUsername: '', // Will be replaced when server confirms
      conversationId: activeConversationId,
      createdAt: DateTime.now(),
      deliveryStatus: MessageDeliveryStatus.sending,
      disappearAfterSeconds: effectiveExpiresIn,
      expiresAt: null,
      tempId: tempId,
      replyToMessageId: effectiveReplyToId,
      replyTo: replyPreview,
    );

    _messages.add(tempMessage);
    if (_replyingToMessage != null) {
      _replyingToMessage = null;
    }
    notifyListeners();

    // Encrypt and send asynchronously
    _encryptAndSend(
      recipientId: recipientId,
      content: content,
      tempId: tempId,
      effectiveExpiresIn: effectiveExpiresIn,
      effectiveReplyToId: effectiveReplyToId,
    );
  }

  void sendPing(int recipientId) {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId = _newTempId();

    final tempMessage = MessageModel(
      id: -(++MessagingProvider._tempIdSeq),
      content: '',
      senderId: _currentUserId!,
      senderUsername: '',
      conversationId: activeConversationId,
      createdAt: DateTime.now(),
      deliveryStatus: MessageDeliveryStatus.sending,
      messageType: MessageType.ping,
      disappearAfterSeconds: effectiveExpiresIn,
      expiresAt: null,
      tempId: tempId,
    );

    _messages.add(tempMessage);
    _showPingEffect = true;
    notifyListeners();

    _encryptAndSend(
      recipientId: recipientId,
      content: '',
      tempId: tempId,
      effectiveExpiresIn: effectiveExpiresIn,
      messageType: 'PING',
    );
  }

  /// Returns true only AFTER the box took the image's frames (spec §3
  /// ordering contract) — callers sequencing a caption must await this.
  /// False = failed before that (no conversation, oversize, no box route,
  /// upload/encrypt failure); the optimistic bubble is marked failed
  /// internally.
  Future<bool> sendImageMessage(XFile imageFile, int recipientId) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return false;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId = _newTempId();
    final effectiveReplyToId = _replyingToMessage?.id;

    _messages.add(
      _buildOptimisticMediaMessage(
        tempId: tempId,
        conversationId: activeConversationId,
        messageType: MessageType.image,
        content: '',
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
      ),
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      final rawBytes = await imageFile.readAsBytes();
      if (rawBytes.length > MediaCryptoService.maxBytes) {
        _markMessageFailed(tempId, 'Image too large (max 20 MB)');
        return false;
      }
      final preview = await _extractMediaPreviewMetadata(rawBytes);
      if (preview != null) {
        _applyMediaPreview(tempId, preview);
      }
      return await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: 'IMAGE',
        bytes: Uint8List.fromList(rawBytes),
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaWidth: preview?.width,
        mediaHeight: preview?.height,
        mediaThumbHash: preview?.thumbHash,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] Image send failed: $e');
      _markMessageFailed(tempId, 'Image send failed: ${e.toString()}');
      return false;
    }
  }

  /// Shows the geometry of the attachment [tempId] on its optimistic row.
  void _applyMediaPreview(String tempId, MediaPreviewMetadata preview) {
    final index = _messages.indexWhere((m) => m.tempId == tempId);
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(
      mediaWidth: preview.width,
      mediaHeight: preview.height,
      mediaThumbHash: preview.thumbHash,
    );
    notifyListeners();
  }

  Future<void> sendVoiceMessage({
    required int recipientId,
    required int duration,
    int? conversationId,
    String? localAudioPath,
    List<int>? localAudioBytes,
  }) async {
    if (localAudioPath == null && localAudioBytes == null) {
      throw Exception('Either localAudioPath or localAudioBytes required');
    }
    if (_currentUserId == null) {
      throw StateError('Cannot send voice message: not authenticated');
    }

    // Use provided conversationId or active one
    final effectiveConvId =
        conversationId ?? _conversationsProvider?.activeConversationId;
    if (effectiveConvId == null) {
      throw StateError('Cannot send voice message: no active conversation');
    }

    final tempId = _newTempId();
    final effectiveReplyToId = _replyingToMessage?.id;
    // Get disappearing timer from conversation (null-safe: stale conv id must
    // not throw mid-send, same reasoning as sendMessage).
    final conversations = _conversationsProvider!.conversations;
    final conv = conversations
        .where((c) => c.id == effectiveConvId)
        .firstOrNull;
    final effectiveExpiresIn = conv?.disappearingTimer;

    final optimisticMessage = _buildOptimisticMediaMessage(
      tempId: tempId,
      conversationId: effectiveConvId,
      messageType: MessageType.voice,
      content: '',
      effectiveExpiresIn: effectiveExpiresIn,
      effectiveReplyToId: effectiveReplyToId,
      mediaUrl: localAudioPath ?? '',
      mediaDuration: duration,
    );

    _messages.add(optimisticMessage);
    _conversationsProvider?.updateLastMessage(
      effectiveConvId,
      optimisticMessage,
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      final List<int> rawBytes;
      if (localAudioBytes != null) {
        rawBytes = localAudioBytes;
      } else if (localAudioPath != null) {
        rawBytes = await file_utils.readFileBytes(localAudioPath);
      } else {
        throw Exception('Either localAudioPath or localAudioBytes required');
      }
      if (rawBytes.length > MediaCryptoService.maxBytes) {
        throw Exception('Voice file too large');
      }

      await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: 'VOICE',
        bytes: Uint8List.fromList(rawBytes),
        recording: localAudioPath,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaDuration: duration,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] Voice send failed: $e');
      _markMessageFailed(tempId, 'Failed to send voice message');
    }
  }

  /// Send a video message. Mirrors [sendVoiceMessage]/[sendFileMessage]:
  /// optimistic bubble, then the box path ([_sendMediaOverBox]).
  ///
  /// [duration], [width], [height] and [thumbHash] come from the composer's
  /// single `probeVideoPreview` pass — the provider deliberately does NOT
  /// re-probe, because loading a multi-megabyte clip into a decoder twice
  /// costs seconds on a phone. Each is omitted when the platform could not
  /// read it; [width]/[height] drive the receiving bubble's aspect ratio and
  /// [thumbHash] its placeholder, exactly as for images and GIFs.
  ///
  /// Returns true only AFTER the box took the video's frames (same
  /// caption-ordering contract as [sendImageMessage]); false = failed before
  /// that (the optimistic bubble is marked failed internally).
  Future<bool> sendVideoMessage(
    List<int> videoBytes,
    int recipientId, {
    int? duration,
    int? width,
    int? height,
    String? thumbHash,
  }) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return false;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId = _newTempId();
    final effectiveReplyToId = _replyingToMessage?.id;

    _messages.add(
      _buildOptimisticMediaMessage(
        tempId: tempId,
        conversationId: activeConversationId,
        messageType: MessageType.video,
        content: '',
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaDuration: duration,
        mediaWidth: width,
        mediaHeight: height,
        mediaThumbHash: thumbHash,
      ),
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      if (videoBytes.length > MediaCryptoService.maxBytes) {
        _markMessageFailed(tempId, 'Video too large (max 20 MB)');
        return false;
      }
      // Client policy: MediaCryptoService.maxVideoDurationSeconds. The
      // composer already rejects with a toast when it knows the duration;
      // this is the defensive backstop for programmatic callers.
      if (duration != null &&
          duration > MediaCryptoService.maxVideoDurationSeconds) {
        _markMessageFailed(
          tempId,
          'Video too long (max '
          '${MediaCryptoService.maxVideoDurationSeconds} seconds)',
        );
        return false;
      }

      return await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: 'VIDEO',
        bytes: Uint8List.fromList(videoBytes),
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaDuration: duration,
        mediaWidth: width,
        mediaHeight: height,
        mediaThumbHash: thumbHash,
      );
    } catch (e, st) {
      debugPrint('[MessagingProvider] Video send failed: $e\n$st');
      _markMessageFailed(tempId, 'Video send failed: ${e.toString()}');
      return false;
    }
  }

  /// Send a GIF message. Downloads from Giphy, then the box path
  /// ([_sendMediaOverBox]).
  Future<void> sendGif(String gifUrl, int recipientId) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId = _newTempId();
    final effectiveReplyToId = _replyingToMessage?.id;
    // 1. Optimistic message
    _messages.add(
      _buildOptimisticMediaMessage(
        tempId: tempId,
        conversationId: activeConversationId,
        messageType: MessageType.gif,
        content: '',
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
      ),
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      // 2. Download GIF bytes from Giphy. Without a timeout a stalled fetch
      // never reaches the catch below, so _markMessageFailed never runs, the
      // bubble sits on SENDING forever and retryFailedMessage refuses it
      // because the status is not `failed`.
      final response = await http
          .get(Uri.parse(gifUrl))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('Failed to download GIF');
      }
      final gifBytes = response.bodyBytes;

      // 3. Size guard
      if (gifBytes.length > 5 * 1024 * 1024) {
        throw Exception('GIF too large (max 5 MB)');
      }
      final preview = await _extractMediaPreviewMetadata(gifBytes);
      if (preview != null) {
        _applyMediaPreview(tempId, preview);
      }

      await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: 'GIF',
        bytes: Uint8List.fromList(gifBytes),
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaWidth: preview?.width,
        mediaHeight: preview?.height,
        mediaThumbHash: preview?.thumbHash,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] GIF send failed: $e');
      _markMessageFailed(tempId, 'GIF send failed: ${e.toString()}');
    }
  }

  /// Send a file (document) message over the box ([_sendMediaOverBox]); the
  /// file name rides in the envelope.
  Future<void> sendFileMessage(
    List<int> fileBytes,
    String fileName,
    String fileMimeType,
    int recipientId,
  ) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId = _newTempId();
    final effectiveReplyToId = _replyingToMessage?.id;
    _messages.add(
      _buildOptimisticMediaMessage(
        tempId: tempId,
        conversationId: activeConversationId,
        messageType: MessageType.file,
        content: fileName,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
      ),
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      if (fileBytes.length > MediaCryptoService.maxBytes) {
        _markMessageFailed(tempId, 'File too large (max 20 MB)');
        return;
      }

      await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: 'FILE',
        bytes: Uint8List.fromList(fileBytes),
        content: fileName,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] File send failed: $e');
      _markMessageFailed(tempId, 'File send failed: ${e.toString()}');
    }
  }

  /// Anti-Quantum Note: encrypt client-side, POST to server, send URL as text message.
  Future<void> sendAntiQuantumNote({
    required String content,
    required int expiresInSeconds,
  }) async {
    final token = _tokenForReconnect;
    if (token == null) return;

    // AES-256-GCM client-side encryption via WebCrypto / BoringSSL
    final keyBytes = Uint8List(32);
    fillRandomBytes(keyBytes);
    final ivBytes = Uint8List(12);
    fillRandomBytes(ivBytes);

    final aesKey = await AesGcmSecretKey.importRawKey(keyBytes);
    final plainBytes = Uint8List.fromList(utf8.encode(content));
    final ciphertextWithTag = await aesKey.encryptBytes(plainBytes, ivBytes);

    // Format: base64(iv):base64(ciphertext+tag)
    final ciphertextEncoded =
        '${base64.encode(ivBytes)}:${base64.encode(Uint8List.fromList(ciphertextWithTag))}';

    // POST /notes with ciphertext (server never sees key)
    final noteToken = await _api.createSecretNote(
      token,
      ciphertextEncoded,
      expiresInSeconds,
    );

    // Key encoded as base64url for URL fragment (#KEY). The fragment also
    // carries c=<convId> (reveal page's "Open Umbra" deep link back into
    // this chat) and e=<expiry epoch ms> (in-chat self-destruct countdown).
    // Fragments never travel in HTTP requests — the server sees none of it.
    final keyBase64Url = base64Url.encode(keyBytes);
    final convId = _conversationsProvider?.activeConversationId;
    final expiresAtMs = DateTime.now()
        .add(Duration(seconds: expiresInSeconds))
        .millisecondsSinceEpoch;
    final fragmentParams =
        '${convId != null ? '&c=$convId' : ''}&e=$expiresAtMs';
    final noteUrl =
        '${AppConfig.baseUrl}/note/$noteToken#$keyBase64Url$fragmentParams';

    // Send URL as a text message. Notes ignore the conversation's disappearing
    // timer: the carrying message expires with the NOTE's TTL instead, so the
    // banner leaves chat history in step with the note's own destruction.
    sendMessage(noteUrl, expiresIn: expiresInSeconds);
  }

  /// Typing goes over the box inside E2E (slice (g), E61e) and nowhere else:
  /// the account socket never names the pair at the moment of typing
  /// (decision 33). A peer with no box coverage simply gets nothing.
  void sendTypingIndicator(int recipientId, int conversationId) =>
      _sendBoxTyping(recipientId, conversationId);

  /// The voice-recording indicator: the same box signal as typing (decision
  /// 33, E61e).
  void sendRecordingVoiceIndicator(
    int recipientId,
    int conversationId, {
    required bool isRecording,
  }) => _sendBoxRecordingVoice(
    recipientId,
    conversationId,
    isRecording: isRecording,
  );

  /// Emit typing for the active conversation.
  void emitTyping() {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;
    final conversations = _conversationsProvider!.conversations;
    final conv = conversations
        .where((c) => c.id == activeConversationId)
        .firstOrNull;
    if (conv == null) return;
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);
    sendTypingIndicator(recipientId, activeConversationId);
  }

  /// Retry sending a failed message (any type).
  Future<void> retryFailedMessage(String tempId) async {
    _cancelDelayedRetry(tempId);
    final index = _messages.indexWhere((m) => m.tempId == tempId);
    if (index == -1) return;
    final message = _messages[index];
    if (message.deliveryStatus != MessageDeliveryStatus.failed) return;

    final conversations = _conversationsProvider?.conversations ?? [];
    final conv = conversations
        .where((c) => c.id == message.conversationId)
        .firstOrNull;
    if (conv == null) return;
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);

    // A box attachment whose upload never succeeded (item 3 / media wiring,
    // E17b): the SAME held ciphertext, key and IV go up again, under the
    // row's own timer and quote. One uploaded already (`box:<id>` + keys)
    // re-sends the frames only, below.
    if (message.messageType != MessageType.text &&
        message.messageType != MessageType.ping &&
        !isBoxMediaUrl(message.mediaUrl) &&
        _boxMediaBodies.containsKey(tempId)) {
      _messages[index] = _messages[index].copyWith(
        deliveryStatus: MessageDeliveryStatus.sending,
      );
      notifyListeners();
      await _sendMediaOverBox(
        recipientId: recipientId,
        tempId: tempId,
        messageType: message.messageType.name.toUpperCase(),
        content: message.content,
        effectiveExpiresIn: message.disappearAfterSeconds,
        effectiveReplyToId: message.replyToMessageId,
        mediaDuration: message.mediaDuration,
        mediaWidth: message.mediaWidth,
        mediaHeight: message.mediaHeight,
        mediaThumbHash: message.mediaThumbHash,
      );
      return;
    }

    if (message.messageType == MessageType.ping) {
      _messages[index] = _messages[index].copyWith(
        deliveryStatus: MessageDeliveryStatus.sending,
      );
      notifyListeners();
      _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        messageType: 'PING',
      );
      return;
    }

    if (message.messageType != MessageType.text) {
      final url = message.mediaUrl;
      final key = message.mediaKey;
      final iv = message.mediaIv;
      // Uploaded to the box already: the blob URL and keys live on the model,
      // so only the frames go again (geometry + ThumbHash ride along, or a
      // clip that failed once reaches the peer as a square legacy bubble).
      if (isBoxMediaUrl(url) && key != null && iv != null) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: message.content,
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          effectiveReplyToId: message.replyToMessageId,
          messageType: message.messageType.name.toUpperCase(),
          mediaUrl: url,
          mediaDuration: message.mediaDuration,
          mediaKey: key,
          mediaIv: iv,
          mediaWidth: message.mediaWidth,
          mediaHeight: message.mediaHeight,
          mediaThumbHash: message.mediaThumbHash,
        );
        return;
      }
      // A voice note that failed before its file was read: the recording is
      // still on the device, so it is sent again from there.
      if (message.messageType == MessageType.voice &&
          url != null &&
          url.isNotEmpty &&
          !isBoxMediaUrl(url)) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        notifyListeners();
        await sendVoiceMessage(
          recipientId: recipientId,
          localAudioPath: url,
          duration: message.mediaDuration ?? 0,
          conversationId: message.conversationId,
        );
      }
      return;
    }

    final content = message.content;
    if (content.isEmpty) return;
    // Retry in place against the message's OWN conversation, re-sending to
    // recipientId (sendMessage() would target the active conversation).
    _messages[index] = _messages[index].copyWith(
      deliveryStatus: MessageDeliveryStatus.sending,
    );
    notifyListeners();
    _encryptAndSend(
      recipientId: recipientId,
      content: content,
      tempId: tempId,
      effectiveExpiresIn: conv.disappearingTimer,
      effectiveReplyToId: message.replyToMessageId,
      messageType: 'TEXT',
    );
  }

  /// The `sendToken` for [tempId], minted once and reused by every retry of
  /// that same optimistic message (spec §5.4).
  ///
  /// Reuse is the point: the server enforces per-sender uniqueness, so a retry
  /// carrying the same token re-acks the row it already committed rather than
  /// creating a second message the sender cannot tell apart. Uniqueness comes
  /// from the tempId (`temp_<millis>_<n>_<userId>`) plus a random suffix, keeping
  /// it inside the DTO's 8..64 character bound.
  String _sendTokenFor(String tempId) => _sendTokenByTempId.putIfAbsent(
    tempId,
    () {
      final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final raw = '$tempId-$suffix'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
      // DTO bound is 8..64; a tempId is `temp_<millis>_<n>_<userId>`, always
      // well over 8, so only the upper bound can bite.
      return raw.length <= 64 ? raw : raw.substring(raw.length - 64);
    },
  );

  /// Sends one message over the box — the only path (decision 15) — and
  /// returns whether a peer device's box took it. With no route (no box
  /// address for the peer, a route that names no usable device, a reply
  /// whose quote cannot be named) the row FAILS for the user's 'Ponów':
  /// kept on the device (decision 104), nothing emitted, nothing uploaded.
  Future<bool> _encryptAndSend({
    required int recipientId,
    required String content,
    required String tempId,
    int? effectiveExpiresIn,
    int? effectiveReplyToId,
    String messageType = 'TEXT',
    String? mediaUrl,
    int? mediaDuration,
    String? mediaKey,
    String? mediaIv,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
    _BoxRowAtSend? boxRowAtSend,
  }) async {
    // The account this send belongs to, read before the first await: a
    // sign-out or account switch while it runs must not see its kept copy
    // (decision 104) written into the next session.
    final sendOwner = _currentUserId;
    final e2eReady = _encryptionProvider?.isE2EReady ?? false;
    _e2eFlowLog('SEND_START', {
      'recipientId': recipientId,
      'e2eInitialized': e2eReady,
      'messageType': messageType,
      'tempId': tempId,
    });
    if (!e2eReady) {
      _markMessageFailed(
        tempId,
        'Encryption not ready. Please wait and try again.',
      );
      return false;
    }

    // Exactly-once per tempId: a second attempt for the same optimistic
    // message must not even ENCRYPT (each encrypt advances the Double Ratchet
    // and hands the recipient a duplicate they may fail on). Latched for the
    // whole attempt; released by _markMessageFailed so a deliberate user
    // retry of a FAILED message still goes through.
    if (!_emittedSendTempIds.add(tempId)) {
      _e2eFlowLog('SEND_DUPLICATE_BLOCKED', {
        'recipientId': recipientId,
        'tempId': tempId,
      });
      return false;
    }
    // This attempt has not been refused yet: drop any verdict the PREVIOUS
    // attempt for this row left behind, so a retry that fails for a different
    // reason (or succeeds) stops claiming the peer's keys changed.
    _identityRefusedSendTempIds.remove(tempId);
    // Read before the first await: the optimistic row leaves [_messages] once
    // the user opens another chat. A box send quotes and times the message
    // from its row, a retry included (E18a/E18b): a retry reuses the wire
    // id, so a device already holding the message drops the copy, and a
    // timer changed since would differ between devices. A box attachment
    // read its row before its upload ([boxRowAtSend]).
    final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
    final (:replyTo, ttl: boxTtl) =
        boxRowAtSend ??
        (
          replyTo: row?.replyTo,
          ttl: row == null ? effectiveExpiresIn : row.disappearAfterSeconds,
        );

    try {
      // 1. Fetch client-side link preview before encrypting (TEXT only).
      // Anti-Quantum Note links skip previews entirely: the chat renders a
      // dedicated banner card instead, so fetching our own landing page is a
      // wasted round trip on both platforms.
      Map<String, String?>? linkPreview;
      final firstUrl = messageType == 'TEXT'
          ? LinkPreviewService.extractFirstUrl(content)
          : null;
      if (firstUrl != null && !isAntiQuantumNoteUrl(firstUrl)) {
        try {
          if (kIsWeb && _tokenForReconnect != null) {
            // Web goes through the backend proxy (CORS). E2E hygiene: send it
            // ONLY the fragment-stripped first URL, never the message text —
            // plaintext must not reach the server, and URL fragments can hold
            // secrets (Anti-Quantum Note keys ride in `#<key>`).
            linkPreview = await _api.fetchLinkPreview(
              _tokenForReconnect!,
              LinkPreviewService.stripFragment(firstUrl),
            );
            // Preview is for the link as written: restore the full URL so
            // the preview-card tap keeps the fragment (note key).
            if (linkPreview != null) linkPreview['url'] = firstUrl;
          } else {
            linkPreview = await LinkPreviewService.fetchPreview(content);
          }
        } catch (e) {
          debugPrint('[E2E] Link preview fetch failed (non-fatal): $e');
        }
      }

      // 2. The box. A text or a ping (decision 43) — a reply and a
      // disappearing one included — goes there when every live device on
      // both sides has a box address, as does an attachment already uploaded
      // to the box (`box:<id>`, item 3 / media wiring).
      final onBox = isBoxMediaUrl(mediaUrl);
      final outbox = boxOutbox;
      final addresses = outbox?.addressesFor(recipientId) ?? const {};
      // Decision 42: the chat's setting, taken into E2E per message at its
      // send; one outside the timer sheet's range is no timer (E18b).
      final ttl =
          boxTtl != null &&
              boxTtl >= kDisappearingMinSeconds &&
              boxTtl <= kDisappearingMaxSeconds
          ? boxTtl
          : null;
      // Decision 104: a send is kept on the device from before anything can
      // fail or hang until it goes out, so a failed one — or one a reload cut
      // off mid-send — is still shown red with its wire id.
      final conversationId =
          row?.conversationId ??
          _conversationsProvider?.conversations
              .where(
                (c) =>
                    conv_helpers.getOtherUserId(c, _currentUserId) ==
                    recipientId,
              )
              .firstOrNull
              ?.id;
      if (conversationId != null) {
        await _keepBoxUnsent(
          tempId,
          owner: sendOwner,
          conversationId: conversationId,
          createdAt: row?.createdAt ?? DateTime.now(),
          content: content,
          messageType: messageType,
          ttl: ttl,
          replyToId: effectiveReplyToId,
          replyTo: replyTo,
          mediaUrl: onBox ? mediaUrl : null,
          mediaKey: onBox ? mediaKey : null,
          mediaIv: onBox ? mediaIv : null,
          mediaDuration: onBox ? mediaDuration : null,
          mediaWidth: onBox ? mediaWidth : null,
          mediaHeight: onBox ? mediaHeight : null,
          mediaThumbHash: onBox ? mediaThumbHash : null,
        );
      }

      // A reply whose quote the row cannot name would be sent without it:
      // the box would name nothing, so it fails instead. So does a row
      // naming an attachment that is not on the box: the envelope would drop
      // it silently.
      if (outbox != null &&
          addresses.isNotEmpty &&
          (mediaUrl == null || onBox) &&
          (effectiveReplyToId == null || _boxQuoteOf(replyTo) != null)) {
        final route = await _boxRoute(recipientId, outbox, addresses);
        if (route != null) {
          // Awaited: a throw must reach this try's failure handling.
          return await _sendOverBox(
            route,
            recipientId: recipientId,
            content: content,
            tempId: tempId,
            sendToken: _sendTokenFor(tempId),
            linkPreview: linkPreview,
            messageType: messageType,
            ttl: ttl,
            replyTo: replyTo,
            mediaUrl: onBox ? mediaUrl : null,
            mediaKey: onBox ? mediaKey : null,
            mediaIv: onBox ? mediaIv : null,
            mediaDuration: onBox ? mediaDuration : null,
            mediaWidth: onBox ? mediaWidth : null,
            mediaHeight: onBox ? mediaHeight : null,
            mediaThumbHash: onBox ? mediaThumbHash : null,
          );
        }
      }
      // No box route: the row stays failed, kept on the device, and nothing
      // goes to the server (decisions 15, 25, 104). A retry whose route is
      // back re-seals under the same wire id.
      _e2eFlowLog('BOX_RETRY_NO_ROUTE', {'tempId': tempId});
      _markMessageFailed(tempId, 'Could not send. Try again.');
      return false;
    } catch (e) {
      _encryptionProvider?.clearPendingPreKeyFetch(recipientId);
      debugPrint('[E2E] Encryption failed: $e');
      E2ePersistentDiag.record('SEND_FAIL', {
        'recipientId': recipientId,
        'error': e.toString(),
      });
      // Per-ROW verdict for the failed bubble: only a row that actually
      // bounced on the account anchor may tell the user their peer's keys
      // changed. Classified from the THROWN error, not from the peer's
      // standing alarm, so a timeout in a chat awaiting a ceremony keeps
      // saying "Retry" — which is the correct remedy there.
      if (e is AccountIdentityMismatch ||
          e.toString().contains('AccountIdentityMismatch')) {
        _identityRefusedSendTempIds.add(tempId);
      }
      _markMessageFailed(tempId, 'Cannot send encrypted message.');
      if (_isTimeoutError(e)) _scheduleDelayedRetry(tempId);
      return false;
    }
  }

  @visibleForTesting
  Future<void> encryptAndSendForTest({
    required int recipientId,
    required String content,
    required String tempId,
    int? effectiveExpiresIn,
    int? effectiveReplyToId,
    String messageType = 'TEXT',
    String? mediaUrl,
    int? mediaDuration,
    String? mediaKey,
    String? mediaIv,
  }) => _encryptAndSend(
    recipientId: recipientId,
    content: content,
    tempId: tempId,
    effectiveExpiresIn: effectiveExpiresIn,
    effectiveReplyToId: effectiveReplyToId,
    messageType: messageType,
    mediaUrl: mediaUrl,
    mediaDuration: mediaDuration,
    mediaKey: mediaKey,
    mediaIv: mediaIv,
  );

  void _markMessageFailed(String tempId, String errorMsg) {
    // Failed = eligible for retry; release the exactly-once send latch.
    _emittedSendTempIds.remove(tempId);
    final idx = _messages.indexWhere((m) => m.tempId == tempId);
    if (idx != -1) {
      _messages[idx] = _messages[idx].copyWith(
        deliveryStatus: MessageDeliveryStatus.failed,
      );
    }
    notifyListeners();
  }

  bool _isTimeoutError(Object e) {
    final s = e.toString();
    return s.contains('timed out') ||
        s.contains('Timeout') ||
        e is TimeoutException;
  }

  void _cancelDelayedRetry(String? tempId) {
    if (tempId != null && _delayedRetryTempId == tempId) {
      _delayedRetryTimer?.cancel();
      _delayedRetryTimer = null;
      _delayedRetryTempId = null;
    }
  }

  void _cancelDelayedRetryIfAny() {
    _delayedRetryTimer?.cancel();
    _delayedRetryTimer = null;
    _delayedRetryTempId = null;
  }

  void _scheduleDelayedRetry(String tempId) {
    _delayedRetryTimer?.cancel();
    _delayedRetryTempId = tempId;
    _delayedRetryTimer = Timer(const Duration(seconds: 4), () {
      _delayedRetryTimer = null;
      final tid = _delayedRetryTempId;
      _delayedRetryTempId = null;
      if (tid != null) _retrySendInPlace(tid);
      notifyListeners();
    });
  }

  void _retrySendInPlace(String tempId) {
    final idx = _messages.indexWhere((m) => m.tempId == tempId);
    if (idx == -1) return;
    final message = _messages[idx];
    if (message.deliveryStatus != MessageDeliveryStatus.failed) {
      return;
    }
    // Only auto-retry text and ping
    if (message.messageType != MessageType.text &&
        message.messageType != MessageType.ping) {
      return;
    }
    if (message.messageType == MessageType.text && message.content.isEmpty) {
      return;
    }
    final conversations = _conversationsProvider?.conversations ?? [];
    final convList = conversations
        .where((c) => c.id == message.conversationId)
        .toList();
    if (convList.isEmpty) return;
    final conv = convList.first;
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);
    int? effectiveExpiresIn;
    if (message.disappearAfterSeconds != null) {
      effectiveExpiresIn = message.disappearAfterSeconds;
    } else if (message.expiresAt != null) {
      final secs = message.expiresAt!.difference(DateTime.now()).inSeconds;
      effectiveExpiresIn = secs.clamp(1, kDisappearingMaxSeconds);
    } else {
      effectiveExpiresIn = conv.disappearingTimer;
    }
    _messages[idx] = message.copyWith(
      deliveryStatus: MessageDeliveryStatus.sending,
    );
    notifyListeners();
    _encryptAndSend(
      recipientId: recipientId,
      content: message.content,
      tempId: tempId,
      effectiveExpiresIn: effectiveExpiresIn,
      effectiveReplyToId: message.replyToMessageId,
      messageType: message.messageType.name.toUpperCase(),
    );
  }
}
