part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Optimistic send, encrypt-&-send, send-retry, and typing emit.
Future<MediaPreviewMetadata?> _extractMediaPreviewMetadata(
  Uint8List bytes,
) async {
  try {
    return await MediaPreviewMetadata.fromEncodedBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// The addresses one ciphertext-bearing message must reach, plus the
/// device-list stamps that message quotes.
///
/// Shared by a SEND (spec §5.2) and an EDIT (§5.7): an edit is a full re-fan
/// over the same address set, so resolving it twice in two places is how the
/// two paths would silently drift apart.
typedef FanOutPlan = ({
  bool fanOut,
  List<({int userId, int deviceId})> targets,
  VerifiedDeviceList? recipientList,
  VerifiedDeviceList? ownList,
  SenderListInfo senderListInfo,
});

extension MessagingSend on MessagingProvider {
  /// Resolve who a ciphertext-bearing message to [recipientId] must address.
  ///
  /// A device list is used only when this client ALREADY holds a verified one —
  /// seeded by an explicit fetch, a `deviceListChanged`, or a `deviceListStale`
  /// refusal. It deliberately does NOT fetch: an account with no enrollment is
  /// single-device by construction, and paying a device-list round trip on
  /// every send to prove that would slow the overwhelmingly common path for
  /// nothing. Nothing is dropped by the omission, because the SERVER refuses a
  /// legacy send whenever either party is enrolled and hands back both signed
  /// lists — which is what upgrades this client to fan-out (I5 is enforced
  /// server-side).
  FanOutPlan _resolveFanOut(int recipientId) {
    final ownUserId = _currentUserId;
    final recipientList = _encryptionProvider!.cachedDeviceList(recipientId);
    final ownList = ownUserId == null
        ? null
        : _encryptionProvider!.cachedDeviceList(ownUserId);
    final ownDeviceId = _encryptionProvider!.ownDeviceId;

    // Fan out ONLY when the RECIPIENT's list is known. Without it a fan-out
    // would address own devices alone: the server would accept it (every
    // envelope valid, recipient not enrolled so nothing stale), commit the row
    // with a NULL legacy column, and the recipient's history read would answer
    // `none_for_device` forever — the message permanently invisible to the
    // person it was sent to. Own-device self-sync rides along only once the
    // recipient is addressable.
    final fanOut = recipientList != null;
    final targets = <({int userId, int deviceId})>[
      if (recipientList != null)
        for (final deviceId in recipientList.liveDeviceIds)
          (userId: recipientId, deviceId: deviceId),
      if (fanOut && ownList != null && ownUserId != null)
        for (final deviceId in ownList.liveDeviceIds)
          // NEVER this device: it holds the plaintext already, and the server
          // refuses that envelope as self_envelope_for_origin_device.
          if (deviceId != ownDeviceId) (userId: ownUserId, deviceId: deviceId),
    ];

    // `senderListInfo` states which device-list versions this message was
    // addressed from, and rides inside the plaintext where the server cannot
    // see or edit it (spec §12 amendment (xv), extended to edits by (xxxiv)).
    // It is built from verified cached lists only — a party we hold nothing for
    // is reported ABSENT rather than as version 0, because "I do not know your
    // devices" and "you have no devices" are different claims and only one of
    // them is true. It rides EVERY message (owner ruling 2026-08-21) so a split
    // view is exposed by the first message rather than a sampled one.
    return (
      fanOut: fanOut,
      targets: targets,
      recipientList: recipientList,
      ownList: ownList,
      senderListInfo: SenderListInfo(
        ownVersion: ownList?.version,
        ownListHash: ownList?.listHash,
        peerVersion: recipientList?.version,
        peerListHash: recipientList?.listHash,
      ),
    );
  }

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
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';

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
    // Persist plaintext separately so it survives if _messages is overwritten
    // by a messageHistory response before messageSent arrives.
    // Use explicit Map type to avoid DDC/JS IdentityMap subtype errors.
    _pendingSendContent[tempId] = <String, dynamic>{'content': content};
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
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';

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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': '',
      'messageType': 'PING',
    };
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

  /// Returns true only AFTER the image's `sendMessage` socket emit (spec
  /// §3 ordering contract) — callers sequencing a caption must await this.
  /// False = failed before emit (no conversation, oversize, upload/encrypt
  /// failure); the optimistic bubble is marked failed internally.
  Future<bool> sendImageMessage(
    String token,
    XFile imageFile,
    int recipientId,
  ) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return false;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';
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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': '',
      'messageType': 'IMAGE',
    };
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
        // Same reconnect-clears-the-map hazard as after the upload await:
        // readAsBytes + preview extraction are awaits too.
        final pending = _pendingAfterUpload(tempId);
        if (pending == null) return false;
        pending.addAll({
          'mediaWidth': preview.width,
          'mediaHeight': preview.height,
          if (preview.thumbHash != null) 'mediaThumbHash': preview.thumbHash,
        });
        final previewIndex = _messages.indexWhere((m) => m.tempId == tempId);
        if (previewIndex != -1) {
          _messages[previewIndex] = _messages[previewIndex].copyWith(
            mediaWidth: preview.width,
            mediaHeight: preview.height,
            mediaThumbHash: preview.thumbHash,
          );
          notifyListeners();
        }
      }
      final upload = await _mediaUpload.encryptAndUpload(
        bytes: Uint8List.fromList(rawBytes),
        token: token,
        mediaType: 'image',
        expiresIn: effectiveExpiresIn,
        onEncrypted: (key, iv) {
          _pendingSendContent[tempId] = <String, dynamic>{
            'content': '',
            'messageType': 'IMAGE',
            'mediaKey': key,
            'mediaIv': iv,
            if (preview != null) 'mediaWidth': preview.width,
            if (preview != null) 'mediaHeight': preview.height,
            if (preview?.thumbHash != null)
              'mediaThumbHash': preview!.thumbHash,
          };
        },
      );
      final pending = _pendingAfterUpload(tempId);
      if (pending == null) return false;
      pending['mediaUrl'] = upload.mediaUrl;

      final idx = _messages.indexWhere((m) => m.tempId == tempId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          mediaUrl: upload.mediaUrl,
          mediaKey: upload.keyBase64,
          mediaIv: upload.ivBase64,
          mediaWidth: preview?.width,
          mediaHeight: preview?.height,
          mediaThumbHash: preview?.thumbHash,
        );
        notifyListeners();
      }

      return await _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        messageType: 'IMAGE',
        mediaUrl: upload.mediaUrl,
        mediaKey: upload.keyBase64,
        mediaIv: upload.ivBase64,
        mediaWidth: preview?.width,
        mediaHeight: preview?.height,
        mediaThumbHash: preview?.thumbHash,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] Image upload failed: $e');
      _markMessageFailed(tempId, 'Image upload failed: ${e.toString()}');
      return false;
    }
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

    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';
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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': '',
      'messageType': 'VOICE',
    };
    _conversationsProvider?.updateLastMessage(
      effectiveConvId,
      optimisticMessage,
    );
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      if (_tokenForReconnect == null) {
        throw Exception('No authentication token available');
      }

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

      final upload = await _mediaUpload.encryptAndUpload(
        bytes: Uint8List.fromList(rawBytes),
        token: _tokenForReconnect!,
        mediaType: 'voice',
        duration: duration,
        expiresIn: effectiveExpiresIn,
        onEncrypted: (key, iv) {
          _pendingSendContent[tempId] = <String, dynamic>{
            'content': '',
            'messageType': 'VOICE',
            'mediaDuration': duration,
            'mediaKey': key,
            'mediaIv': iv,
          };
        },
      );

      final serverDuration = upload.mediaDuration ?? duration;
      final pending = _pendingAfterUpload(tempId);
      if (pending == null) return;
      pending['mediaUrl'] = upload.mediaUrl;

      final index = _messages.indexWhere((m) => m.tempId == tempId);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(
          mediaUrl: upload.mediaUrl,
          mediaDuration: serverDuration,
          mediaKey: upload.keyBase64,
          mediaIv: upload.ivBase64,
        );
        notifyListeners();
      }

      if (!kIsWeb && localAudioPath != null) {
        await file_utils.deleteFileIfExists(localAudioPath);
      }

      _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        messageType: 'VOICE',
        mediaUrl: upload.mediaUrl,
        mediaDuration: serverDuration,
        mediaKey: upload.keyBase64,
        mediaIv: upload.ivBase64,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] Voice upload failed: $e');
      _markMessageFailed(tempId, 'Failed to send voice message');
    }
  }

  /// Send a video message. Mirrors [sendVoiceMessage]/[sendFileMessage]:
  /// optimistic bubble, AES-GCM encrypt+upload (keys stashed into
  /// _pendingSendContent BEFORE any await — durability invariant), then the
  /// E2E envelope send.
  ///
  /// [duration], [width], [height] and [thumbHash] come from the composer's
  /// single `probeVideoPreview` pass — the provider deliberately does NOT
  /// re-probe, because loading a multi-megabyte clip into a decoder twice
  /// costs seconds on a phone. Each is omitted when the platform could not
  /// read it; [width]/[height] drive the receiving bubble's aspect ratio and
  /// [thumbHash] its placeholder, exactly as for images and GIFs.
  ///
  /// Returns true only AFTER the video's `sendMessage` socket emit (same
  /// caption-ordering contract as [sendImageMessage]); false = failed before
  /// the emit (the optimistic bubble is marked failed internally).
  Future<bool> sendVideoMessage(
    String token,
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
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';
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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': '',
      'messageType': 'VIDEO',
      'mediaDuration': ?duration,
      'mediaWidth': ?width,
      'mediaHeight': ?height,
      'mediaThumbHash': ?thumbHash,
    };
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

      final upload = await _mediaUpload.encryptAndUpload(
        bytes: Uint8List.fromList(videoBytes),
        token: token,
        mediaType: 'video',
        duration: duration,
        expiresIn: effectiveExpiresIn,
        onEncrypted: (key, iv) {
          _pendingSendContent[tempId] = <String, dynamic>{
            'content': '',
            'messageType': 'VIDEO',
            'mediaDuration': ?duration,
            'mediaWidth': ?width,
            'mediaHeight': ?height,
            'mediaThumbHash': ?thumbHash,
            'mediaKey': key,
            'mediaIv': iv,
          };
        },
      );
      final serverDuration = upload.mediaDuration ?? duration;
      final pending = _pendingAfterUpload(tempId);
      if (pending == null) return false;
      pending['mediaUrl'] = upload.mediaUrl;

      final idx = _messages.indexWhere((m) => m.tempId == tempId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          mediaUrl: upload.mediaUrl,
          mediaDuration: serverDuration,
          mediaKey: upload.keyBase64,
          mediaIv: upload.ivBase64,
        );
        notifyListeners();
      }

      return await _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        messageType: 'VIDEO',
        mediaUrl: upload.mediaUrl,
        mediaDuration: serverDuration,
        mediaKey: upload.keyBase64,
        mediaIv: upload.ivBase64,
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

  /// Post-await guard for every media send path — used after ANY await that
  /// precedes a `_pendingSendContent[tempId]` write (file read, preview
  /// extraction, Giphy download, the upload itself).
  ///
  /// The reconnect handler wipes `_pendingSendContent` AND the exactly-once
  /// latch (`messaging_provider.dart` onConnect(isReconnect: true) — a
  /// reconnect cancels any queued retry). A send that was IN FLIGHT across
  /// that reconnect resumes here to find its entry gone. Proceeding anyway
  /// would emit with reset exactly-once state; indexing with `!` (the old
  /// code) crashed into the generic catch. The only safe move is to fail the
  /// bubble cleanly for a manual retry.
  ///
  /// Returns the live entry, or null after marking the message failed.
  Map<String, dynamic>? _pendingAfterUpload(String tempId) {
    final pending = _pendingSendContent[tempId];
    if (pending == null) {
      _markMessageFailed(
        tempId,
        'Connection was reset during send. Please retry.',
      );
    }
    return pending;
  }

  /// Send a GIF message. Downloads from Giphy, encrypts bytes, uploads blob, E2E envelope.
  Future<void> sendGif(String token, String gifUrl, int recipientId) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';
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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': '',
      'messageType': 'GIF',
    };
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
        // Giphy download + preview extraction sit before this write; a
        // reconnect in that window cleared the map (same hazard as post-
        // upload).
        final pending = _pendingAfterUpload(tempId);
        if (pending == null) return;
        pending.addAll({
          'mediaWidth': preview.width,
          'mediaHeight': preview.height,
          if (preview.thumbHash != null) 'mediaThumbHash': preview.thumbHash,
        });
        final previewIndex = _messages.indexWhere((m) => m.tempId == tempId);
        if (previewIndex != -1) {
          _messages[previewIndex] = _messages[previewIndex].copyWith(
            mediaWidth: preview.width,
            mediaHeight: preview.height,
            mediaThumbHash: preview.thumbHash,
          );
          notifyListeners();
        }
      }

      final upload = await _mediaUpload.encryptAndUpload(
        bytes: Uint8List.fromList(gifBytes),
        token: token,
        mediaType: 'gif',
        expiresIn: effectiveExpiresIn,
        onEncrypted: (key, iv) {
          _pendingSendContent[tempId] = <String, dynamic>{
            'content': '',
            'messageType': 'GIF',
            'mediaKey': key,
            'mediaIv': iv,
            if (preview != null) 'mediaWidth': preview.width,
            if (preview != null) 'mediaHeight': preview.height,
            if (preview?.thumbHash != null)
              'mediaThumbHash': preview!.thumbHash,
          };
        },
      );
      final pending = _pendingAfterUpload(tempId);
      if (pending == null) return;
      pending['mediaUrl'] = upload.mediaUrl;

      final idx = _messages.indexWhere((m) => m.tempId == tempId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          mediaUrl: upload.mediaUrl,
          mediaKey: upload.keyBase64,
          mediaIv: upload.ivBase64,
          mediaWidth: preview?.width,
          mediaHeight: preview?.height,
          mediaThumbHash: preview?.thumbHash,
        );
        notifyListeners();
      }

      _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        messageType: 'GIF',
        mediaUrl: upload.mediaUrl,
        mediaKey: upload.keyBase64,
        mediaIv: upload.ivBase64,
        mediaWidth: preview?.width,
        mediaHeight: preview?.height,
        mediaThumbHash: preview?.thumbHash,
      );
    } catch (e) {
      debugPrint('[MessagingProvider] GIF send failed: $e');
      _markMessageFailed(tempId, 'GIF send failed: ${e.toString()}');
    }
  }

  /// Send a file (document) message. Uploads to backend, then encrypts URL + filename in envelope.
  Future<void> sendFileMessage(
    String token,
    List<int> fileBytes,
    String fileName,
    String fileMimeType,
    int recipientId,
  ) async {
    final activeConversationId = _conversationsProvider?.activeConversationId;
    if (activeConversationId == null || _currentUserId == null) return;

    final effectiveExpiresIn =
        _conversationsProvider!.conversationDisappearingTimer;
    final tempId =
        'temp_${DateTime.now().millisecondsSinceEpoch}_$_currentUserId';
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
    _pendingSendContent[tempId] = <String, dynamic>{
      'content': fileName,
      'messageType': 'FILE',
    };
    _clearReplyingToAfterSendStart();
    notifyListeners();

    try {
      if (fileBytes.length > MediaCryptoService.maxBytes) {
        _markMessageFailed(tempId, 'File too large (max 20 MB)');
        return;
      }

      final upload = await _mediaUpload.encryptAndUpload(
        bytes: Uint8List.fromList(fileBytes),
        token: token,
        mediaType: 'file',
        fileName: fileName,
        onEncrypted: (key, iv) {
          _pendingSendContent[tempId] = <String, dynamic>{
            'content': fileName,
            'messageType': 'FILE',
            'mediaKey': key,
            'mediaIv': iv,
          };
        },
      );
      final pending = _pendingAfterUpload(tempId);
      if (pending == null) return;
      pending['mediaUrl'] = upload.mediaUrl;

      final idx = _messages.indexWhere((m) => m.tempId == tempId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          mediaUrl: upload.mediaUrl,
          mediaKey: upload.keyBase64,
          mediaIv: upload.ivBase64,
        );
        notifyListeners();
      }

      _encryptAndSend(
        recipientId: recipientId,
        content: fileName,
        tempId: tempId,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        messageType: 'FILE',
        mediaUrl: upload.mediaUrl,
        mediaKey: upload.keyBase64,
        mediaIv: upload.ivBase64,
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

  void sendTypingIndicator(int recipientId, int conversationId) {
    _emit?.call('typing', {
      'recipientId': recipientId,
      'conversationId': conversationId,
    });
  }

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

  /// A send the server refused because this client's device-list view was
  /// unusable (spec §5.2 layer 1 + §12 amendments (vi)/(x)).
  ///
  /// Repair is one round trip by design: the refusal carries each stale
  /// party's FULL signed list, which is verified here along the I7 chain
  /// before anything is trusted — an invalid chain fails the send outright
  /// rather than adopting the server's word (falsification 4).
  ///
  /// A party can be MISSING from `lists` while still blocking the send: a
  /// legacy send is refused when EITHER side is enrolled, and the non-enrolled
  /// side contributes no entry. Those are resolved explicitly, or the resend
  /// would repeat the same legacy shape and burn the retry budget.
  Future<void> onDeviceListStale(dynamic data) async {
    if (data is! Map) return;
    final tempId = data['tempId'] as String?;
    final lists = data['lists'];
    final encryption = _encryptionProvider;
    if (encryption == null) return;

    try {
      if (lists is List) {
        for (final entry in lists) {
          if (entry is! Map) continue;
          final userId = entry['userId'] as int?;
          final enrollment = entry['enrollment'];
          if (userId == null || enrollment is! Map) continue;
          // Re-shape the refusal entry into the `authorization` map the
          // verifier consumes, so both delivery routes share one chain check.
          await encryption.adoptDeliveredDeviceList(userId, {
            'dakPub': enrollment['dakPub'],
            'enrollmentSig': enrollment['enrollmentSig'],
            'enrollmentCreatedAt': enrollment['enrollmentCreatedAt'],
            'listVersion': entry['version'],
            'listSignature': entry['listSignature'],
            'listCanonical': entry['listCanonical'],
          });
        }
      }

      // An EDIT refusal is correlated by messageId, not tempId (spec §5.7 +
      // §12 amendment (xxxi)). It MUST be driven to a conclusion: the edit was
      // applied optimistically, so returning here would leave this device
      // showing the new text forever while the server and the peer keep the old
      // ciphertext — a silent divergence that survives a reopen.
      final staleEditId = data['messageId'] as int?;
      if (staleEditId != null) {
        await _retryStaleEdit(staleEditId);
        return;
      }

      if (tempId == null) return;
      final index = _messages.indexWhere((m) => m.tempId == tempId);
      if (index == -1) return;
      final conversations = _conversationsProvider?.conversations ?? [];
      final conv = conversations
          .where((c) => c.id == _messages[index].conversationId)
          .firstOrNull;
      if (conv == null) return;
      final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);

      // Resolve every party the resend needs. A `getDeviceList` answering
      // `authorization: null` caches "not enrolled, device 1 only", which is
      // what flips this send from the legacy shape to a fan-out.
      for (final userId in {recipientId, ?_currentUserId}) {
        if (encryption.cachedDeviceList(userId) == null) {
          await encryption.getVerifiedDeviceList(userId);
        }
      }

      // Bounded retry (spec §5.2: cap then a surfaced failure — Sesame §3.3
      // mandates a finite loop). Never silently drop a device instead.
      final attempts = (_staleResendAttempts[tempId] ?? 0) + 1;
      _staleResendAttempts[tempId] = attempts;
      if (attempts > 3) {
        _markMessageFailed(
          tempId,
          'Could not confirm this chat\'s devices. Please try again.',
        );
        return;
      }

      // Release the exactly-once latch and re-drive the normal send path, which
      // now sees the verified lists and fans out.
      _emittedSendTempIds.remove(tempId);
      _staleResendTempIds.add(tempId);
      try {
        await retryFailedMessage(tempId);
      } finally {
        _staleResendTempIds.remove(tempId);
      }
    } catch (e) {
      debugPrint('[E2E] deviceListStale repair failed: $e');
      if (tempId != null) {
        _markMessageFailed(
          tempId,
          'Could not verify this chat\'s devices. Please try again.',
        );
      }
    }
  }

  /// Re-drive an edit the server refused as `device_list_stale`, now that the
  /// signed lists from the refusal have been adopted (spec §5.7, same bounded
  /// bounce as §5.2).
  ///
  /// Bounded for the same reason a send is: three attempts, then the optimistic
  /// edit is REVERTED rather than left diverging from the server. Retrying
  /// forever against a list this client cannot verify would strand the row in a
  /// state only this device believes in.
  Future<void> _retryStaleEdit(int messageId) async {
    // Every early return below means the edit can no longer be re-driven, so
    // the optimistic snapshot must not be left behind: `_pendingEdits` would
    // hold that row forever, and a later revert would restore text from an edit
    // the user has long forgotten.
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) {
      _revertPendingEdit(messageId, 'device_list_stale');
      return;
    }
    final row = _messages[index];
    final conv = (_conversationsProvider?.conversations ?? [])
        .where((c) => c.id == row.conversationId)
        .firstOrNull;
    if (conv == null) {
      _revertPendingEdit(messageId, 'device_list_stale');
      return;
    }
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);
    final encryption = _encryptionProvider;
    if (encryption == null) {
      _revertPendingEdit(messageId, 'device_list_stale');
      return;
    }

    // Resolve every party the re-fan needs; an `authorization: null` answer
    // caches "not enrolled, device 1 only", which is what decides the shape.
    for (final userId in {recipientId, ?_currentUserId}) {
      if (encryption.cachedDeviceList(userId) == null) {
        await encryption.getVerifiedDeviceList(userId);
      }
    }

    final key = 'edit:$messageId';
    final attempts = (_staleResendAttempts[key] ?? 0) + 1;
    _staleResendAttempts[key] = attempts;
    if (attempts > 3) {
      _staleResendAttempts.remove(key);
      _revertPendingEdit(messageId, 'device_list_stale');
      return;
    }

    await _encryptAndEmitEdit(
      messageId: messageId,
      recipientId: recipientId,
      // The optimistically applied text — the edit the user actually asked for.
      content: row.content,
    );
  }

  /// Retry sending a failed message (any type).
  Future<void> retryFailedMessage(String tempId) async {
    _cancelDelayedRetry(tempId);
    final index = _messages.indexWhere((m) => m.tempId == tempId);
    if (index == -1) return;
    final message = _messages[index];
    // A stale-list resend re-drives this path while the row is still SENDING —
    // the send was refused before delivery, so flashing a failure at the user
    // and back would be a lie (spec §12 (vi)/(x)).
    if (message.deliveryStatus != MessageDeliveryStatus.failed &&
        !_staleResendTempIds.contains(tempId)) {
      return;
    }

    final conversations = _conversationsProvider?.conversations ?? [];
    final conv = conversations
        .where((c) => c.id == message.conversationId)
        .firstOrNull;
    if (conv == null) return;
    final recipientId = conv_helpers.getOtherUserId(conv, _currentUserId);

    if (message.messageType == MessageType.ping) {
      _messages[index] = _messages[index].copyWith(
        deliveryStatus: MessageDeliveryStatus.sending,
      );
      _pendingSendContent[tempId] = <String, dynamic>{
        'content': '',
        'messageType': 'PING',
      };
      notifyListeners();
      _encryptAndSend(
        recipientId: recipientId,
        content: '',
        tempId: tempId,
        messageType: 'PING',
      );
      return;
    }

    if (message.messageType == MessageType.voice) {
      final vUrl = message.mediaUrl;
      final vKey = message.mediaKey;
      final vIv = message.mediaIv;
      // After encrypt+upload, blob URL and keys live on the model — retry E2E send only.
      if (vUrl != null &&
          vUrl.isNotEmpty &&
          vKey != null &&
          vIv != null &&
          vUrl.startsWith('http')) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'VOICE',
          'mediaUrl': vUrl,
          'mediaDuration': message.mediaDuration,
          'mediaKey': vKey,
          'mediaIv': vIv,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          messageType: 'VOICE',
          mediaUrl: vUrl,
          mediaDuration: message.mediaDuration,
          mediaKey: vKey,
          mediaIv: vIv,
        );
        return;
      }
      if (message.mediaUrl != null &&
          (message.mediaUrl!.contains('cloudinary') ||
              message.mediaUrl!.contains('/media/'))) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'VOICE',
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          messageType: 'VOICE',
          mediaUrl: message.mediaUrl,
          mediaDuration: message.mediaDuration,
        );
      } else {
        final localPath = message.mediaUrl;
        if (localPath == null || localPath.isEmpty) {
          return;
        }
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        notifyListeners();
        await sendVoiceMessage(
          recipientId: recipientId,
          localAudioPath: localPath,
          duration: message.mediaDuration ?? 0,
          conversationId: message.conversationId,
        );
      }
      return;
    }

    if (message.messageType == MessageType.video) {
      final vUrl = message.mediaUrl;
      final vKey = message.mediaKey;
      final vIv = message.mediaIv;
      // After encrypt+upload, blob URL and keys live on the model — retry the
      // E2E send only; pre-upload failures have no local copy to re-upload.
      if (vUrl != null && vUrl.isNotEmpty && vKey != null && vIv != null) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        // Geometry + ThumbHash ride along exactly as the image branch does.
        // They were dropped here, so a video that failed once and was retried
        // reached the peer WITHOUT geometry — a square legacy bubble with no
        // poster — while the first attempt's optimistic bubble looked right.
        // Second independent cause of the 2026-09-05 "square video" report.
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'VIDEO',
          'mediaUrl': vUrl,
          if (message.mediaDuration != null)
            'mediaDuration': message.mediaDuration,
          'mediaKey': vKey,
          'mediaIv': vIv,
          if (message.mediaWidth != null) 'mediaWidth': message.mediaWidth,
          if (message.mediaHeight != null) 'mediaHeight': message.mediaHeight,
          if (message.mediaThumbHash != null)
            'mediaThumbHash': message.mediaThumbHash,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          messageType: 'VIDEO',
          mediaUrl: vUrl,
          mediaDuration: message.mediaDuration,
          mediaKey: vKey,
          mediaIv: vIv,
          mediaWidth: message.mediaWidth,
          mediaHeight: message.mediaHeight,
          mediaThumbHash: message.mediaThumbHash,
        );
      }
      return;
    }

    if (message.messageType == MessageType.image) {
      final iUrl = message.mediaUrl;
      final iKey = message.mediaKey;
      final iIv = message.mediaIv;
      if (iUrl != null && iUrl.isNotEmpty && iKey != null && iIv != null) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'IMAGE',
          'mediaUrl': iUrl,
          'mediaKey': iKey,
          'mediaIv': iIv,
          if (message.mediaWidth != null) 'mediaWidth': message.mediaWidth,
          if (message.mediaHeight != null) 'mediaHeight': message.mediaHeight,
          if (message.mediaThumbHash != null)
            'mediaThumbHash': message.mediaThumbHash,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          messageType: 'IMAGE',
          mediaUrl: iUrl,
          mediaKey: iKey,
          mediaIv: iIv,
          mediaWidth: message.mediaWidth,
          mediaHeight: message.mediaHeight,
          mediaThumbHash: message.mediaThumbHash,
        );
        return;
      }
      if (message.mediaUrl != null &&
          (message.mediaUrl!.contains('cloudinary') ||
              message.mediaUrl!.contains('/media/'))) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'IMAGE',
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          messageType: 'IMAGE',
          mediaUrl: message.mediaUrl,
          mediaWidth: message.mediaWidth,
          mediaHeight: message.mediaHeight,
          mediaThumbHash: message.mediaThumbHash,
        );
      }
      return;
    }

    if (message.messageType == MessageType.gif) {
      final gUrl = message.mediaUrl;
      final gKey = message.mediaKey;
      final gIv = message.mediaIv;
      if (gUrl != null && gUrl.isNotEmpty && gKey != null && gIv != null) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': '',
          'messageType': 'GIF',
          'mediaUrl': gUrl,
          'mediaKey': gKey,
          'mediaIv': gIv,
          if (message.mediaWidth != null) 'mediaWidth': message.mediaWidth,
          if (message.mediaHeight != null) 'mediaHeight': message.mediaHeight,
          if (message.mediaThumbHash != null)
            'mediaThumbHash': message.mediaThumbHash,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: '',
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          messageType: 'GIF',
          mediaUrl: gUrl,
          mediaKey: gKey,
          mediaIv: gIv,
          mediaWidth: message.mediaWidth,
          mediaHeight: message.mediaHeight,
          mediaThumbHash: message.mediaThumbHash,
        );
      }
      return;
    }

    if (message.messageType == MessageType.file) {
      final fUrl = message.mediaUrl;
      final fKey = message.mediaKey;
      final fIv = message.mediaIv;
      final fileName = message.content;
      if (fUrl != null && fUrl.isNotEmpty && fKey != null && fIv != null) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': fileName,
          'messageType': 'FILE',
          'mediaUrl': fUrl,
          'mediaKey': fKey,
          'mediaIv': fIv,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: fileName,
          tempId: tempId,
          effectiveExpiresIn: conv.disappearingTimer,
          messageType: 'FILE',
          mediaUrl: fUrl,
          mediaKey: fKey,
          mediaIv: fIv,
        );
        return;
      }
      if (message.mediaUrl != null &&
          (message.mediaUrl!.contains('cloudinary') ||
              message.mediaUrl!.contains('/media/'))) {
        _messages[index] = _messages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.sending,
        );
        _pendingSendContent[tempId] = <String, dynamic>{
          'content': message.content,
          'messageType': 'FILE',
          'mediaUrl': message.mediaUrl,
        };
        notifyListeners();
        _encryptAndSend(
          recipientId: recipientId,
          content: message.content,
          tempId: tempId,
          messageType: 'FILE',
          mediaUrl: message.mediaUrl,
        );
      }
      return;
    }

    if (message.messageType == MessageType.text) {
      final content = message.content;
      if (content.isEmpty) return;
      // Retry in place against the message's OWN conversation. The old path
      // removed the bubble and only re-sent when it was the active chat — so a
      // retry from anywhere else silently DELETED the message, and even when
      // active it re-sent via sendMessage() (which targets the active conv, not
      // necessarily this one). Re-encrypt + resend to recipientId instead.
      _messages[index] = _messages[index].copyWith(
        deliveryStatus: MessageDeliveryStatus.sending,
      );
      _pendingSendContent[tempId] = <String, dynamic>{
        'content': content,
        'messageType': 'TEXT',
      };
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
  }

  /// The `sendToken` for [tempId], minted once and reused by every retry of
  /// that same optimistic message (spec §5.4).
  ///
  /// Reuse is the point: the server enforces per-sender uniqueness, so a retry
  /// carrying the same token re-acks the row it already committed rather than
  /// creating a second message the sender cannot tell apart. Uniqueness comes
  /// from the tempId (`temp_<millis>_<userId>`) plus a random suffix, keeping
  /// it inside the DTO's 8..64 character bound.
  String _sendTokenFor(String tempId) => _sendTokenByTempId.putIfAbsent(
    tempId,
    () {
      final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final raw = '$tempId-$suffix'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
      // DTO bound is 8..64; a tempId is `temp_<millis>_<userId>`, always
      // well over 8, so only the upper bound can bite.
      return raw.length <= 64 ? raw : raw.substring(raw.length - 64);
    },
  );

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
  }) async {
    final e2eReady = _encryptionProvider?.isE2EReady ?? false;
    _e2eFlowLog('SEND_START', {
      'recipientId': recipientId,
      'e2eInitialized': e2eReady,
      'messageType': messageType,
      'tempId': tempId,
    });
    if (!e2eReady) {
      _logMediaOrphanLikely(tempId, mediaUrl);
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

      // 2. Store all fields in pending content so _addMessageToState can restore them
      final pending = _pendingSendContent[tempId];
      if (pending != null) {
        pending['messageType'] = messageType;
        if (mediaUrl != null) pending['mediaUrl'] = mediaUrl;
        if (mediaDuration != null) pending['mediaDuration'] = mediaDuration;
        if (mediaKey != null) pending['mediaKey'] = mediaKey;
        if (mediaIv != null) pending['mediaIv'] = mediaIv;
        if (mediaWidth != null) pending['mediaWidth'] = mediaWidth;
        if (mediaHeight != null) pending['mediaHeight'] = mediaHeight;
        if (mediaThumbHash != null) pending['mediaThumbHash'] = mediaThumbHash;
        if (linkPreview != null) {
          if (linkPreview['url'] != null) {
            pending['linkPreviewUrl'] = linkPreview['url'];
          }
          if (linkPreview['title'] != null) {
            pending['linkPreviewTitle'] = linkPreview['title'];
          }
          if (linkPreview['imageUrl'] != null) {
            pending['linkPreviewImageUrl'] = linkPreview['imageUrl'];
          }
        }
      }

      // 2b. The box (metadata-privacy PR3.1 slice (c)). A plain text goes
      // there — and ONLY there (decision 15) — when every live device on
      // both sides has a box address; otherwise the old path below, as ever.
      // Media, pings, replies and disappearing timers stay on the old path:
      // the box envelope carries none of them yet.
      final outbox = boxOutbox;
      final addresses = outbox?.addressesFor(recipientId) ?? const {};
      if (outbox != null &&
          addresses.isNotEmpty &&
          messageType == 'TEXT' &&
          // The box envelope carries no media fields: a TEXT that ever did
          // carry a `mediaUrl` would lose it silently.
          mediaUrl == null &&
          effectiveReplyToId == null &&
          (effectiveExpiresIn ?? 0) <= 0) {
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
          );
        }
      }
      if (_boxTempIds.contains(tempId)) {
        // A retry of a box send whose route is gone (a peer device lost its
        // address, ours gained a sibling): the box may already have handed
        // it to some devices, and the old path's reader would show those a
        // second copy. It stays failed; nothing goes to the server.
        _e2eFlowLog('BOX_RETRY_NO_ROUTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }

      // 3. Resolve the addresses this send must reach (spec §5.2 + §12
      // amendment (x)).
      //
      // A device list is used only when this client ALREADY holds a verified
      // one — seeded by an explicit fetch, a `deviceListChanged`, or a
      // `deviceListStale` refusal. It deliberately does NOT fetch here: an
      // account with no enrollment is single-device by construction, and
      // paying a device-list round trip on every send to prove that would slow
      // the overwhelmingly common path for nothing. Nothing is dropped by the
      // omission, because the SERVER refuses a legacy send whenever either
      // party is enrolled and hands back both signed lists — which is what
      // upgrades this client to fan-out (I5 is enforced server-side).
      final resolved = _resolveFanOut(recipientId);
      final recipientList = resolved.recipientList;
      final ownList = resolved.ownList;
      final fanOut = resolved.fanOut;
      final targets = resolved.targets;
      final senderListInfo = resolved.senderListInfo;
      // Minted once per tempId and reused by every retry (see
      // [_sendTokenFor]), so a resend carries the same wire id as the first
      // attempt. It rides inside the plaintext as `msgId` (PR2.1): the server
      // echoes the token only to this device, so it is how every OTHER device
      // learns the message's wire id.
      final sendToken = _sendTokenFor(tempId);
      final envelopeJson = jsonEncode(
        E2eEnvelope.build(
          content,
          messageType: messageType,
          mediaUrl: mediaUrl,
          mediaDuration: mediaDuration,
          mediaKey: mediaKey,
          mediaIv: mediaIv,
          mediaWidth: mediaWidth,
          mediaHeight: mediaHeight,
          mediaThumbHash: mediaThumbHash,
          linkPreview: linkPreview,
          senderListInfo: senderListInfo.toJson(),
          msgId: sendToken,
        ),
      );

      // 5. Encrypt. With the recipient's list known that is ONE ciphertext per
      // address — reusing one across devices is not an option, because Signal
      // decryption consumes the message key and every device but the first
      // would fail terminally. Otherwise it is the legacy single-ciphertext
      // shape for device 1, which the server normalizes into a device-1
      // envelope at ingest (§8, amendment (v)).
      final envelopes = <Map<String, dynamic>>[];
      String? legacyCiphertext;
      for (final target
          in fanOut ? targets : [(userId: recipientId, deviceId: 1)]) {
        await _encryptionProvider!.ensureSession(
          target.userId,
          deviceId: target.deviceId,
        );
        final ciphertext = await _encryptionProvider!.encrypt(
          target.userId,
          envelopeJson,
          deviceId: target.deviceId,
        );
        // Authoritative size guard mirroring the DTO's @MaxLength(65536);
        // applies PER ciphertext, since each is validated separately.
        if (ciphertext.length > 65536) {
          _markMessageFailed(tempId, 'Message is too long to send.');
          return false;
        }
        if (fanOut) {
          envelopes.add({
            'userId': target.userId,
            'deviceId': target.deviceId,
            'ciphertext': ciphertext,
          });
        } else {
          legacyCiphertext = ciphertext;
        }
      }
      _e2eFlowLog('SEND_ENCRYPT_DONE', {
        'recipientId': recipientId,
        'fanOut': fanOut,
        'envelopes': envelopes.length,
        'targets': targets.map((t) => '${t.userId}:${t.deviceId}').join(','),
      });

      // 5b. Durable lost-ack insurance. Keyed by the send TOKEN once this is a
      // fan-out (spec §12 amendment (ix)): such a row carries NO ciphertext for
      // its own origin device — the server serves it `envelopeStatus:
      // own_origin` — so the exact-ciphertext match would never fire again and
      // the ONLY plaintext copy would be stranded. A legacy send keeps the
      // ciphertext key, which is what its own row echoes back. The token is
      // minted per tempId and REUSED by a retry of the same send, so a retry
      // reconciles to the same row either way. Fire-and-forget: the send is
      // never delayed or failed by this. (The token itself was minted above,
      // before the envelope that carries it.)
      final pendingSnapshot = _pendingSendContent[tempId];
      if (pendingSnapshot != null) {
        _encryptionProvider!
            .savePendingSendRecord(
              fanOut ? sendToken : legacyCiphertext!,
              // The minted token rides along so a lost-ack reconcile stamps
              // OUR wire id, never the server's echo of it.
              {...pendingSnapshot, PlaintextRecordCodec.wireIdKey: sendToken},
            )
            .ignore();
      }

      // 6. Send. Version stamps are quoted only for an ENROLLED party: a
      // non-enrolled account is single-device by construction and carries no
      // stamp (amendment (v)), and quoting one would be refused as stale.
      _e2eFlowLog('SEND_EMIT', {'recipientId': recipientId, 'tempId': tempId});
      final emitPayload = <String, dynamic>{
        'recipientId': recipientId,
        'content': '[encrypted]',
        if (fanOut) 'envelopes': envelopes,
        if (!fanOut) 'encryptedContent': legacyCiphertext,
        'sendToken': sendToken,
        'expiresIn': effectiveExpiresIn,
        'tempId': tempId,
        // A box message's LOCAL id names no server row (decision 14).
        if (effectiveReplyToId != null && isServerMessageId(effectiveReplyToId))
          'replyToMessageId': effectiveReplyToId,
      };
      if (fanOut && recipientList?.version != null) {
        emitPayload['recipientListVersion'] = recipientList!.version;
      }
      if (fanOut && ownList?.version != null) {
        emitPayload['senderListVersion'] = ownList!.version;
      }
      if (messageType != 'TEXT') {
        emitPayload['messageType'] = messageType;
      }
      if (mediaUrl != null && mediaUrl.isNotEmpty) {
        emitPayload['mediaUrl'] = mediaUrl;
      }
      if (mediaDuration != null) {
        emitPayload['mediaDuration'] = mediaDuration;
      }
      _emit?.call('sendMessage', emitPayload);
      return true;
    } catch (e) {
      _encryptionProvider?.clearPendingPreKeyFetch(recipientId);
      debugPrint('[E2E] Encryption failed: $e');
      E2ePersistentDiag.record('SEND_FAIL', {
        'recipientId': recipientId,
        'error': e.toString(),
      });
      _logMediaOrphanLikely(tempId, mediaUrl);
      // Per-ROW verdict for the failed bubble: only a row that actually
      // bounced on the account anchor may tell the user their peer's keys
      // changed. Classified from the THROWN error, not from the peer's
      // standing alarm, so a timeout in a chat awaiting a ceremony keeps
      // saying "Retry" — which is the correct remedy there.
      if (e is AccountIdentityMismatch ||
          e.toString().contains('AccountIdentityMismatch')) {
        _identityRefusedSendTempIds.add(tempId);
      }
      final String userMsg = _userFriendlySendError(e, recipientId);
      _markMessageFailed(tempId, userMsg);
      if (_isKeyBundleOrTimeoutError(e)) {
        if (_isMissingKeyBundleError(e)) {
          _refreshRecipientDeviceListAfterDeadAddress(recipientId);
        }
        _scheduleDelayedRetry(tempId);
      }
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

  /// Observability for the I1 media-orphan gap: a media blob was uploaded
  /// (`mediaUrl` obtained) but the send failed before the `sendMessage` emit,
  /// so the `.bin` is now orphaned on the server until the cleanup cron sweeps
  /// it. Logs an id-only event so the client side of the gap is measurable.
  /// No-op for text/ping sends (no upload, so `mediaUrl` is null/empty).
  void _logMediaOrphanLikely(String tempId, String? mediaUrl) {
    if (mediaUrl == null || mediaUrl.isEmpty) return;
    _e2eFlowLog('MEDIA_ORPHAN_LIKELY', {'tempId': tempId});
  }

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

  /// Mark any message currently in "sending" state as failed — except a box
  /// send still waiting on the box: an account-socket error says nothing
  /// about it, and a retry started now would store a second copy.
  void markSendingMessagesFailed(String errorMsg) {
    final sending = _messages
        .where(
          (m) =>
              m.deliveryStatus == MessageDeliveryStatus.sending &&
              !_boxInFlight.contains(m.tempId),
        )
        .toList();
    if (sending.isEmpty) return;
    for (final msg in sending) {
      final tid = msg.tempId;
      if (tid != null) _emittedSendTempIds.remove(tid);
      final idx = _messages.indexWhere((m) => m.tempId == msg.tempId);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(
          deliveryStatus: MessageDeliveryStatus.failed,
        );
      }
    }
    notifyListeners();
  }

  bool _isKeyBundleOrTimeoutError(Object e) {
    final s = e.toString();
    return s.contains('key bundle') ||
        s.contains('no key bundle') ||
        s.contains('timed out') ||
        s.contains('Timeout') ||
        e is TimeoutException;
  }

  /// The recipient has no key bundle at an address we just encrypted for — as
  /// opposed to a timeout, which says nothing about WHICH devices exist.
  bool _isMissingKeyBundleError(Object e) =>
      e.toString().contains('no key bundle');

  /// Peer wedged after a phrase restore, 2026-09-22: the recipient restored
  /// its identity, the server moved its bundle to a NEW deviceId and revoked
  /// the old one, and this client re-encrypted to the dead address off its
  /// cached verified list every 4 s for over five minutes. Invalidating alone
  /// would not heal it — a null cache makes [_resolveFanOut] fall back to the
  /// legacy device 1, the same dead address — so the list is re-verified here,
  /// before the retry re-resolves it. `forceRefresh` rather than invalidate +
  /// fetch, so a failing round trip leaves the list we hold standing.
  void _refreshRecipientDeviceListAfterDeadAddress(int recipientId) {
    final enc = _encryptionProvider;
    if (enc == null || !_listRefreshLimiter.tryBegin(recipientId)) return;
    enc
        .getVerifiedDeviceList(recipientId, forceRefresh: true)
        .whenComplete(() => _listRefreshLimiter.end(recipientId))
        .ignore();
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

  /// User-friendly error when encrypt/send fails.
  String _userFriendlySendError(Object e, int recipientId) {
    final s = e.toString();
    if (s.contains('Recipient has no key bundle') ||
        s.contains('no key bundle')) {
      final conversations = _conversationsProvider?.conversations ?? [];
      final otherName = conversations
          .where(
            (c) =>
                conv_helpers.getOtherUserId(c, _currentUserId) == recipientId,
          )
          .map((c) => conv_helpers.getOtherUserUsername(c, _currentUserId))
          .firstOrNull;
      final who = otherName ?? 'Recipient';
      return 'Cannot send: $who does not have encryption keys yet. Ask them to open the app.';
    }
    // (lv) This is a SECURITY refusal, not a missing-keys problem, and it has a
    // specific remedy: the banner the refusal just raised opens the
    // out-of-band fingerprint comparison. The catch-all below told the user to
    // ask the recipient to open an app they already have open, which is why
    // this state read as an unexplained permanent outage.
    if (e is AccountIdentityMismatch ||
        s.contains('AccountIdentityMismatch')) {
      return 'Cannot send: this contact\'s security keys changed and could not '
          'be verified. Open the security warning for this chat and compare '
          'their safety number before sending.';
    }
    if (e is TimeoutException ||
        s.contains('timed out') ||
        s.contains('Timeout')) {
      return 'Timed out waiting for recipient keys. Try again.';
    }
    if (!(_encryptionProvider?.isE2EReady ?? false)) {
      return 'Encryption not ready. Wait a moment and try again.';
    }
    return 'Cannot send encrypted message. Recipient may not have encryption enabled – ask them to open the app.';
  }
}
