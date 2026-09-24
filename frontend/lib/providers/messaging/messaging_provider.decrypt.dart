part of '../messaging_provider.dart';

// These extension methods live in MessagingProvider's own library and operate on
// its private state, so calling the ChangeNotifier's `notifyListeners()` here is
// legitimate; the analyzer's protected / visible-for-testing checks (which assume
// the call sits in a ChangeNotifier subclass body, not an extension) don't apply.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Decrypt, per-sender ordering, decrypt-retry, and decrypted-content persistence.
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

  /// Which device this session is, but ONLY once the server has confirmed it on
  /// `socketReady` (spec §12 amendment (xii)). Null while unconfirmed, which
  /// makes every device-scoped own-row decision fall back to "treat it as our
  /// own send" — the safe direction, since the alternative would decrypt a
  /// ciphertext this device produced and burn the only plaintext copy.
  int? get _confirmedOwnDeviceId {
    final enc = _encryptionProvider;
    if (enc == null || !enc.ownDeviceIdConfirmed) return null;
    return enc.ownDeviceId;
  }

  /// The master decrypt gate, device-scoped. Single source of truth for every
  /// decrypt entry point in this provider.
  bool _needsDecryption(MessageModel m) =>
      m.needsDecryption(_currentUserId, ownDeviceId: _confirmedOwnDeviceId);

  /// Our own row produced by ANOTHER of our devices (spec §12 amendment (xi)):
  /// decrypt it as ordinary inbound, and NEVER let it touch the pending-send
  /// record — that record belongs to a genuinely in-flight local send.
  bool _isSelfSyncRow(MessageModel m) =>
      m.isSelfSyncRow(_currentUserId, _confirmedOwnDeviceId);

  /// Is the device that PRODUCED this ciphertext still live in the sender's
  /// verified device list (spec §12 amendments (e)/(xxvii))?
  ///
  /// Fail-closed, but only on VERIFIED data, and never with a terminal verdict:
  /// whichever way this answers false, the row is recorded in
  /// [_acceptGateWithheldIds] so the post-retry sweep does not stamp
  /// `[Decryption failed]` over it and the recovery pass does not ask the peer
  /// to re-key a session that is perfectly healthy. Nothing failed here — we
  /// either refused a revoked sender or do not yet know.
  ///
  /// Own rows never reach here — the (xi) own-row branches run first — so this
  /// gates genuine inbound envelopes only.
  Future<bool> _originDeviceIsLive(MessageModel m) async {
    final enc = _encryptionProvider;
    if (enc == null) return false;
    final originDeviceId = m.originDeviceId ?? 1;
    final cached = enc.cachedDeviceList(m.senderId);
    if (cached != null) {
      var verified = cached;
      // Peer wedged after a phrase restore, 2026-09-22: the sender restored
      // its identity, the server moved its bundle to a NEW deviceId and
      // revoked the old one, and we sat on the pre-restore list — withholding
      // every row from the new device. The in-band `senderListInfo` that would
      // refresh the list rides INSIDE the plaintext of the very row we refuse,
      // so a cache HIT could never heal itself. ONE rate-limited re-verify
      // before the refusal, and only when the device is ABSENT: a list that
      // names it REVOKED is a verdict, not ignorance.
      if (!verified.devices.any((d) => d.deviceId == originDeviceId) &&
          _listRefreshLimiter.tryBegin(m.senderId)) {
        try {
          // forceRefresh, never invalidate-then-fetch: a FAILING refetch must
          // leave the verified list we already hold standing, or this refusal
          // would decay into the device-1 "list unavailable" acceptance below.
          verified = await enc.getVerifiedDeviceList(
            m.senderId,
            forceRefresh: true,
          );
        } on Object catch (_) {
          // Keep the cached verdict; the row stays retryable either way.
        } finally {
          _listRefreshLimiter.end(m.senderId);
        }
      }
      if (verified.isLiveDevice(originDeviceId)) {
        _acceptGateWithheldIds.remove(m.id);
        return true;
      }
      _acceptGateWithheldIds.add(m.id);
      _e2eFlowLog('DECRYPT_REFUSED_REVOKED_ORIGIN', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'listVersion': verified.version,
      });
      return false;
    }
    // No verified list held for this sender yet — the normal state after any
    // reload, since the cache is memory-only. AWAIT one round trip rather than
    // deferring the row: deferring would leave the first inbound message of
    // every session sitting at `[encrypted]` until something else happened to
    // re-trigger a decrypt pass.
    try {
      final fetched = await enc.getVerifiedDeviceList(m.senderId);
      if (fetched.isLiveDevice(originDeviceId)) {
        _acceptGateWithheldIds.remove(m.id);
        return true;
      }
      _acceptGateWithheldIds.add(m.id);
      _e2eFlowLog('DECRYPT_REFUSED_REVOKED_ORIGIN', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'listVersion': fetched.version,
      });
      return false;
    } catch (e) {
      // The fetch itself failed (timeout, no TOFU identity, bad chain — the
      // fail-closed contract of `getVerifiedDeviceList`). What that means here
      // depends on WHICH device claims to have sent the message:
      //
      //  * `originDeviceId >= 2` exists only under multi-device, so a row we
      //    cannot verify is withheld — that is the whole point of (e).
      //  * device 1 keeps its pre-T6 behaviour and decrypts. Refusing it would
      //    let one broken (or withheld) `getDeviceList` answer silence EVERY
      //    conversation of a single-device account, and it buys almost nothing:
      //    §5.5 refuses to revoke a primary at all, and the only path that
      //    revokes device 1 is the §6.2 reset — which also replaces the
      //    account identity, so that device's ciphertext no longer decrypts
      //    for anyone regardless of this check.
      if (originDeviceId == 1) {
        _acceptGateWithheldIds.remove(m.id);
        _e2eFlowLog('ACCEPT_GATE_LIST_UNAVAILABLE_DEVICE1', {
          'msgId': m.id,
          'senderId': m.senderId,
          'error': e.toString(),
        });
        return true;
      }
      _acceptGateWithheldIds.add(m.id);
      _e2eFlowLog('DECRYPT_WITHHELD_NO_LIST', {
        'msgId': m.id,
        'senderId': m.senderId,
        'originDeviceId': originDeviceId,
        'error': e.toString(),
      });
      return false;
    }
  }

  /// Reacts to a peer's in-band device-list claim (spec §12 (xv)/(xvi)).
  ///
  /// Everything here is deliberately modest: at most ONE rate-limited re-fetch,
  /// a calm "syncing" flag for our own skew, and a durable diagnostic when our
  /// OWN verified data confirms a peer is frozen. A claim by itself never
  /// changes trust, never blocks a send, and never raises the identity surface
  /// (I7) — an injected claim would otherwise be a remote off switch for this
  /// client's warnings, or a way to make us cry wolf until the user stops
  /// listening.
  void _evaluateSenderListInfo(int senderId, Object? rawClaim) {
    final enc = _encryptionProvider;
    final me = _currentUserId;
    if (enc == null || me == null || senderId == me) return;
    final claim = SenderListInfo.fromJson(rawClaim);
    if (claim == null) return;

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
        _setDevicesSyncing(false);
      case SenderListInfoOutcome.ownDevicesSyncing:
        // Benign: our own devices have not converged yet. The calm state is
        // raised only while we are actually DOING something about it — the peer
        // controls the claimed version, so raising it on every message would let
        // it pin "syncing devices…" on forever as a nuisance. Bounded by the
        // same limiter as the fetch: one window per cooldown, cleared as soon as
        // our own list comes back.
        if (_listRefreshLimiter.tryBegin(me)) {
          _setDevicesSyncing(true);
          enc.invalidateDeviceList(me);
          enc
              .getVerifiedDeviceList(me)
              .onError((_, _) => const VerifiedDeviceList.notEnrolled())
              .whenComplete(() {
                _setDevicesSyncing(false);
                _listRefreshLimiter.end(me);
              });
        }
      case SenderListInfoOutcome.refreshPeerList:
        // The peer claims a newer list than we hold — the common, legitimate
        // case (it linked a device). ONE re-fetch, then the claim is discarded;
        // a parallel re-fetch would let a stale answer overwrite a fresh one.
        if (_listRefreshLimiter.tryBegin(senderId)) {
          enc.invalidateDeviceList(senderId);
          enc
              .getVerifiedDeviceList(senderId)
              .onError((_, _) => const VerifiedDeviceList.notEnrolled())
              .whenComplete(() => _listRefreshLimiter.end(senderId));
        }
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

  void _setDevicesSyncing(bool value) {
    if (_devicesSyncing == value) return;
    _devicesSyncing = value;
    notifyListeners();
  }

  /// True for a row that still NEEDS a decrypt pass: shows the "[encrypted]"
  /// placeholder AND has no usable decrypted content. The second check is
  /// load-bearing: restored keyed-media rows (voice/image) legitimately keep
  /// `content == '[encrypted]'` forever — their decrypted payload is the
  /// mediaKey/mediaIv, not text — so placeholder-only predicates counted every
  /// received media message as "still undecrypted" and re-armed the
  /// session-reset machinery on every history pass (the 2026-06-12
  /// SESSION_RESET{historyRetry} loop).
  bool _isUnresolvedEncryptedInbound(MessageModel m) =>
      !_isRetiredMessage(m) &&
      // A row the accept gate withheld is not "unresolved" in the sense this
      // predicate means: asking the peer to re-key would not change the answer,
      // because the refusal is about WHICH DEVICE sent it (amendment (e)).
      !_acceptGateWithheldIds.contains(m.id) &&
      _needsDecryption(m) &&
      m.displayAsEncryptedPlaceholder &&
      !_hasUsableDecryptedContent(m);

  /// A retired id has had its only plaintext copy deliberately destroyed.
  /// Its ciphertext remains on the server, but its ratchet key was consumed at
  /// first decrypt, so it must never re-enter any decrypt or retry path.
  bool _isRetiredMessage(MessageModel msg) =>
      msg.content == kRetiredMessageLabel ||
      (_encryptionProvider?.isRetired(msg.id) ?? false);

  bool _markMessageAsRetired(MessageModel msg) {
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    if (idx == -1 || _messages[idx].content == kRetiredMessageLabel) {
      return false;
    }
    _messages[idx] = _messages[idx].copyWith(content: kRetiredMessageLabel);
    return true;
  }

  MessageModel _retiredMessagePlaceholder(MessageModel msg) =>
      msg.content == kRetiredMessageLabel
      ? msg
      : msg.copyWith(content: kRetiredMessageLabel);

  /// Stamp the honest "sent before this device was linked" placeholder on a row
  /// the server marked `none_for_device` (spec §12 amendment (viii)).
  ///
  /// Deliberately NOT `[Decryption failed]`: nothing failed. The row simply
  /// predates this device, and Matrix's `UtdCause::SentBeforeWeJoined` draws
  /// the same distinction for the same reason.
  bool _markMessageNotLinkedYet(MessageModel msg) {
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    if (idx == -1 || _messages[idx].content == kNotLinkedYetMessageLabel) {
      return false;
    }
    _messages[idx] = _messages[idx].copyWith(
      content: kNotLinkedYetMessageLabel,
    );
    return true;
  }

  /// Whether [messages] hides [msg] as predating this device.
  ///
  /// (lxxxi): the server marked it `none_for_device` — it predates the link.
  /// (lxxxvi): it is UNREADABLE and the server stamped it before [since], the
  /// instant this install's identity became the account's — it was sealed to
  /// an identity this install does not hold, so no pass will ever open it.
  /// A readable row is never hidden, whatever its age: plaintext restored from
  /// a history file, or decrypted under an earlier device id, still renders.
  bool _predatesThisDevice(MessageModel msg, DateTime? since) {
    if (msg.content == kNotLinkedYetMessageLabel) return true;
    if (since == null || !msg.createdAt.isBefore(since)) return false;
    return msg.content == kDecryptionFailedLabel ||
        (msg.content == kEncryptedPlaceholderLabel &&
            !_hasUsableDecryptedContent(msg));
  }

  bool _conversationHasUndecryptedInbound(int conversationId) {
    return _messages.any(
      (m) =>
          m.conversationId == conversationId &&
          _isUnresolvedEncryptedInbound(m),
    );
  }

  /// Re-run ordered history decrypt for the open chat (after E2E init or session mismatch).
  Future<void> retryDecryptActiveConversation() async {
    final convId = _effectiveActiveConversationId;
    if (convId == null) return;
    if (!(_encryptionProvider?.isE2EReady ?? false)) {
      return;
    }
    if (!_conversationHasUndecryptedInbound(convId)) {
      return;
    }
    _decryptHistoryGeneration++;
    final generation = _decryptHistoryGeneration;
    _decryptingHistory = true;
    // try/finally, matching the .whenComplete() the two getMessages call sites
    // use. _decryptMessageHistory can throw before its internal guards take
    // over (_waitForE2EReady, the prefetch), and without this the flag would
    // stay true for the rest of the session — which now means every text row
    // renders a "Decrypting…" that never resolves.
    try {
      await _decryptMessageHistory(generation);
    } finally {
      _finishHistoryDecryptPass(
        generation,
        conversationId: convId,
        updateCache: true,
      );
    }
  }

  /// [wireId] scoped to the account that sent it (PR2.1; see [WireKey]).
  /// [senderId] must be authenticated, never a bare server field: our own
  /// account for our own sends, or the sender whose pairwise session
  /// decrypted the row.
  WireKey? _wireKey(int senderId, String? wireId) =>
      wireId == null ? null : (senderId: senderId, wireId: wireId);

  /// [msg] carrying the decrypted [parsed] envelope. Also evaluates the
  /// sender's `senderListInfo` claim (§5.2 layer 2): every decrypt path that
  /// reads an envelope must, or a stale-list signal is silently lost.
  MessageModel _withEnvelope(MessageModel msg, E2eEnvelopeFields parsed) {
    // §5.2 layer 2 (amendment (xv)/(xvi)): the sender told us which
    // device-list versions it addressed this message from. Evaluate it
    // against DAK-verified data we already hold. A bare claim NEVER alarms
    // and NEVER changes trust (I7) — it can only make us re-check.
    _evaluateSenderListInfo(msg.senderId, parsed.senderListInfo);
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
      mediaUrl: parsed.mediaUrl,
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

  Future<void> _persistDecryptedContent(MessageModel decrypted) async {
    if (decrypted.content == kDecryptionFailedLabel ||
        decrypted.content == '[Encryption not initialized]' ||
        decrypted.content == kRetiredMessageLabel) {
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
    final data = <String, dynamic>{
      'content': decrypted.content,
      // A box message has no server row to name its sender on the next
      // launch (decision 14): the record is the only place it survives.
      if (!isServerMessageId(decrypted.id)) 'senderId': decrypted.senderId,
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
        expiresAt: decrypted.expiresAt,
        disappearAfterSeconds: decrypted.disappearAfterSeconds,
        // A NEW pair is only ever stamped from an authenticated sender: a
        // wire id first reaches a row from an envelope that decrypted under
        // the pairwise session KEYED by `senderId` (a relabelled row fails
        // decrypt), or from our own minted token. A row RESTORED from disk
        // carries its stored `_wid` beside the server row's `senderId`, which
        // is safe only because the store keeps an existing pair (first write
        // wins) and never lets a later write fill in a missing sender.
        wire: _wireKey(decrypted.senderId, decrypted.wireId),
      );
    } catch (_) {}
  }

  /// True when [msg] has displayable plaintext (or decrypted media), not an E2E placeholder.
  ///
  /// The `none_for_device` sentinel is a placeholder too (amendment (lxvi)
  /// clause 2): counting it as usable let the snapshot hydration skip the
  /// persisted copy, so a re-linked install showed "sent before this device
  /// was linked" over rows it had already decrypted under its previous id.
  bool _hasUsableDecryptedContent(MessageModel msg) {
    if (_isRetiredMessage(msg) ||
        msg.content == kDecryptionFailedLabel ||
        msg.content == kNotLinkedYetMessageLabel ||
        msg.content == '[Encryption not initialized]') {
      return false;
    }
    if (_missingEncryptedMediaKeys(msg)) {
      return false;
    }
    // Decrypted E2E media is usable once it has its one-shot keys + URL, even if
    // the text content is still the "[encrypted]" placeholder — voice/image rows
    // carry no text, so their decrypted content is legitimately empty. Without
    // this, restore-on-reopen treats a keyed media row as an undecrypted
    // placeholder and pointlessly re-decrypts it → DuplicateMessage →
    // "[Decryption failed]" in memory (the keys are safe in storage but unused),
    // so received voice/image fails to replay after reopening the chat.
    if (msg.mediaKey != null &&
        msg.mediaIv != null &&
        msg.mediaUrl != null &&
        msg.messageType != MessageType.text) {
      return true;
    }
    if (!_needsDecryption(msg)) {
      if (msg.content == kEncryptedPlaceholderLabel ||
          msg.displayAsEncryptedPlaceholder) {
        return false;
      }
      return true;
    }
    if (msg.displayAsEncryptedPlaceholder) return false;
    return msg.content.isNotEmpty ||
        msg.mediaUrl != null ||
        msg.messageType != MessageType.text;
  }

  /// True when [serverEditedAt] is newer than the [cachedEditedAt] a stored
  /// plaintext was decrypted at — i.e. an edit landed and the cache is stale, so
  /// the new ciphertext must be re-decrypted instead of served from cache.
  bool _isEditStale(DateTime? serverEditedAt, DateTime? cachedEditedAt) {
    if (serverEditedAt == null) return false;
    if (cachedEditedAt == null) return true;
    return serverEditedAt.isAfter(cachedEditedAt);
  }

  /// Ciphertext type prefix ("{type}:{base64}"): 3 = PreKey, 2 = Signal
  /// (CiphertextMessage.prekeyType / whisperType in libsignal_protocol_dart).
  /// Diagnostic only — null when the prefix is absent/unparseable.
  int? _ciphertextType(String? ciphertext) {
    if (ciphertext == null) return null;
    final colonIdx = ciphertext.indexOf(':');
    if (colonIdx <= 0) return null;
    return int.tryParse(ciphertext.substring(0, colonIdx));
  }

  void _requestSessionRebuildForPeer(int peerId, {required String trigger}) {
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
  /// on its next send when the decision says so. Shared by the server-row and
  /// the box decrypt paths so both heal a stale session the same way.
  void _askPeerToRekey(DecryptionFailureDecision decision, int senderId) {
    if (!decision.notifyPeerRebuild) return;
    if (decision.rule == DecryptionFailureRule.identityReset) {
      if (_identityResetRebuildNotified.add(senderId)) {
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

  /// Drop peers whose inbound rows are all resolved or terminal — nothing a
  /// session rebuild could still recover. Without this, one live decrypt
  /// failure keeps the peer armed for the whole app session, and every later
  /// history pass re-fires the reset machinery (the Bad-MAC → reset loop).
  void _pruneLiveDecryptFailedPeers() {
    if (_liveDecryptFailedPeers.isEmpty) return;
    _liveDecryptFailedPeers.removeWhere((peerId) {
      final hasRecoverable = _messages.any(
        (m) => m.senderId == peerId && _isUnresolvedEncryptedInbound(m),
      );
      if (!hasRecoverable) {
        _e2eFlowLog('LIVE_RETRY_PRUNED', {'peerId': peerId});
      }
      return !hasRecoverable;
    });
  }

  /// Rebuild [msg] from a persisted plaintext [payload].
  ///
  /// The link-preview image is re-validated so a payload written by an older
  /// build cannot introduce an unsafe URL. Note this gates what the payload can
  /// ADD: `copyWith` is null-preserving, so a failed check falls back to
  /// `msg.linkPreviewImageUrl` rather than clearing it — harmless because the
  /// backend never populates linkPreview* for a row carrying encryptedContent.
  MessageModel _restoreFromPersistedPayload(
    MessageModel msg,
    Map<String, dynamic> payload,
  ) {
    // SELF-HEAL the record's expiry stamp. This mapper is the one place every
    // served row meets its persisted record (fast hydrate, main pass, ledger
    // gate), so it is where a stamp lost in flight gets repaired. The
    // `messageDelivered` stamp travels on a single unacked socket event and
    // can race the persist or miss the socket window; an unstamped record no
    // longer expires locally (see EncryptionService._recordExpiryDeadlineMs),
    // so without this repair its plaintext would sit until reconciliation.
    // Gated on the payload's stored stamp so the common already-stamped row
    // costs one map lookup, not an authoritative storage read. Ordering note:
    // the sweep may run BEFORE any history pass — the heal is the recovery
    // layer, the sweep-side stamp requirement is the guarantee.
    final rowExpiry = msg.expiresAt;
    if (rowExpiry != null) {
      final stamped = payload[PlaintextRecordCodec.expiresAtKey];
      final rowExpiryMs = rowExpiry.toUtc().millisecondsSinceEpoch;
      if (stamped != rowExpiryMs) {
        unawaited(
          _encryptionProvider?.stampRecordExpiry(msg.id, rowExpiry) ??
              Future.value(),
        );
      }
    }
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
    return msg.copyWith(
      // A PING carries no plaintext, so its persisted content is legitimately
      // empty. Falling back to msg.content ('[encrypted]') would keep
      // displayAsEncryptedPlaceholder true and force a redundant live
      // re-decrypt on every chat entry, re-firing the ping sound/effect
      // forever (Bug 3). Restore it as genuinely decrypted (empty content) so
      // it is consumed exactly once.
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
    );
  }

  /// Fill a freshly parsed server snapshot with plaintext we already hold,
  /// BEFORE it is merged into [_messages] and painted.
  ///
  /// The server ships `content: "[encrypted]"` for every E2E row, so without
  /// this the first frame of a cold chat entry paints placeholders and the
  /// list only flips once the async decrypt pass finishes — the visible
  /// "[encrypted] for a fraction of a second" flash. Operates on the caller's
  /// local list before any shared state is touched, so the merge + notify that
  /// follow stay atomic exactly as before.
  ///
  /// Upgrade-only: a row is replaced solely when the restored version has
  /// usable plaintext, so this can never downgrade a row to a placeholder.
  /// It performs NO Signal work — purely RAM cache plus one batched read of
  /// plaintext this account already decrypted.
  ///
  /// Returns null when everything resolved synchronously (no provider, no rows,
  /// or the RAM cache covered them all), so the caller keeps its fully
  /// synchronous, atomic merge+notify. Only a genuine cold entry that has to
  /// touch storage introduces a suspension point.
  Future<void>? _hydrateSnapshotFromCaches(List<MessageModel> rows) {
    final provider = _encryptionProvider;
    if (provider == null || rows.isEmpty) return null;

    // Pass 1: RAM cache, free and synchronous — INBOUND rows only.
    //
    // Own rows are deliberately excluded. They come back from the server as
    // "[encrypted]" too, but the history pass's own-message branch is also the
    // lost-ack reconcile: when nothing is persisted under the real id it
    // recovers plaintext from the durable pending-send record, writes it under
    // the real id, verifies the read-back and only then consumes the record.
    // Satisfying such a row from RAM would flip it to plaintext, the branch
    // condition would no longer match, and that durable persist would silently
    // never happen. The disk pass below still hydrates own rows, which is safe
    // precisely because a persisted entry means the reconcile had nothing left
    // to do.
    final needDisk = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (_isRetiredMessage(row)) {
        rows[i] = _retiredMessagePlaceholder(row);
        continue;
      }
      if (_hasUsableDecryptedContent(row)) continue;
      if (_needsDecryption(row)) {
        final cached = provider.getCachedDecryption(row.id);
        if (cached != null &&
            _hasUsableDecryptedContent(cached) &&
            !_isEditStale(row.editedAt, cached.editedAt)) {
          rows[i] = _mergeMessagePreferNewer(row, cached);
          continue;
        }
      }
      needDisk.add(row.id);
    }
    if (needDisk.isEmpty) return null;
    return _hydrateSnapshotFromStorage(rows, needDisk, provider);
  }

  /// Pass 2 of [_hydrateSnapshotFromCaches]: ONE batched persisted read for
  /// every row the RAM cache could not resolve.
  ///
  /// A miss is not authoritative (see
  /// [EncryptionService.getDecryptedContentMany]) — it just means the decrypt
  /// pass resolves that row the slow way, as it always did. Nothing is
  /// downgraded on a miss.
  Future<void> _hydrateSnapshotFromStorage(
    List<MessageModel> rows,
    List<int> ids,
    EncryptionProvider provider,
  ) async {
    final persisted = await provider.getDecryptedContentMany(ids);
    if (persisted.isEmpty) return;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final payload = persisted[row.id];
      if (payload == null) continue;
      final content = payload['content'] as String? ?? '';
      if (content == kDecryptionFailedLabel) continue;
      final hasPayload =
          content.isNotEmpty ||
          payload['mediaUrl'] != null ||
          payload['messageType'] != null;
      if (!hasPayload) continue;
      final editedAt = payload['editedAt'] != null
          ? DateTime.tryParse(payload['editedAt'] as String)
          : null;
      if (_isEditStale(row.editedAt, editedAt)) continue;
      final restored = _restoreFromPersistedPayload(row, payload);
      if (!_hasUsableDecryptedContent(restored)) continue;
      rows[i] = restored;
      provider.cacheDecryption(row.id, restored);
    }
  }

  /// One batched, cross-engine-coherent snapshot of the persisted plaintext for
  /// every row a history pass could consult.
  ///
  /// Deliberately prefetches EVERY id in [rows] rather than re-deriving the
  /// loop's branch conditions: after the single reload each extra id is one
  /// synchronous map lookup, and a second copy of the predicate would rot out
  /// of sync with the loop and silently strand rows on "[encrypted]".
  Future<Map<int, Map<String, dynamic>>> _prefetchPersistedPlaintext(
    List<MessageModel> rows,
  ) async {
    final provider = _encryptionProvider;
    if (provider == null || rows.isEmpty) {
      return const <int, Map<String, dynamic>>{};
    }
    return provider.getDecryptedContentMany(rows.map((m) => m.id));
  }

  /// Persisted plaintext for [id]: the batched snapshot when it has the row,
  /// otherwise the authoritative single read.
  ///
  /// A batch miss is NOT "no plaintext" — the batch covers the SharedPreferences
  /// namespace only, so an absent id still has to consult
  /// [EncryptionProvider.getDecryptedContent] (which also serves the mobile
  /// legacy store). Misses are the rows that were about to be live-decrypted
  /// anyway, so the fall-through does not reintroduce the per-row cost on the
  /// common path.
  Future<Map<String, dynamic>?> _persistedPlaintextFor(
    int id,
    Map<int, Map<String, dynamic>> batch,
  ) async {
    final hit = batch[id];
    if (hit != null) return hit;
    return _encryptionProvider?.getDecryptedContent(id);
  }

  Future<void> _decryptMessageHistory(int generation) async {
    _historyDecryptFailedPeers = <int>{};
    _historySessionRebuildRequested = <int>{};
    await _waitForE2EReady(maxAttempts: 100);
    if (!(_encryptionProvider?.isE2EReady ?? false)) {
      _e2eFlowLog('HISTORY_DECRYPT_SKIP_E2E_NOT_READY', {});
      return;
    }
    final toDecrypt = _messages
        .where((m) => _needsDecryption(m) && !_isRetiredMessage(m))
        .length;
    if (toDecrypt > 0) {
      _e2eFlowLog('HISTORY_DECRYPT_START', {'count': toDecrypt});
    }
    // Double Ratchet requires decrypting in chronological order (oldest first).
    final sorted = List<MessageModel>.from(_messages)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    // ONE cross-engine coherence read for the whole pass instead of one per
    // row. Before this, every row awaited getDecryptedContent, and each of
    // those did a full SharedPreferences.reload() on web — a complete
    // localStorage enumeration + JSON decode of every cached record (capped at
    // 2000). Entering a chat therefore cost O(rows x cached records) of
    // blocking main-thread work (measured: ~65 ms for one 50-row page at the
    // cap on desktop, several times that on a phone) and the list stayed on
    // "[encrypted]" placeholders for the whole pass. See the safety note on
    // EncryptionService.getDecryptedContentMany: the reload is NOT dropped,
    // it is hoisted, and the raw replay cache still covers writes that land
    // mid-pass.
    final persistedById = await _prefetchPersistedPlaintext(sorted);
    if (_decryptHistoryGeneration != generation) return;
    bool changed = false;
    // NOTE: do NOT "reveal progressively" here. The pass MUST run oldest-first
    // (Double Ratchet ordering, see the sort above) while the list is
    // reverse:true and shows the NEWEST rows. Notifying mid-pass therefore
    // resolves off-screen rows first and leaves the visible ones on
    // "[encrypted]" until last — pure rebuild churn for no perceived gain.
    // The cost that makes a first entry visible is the per-row storage work
    // below, not the notify cadence.
    for (var i = 0; i < sorted.length; i++) {
      if (_decryptHistoryGeneration != generation) break;
      final msg = sorted[i];
      if (_isRetiredMessage(msg)) {
        if (_markMessageAsRetired(msg)) changed = true;
        continue;
      }
      if (_needsDecryption(msg)) {
        // Cache-first: only skip live decrypt when cache holds real plaintext.
        final cached = _encryptionProvider?.getCachedDecryption(msg.id);
        if (cached != null) {
          if (cached.content == kDecryptionFailedLabel) {
            // Terminal failure cached — restore and skip without live decrypt.
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1 &&
                _messages[idx].content != kDecryptionFailedLabel) {
              _messages[idx] = _messages[idx].copyWith(
                content: kDecryptionFailedLabel,
              );
              changed = true;
            }
            continue;
          }
          if (_hasUsableDecryptedContent(cached) &&
              !_isEditStale(msg.editedAt, cached.editedAt)) {
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1) {
              // `_mergeMessagePreferNewer` returns `server.copyWith(...)`, so
              // the RAM decryption cache's OWN reactions map wins — and that
              // copy was cached when this device could not yet name the
              // tokens. Without re-resolving, this pass silently reverts an
              // already-named chip to the unreadable placeholder, which is why
              // inbound rows stayed placeholders after a relaunch while the
              // sender's own rows resolved.
              final merged = _withRenderableReactions(
                _mergeMessagePreferNewer(_messages[idx], cached),
              );
              _messages[idx] = merged;
              _encryptionProvider?.cacheDecryption(msg.id, merged);
              changed = true;
            }
            continue;
          }
        }
        // Batched snapshot from the head of the pass; a miss still consults
        // the authoritative single read.
        final persisted = await _persistedPlaintextFor(msg.id, persistedById);
        final pContent = persisted?['content'] as String? ?? '';
        final persistedEditedAt = persisted?['editedAt'] != null
            ? DateTime.tryParse(persisted!['editedAt'] as String)
            : null;
        final hasPersistedPayload =
            persisted != null &&
            (pContent.isNotEmpty ||
                persisted['mediaUrl'] != null ||
                persisted['messageType'] != null);
        if (hasPersistedPayload &&
            !_isEditStale(msg.editedAt, persistedEditedAt)) {
          if (pContent == kDecryptionFailedLabel) {
            // Terminal failure persisted — restore and skip without live decrypt.
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1 &&
                _messages[idx].content != kDecryptionFailedLabel) {
              _messages[idx] = _messages[idx].copyWith(
                content: kDecryptionFailedLabel,
              );
              changed = true;
            }
            continue;
          }
          final restored = _restoreFromPersistedPayload(msg, persisted);
          final idx = _messages.indexWhere((m) => m.id == msg.id);
          final merged = idx != -1
              ? _mergeMessagePreferNewer(_messages[idx], restored)
              : restored;
          if (_hasUsableDecryptedContent(merged)) {
            _encryptionProvider?.cacheDecryption(msg.id, merged);
            if (idx != -1) {
              _messages[idx] = merged;
              changed = true;
            }
            // Pending-ping resurrection (Bug 3, "arrived while away" case):
            // if the live decrypt ran in a PREVIOUS process (backgrounded
            // arrival, then OS kill before the chat was opened), the transient
            // _showPingEffect died with that process while the persisted
            // record suppresses any re-decrypt here. The durable consume
            // record is the READ mark: markConversationRead is emitted AFTER
            // this history payload was built (history.dart onMessageHistory),
            // so a never-seen ping still arrives un-READ. Fire once per id;
            // the read-mark that follows keeps every later entry, restart,
            // and resync silent.
            if (merged.messageType == MessageType.ping &&
                merged.senderId != _currentUserId &&
                merged.deliveryStatus != MessageDeliveryStatus.read &&
                _pingEffectFiredIds.add(merged.id)) {
              _showPingEffect = true;
            }
            continue;
          }
          // Stale persisted row (mediaUrl without keys) — fall through to live decrypt.
        }
        final idx = _messages.indexWhere((m) => m.id == msg.id);
        final rowForDecrypt = idx != -1 ? _messages[idx] : msg;
        if (_isRetiredMessage(rowForDecrypt)) {
          if (_markMessageAsRetired(rowForDecrypt)) changed = true;
          continue;
        }
        // The server said this device has no ciphertext for this row by design
        // (spec §12 amendment (viii)): it predates this device's link. There is
        // nothing to decrypt, so it must never enter the pass and degrade into
        // `[Decryption failed]` — it renders an honest placeholder instead. Not
        // a destruction trigger either (I8, falsification 13).
        if (rowForDecrypt.envelopeStatus == 'none_for_device') {
          if (_markMessageNotLinkedYet(rowForDecrypt)) changed = true;
          continue;
        }
        if (_hasUsableDecryptedContent(rowForDecrypt)) {
          _encryptionProvider?.cacheDecryption(msg.id, rowForDecrypt);
          continue;
        }
        // [Decryption failed] is a terminal state from a prior retry — skipping
        // prevents re-triggering deleteSessionWithPeer on every reconnect, which
        // would cascade to break decryption of all subsequent messages from this peer.
        if (rowForDecrypt.content == kDecryptionFailedLabel) continue;
        // No cache — live decrypt (advances session ratchet)
        final decrypted = await _decryptMessageAsyncQueued(rowForDecrypt);
        if (idx != -1) {
          _messages[idx] = _mergeMessagePreferNewer(_messages[idx], decrypted);
          _encryptionProvider?.cacheDecryption(msg.id, _messages[idx]);
          changed = true;
        }
      } else if (msg.senderId == _currentUserId &&
          // Origin-scoped (amendment (xi)): only the device that SENT the row
          // holds its plaintext locally, so only that device restores from the
          // local store. A self-sync copy took the decrypt branch above.
          !_isSelfSyncRow(msg) &&
          (msg.content == kEncryptedPlaceholderLabel ||
              _missingEncryptedMediaKeys(msg))) {
        // Own-message branch, same batched snapshot + fall-through.
        final stored = await _persistedPlaintextFor(msg.id, persistedById);
        final storedContent = stored?['content'] as String? ?? '';
        if (storedContent.isNotEmpty ||
            (stored?['messageType'] as String?) != null ||
            stored?['mediaUrl'] != null) {
          // Restore all fields from persisted cache (SSRF validated)
          final rawImageUrl = stored?['linkPreviewImageUrl'] as String?;
          final rawPageUrl = stored?['linkPreviewUrl'] as String?;
          final safeImageUrl =
              rawImageUrl != null &&
                  rawPageUrl != null &&
                  LinkPreviewService.isSafeImageUrl(rawImageUrl, rawPageUrl)
              ? rawImageUrl
              : null;
          final restoredType = _parseMessageTypeString(
            stored?['messageType'] as String?,
          );
          final restored = msg.copyWith(
            content: storedContent.isNotEmpty ? storedContent : null,
            messageType: restoredType,
            mediaUrl: stored?['mediaUrl'] as String?,
            mediaDuration: stored?['mediaDuration'] as int?,
            mediaKey: stored?['mediaKey'] as String?,
            mediaIv: stored?['mediaIv'] as String?,
            mediaWidth: stored?['mediaWidth'] as int?,
            mediaHeight: stored?['mediaHeight'] as int?,
            mediaThumbHash: stored?['mediaThumbHash'] as String?,
            linkPreviewUrl: stored?['linkPreviewUrl'] as String?,
            linkPreviewTitle: stored?['linkPreviewTitle'] as String?,
            linkPreviewImageUrl: safeImageUrl,
            wireId: stored?[PlaintextRecordCodec.wireIdKey] as String?,
          );
          final idx = _messages.indexWhere((m) => m.id == msg.id);
          if (idx != -1) {
            final merged = _mergeMessagePreferNewer(_messages[idx], restored);
            _messages[idx] = merged;
            _encryptionProvider?.cacheDecryption(msg.id, merged);
            changed = true;
          }
        } else {
          // Lost-ack reconcile: the `messageSent` ack died with a socket drop,
          // so this own row arrived as '[encrypted]' with nothing persisted
          // under its real id.
          //
          // The key MUST mirror what the send path saved the record under
          // (`messaging_provider.send.dart`): a legacy send stores it under the
          // exact ciphertext, a fan-out under the send token. So try the
          // ciphertext FIRST — a legacy row always has one, and it also carries
          // an echoed `sendToken` (the server persists the token for its own
          // idempotency and returns it to the origin device), so preferring the
          // token here would look up a key the record was never saved under and
          // strand the plaintext. That plaintext is the ONLY copy: a Signal
          // sender cannot decrypt its own ciphertext (`frontend/CLAUDE.md` §5).
          //
          // A NEW-MODEL row has a NULL ciphertext for its origin device
          // (`envelopeStatus: own_origin`), so it falls through to the token —
          // which is exactly the case amendment (ix) added the token for.
          //
          // A miss means stay '[encrypted]', never a heuristic guess (the 07-08
          // field case msg 14667, docs/runbooks/e2e-decryption-failed.md).
          //
          // ORIGIN-SCOPED, asserted not assumed (spec §12 amendment (xiv)): only
          // the device that SENT the row may consume its pending record. A
          // self-sync copy from another of our devices reaches here with a real
          // ciphertext that is meaningless as a record key, and a lookup under it
          // could only ever collide with a genuinely in-flight local send. Today
          // the server withholds the `sendToken` from every non-origin device,
          // which makes such a collision unreachable — this check is what keeps
          // it unreachable if that ever changes.
          //
          // The same rule has to hold in the window BEFORE `socketReady`
          // confirms which device we are (amendment (xii)), where
          // `_isSelfSyncRow` cannot answer yet. Three cases, and only one of
          // them defers:
          //  * `own_origin` — the SERVER already compared the origin to this
          //    session's device and says we sent it (branch 1 of (xi)); no
          //    local device id is needed, and this is the row whose only key
          //    IS the token, so it must reconcile immediately;
          //  * NULL `originDeviceId` — pre-migration or legacy-client, device 1
          //    by definition. Every production send is this shape until
          //    enrollment ships, so deferring it would strand real plaintext
          //    against a server that never echoes a deviceId;
          //  * an origin CLAIM we cannot yet compare — no record key, because
          //    consuming on an unevaluated origin is exactly what (xiv) forbids.
          final serverSaysThisDeviceSentIt = msg.envelopeStatus == 'own_origin';
          final originUnknowable =
              !serverSaysThisDeviceSentIt &&
              msg.originDeviceId != null &&
              _confirmedOwnDeviceId == null;
          final recordKey = (_isSelfSyncRow(msg) || originUnknowable)
              ? null
              : msg.encryptedContent ?? msg.sendToken;
          // Peek (never consume-first): the pending record is the ONLY
          // surviving plaintext copy, and saveDecryptedContent swallows
          // failures — so persist, VERIFY by read-back, and only then take.
          // A failed persist leaves the record for the next history pass.
          final pending = recordKey != null
              ? await _encryptionProvider!.peekPendingSendRecord(recordKey)
              : null;
          if (pending != null) {
            final restoredType = _parseMessageTypeString(
              pending['messageType'] as String?,
            );
            final pendingContent = pending['content'] as String? ?? '';
            // The token THIS device minted, saved with the record — never the
            // server's echo (see `_addMessageToState`). A record saved before
            // it carried one has no wire id: fail closed.
            final ownWireId = pending[PlaintextRecordCodec.wireIdKey];
            final wireId = ownWireId is String ? ownWireId : null;
            final restored = msg.copyWith(
              content: pendingContent.isNotEmpty ? pendingContent : null,
              messageType: restoredType,
              mediaUrl: pending['mediaUrl'] as String?,
              mediaDuration: pending['mediaDuration'] as int?,
              mediaKey: pending['mediaKey'] as String?,
              mediaIv: pending['mediaIv'] as String?,
              mediaWidth: pending['mediaWidth'] as int?,
              mediaHeight: pending['mediaHeight'] as int?,
              mediaThumbHash: pending['mediaThumbHash'] as String?,
              linkPreviewUrl: pending['linkPreviewUrl'] as String?,
              linkPreviewTitle: pending['linkPreviewTitle'] as String?,
              linkPreviewImageUrl: pending['linkPreviewImageUrl'] as String?,
              wireId: wireId,
            );
            // peek → persist → verify → take:
            await _encryptionProvider!.saveDecryptedContent(
              msg.id,
              {
                'content': pendingContent,
                if (pending['messageType'] != null)
                  'messageType': pending['messageType'],
                if (pending['mediaUrl'] != null)
                  'mediaUrl': pending['mediaUrl'],
                if (pending['mediaDuration'] != null)
                  'mediaDuration': pending['mediaDuration'],
                if (pending['mediaKey'] != null)
                  'mediaKey': pending['mediaKey'],
                if (pending['mediaIv'] != null) 'mediaIv': pending['mediaIv'],
                if (pending['mediaWidth'] != null)
                  'mediaWidth': pending['mediaWidth'],
                if (pending['mediaHeight'] != null)
                  'mediaHeight': pending['mediaHeight'],
                if (pending['mediaThumbHash'] != null)
                  'mediaThumbHash': pending['mediaThumbHash'],
                if (pending['linkPreviewUrl'] != null)
                  'linkPreviewUrl': pending['linkPreviewUrl'],
                if (pending['linkPreviewTitle'] != null)
                  'linkPreviewTitle': pending['linkPreviewTitle'],
                if (pending['linkPreviewImageUrl'] != null)
                  'linkPreviewImageUrl': pending['linkPreviewImageUrl'],
              },
              wire: _wireKey(_currentUserId!, wireId),
            );
            final persisted = await _encryptionProvider!.getDecryptedContent(
              msg.id,
            );
            final verified =
                (persisted?['content'] as String? ?? '') == pendingContent &&
                (pendingContent.isNotEmpty ||
                    persisted?['messageType'] != null);
            if (verified) {
              await _encryptionProvider!.takePendingSendRecord(recordKey!);
            }
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1) {
              final merged = _mergeMessagePreferNewer(_messages[idx], restored);
              _messages[idx] = merged;
              _encryptionProvider?.cacheDecryption(msg.id, merged);
              changed = true;
            }
            _e2eFlowLog('SEND_ACK_RECONCILED', {
              'msgId': msg.id,
              'persistVerified': verified,
            });
            E2ePersistentDiag.record('SEND_ACK_RECONCILED', {
              'msgId': msg.id,
              'persistVerified': verified,
            });
          }
        }
      }
    }
    if (_decryptHistoryGeneration == generation) {
      final peersNeedingRetry = <int>{
        ...?_historyDecryptFailedPeers,
        ..._liveDecryptFailedPeers,
        for (final m in _messages)
          if (_isUnresolvedEncryptedInbound(m)) m.senderId,
      };
      if (peersNeedingRetry.isNotEmpty) {
        final retried = await _retryDecryptForPeers(
          generation,
          peersNeedingRetry,
        );
        if (retried) changed = true;
      }
      if (_recoverUnresolvedEncryptedInbound(generation)) {
        changed = true;
      }
      if (_markHistoryDecryptFailuresAfterRetry(generation)) {
        changed = true;
      }
      // Rows that stayed locked are terminal now — disarm their peers so the
      // next pass doesn't re-run the reset machinery for unrecoverable rows.
      _pruneLiveDecryptFailedPeers();
    }
    _historyDecryptFailedPeers = null;
    _historySessionRebuildRequested = null;
    // Persist the pass's ledger entries. Buffered during the pass so a 50-row
    // page costs one write instead of fifty; unflushed ids are simply lost on
    // exit, which degrades to the old behaviour rather than to a false
    // "unavailable", but the common page is under the auto-flush threshold so
    // without this most passes would never persist at all.
    await _encryptionProvider?.flushDecryptedLedger();
    if (changed) _e2eFlowLog('HISTORY_DECRYPT_DONE', {'changed': true});
    if (changed) notifyListeners();
  }

  /// When inbound rows still show [encrypted] (not [Decryption failed]) after decrypt+retry, request session rebuild (silent).
  /// [Decryption failed] is terminal — excluded here to avoid markSessionRebuild on every history pass.
  bool _recoverUnresolvedEncryptedInbound(int generation) {
    if (_decryptHistoryGeneration != generation) return false;
    final unresolvedPeers = <int>{};
    for (final m in _messages) {
      if (_isUnresolvedEncryptedInbound(m)) {
        unresolvedPeers.add(m.senderId);
      }
    }
    if (unresolvedPeers.isEmpty) return false;
    // Dedupe against the rebuilds _retryDecryptForPeers already requested this
    // pass — the old double emit made the peer discard their session twice.
    final rebuildRequested = _historySessionRebuildRequested ??= <int>{};
    for (final peerId in unresolvedPeers) {
      if (rebuildRequested.add(peerId)) {
        _requestSessionRebuildForPeer(peerId, trigger: 'recoverUnresolved');
      }
    }
    _e2eFlowLog('E2E_RECOVERY_SESSION_RESET', {
      'peerIds': unresolvedPeers.toList(),
    });
    return true;
  }

  /// After ordered history decrypt + session retry, mark rows that are still locked.
  bool _markHistoryDecryptFailuresAfterRetry(int generation) {
    if (_decryptHistoryGeneration != generation) return false;
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (_isRetiredMessage(m)) {
        if (_markMessageAsRetired(m)) changed = true;
        continue;
      }
      if (!_needsDecryption(m)) continue;
      // Withheld by the accept-side revocation gate (amendment (e)/(xxvii)):
      // nothing failed, so it must not be labelled as a failure. A revoked
      // origin stays a silent placeholder; an undecided one is retried once a
      // verified list arrives.
      if (_acceptGateWithheldIds.contains(m.id)) continue;
      if (!_hasUsableDecryptedContent(m) &&
          m.content != kDecryptionFailedLabel &&
          (m.displayAsEncryptedPlaceholder ||
              m.content == kEncryptedPlaceholderLabel)) {
        _messages[i] = m.copyWith(content: kDecryptionFailedLabel);
        changed = true;
      }
    }
    return changed;
  }

  /// After history/live decrypt failures, request a session rebuild from each
  /// peer (once per pass) and replay decrypt oldest-first. Does not downgrade
  /// [Decryption failed] to [encrypted] — failed rows stay failed until decrypt succeeds.
  ///
  /// This path must NEVER call deleteSessionWithPeer. Deleting the local
  /// SessionRecord wipes the current AND archived ratchet states, so every
  /// message the peer already encrypted with them becomes a permanent Bad-MAC
  /// loss — that is the mid-conversation [Decryption failed] cascade. The
  /// rebuild *request* is lossless: when either side later sends a PreKey
  /// message, libsignal archives the old state instead of destroying it, so
  /// in-flight old-session messages stay decryptable.
  Future<bool> _retryDecryptForPeers(
    int generation,
    Set<int> peerIds, {
    String trigger = 'historyRetry',
  }) async {
    bool changed = false;
    final retryablePeerIds = <int>{
      for (final m in _messages)
        if (peerIds.contains(m.senderId) &&
            _needsDecryption(m) &&
            !_isRetiredMessage(m))
          m.senderId,
    };
    final rebuildRequested = _historySessionRebuildRequested ??= <int>{};
    for (final peerId in retryablePeerIds) {
      if (_decryptHistoryGeneration != generation) return changed;
      if (rebuildRequested.add(peerId)) {
        _requestSessionRebuildForPeer(peerId, trigger: trigger);
      }
    }

    final sorted =
        _messages
            .where(
              (m) =>
                  retryablePeerIds.contains(m.senderId) &&
                  _needsDecryption(m) &&
                  !_isRetiredMessage(m),
            )
            .toList()
          ..sort((a, b) {
            final byTime = a.createdAt.compareTo(b.createdAt);
            if (byTime != 0) return byTime;
            return a.id.compareTo(b.id);
          });

    for (final msg in sorted) {
      if (_decryptHistoryGeneration != generation) break;
      final idx = _messages.indexWhere((m) => m.id == msg.id);
      final row = idx != -1 ? _messages[idx] : msg;
      if (_isRetiredMessage(row)) {
        if (_markMessageAsRetired(row)) changed = true;
        continue;
      }
      if (_hasUsableDecryptedContent(row)) {
        _encryptionProvider?.cacheDecryption(msg.id, row);
        continue;
      }
      // [Decryption failed] is terminal (same guard as the main history loop):
      // re-attempting it can only fail again, and the failure re-arms the
      // retry sets — that re-arming is what kept the reset loop alive forever.
      if (row.content == kDecryptionFailedLabel) continue;
      final decrypted = await _decryptMessageAsyncQueued(row);
      if (idx == -1) continue;
      _messages[idx] = _mergeMessagePreferNewer(_messages[idx], decrypted);
      changed = true;
      if (decrypted.content != kDecryptionFailedLabel &&
          decrypted.content != '[Encryption not initialized]') {
        _encryptionProvider?.cacheDecryption(msg.id, _messages[idx]);
        _liveDecryptFailedPeers.remove(msg.senderId);
        _encryptionProvider?.clearSessionRebuild(msg.senderId);
      }
    }
    _pruneLiveDecryptFailedPeers();
    return changed;
  }

  /// Debounced retry after live decrypt failure (no per-message SESSION_RESET).
  void _scheduleLiveDecryptRetry(int peerId) {
    _liveDecryptFailedPeers.add(peerId);
    _liveDecryptRetryTimer?.cancel();
    _liveDecryptRetryTimer = Timer(const Duration(milliseconds: 800), () {
      _liveDecryptRetryTimer = null;
      _runLiveDecryptRetries().ignore();
    });
  }

  Future<void> _runLiveDecryptRetries() async {
    if (_decryptingHistory || _liveDecryptFailedPeers.isEmpty) return;
    final peers = Set<int>.from(_liveDecryptFailedPeers);
    final gen = _decryptHistoryGeneration;
    final changed = await _retryDecryptForPeers(
      gen,
      peers,
      trigger: 'liveRetry',
    );
    if (_decryptHistoryGeneration != gen) return;
    if (changed) {
      final cid = _effectiveActiveConversationId;
      if (cid != null) _updateCache(cid);
      notifyListeners();
    }
  }

  Future<MessageModel> _decryptMessageAsyncQueued(MessageModel msg) {
    if (_isRetiredMessage(msg)) {
      return Future.value(_retiredMessagePlaceholder(msg));
    }
    // Our OWN send: skip the ratchet (a Signal sender cannot decrypt its own
    // output). A self-sync copy from another of our devices is NOT our own
    // send in this sense — it is ordinary inbound and must decrypt (xi).
    if (msg.senderId == _currentUserId && !_isSelfSyncRow(msg)) {
      return Future.value(msg);
    }
    return _runDecryptSerialized(msg.senderId, () => _decryptMessageAsync(msg));
  }

  Future<MessageModel> _decryptMessageAsync(MessageModel msg) async {
    // Defense in depth for any future caller that bypasses the serialized entry
    // point: retired ciphertext must never reach Signal decryption.
    if (_isRetiredMessage(msg)) return _retiredMessagePlaceholder(msg);
    // Own messages: server stored "[encrypted]" as content but we already
    // showed plaintext optimistically, so skip decryption for our own sends.
    // Origin-scoped: a self-sync row has no local plaintext to show (xi).
    if (msg.senderId == _currentUserId && !_isSelfSyncRow(msg)) return msg;

    // Already decrypted (e.g. live path) — never re-run ratchet decrypt on the
    // same ciphertext; that advances the session and causes Bad Mac on retry.
    if (_hasUsableDecryptedContent(msg)) return msg;

    // The ledger says this id's plaintext was persisted at least once, and it
    // is not in RAM. Work out whether anything can still serve it before
    // letting the ratchet anywhere near a key that may already be spent.
    if (_encryptionProvider?.wasDecryptedBefore(msg.id) ?? false) {
      // Tri-state ON PURPOSE. `getDecryptedContent` returns null for an unbound
      // user and for any caught exception as well as for a real miss, so acting
      // destructively on its null would let a transient storage error retire a
      // message whose bytes are still on disk. Only a DEFINITE absence, of
      // EVERY readable source, is allowed to retire anything.
      final exists = await _encryptionProvider?.recordExists(msg.id);

      if (exists == true) {
        final payload = await _encryptionProvider?.getDecryptedContent(msg.id);
        final persistedEditedAt = payload?['editedAt'] != null
            ? DateTime.tryParse(payload!['editedAt'] as String)
            : null;
        // An edit replaces the ciphertext under the same id, so a record from
        // before it is stale and its NEW key has never been spent. Every other
        // restore path in this file gates on this (:381, :420, :554); serving it
        // here would show pre-edit text forever. Fall through and decrypt.
        final editStale = _isEditStale(msg.editedAt, persistedEditedAt);
        if (editStale) {
          _encryptionProvider?.invalidateDecryptionCache(msg.id);
        } else {
          if (payload != null) {
            final restored = _restoreFromPersistedPayload(msg, payload);
            // Merely unhydrated. Serve the record — decrypting would have been
            // a second consumption of an already-spent key for no gain.
            if (_hasUsableDecryptedContent(restored)) return restored;
          }
          // On disk but unreadable this pass (corrupt, or a decode that threw).
          // Do not decrypt, and do not retire: the bytes are there and a later
          // pass may read them. Leave the row untouched so it retries.
          return msg;
        }
      } else {
        // No plaintext record — but that is NOT proof the message is lost.
        // `decrypt` consults the raw replay cache BEFORE the ratchet and returns
        // its plaintext with zero ratchet work, so a row that cache still covers
        // is fully readable. Retiring it would destroy readable data, which is
        // exactly the direction the governing rule forbids.
        final replayable = await _encryptionProvider?.rawReplayExists(msg.id);

        if (replayable == true) {
          // Safe to continue: the decrypt below resolves from the replay cache.
        } else if (exists == false && replayable == false) {
          // Every readable source is definitively gone — quota, eviction,
          // corruption, or a purge bug. Decrypting would hit DuplicateMessage on
          // the consumed key and burn the row into a permanent
          // "[Decryption failed]", which reads as corruption and destroys the
          // evidence it was ever readable. Retire it: an honest "no longer
          // stored on this device" that a resend can fix.
          //
          // Durable, not the ring: this is the feature's only permanent
          // destruction and the ring rotates at 200, so without this the owner's
          // diag dump would carry no evidence it ever happened.
          E2ePersistentDiag.record('LEDGER_RECORD_LOST', {
            'msgId': msg.id,
            'senderId': msg.senderId,
          });
          await _encryptionProvider?.retireLostMessage(msg.id);
          return _retiredMessagePlaceholder(msg);
        } else {
          // Undetermined. Change nothing — not the content, not the retired set
          // — so the next pass can ask again once storage is answering.
          return msg;
        }
      }
    }

    await _waitForE2EReady();
    if (!(_encryptionProvider?.isE2EReady ?? false)) {
      return msg.copyWith(content: '[Encryption not initialized]');
    }

    // Accept-side revocation (spec §12 amendments (e)/(xxvii)). Revocation is
    // bidirectional: a revoked device's ciphertext must not be accepted just
    // because a session for it exists. Checked HERE, after the own-row law's
    // branches, so it only ever gates a genuine inbound envelope.
    if (!await _originDeviceIsLive(msg)) {
      // Left RETRYABLE on purpose — no ledger consumption, no terminal
      // failure. A refusal here is silent (I7: this is a decrypt refusal, not
      // an alarm surface).
      return msg;
    }

    // hasSession + ciphertext type make every failure self-explaining in the
    // field: a type-1 (Signal) message with hasSession:false is state loss on
    // our side; type 3 (PreKey) failing means OTP/identity trouble. Ids,
    // types and booleans only — never plaintext or key material.
    final hadSessionAtDecrypt = await _encryptionProvider!.hasSessionWith(
      msg.senderId,
      deviceId: msg.originDeviceId ?? 1,
    );
    _e2eFlowLog('DECRYPT_START', {
      'msgId': msg.id,
      'senderId': msg.senderId,
      'originDeviceId': msg.originDeviceId ?? 1,
      'ctype': _ciphertextType(msg.encryptedContent),
      'hasSession': hadSessionAtDecrypt,
    });
    try {
      final plaintext = await _encryptionProvider!.decrypt(
        msg.senderId,
        msg.encryptedContent!,
        messageId: msg.id,
        // The pairwise session is keyed by the device that PRODUCED this
        // ciphertext (spec §5.4). A NULL originDeviceId is a pre-migration or
        // legacy-client row, i.e. device 1.
        deviceId: msg.originDeviceId ?? 1,
      );
      // Decrypt from this peer works again — allow a future failure to issue
      // a fresh rebuild request.
      _rebuildRequestedPeers.remove(msg.senderId);
      try {
        final parsed = E2eEnvelope.parse(plaintext);
        _e2eFlowLog('DECRYPT_OK', {
          'msgId': msg.id,
          'contentLength': parsed.content.length,
        });
        final decryptedMsg = _withEnvelope(msg, parsed);
        final parsedType = decryptedMsg.messageType;
        // Trigger ping effect for recipient when decrypted type is PING.
        // `_pingEffectFiredIds.add` returns false if already fired, so a
        // duplicate/redelivered ping that reaches live decrypt cannot re-fire
        // (transient event dedup; the persisted-cache restore path never
        // live-decrypts a ping, so restart/re-enter stay silent by construction).
        // The READ gate mirrors the restore path: if _persistDecryptedContent
        // ever fails silently, an old ping would live-re-decrypt on every cold
        // entry — a genuinely new arrival is never READ, so the clause only
        // blocks that failure-mode replay. One consume record on both paths.
        if (parsedType == MessageType.ping &&
            msg.senderId != _currentUserId &&
            msg.deliveryStatus != MessageDeliveryStatus.read &&
            _pingEffectFiredIds.add(msg.id)) {
          _showPingEffect = true;
        }
        _encryptionProvider?.cacheDecryption(msg.id, decryptedMsg);
        await _persistDecryptedContent(decryptedMsg);
        return decryptedMsg;
      } catch (parseErr) {
        debugPrint(
          '[E2E] Envelope parse failed for msg ${msg.id}, using raw plaintext: $parseErr',
        );
        final fallback = msg.copyWith(content: plaintext);
        _encryptionProvider?.cacheDecryption(msg.id, fallback);
        if (plaintext.isNotEmpty) await _persistDecryptedContent(fallback);
        return fallback;
      }
    } catch (e) {
      final cached = _encryptionProvider?.getCachedDecryption(msg.id);
      if (cached != null && _hasUsableDecryptedContent(cached)) return cached;
      if (_hasUsableDecryptedContent(msg)) return msg;

      final persisted = await _encryptionProvider!.getDecryptedContent(msg.id);
      final persistedContent = persisted?['content'] as String? ?? '';
      final canRestorePersisted =
          persisted != null &&
          (persistedContent.isNotEmpty ||
              persisted['mediaUrl'] != null ||
              persisted['messageType'] != null);
      if (canRestorePersisted) {
        final rawImageUrl = persisted['linkPreviewImageUrl'] as String?;
        final rawPageUrl = persisted['linkPreviewUrl'] as String?;
        final safeImageUrl =
            rawImageUrl != null &&
                rawPageUrl != null &&
                LinkPreviewService.isSafeImageUrl(rawImageUrl, rawPageUrl)
            ? rawImageUrl
            : null;
        final restoredType = _parseMessageTypeString(
          persisted['messageType'] as String?,
        );
        final restored = msg.copyWith(
          content: persistedContent.isNotEmpty ? persistedContent : msg.content,
          messageType: restoredType,
          mediaUrl: persisted['mediaUrl'] as String?,
          mediaDuration: persisted['mediaDuration'] as int?,
          mediaKey: persisted['mediaKey'] as String?,
          mediaIv: persisted['mediaIv'] as String?,
          mediaWidth: persisted['mediaWidth'] as int?,
          mediaHeight: persisted['mediaHeight'] as int?,
          mediaThumbHash: persisted['mediaThumbHash'] as String?,
          linkPreviewUrl: persisted['linkPreviewUrl'] as String?,
          linkPreviewTitle: persisted['linkPreviewTitle'] as String?,
          linkPreviewImageUrl: safeImageUrl,
          wireId: persisted[PlaintextRecordCodec.wireIdKey] as String?,
        );
        if (_hasUsableDecryptedContent(restored)) {
          _encryptionProvider?.cacheDecryption(msg.id, restored);
          return restored;
        }
      }

      // Decision logic extracted to a pure, characterization-tested policy
      // (utils/decryption_failure_policy.dart). A wrong branch here deletes a
      // working Signal session, so the branching is unit-tested in isolation.
      // Precedence: duplicate/badMac (terminal, persist) > identityReset
      // (terminal, no persist) > noSession (keep [encrypted], retry) > unknown
      // (live: terminal+retry; history: keep [encrypted], retry).
      final kind = _classifyDecryptError(e);
      final decision = decideDecryptionFailure(
        kind,
        hadIdentityReset: _encryptionProvider?.hadIdentityReset == true,
        isHistory: _decryptingHistory,
      );
      _logDecryptionFailure(decision.rule, msg, e);
      // One line that fully explains the outcome of this failure: what the
      // error was classified as, which rule fired and with which inputs, and
      // exactly what the caller will do about it. Durably deduped on
      // (msgId, kind): a known-terminal row re-failing identically every boot
      // adds no evidence and was evicting real failures from the cap-80 log
      // (design terminal-duplicate-retirement.md §4). Trailing delimiters in
      // the match substrings stop an id from prefix-matching a longer one;
      // the payload's key order is pinned by a line-format test.
      E2ePersistentDiag.recordDeduped(
        'DECRYPT_DECISION',
        {
          'msgId': msg.id,
          'senderId': msg.senderId,
          'kind': kind.name,
          'rule': decision.rule.name,
          'isHistory': _decryptingHistory,
          'idReset': _encryptionProvider?.hadIdentityReset == true,
          'hadSession': hadSessionAtDecrypt,
          'persist': decision.persistTerminalFailure,
          'markFailed': decision.markContentFailed,
          'retry': decision.retryAction.name,
          'notifyPeer': decision.notifyPeerRebuild,
        },
        matchAll: ['{msgId: ${msg.id},', ' kind: ${kind.name},'],
      );
      // Terminal-duplicate retirement (design terminal-duplicate-retirement.md
      // §3): a HISTORY row failing `duplicate` with no ledger entry is the
      // retry-forever class the ledger gate cannot reach. Guard (a) — the
      // ledger check — is jurisdictional; safety rests on the DEFINITE-false
      // tri-state checks inside [_evaluateTerminalDuplicate]. `?? true` fails
      // toward "in ledger" (skip) when the provider is unbound.
      if (kind == DecryptionFailureKind.duplicate &&
          _decryptingHistory &&
          !(_encryptionProvider?.wasDecryptedBefore(msg.id) ?? true)) {
        final retired = await _evaluateTerminalDuplicate(msg);
        if (retired != null) return retired;
      }
      if (decision.persistTerminalFailure) {
        // Persist so future app starts skip this message without re-attempting.
        await _encryptionProvider?.saveDecryptedContent(msg.id, {
          'content': kDecryptionFailedLabel,
        });
      }
      _askPeerToRekey(decision, msg.senderId);
      switch (decision.retryAction) {
        case DecryptionRetryAction.markHistoryPeerForRetry:
          // Keep [encrypted] until retry + session reset finish (see
          // [_markHistoryDecryptFailuresAfterRetry]).
          _historyDecryptFailedPeers?.add(msg.senderId);
          break;
        case DecryptionRetryAction.scheduleLiveRetry:
          _scheduleLiveDecryptRetry(msg.senderId);
          break;
        case DecryptionRetryAction.none:
          break;
      }
      return decision.markContentFailed
          ? msg.copyWith(content: kDecryptionFailedLabel)
          : msg;
    }
  }

  /// Terminal-duplicate retirement rule
  /// (docs/design/terminal-duplicate-retirement.md §3). Returns the retired
  /// placeholder when the rule fired this call, null otherwise.
  ///
  /// Runs ONLY from the duplicate-failure catch, after every restore attempt
  /// missed. Three outcomes, each fail-closed:
  ///  * a DEFINITE readable source (`recordExists`/`rawReplayExists` == true)
  ///    → the earlier misses were transient; RESET the counter, retire nothing;
  ///  * any undetermined answer (null) → change NOTHING — not the counter in
  ///    either direction, so a throwing store can neither advance nor erase
  ///    the evidence;
  ///  * both DEFINITELY false → record one observation (at most one per
  ///    process lifetime, boot-nonce-gated in the service), and only at
  ///    [EncryptionService.terminalDuplicateRetireSessions] distinct boots
  ///    retire the row — never deleting anything; a resend fully recovers it.
  Future<MessageModel?> _evaluateTerminalDuplicate(MessageModel msg) async {
    final enc = _encryptionProvider;
    if (enc == null) return null;
    // Belt and braces on guard (d): retired rows short-circuit at the entry
    // points and our own sends return before decrypt, but this rule must hold
    // even if a future caller bypasses them. Origin-scoped (amendment (xi)): a
    // self-sync copy IS a served envelope, so it is eligible for this rule like
    // any other inbound row — only THIS device's own sends are exempt, because
    // they never had an envelope to be a duplicate of.
    if (enc.isRetired(msg.id) ||
        (msg.senderId == _currentUserId && !_isSelfSyncRow(msg))) {
      return null;
    }
    final exists = await enc.recordExists(msg.id);
    final replayable = await enc.rawReplayExists(msg.id);
    if (exists == true || replayable == true) {
      await enc.clearTerminalDuplicate(msg.id);
      return null;
    }
    if (exists != false || replayable != false) return null;
    final n = await enc.noteTerminalDuplicate(msg.id);
    if (n == null) return null;
    _e2eFlowLog('DUP_TERMINAL_SEEN', {'msgId': msg.id, 'n': n});
    if (n < EncryptionService.terminalDuplicateRetireSessions) return null;
    // Durable, not the ring: this is the rule's only destruction-adjacent act
    // and the permanent evidence the row was retired BY RULE, not lost.
    E2ePersistentDiag.record('DUP_TERMINAL_RETIRED', {
      'msgId': msg.id,
      'senderId': msg.senderId,
      'sessions': n,
    });
    await enc.retireLostMessage(msg.id);
    // Drop the counter (design §3.1): the retired set short-circuits future
    // passes, but if a later boot's retired-set LOAD transiently fails, a
    // surviving n>=3 entry would instantly re-retire and burn a SECOND
    // durable for the same id — contradicting the once-per-id contract.
    // Cleared, that boot restarts from n=1.
    await enc.clearTerminalDuplicate(msg.id);
    return _retiredMessagePlaceholder(msg);
  }
}
