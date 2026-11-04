part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Decrypt-failure policy, the accept gate, the sender's device-list claim and
/// the persisted-plaintext record of a box message.
extension MessagingDecrypt on MessagingProvider {
  bool _isDuplicateDecryptError(Object e) =>
      e.toString().contains('DuplicateMessageException');

  // Bad Mac = message encrypted for a different/old session key.
  // Session itself is valid — treat as terminal like DuplicateMessageException.
  bool _isBadMacDecryptError(Object e) => e.toString().contains('Bad Mac');

  bool _isNoSessionDecryptError(Object e) =>
      e.toString().contains('NoSessionException');

  /// Classify a raw decrypt exception (string-matched). Precedence:
  /// duplicate → badMac → noSession → unknown. Identity-reset is orthogonal and
  /// applied by [decideDecryptionFailure], not here.
  DecryptionFailureKind _classifyDecryptError(Object e) {
    if (_isDuplicateDecryptError(e)) return DecryptionFailureKind.duplicate;
    if (_isBadMacDecryptError(e)) return DecryptionFailureKind.badMac;
    if (_isNoSessionDecryptError(e)) return DecryptionFailureKind.noSession;
    return DecryptionFailureKind.unknown;
  }

  /// Emit the same diagnostic the original if-chain did, per fired rule.
  void _logDecryptionFailure(
    DecryptionFailureRule rule,
    MessageModel msg,
    Object e,
  ) {
    switch (rule) {
      case DecryptionFailureRule.duplicate:
        // Ratchet already consumed this key (live-decrypted earlier); session valid.
        _e2eFlowLog('DECRYPT_DUPLICATE', {'msgId': msg.id});
        break;
      case DecryptionFailureRule.badMac:
        // MAC mismatch: encrypted for a different/old session key; session valid.
        _e2eFlowLog('DECRYPT_BAD_MAC', {'msgId': msg.id});
        break;
      case DecryptionFailureRule.identityReset:
        // Identity regenerated (reinstall / storage loss) — old messages unrecoverable.
        _e2eFlowLog('DECRYPT_IDENTITY_RESET', {'msgId': msg.id});
        break;
      case DecryptionFailureRule.noSession:
        _e2eFlowLog('DECRYPT_SKIP', {'msgId': msg.id, 'reason': e.toString()});
        break;
      case DecryptionFailureRule.unknown:
        debugPrint('[E2E] Decrypt failed for msg ${msg.id}: $e');
        _e2eFlowLog('DECRYPT_FAIL', {'msgId': msg.id, 'error': e.toString()});
        break;
    }
  }

  /// Is the device that PRODUCED this ciphertext still live in the sender's
  /// verified device list (spec §12 amendments (e)/(xxvii))?
  ///
  /// Fail-closed, but only on VERIFIED data, and never with a terminal verdict:
  /// a refused row is never stamped `[Decryption failed]`. Nothing failed
  /// here — we either refused a revoked sender or do not yet know.
  ///
  /// Never times a lookup of a list it holds: a box frame must not name the
  /// pair to the server at the moment it is read (E50f). A list held by NO
  /// verified copy is asked once; a failed lookup refuses device ≥ 2 and
  /// accepts device 1 (§5.5 refuses to revoke a primary at all).
  Future<bool> _originDeviceIsLive(MessageModel m) async {
    final enc = _encryptionProvider;
    if (enc == null) return false;
    final originDeviceId = m.originDeviceId ?? 1;
    final cached = enc.cachedDeviceList(m.senderId);
    if (cached != null) {
      if (cached.isLiveDevice(originDeviceId)) return true;
      _e2eFlowLog('DECRYPT_REFUSED_REVOKED_ORIGIN', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'listVersion': cached.version,
      });
      return false;
    }
    // No verified list held for this sender yet: one lookup rather than
    // deferring the row. A box peer's list is kept, so this runs only for a
    // list never kept (the first start after upgrading) or dropped since — a
    // named residual of E50f, since nothing re-offers a held box frame once
    // the connect refresh lands.
    try {
      final fetched = await enc.getVerifiedDeviceList(m.senderId);
      if (fetched.isLiveDevice(originDeviceId)) return true;
      _e2eFlowLog('DECRYPT_REFUSED_REVOKED_ORIGIN', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'listVersion': fetched.version,
      });
      return false;
    } catch (e) {
      // The lookup itself failed (timeout, no TOFU identity, bad chain — the
      // fail-closed contract of `getVerifiedDeviceList`). Device 1 keeps its
      // pre-multi-device behaviour and is read: refusing it would let one
      // broken lookup silence every chat of a single-device account.
      // `originDeviceId >= 2` exists only under multi-device, so a row we
      // cannot verify is withheld.
      if (originDeviceId == 1) {
        _e2eFlowLog('ACCEPT_GATE_LIST_UNAVAILABLE_DEVICE1', {
          'msgId': m.id,
          'senderId': m.senderId,
          'error': e.toString(),
        });
        return true;
      }
      _e2eFlowLog('DECRYPT_WITHHELD_NO_LIST', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'error': e.toString(),
      });
      return false;
    }
  }

  /// Reacts to the claim a box frame from [boxDevice] of [senderId] makes
  /// about the device lists it was addressed from (spec §12 (xv)/(xvi), E50f).
  ///
  /// Deliberately modest: a view of OUR list older than ours is answered with
  /// our list into that device's queue, and a durable diagnostic is kept when
  /// our OWN verified data confirms the sender is frozen. A claim by itself
  /// never changes trust, never blocks a send, never raises the identity
  /// surface (I7), and never times a lookup: a lookup timed by a box frame
  /// would name the pair; the sender's own announcements carry its list
  /// (decision 51).
  void _evaluateSenderListInfo(
    int senderId,
    Object? rawClaim, {
    required int boxDevice,
  }) {
    final enc = _encryptionProvider;
    final me = _currentUserId;
    if (enc == null || me == null || senderId == me) return;
    final claim = SenderListInfo.fromJson(rawClaim);
    if (claim == null) return;
    _answerStaleView(senderId, boxDevice, claim.peerVersion);

    final ourPeerView = enc.cachedDeviceList(senderId);
    final ourOwnView = enc.cachedDeviceList(me);
    final outcome = SenderListInfoChecker.evaluate(
      claim: claim,
      ourVersionOfPeer: ourPeerView?.version,
      ourHashOfPeer: ourPeerView?.listHash,
      ourOwnVersion: ourOwnView?.version,
      ourOwnHash: ourOwnView?.listHash,
    );

    switch (outcome) {
      case SenderListInfoOutcome.consistent:
      case SenderListInfoOutcome.ownDevicesSyncing:
        break;
      case SenderListInfoOutcome.refreshPeerList:
        _e2eFlowLog('SENDER_LIST_INFO_NEWER_ON_BOX', {
          'senderId': senderId,
          'claimedVersion': claim.ownVersion,
        });
      case SenderListInfoOutcome.peerListFrozen:
        // Our OWN verified data disagrees with what the sender claims about its
        // own list. That is a real inconsistency between two signed views — but
        // the claimed version and hash are peer-controlled and NOT DAK-signed,
        // so the durable record is DEDUPED per sender. The ring holds 80 entries
        // and evicts oldest-first, so recording one row per message would let a
        // peer forging a mismatch on every message evict every other piece of
        // forensic evidence (`CONTENT_KEY_LOST`, `OWN_IDENTITY_REPLACED`, …).
        // One surviving row per peer is all an operator needs; the flow log
        // (ring-only, not durable) keeps the per-message detail.
        E2ePersistentDiag.recordDeduped(
          'SENDER_LIST_INFO_FROZEN',
          {
            'senderId': senderId,
            'claimedVersion': claim.ownVersion,
            'ourVersion': ourPeerView?.version,
          },
          matchAll: ['senderId: $senderId,'],
        );
        _e2eFlowLog('SENDER_LIST_INFO_FROZEN', {
          'senderId': senderId,
          'claimedVersion': claim.ownVersion,
          'ourVersion': ourPeerView?.version,
        });
    }
  }

  /// [wireId] scoped to the account that sent it (PR2.1; see [WireKey]).
  /// [senderId] must be authenticated: our own account for our own sends, or
  /// the sender whose pairwise session decrypted the frame.
  WireKey? _wireKey(int senderId, String? wireId) =>
      wireId == null ? null : (senderId: senderId, wireId: wireId);

  /// [msg] carrying the decrypted [parsed] box envelope. Also evaluates the
  /// sender's `senderListInfo` claim (§5.2 layer 2): every decrypt path that
  /// reads an envelope must, or a stale-list signal is silently lost.
  ///
  /// An attachment is named by `boxMedia` alone (item 3 / media wiring,
  /// E17a) — its `box:<id>`, only with its key and IV, never an envelope
  /// `mediaUrl`. Without a usable id a media type keeps no url: today's
  /// broken-media bubble, never a dropped message.
  MessageModel _withEnvelope(MessageModel msg, E2eEnvelopeFields parsed) {
    // A bare claim NEVER alarms and NEVER changes trust (I7) — it can only
    // make us answer.
    _evaluateSenderListInfo(
      msg.senderId,
      parsed.senderListInfo,
      boxDevice: msg.originDeviceId ?? 1,
    );
    // SSRF: validate imageUrl before storing
    final safeImageUrl =
        parsed.linkPreviewImageUrl != null &&
            parsed.linkPreviewUrl != null &&
            LinkPreviewService.isSafeImageUrl(
              parsed.linkPreviewImageUrl,
              parsed.linkPreviewUrl,
            )
        ? parsed.linkPreviewImageUrl
        : null;
    return msg.copyWith(
      content: parsed.content,
      messageType: _parseMessageTypeString(parsed.messageType),
      mediaUrl: _boxMediaUrlOf(parsed),
      mediaDuration: parsed.mediaDuration,
      mediaKey: parsed.mediaKey,
      mediaIv: parsed.mediaIv,
      mediaWidth: parsed.mediaWidth,
      mediaHeight: parsed.mediaHeight,
      mediaThumbHash: parsed.mediaThumbHash,
      linkPreviewUrl: parsed.linkPreviewUrl,
      linkPreviewTitle: parsed.linkPreviewTitle,
      linkPreviewImageUrl: safeImageUrl,
      // The sender's wire id (PR2.1). A row that already has one keeps
      // it: an edit re-decrypts through here with a peer-built envelope.
      wireId: msg.wireId ?? parsed.msgId,
    );
  }

  String? _boxMediaUrlOf(E2eEnvelopeFields parsed) {
    final id = parsed.boxMedia;
    if (id == null || parsed.mediaKey == null || parsed.mediaIv == null) {
      return null;
    }
    final type = _parseMessageTypeString(parsed.messageType);
    if (type == null || type == MessageType.text || type == MessageType.ping) {
      return null;
    }
    return boxMediaUrl(id);
  }

  Future<void> _persistDecryptedContent(MessageModel decrypted) async {
    if (decrypted.content == kDecryptionFailedLabel ||
        decrypted.content == kEncryptionNotInitializedLabel) {
      return;
    }
    final hasText = decrypted.content.isNotEmpty;
    final hasMedia = decrypted.mediaUrl != null;
    if (!hasText && !hasMedia && decrypted.messageType == MessageType.text) {
      return;
    }
    // Validate linkPreviewImageUrl before persist (SSRF defense in depth)
    final safeImageUrl =
        decrypted.linkPreviewImageUrl != null &&
            decrypted.linkPreviewUrl != null &&
            LinkPreviewService.isSafeImageUrl(
              decrypted.linkPreviewImageUrl,
              decrypted.linkPreviewUrl,
            )
        ? decrypted.linkPreviewImageUrl
        : null;
    final ttl = decrypted.disappearAfterSeconds;
    final expiresAt = decrypted.expiresAt;
    final data = <String, dynamic>{
      'content': decrypted.content,
      // A box message has no server row to name its sender on the next
      // launch (decision 14): the record is the only place it survives.
      'senderId': decrypted.senderId,
      // Nor its quote (E18a).
      if (decrypted.replyTo != null) 'replyTo': decrypted.replyTo!.toJson(),
      // Nor its reactions: plain emoji, kept only here (item 4, E19d).
      if (decrypted.reactions.isNotEmpty) 'reactions': decrypted.reactions,
      // When its countdown started (decision 41): a restart restores the
      // deadline of a started one, and leaves an unstarted one to the
      // 1-day cap.
      if (ttl != null && expiresAt != null)
        _boxCountdownFromKey:
            expiresAt.toUtc().millisecondsSinceEpoch - ttl * 1000,
      // How far a peer's receipt moved OUR box message, and whether this
      // device reported a PEER's box message read (slice (g), E61d/E61f).
      if (decrypted.deliveryStatus == MessageDeliveryStatus.read ||
          (decrypted.senderId == _currentUserId &&
              decrypted.deliveryStatus == MessageDeliveryStatus.delivered))
        _boxTickKey: decrypted.deliveryStatus.name,
      if (decrypted.editedAt != null)
        'editedAt': decrypted.editedAt!.toIso8601String(),
      if (decrypted.messageType != MessageType.text)
        'messageType': decrypted.messageType.name.toUpperCase(),
      if (decrypted.mediaUrl != null) 'mediaUrl': decrypted.mediaUrl!,
      if (decrypted.mediaDuration != null)
        'mediaDuration': decrypted.mediaDuration!,
      if (decrypted.mediaKey != null) 'mediaKey': decrypted.mediaKey!,
      if (decrypted.mediaIv != null) 'mediaIv': decrypted.mediaIv!,
      if (decrypted.mediaWidth != null) 'mediaWidth': decrypted.mediaWidth!,
      if (decrypted.mediaHeight != null) 'mediaHeight': decrypted.mediaHeight!,
      if (decrypted.mediaThumbHash != null)
        'mediaThumbHash': decrypted.mediaThumbHash!,
      if (decrypted.linkPreviewUrl != null)
        'linkPreviewUrl': decrypted.linkPreviewUrl!,
      if (decrypted.linkPreviewTitle != null)
        'linkPreviewTitle': decrypted.linkPreviewTitle!,
    };
    if (safeImageUrl != null) {
      data['linkPreviewImageUrl'] = safeImageUrl;
    }
    try {
      await _encryptionProvider?.saveDecryptedContent(
        decrypted.id,
        data,
        conversationId: decrypted.conversationId,
        createdAt: decrypted.createdAt,
        expiresAt: _boxRecordExpiry(decrypted),
        disappearAfterSeconds: decrypted.disappearAfterSeconds,
        // A NEW pair is only ever stamped from an authenticated sender: a
        // wire id first reaches a row from an envelope that decrypted under
        // the pairwise session KEYED by `senderId`, or from our own minted
        // token. The store keeps an existing pair (first write wins) and
        // never lets a later write fill in a missing sender.
        wire: _wireKey(decrypted.senderId, decrypted.wireId),
      );
    } catch (_) {}
  }

  /// True when [msg] has displayable plaintext (or decrypted media), not an
  /// E2E placeholder.
  bool _hasUsableDecryptedContent(MessageModel msg) {
    if (msg.content == kDecryptionFailedLabel ||
        msg.content == kEncryptionNotInitializedLabel) {
      return false;
    }
    // Decrypted E2E media is usable once it has its one-shot keys + URL, even if
    // the text content is still the "[encrypted]" placeholder — voice/image rows
    // carry no text, so their decrypted content is legitimately empty.
    if (msg.mediaKey != null &&
        msg.mediaIv != null &&
        msg.mediaUrl != null &&
        msg.messageType != MessageType.text) {
      return true;
    }
    return msg.content != kEncryptedPlaceholderLabel &&
        !msg.displayAsEncryptedPlaceholder;
  }

  void _requestSessionRebuildForPeer(int peerId, {required String trigger}) {
    // A friendship made over the box (owner decision 52): the server does
    // not know the pair, and `requestSessionRebuild` would name it.
    if (_boxOnlyPeer(peerId)) {
      _e2eFlowLog('SESSION_RESET_SKIPPED', {
        'peerId': peerId,
        'trigger': trigger,
        'reason': 'boxOnly',
      });
      return;
    }
    // Once per peer until a decrypt from them succeeds: every emit forces the
    // peer to re-key on their next send (OTP burn; on pre-fix clients a
    // lossful local delete), so the old per-pass dedupe re-spammed it on
    // every reconnect/history pass — the SESSION_RESET{historyRetry} loop.
    if (!_rebuildRequestedPeers.add(peerId)) {
      _e2eFlowLog('SESSION_RESET_SKIPPED', {
        'peerId': peerId,
        'trigger': trigger,
        'reason': 'alreadyRequested',
      });
      return;
    }
    // NOTE: deliberately NO markSessionRebuild here. This request asks the
    // PEER to re-key; our own outbound session stays untouched — it either
    // still works, or the peer sends US sessionRebuildNeeded (the one
    // legitimate setter of the force-rebuild flag). The old mark made our
    // next send rebuild a perfectly valid session, and with the pre-fix
    // delete-on-rebuild that destroyed the archived ratchet states the
    // peer's in-flight messages needed (msg 8489 Bad-MAC class).
    _emit?.call('requestSessionRebuild', {'recipientId': peerId});
    E2ePersistentDiag.record('SESSION_RESET', {
      'peerId': peerId,
      'trigger': trigger,
    });
  }

  /// The peer side of a [DecryptionFailureDecision]: asks [senderId] to re-key
  /// on its next send when the decision says so. Shared by the box and the
  /// sibling decrypt paths so both heal a stale session the same way.
  void _askPeerToRekey(DecryptionFailureDecision decision, int senderId) {
    if (!decision.notifyPeerRebuild) return;
    if (decision.rule == DecryptionFailureRule.identityReset) {
      if (!_boxOnlyPeer(senderId) &&
          _identityResetRebuildNotified.add(senderId)) {
        // Identity reset: tell the peer to re-key on their next send. No
        // local state is touched (there is none to protect — the old
        // identity is gone); without this the peer keeps sending
        // undecryptable messages until we happen to reply.
        _emit?.call('requestSessionRebuild', {'recipientId': senderId});
        _e2eFlowLog('IDENTITY_RESET_REBUILD_REQUESTED', {'peerId': senderId});
      }
    } else if (decision.rule == DecryptionFailureRule.badMac) {
      // The failed row is unrecoverable, but a Bad MAC on a fresh type-2
      // message is evidence the peer is encrypting from a stale sender
      // ratchet. Ask them to build over their session on the next send.
      _requestSessionRebuildForPeer(senderId, trigger: 'badMac');
    }
  }

  /// Rebuild [msg] from a persisted plaintext [payload].
  ///
  /// The link-preview image is re-validated so a payload written by an older
  /// build cannot introduce an unsafe URL. Note this gates what the payload can
  /// ADD: `copyWith` is null-preserving, so a failed check falls back to
  /// `msg.linkPreviewImageUrl` rather than clearing it.
  MessageModel _restoreFromPersistedPayload(
    MessageModel msg,
    Map<String, dynamic> payload,
  ) {
    final content = payload['content'] as String? ?? '';
    final imageUrl = payload['linkPreviewImageUrl'] as String?;
    final pageUrl = payload['linkPreviewUrl'] as String?;
    final validImage =
        imageUrl != null &&
            pageUrl != null &&
            LinkPreviewService.isSafeImageUrl(imageUrl, pageUrl)
        ? imageUrl
        : null;
    final restoredType = _parseMessageTypeString(
      payload['messageType'] as String?,
    );
    final quote = payload['replyTo'];
    final editedAtRaw = payload['editedAt'];
    return msg.copyWith(
      // A PING carries no plaintext, so its persisted content is legitimately
      // empty. Falling back to msg.content ('[encrypted]') would keep
      // displayAsEncryptedPlaceholder true. Restore it as genuinely decrypted
      // (empty content).
      content: restoredType == MessageType.ping
          ? ''
          : (content.isNotEmpty ? content : msg.content),
      messageType: restoredType,
      mediaUrl: payload['mediaUrl'] as String?,
      mediaDuration: payload['mediaDuration'] as int?,
      mediaKey: payload['mediaKey'] as String?,
      mediaIv: payload['mediaIv'] as String?,
      mediaWidth: payload['mediaWidth'] as int?,
      mediaHeight: payload['mediaHeight'] as int?,
      mediaThumbHash: payload['mediaThumbHash'] as String?,
      linkPreviewUrl: payload['linkPreviewUrl'] as String?,
      linkPreviewTitle: payload['linkPreviewTitle'] as String?,
      linkPreviewImageUrl: validImage,
      wireId: payload[PlaintextRecordCodec.wireIdKey] as String?,
      replyTo: quote is Map<String, dynamic>
          ? ReplyToPreview.fromJson(quote)
          : null,
      reactions: _recordReactions(payload['reactions']),
      editedAt: editedAtRaw is String ? DateTime.tryParse(editedAtRaw) : null,
    );
  }

  /// A box record's reactions (item 4, E19d): emoji → user ids; anything
  /// else in the record is none.
  Map<String, List<int>>? _recordReactions(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    return {
      for (final MapEntry(:key, :value) in raw.entries)
        if (value is List && value.every((u) => u is int) && value.isNotEmpty)
          key: value.cast<int>(),
    };
  }
}
