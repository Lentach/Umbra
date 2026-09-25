part of '../messaging_provider.dart';

/// A box send's plan (slice (c)): one address per live peer device, and —
/// sibling queues part B — one self-queue per live other device of ours.
typedef _BoxRoute = ({
  BoxOutbox outbox,
  List<ContactOutbound> targets,
  List<ContactOutbound> siblings,
  int conversationId,
  SenderListInfo senderListInfo,
});

/// Box deliveries (metadata-privacy PR3.1 slice (b)): the ONE dispatcher. A
/// journaled delivery is decrypted here, NOW — unlike a server row, nothing
/// can serve its ciphertext again — and routed on the envelope's `t`.
///
/// And the send side (slice (c)): [_boxRoute] decides whether a text goes
/// over the box at all, [_sendOverBox] sends it.
extension MessagingBox on MessagingProvider {
  /// Reads one journaled delivery from [peer]. True when finished with it —
  /// stored and shown, a duplicate, or refused for good; false to be offered
  /// again (`BoxInbox.drain`) because it cannot be read YET.
  ///
  /// The entry's [BoxInboxEntry.localId] is the message id (decision 14) and
  /// the key of Signal's replay cache, so an offer repeated after the
  /// ratchet already advanced reads the cached plaintext instead of failing.
  Future<bool> consumeBoxEntry(BoxInboxEntry entry, ContactRecord? peer) {
    final signal = entry.signal;
    if (signal == null) return Future.value(true);
    // One of this account's OWN devices (PR3.1 sibling queues): read before
    // the contact-record refusals — the own account has no contact record.
    final own = _currentUserId;
    if (own != null && entry.peerUserId == own) {
      return _runDecryptSerialized(own, () => _consumeSiblingBox(entry, signal));
    }
    final conversationId = peer?.legacy.conversationId;
    // The chat list still hangs off server conversation ids (release N).
    // A contact without one, or one this account blocked, gets nothing shown.
    final refusal = switch (peer) {
      null => 'no_contact',
      ContactRecord(state: ContactState.blocked) => 'blocked',
      _ when conversationId == null => 'no_conversation',
      _ => null,
    };
    if (refusal != null) {
      _e2eFlowLog('BOX_DROPPED', {
        'peer': entry.peerUserId,
        'reason': refusal,
      });
      return Future.value(true);
    }
    final msg = MessageModel(
      id: entry.localId,
      content: '',
      senderId: entry.peerUserId,
      senderUsername: peer!.username,
      conversationId: conversationId!,
      createdAt: entry.receivedAt,
      encryptedContent: signal,
      originDeviceId: entry.senderDeviceId,
      deliveryStatus: MessageDeliveryStatus.delivered,
    );
    return _runDecryptSerialized(
      entry.peerUserId,
      () => _consumeBox(msg, entry.receivedAt),
    );
  }

  /// Reads [msg]; a delivery it is FINISHED with — stored, a duplicate, an
  /// unknown type, empty, refused for good — is never offered again, so its
  /// raw replay row (plaintext, keyed by the local id) goes with it, whatever
  /// the exit.
  Future<bool> _consumeBox(MessageModel msg, DateTime receivedAt) async {
    final finished = await _readBox(msg, receivedAt);
    if (finished) await _encryptionProvider?.removeRawReplay(msg.id);
    return finished;
  }

  /// Reads a delivery from sibling [BoxInboxEntry.senderDeviceId] (its
  /// `queue_handoff` on our request or self-queue, its ack, or — part B — a
  /// sent copy on our self-queue). Same contract as [consumeBoxEntry].
  Future<bool> _consumeSiblingBox(BoxInboxEntry entry, String signal) async {
    final finished = await _readSiblingBox(entry, signal);
    if (finished) await _encryptionProvider?.removeRawReplay(entry.localId);
    return finished;
  }

  Future<bool> _readSiblingBox(BoxInboxEntry entry, String signal) async {
    final enc = _encryptionProvider;
    final link = boxSiblings;
    if (enc == null || link == null || !enc.isE2EReady) return false;
    // A sent copy read and shown earlier whose record never committed: only
    // the store is owed.
    final unsaved = _boxUnsaved[entry.localId];
    if (unsaved != null && unsaved.senderId == entry.peerUserId) {
      return _storeBoxMessage(unsaved, alreadyShown: true);
    }
    final device = entry.senderDeviceId;
    final msg = MessageModel(
      id: entry.localId,
      content: '',
      senderId: entry.peerUserId,
      senderUsername: '',
      conversationId: 0,
      createdAt: entry.receivedAt,
      encryptedContent: signal,
      originDeviceId: device,
    );
    // A request queue is public: anyone can seal a frame naming our account.
    // A sibling shares the account identity, so a PreKey message carrying any
    // other key is a stranger's — refused BEFORE Signal sees it, because
    // decrypting it would replace the real session with that device. Local
    // and cheap, so it runs first.
    if (!await enc.carriesOwnIdentity(signal)) {
      _e2eFlowLog('BOX_SIBLING_FOREIGN_IDENTITY', {'device': device});
      return true;
    }
    // What cannot be read NOW is held only on a self-queue, whose sid only
    // siblings hold, and only for the box TTL (E8): past it the sibling's
    // copy of the frame is gone from the box too, and nothing it could still
    // send would make this one readable. On the public request queue it is
    // finished: anyone can fill that queue, and a real sibling hands off
    // again on its next connect.
    // Decided when the delivery was taken in: the queue may have retired
    // since, and left the sibling row.
    final viaSelf = entry.viaSelfQueue;
    final heldIfUnreadable =
        viaSelf &&
        DateTime.now().toUtc().difference(entry.receivedAt) <=
            kBoxRedeliveryWindow;
    // The accept gate a peer delivery passes, against the OWN verified list:
    // a revoked device of ours is refused like a revoked peer device. A list
    // that names it REVOKED is a verdict, finished at once — that device
    // keeps its sid for our self-queue until the rotation deletes it (E6);
    // only an ABSENT one waits, since our list may be stale.
    if (!await _originDeviceIsLive(msg)) {
      final revoked =
          enc
              .cachedDeviceList(entry.peerUserId)
              ?.devices
              .any((d) => d.deviceId == device && d.revokedAtMs != null) ??
          false;
      if (revoked) {
        _e2eFlowLog('BOX_SIBLING_REVOKED_ORIGIN', {'device': device});
        return true;
      }
      return !heldIfUnreadable;
    }
    // Decision 37 (O6): a device's frame names its sender, which nothing
    // authenticates, and a revoked sibling still holds the account identity.
    // A PreKey message that would REPLACE our session with this sibling is
    // read only when this device asked for the re-key; otherwise it is
    // finished unread and answered by OUR re-key — a fresh PreKey handoff
    // built from the sibling's real bundle, which only it can read. A sibling
    // that really lost its session then takes ours: it asked.
    if (!link.awaitingRekeyFrom(device) &&
        await enc.siblingPreKeyWouldReplace(entry.peerUserId, device, signal)) {
      _e2eFlowLog('BOX_SIBLING_PREKEY_REFUSED', {'device': device});
      await link.rekeySibling(device);
      return true;
    }

    final String plaintext;
    try {
      plaintext = await enc.decrypt(
        entry.peerUserId,
        signal,
        messageId: entry.localId,
        deviceId: device,
      );
    } on Object catch (e) {
      final decision = _siblingDecryptFailed(msg, e);
      // The peer policy asks a peer to re-key; a sibling is re-keyed from
      // OUR side: a fresh handoff is a PreKey message it can read, and what
      // it sends next is under a session we hold.
      if (decision.rule == DecryptionFailureRule.noSession && viaSelf) {
        await link.rekeySibling(device);
      }
      return !heldIfUnreadable ||
          decision.retryAction == DecryptionRetryAction.none;
    }
    link.rekeyAnswered(device);
    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(plaintext);
    } on Object {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {'device': device});
      return true;
    }
    switch (parsed.type) {
      case E2eEnvelope.typeQueueHandoff:
        return _takeSiblingHandoff(link, device, plaintext);
      case E2eEnvelope.typeQueueHandoffAck:
        final sid = E2eEnvelope.parseQueueHandoffAck(plaintext);
        if (sid == null) {
          _e2eFlowLog('BOX_SIBLING_UNREADABLE', {
            'device': device,
            't': parsed.type,
          });
          return true;
        }
        return await link.siblingAcked(device, sid) !=
            SiblingWrite.retryLater;
      case E2eEnvelope.typeMessage:
        // A sent copy travels only into our self-queue.
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        return _takeSentCopy(link, msg, parsed);
      default:
        _e2eFlowLog('BOX_UNKNOWN_TYPE', {
          'msgId': entry.localId,
          't': parsed.type,
        });
        return true;
    }
  }

  /// Files a sibling's SENT COPY (E5) under the chat of the peer it names,
  /// as OUR row: sent, from that sibling ([msg]'s origin), under the
  /// sender's wire id and clamped send time. Kept for the next offer while
  /// this device holds no contact record (with a chat) for that peer — the
  /// sibling may simply have befriended them first — but only for the box
  /// TTL since it came in (E8); a peer this device blocked, or a copy naming
  /// no peer or our own account, is finished.
  Future<bool> _takeSentCopy(
    BoxSiblingLink link,
    MessageModel msg,
    E2eEnvelopeFields parsed,
  ) {
    final to = parsed.sentTo;
    if (to == null || to == msg.senderId) {
      _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'no_peer'});
      return Future.value(true);
    }
    final peer = link.contactOf(to);
    final conversationId = peer?.legacy.conversationId;
    if (peer?.state == ContactState.blocked) {
      _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'blocked'});
      return Future.value(true);
    }
    final receivedAt = msg.createdAt;
    if (conversationId == null) {
      if (DateTime.now().toUtc().difference(receivedAt) >
          kBoxRedeliveryWindow) {
        _e2eFlowLog('BOX_SIBLING_COPY_EXPIRED', {'peer': to});
        return Future.value(true);
      }
      _e2eFlowLog('BOX_SIBLING_COPY_WAITING', {'peer': to});
      return Future.value(false);
    }
    final sentAt = parsed.sentAt;
    final row = MessageModel(
      id: msg.id,
      content: '',
      senderId: msg.senderId,
      senderUsername: '',
      conversationId: conversationId,
      createdAt: sentAt == null || sentAt.isAfter(receivedAt)
          ? receivedAt
          : sentAt,
      encryptedContent: msg.encryptedContent,
      originDeviceId: msg.originDeviceId,
      // Status is the model's default, `sent`: ours went out when the
      // sibling's box took every frame (decision 20).
    );
    return _consumeBoxMessage(_withEnvelope(row, parsed));
  }

  /// Hands sibling [device]'s self-queue from its handoff to the box, which
  /// stores it, acks it and hands ours back when owed
  /// ([BoxSiblingLink.takeSiblingHandoff]). Kept for the next offer only when
  /// the store cannot take it now.
  Future<bool> _takeSiblingHandoff(
    BoxSiblingLink link,
    int device,
    String plaintext,
  ) async {
    final address = E2eEnvelope.parseQueueHandoff(plaintext);
    if (address == null) {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {
        'device': device,
        't': E2eEnvelope.typeQueueHandoff,
      });
      return true;
    }
    switch (await link.takeSiblingHandoff(
      device,
      sid: address.sid,
      sealPub: address.sealPub,
    )) {
      case SiblingWrite.retryLater:
        return false;
      case SiblingWrite.refused:
        _e2eFlowLog('BOX_SIBLING_HANDOFF_REFUSED', {'device': device});
        return true;
      case SiblingWrite.stored:
        return true;
    }
  }

  /// The box failure policy ([decideDecryptionFailure]) for a sibling: what
  /// may heal is offered again, the rest is finished. No re-key REQUEST:
  /// `requestSessionRebuild` names an ACCOUNT and its receivers mark their
  /// device-1 session for a rebuild — for the own account that is every
  /// sibling's session with device 1, not the pair that failed; the reader
  /// re-keys that sibling itself ([BoxSiblingLink.rekeySibling]).
  DecryptionFailureDecision _siblingDecryptFailed(MessageModel msg, Object e) {
    final decision = decideDecryptionFailure(
      _classifyDecryptError(e),
      hadIdentityReset: _encryptionProvider?.hadIdentityReset == true,
      isHistory: false,
    );
    _logDecryptionFailure(decision.rule, msg, e);
    _e2eFlowLog('BOX_SIBLING_DECRYPT_FAILED', {
      'msgId': msg.id,
      'device': msg.originDeviceId,
      'rule': decision.rule.name,
    });
    return decision;
  }

  /// Encrypts [json] for this account's own device [deviceId] and frames it
  /// as from THIS device — the [OwnDeviceEncrypt] the box's sibling swap
  /// uses, and the ack path above. Null when it cannot now (E2E not ready,
  /// no session could be built) and for any device the own VERIFIED list
  /// does not name live, this one included: the server's `ownRequestQueues`
  /// says which siblings exist, but it must never decide who is handed our
  /// self-queue — rotation (decision 27) depends on a revoked or phantom
  /// device never holding it.
  ///
  /// [fresh] (a re-key, decision 37): the session is REBUILT from the
  /// sibling's bundle first — [EncryptionProvider.ensureSession]'s rebuild,
  /// which builds over the record, so libsignal archives the current state
  /// and what the sibling already sent on it still reads — and the frame is
  /// a PreKey message.
  Future<BoxFrame?> encryptForOwnDevice(
    int deviceId,
    String json, {
    bool fresh = false,
  }) async {
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (enc == null || own == null || !enc.isE2EReady) return null;
    try {
      final verified =
          enc.cachedDeviceList(own) ?? await enc.getVerifiedDeviceList(own);
      if (deviceId == enc.ownDeviceId || !verified.isLiveDevice(deviceId)) {
        _e2eFlowLog('BOX_SIBLING_NOT_LIVE', {'device': deviceId});
        return null;
      }
      if (fresh) enc.markSessionRebuild(own, deviceId: deviceId);
      await enc.ensureSession(own, deviceId: deviceId);
      return BoxFrame.fromSignalCiphertext(
        await enc.encrypt(own, json, deviceId: deviceId),
        senderDeviceId: enc.ownDeviceId,
      );
    } on Object catch (e) {
      _e2eFlowLog('BOX_SIBLING_ENCRYPT_FAILED', {
        'device': deviceId,
        'error': e.runtimeType.toString(),
      });
      return null;
    }
  }

  /// This device's id and the device ids the own VERIFIED list names live —
  /// the [OwnLiveDevices] the box's rotation on revoke (E6/E7) acts on. Null
  /// when E2E is not ready, the device id is not confirmed by `socketReady`
  /// (a guess would let this device prune the real one), or the list cannot
  /// be verified now. Read from the verified cache when held; never tied to
  /// a send.
  Future<({int self, Set<int> live})?> ownLiveDevices() async {
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (enc == null ||
        own == null ||
        !enc.isE2EReady ||
        !enc.ownDeviceIdConfirmed) {
      return null;
    }
    try {
      final verified =
          enc.cachedDeviceList(own) ?? await enc.getVerifiedDeviceList(own);
      return (self: enc.ownDeviceId, live: verified.liveDeviceIds.toSet());
    } on Object {
      return null;
    }
  }

  Future<bool> _readBox(MessageModel msg, DateTime receivedAt) async {
    // Read and shown earlier, but its plaintext record never committed: only
    // the store is owed, never a second decrypt or a second display.
    final unsaved = _boxUnsaved[msg.id];
    if (unsaved != null &&
        unsaved.senderId == msg.senderId &&
        unsaved.conversationId == msg.conversationId) {
      return _storeBoxMessage(unsaved, alreadyShown: true);
    }
    final enc = _encryptionProvider;
    if (enc == null) return false;
    // Stored by an earlier offer whose journal update did not land: done.
    if (await enc.recordExists(msg.id) == true) return true;
    // Not ready: hand it back at once. The E2E-ready drain offers it again,
    // and waiting here would hold every read queued behind it.
    if (!enc.isE2EReady) return false;
    // Accept-side revocation (spec §12 (e)/(xxvii)), as for a server row.
    if (!await _originDeviceIsLive(msg)) return false;

    final String plaintext;
    try {
      plaintext = await enc.decrypt(
        msg.senderId,
        msg.encryptedContent!,
        messageId: msg.id,
        deviceId: msg.originDeviceId ?? 1,
      );
    } on Object catch (e) {
      return _boxDecryptFailed(msg, e);
    }
    _rebuildRequestedPeers.remove(msg.senderId);

    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(plaintext);
    } on Object {
      _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'msgId': msg.id});
      return true;
    }
    switch (parsed.type) {
      case E2eEnvelope.typeMessage:
        // Decision 13: the sender's clock, never past our own receive time.
        final sentAt = parsed.sentAt;
        final createdAt = sentAt == null || sentAt.isAfter(receivedAt)
            ? receivedAt
            : sentAt;
        return _consumeBoxMessage(
          _withEnvelope(msg, parsed).copyWith(createdAt: createdAt),
        );
      default:
        // A type a newer peer speaks: nothing here can show it.
        _e2eFlowLog('BOX_UNKNOWN_TYPE', {'msgId': msg.id, 't': parsed.type});
        return true;
    }
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

  Future<bool> _consumeBoxMessage(MessageModel decrypted) async {
    final enc = _encryptionProvider!;
    final wire = _wireKey(decrypted.senderId, decrypted.wireId);
    if (wire != null) {
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
    return _storeBoxMessage(decrypted, alreadyShown: false);
  }

  /// Stores [msg]'s plaintext and shows it. True only once the record is
  /// PROVEN on disk (read back from the store, not the write's word — the
  /// save path swallows a refused commit): the entry leaves the journal only
  /// then, because its ciphertext's ratchet key is already spent. Until
  /// then the message is shown from RAM and the next offer retries the
  /// store alone.
  Future<bool> _storeBoxMessage(
    MessageModel msg, {
    required bool alreadyShown,
  }) async {
    final enc = _encryptionProvider!..cacheDecryption(msg.id, msg);
    await _persistDecryptedContent(msg);
    final stored = await enc.recordExists(msg.id) == true;
    if (!alreadyShown) _showBoxMessage(msg);
    if (stored) {
      _boxUnsaved.remove(msg.id);
      return true;
    }
    E2ePersistentDiag.record('BOX_STORE_UNPROVEN', {'msgId': msg.id});
    _boxUnsaved[msg.id] = msg;
    return false;
  }

  void _showBoxMessage(MessageModel msg) {
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    final inView = msg.conversationId == viewing;
    if (inView &&
        msg.messageType == MessageType.ping &&
        _pingEffectFiredIds.add(msg.id)) {
      _showPingEffect = true;
    }
    _addMessageToState(msg);
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

  /// Adds [conversationId]'s stored box messages to the open chat once its
  /// first history page has landed. A separate step on purpose: the page's
  /// own merge stays the single synchronous install it is on a warm entry.
  Future<void> _mergeLocalBoxRows(int conversationId) async {
    final rows = await _localBoxRows(conversationId);
    if (rows.isEmpty || _isDisposed) return;
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    if (viewing != conversationId) return;
    final held = {for (final m in _messages) m.id};
    final missing = [
      for (final row in rows)
        if (!held.contains(row.id) && !_deletedMessageIds.contains(row.id)) row,
    ];
    if (missing.isEmpty) return;
    _messages = [..._messages, ...missing]
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    if (_conversationCache.containsKey(conversationId)) {
      _updateCache(conversationId);
    }
    notifyListeners();
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
        ?_boxRowFrom(id, conversationId, record, conversation),
    ];
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
    final row = _restoreFromPersistedPayload(
      MessageModel(
        id: id,
        content: '',
        senderId: senderId,
        senderUsername: sender?.id == senderId ? sender!.username : '',
        conversationId: conversationId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
        // Ours went out when the box took every frame (decision 20); no
        // receipt comes back over the box yet.
        deliveryStatus: senderId == _currentUserId
            ? MessageDeliveryStatus.sent
            : MessageDeliveryStatus.delivered,
      ),
      record,
    );
    return _hasUsableDecryptedContent(row) ? row : null;
  }

  /// Where a TEXT to [recipientId] goes over the box (slice (c), decision
  /// 16): only when EVERY live device of the peer has a box address and
  /// every live OTHER device of ours has a self-queue address (sibling
  /// queues part B, E5) — one message is never split across the two paths,
  /// because an old-path copy is a server row naming the pair that the box
  /// devices would then be served as `none_for_device`. Null = the old path,
  /// and ONLY on evidence: a verified list naming a device with no address.
  /// A list that cannot be verified THROWS (the caller fails the row for a
  /// retry): the peer is box-covered as far as we know, and on web
  /// socket.io would replay an old-path emit buffered while offline as a
  /// server row.
  ///
  /// [addresses] is the outbox's answer for the peer, taken by the caller
  /// WITHOUT an await, so a peer with none (every chat until the handoff
  /// slice) reaches the old path's emit on exactly the turns it always did.
  ///
  /// Both lists come from the verified cache (the peer path of
  /// `getDeviceList` stays until PR4.1): unlike the old path, the box has no
  /// server bounce to catch a device we did not know about. Both are the
  /// ones THIS connect verified ([refreshBoxDeviceLists], decision 21); a
  /// send never looks one up, which would hand the server the pair (the
  /// peer's list) or the sender (the own list) at the time of the message.
  Future<_BoxRoute?> _boxRoute(
    int recipientId,
    BoxOutbox outbox,
    Map<int, ContactOutbound> addresses,
  ) async {
    final enc = _encryptionProvider;
    final ownUserId = _currentUserId;
    if (enc == null || ownUserId == null) return null;
    void declined(String why) => _e2eFlowLog('BOX_ROUTE_OLD_PATH', {
      'peer': recipientId,
      'why': why,
    });
    final conversationId = _conversationsProvider?.conversations
        .where((c) => conv_helpers.getOtherUserId(c, ownUserId) == recipientId)
        .firstOrNull
        ?.id;
    if (conversationId == null) {
      declined('no_conversation');
      return null;
    }
    final VerifiedDeviceList peer;
    final VerifiedDeviceList own;
    try {
      final peerLookup = _boxLists.readyFor(recipientId);
      final ownLookup = _boxLists.readyFor(ownUserId);
      // Fail closed on both: an own list some other path cached is not one
      // this connect verified.
      if (peerLookup == null || ownLookup == null) {
        throw StateError('device list not looked up this connect');
      }
      await peerLookup;
      await ownLookup;
      // Dropped since the lookup (a rebuild request, an identity change,
      // `deviceListChanged`): the refresh looks it up again; this send fails
      // for a retry.
      final heldPeer = enc.cachedDeviceList(recipientId);
      final heldOwn = enc.cachedDeviceList(ownUserId);
      if (heldPeer == null || heldOwn == null) {
        throw StateError('device list dropped');
      }
      peer = heldPeer;
      own = heldOwn;
    } on Object {
      _e2eFlowLog('BOX_ROUTE_UNVERIFIED', {'peer': recipientId});
      rethrow;
    }
    final siblingIds = [
      for (final d in own.liveDeviceIds)
        if (d != enc.ownDeviceId) d,
    ];
    final siblingAddresses = outbox.siblingAddresses();
    final siblings = [for (final d in siblingIds) ?siblingAddresses[d]];
    if (siblings.length != siblingIds.length) {
      declined('own_uncovered');
      return null;
    }
    final live = peer.liveDeviceIds;
    final targets = [for (final d in live) ?addresses[d]];
    if (live.isEmpty || targets.length != live.length) {
      declined('peer_uncovered');
      return null;
    }
    return (
      outbox: outbox,
      targets: targets,
      siblings: siblings,
      conversationId: conversationId,
      senderListInfo: SenderListInfo(
        ownVersion: own.version,
        ownListHash: own.listHash,
        peerVersion: peer.version,
        peerListHash: peer.listHash,
      ),
    );
  }

  /// Sends [content] along [route]: one Signal message per peer device, each
  /// sealed into that device's queue, and a SENT COPY — the same message
  /// naming the peer inside E2E (E5) — per sibling, sealed into its
  /// self-queue. The row is SENT only once the box took every frame, the
  /// copies included (decision 20); anything less fails it for a retry
  /// (decision 19), which re-seals under the same wire id, so a device that
  /// already holds the message drops the copy (`wireHeldByOther`). Every
  /// frame is built before the first goes out, so nothing reaches some
  /// devices only.
  ///
  /// While it runs, the tempId is in [_boxInFlight]: an account-socket error
  /// cannot fail the row under it and a retry cannot start a second attempt
  /// (each would take its own local id and store a second copy). It joins
  /// [_boxTempIds] only just before the first frame goes out — the first
  /// moment a device may hold the message.
  Future<bool> _sendOverBox(
    _BoxRoute route, {
    required int recipientId,
    required String content,
    required String tempId,
    required String sendToken,
    Map<String, String?>? linkPreview,
  }) async {
    _boxInFlight.add(tempId);
    try {
      final enc = _encryptionProvider!;
      // Whole ms: the envelope's `ts` and the stored `createdAt` must agree.
      final sentAt = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      );
      final envelope = boxEnvelope(
        content,
        linkPreview: linkPreview,
        senderListInfo: route.senderListInfo.toJson(),
        msgId: sendToken,
        sentAt: sentAt,
        sentTo: recipientId,
      );
      final ownUserId = _currentUserId!;
      final frames = <(ContactOutbound, Uint8List)>[];
      for (final (userId, to, json) in [
        for (final to in route.targets) (recipientId, to, envelope.json),
        for (final to in route.siblings) (ownUserId, to, envelope.copyJson),
      ]) {
        await enc.ensureSession(userId, deviceId: to.peerDeviceId);
        final frame = BoxFrame.fromSignalCiphertext(
          await enc.encrypt(userId, json, deviceId: to.peerDeviceId),
          senderDeviceId: enc.ownDeviceId,
        );
        if (frame == null) throw StateError('encrypt gave no Signal message');
        if (frame.signal.length > BoxFrame.maxSignalBytes) {
          _e2eFlowLog('BOX_SEND_TOO_LONG', {
            'tempId': tempId,
            'bytes': frame.signal.length,
          });
          _markMessageFailed(tempId, 'Message is too long to send.');
          return false;
        }
        frames.add((to, frame.encode()));
      }
      final localId = await route.outbox.nextLocalId();
      if (localId == null) {
        _e2eFlowLog('BOX_SEND_NO_LOCAL_ID', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      _boxTempIds.add(tempId);
      final accepted = await Future.wait([
        for (final (to, body) in frames) route.outbox.deliver(to, body),
      ]);
      _e2eFlowLog('BOX_SEND', {
        'tempId': tempId,
        'frames': frames.length,
        'accepted': accepted.where((ok) => ok).length,
      });
      if (accepted.contains(false)) {
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      final preview = envelope.linkPreview;
      // Status is the model's default, `sent`: the box took every frame.
      final sent = MessageModel(
        id: localId,
        content: content,
        senderId: ownUserId,
        senderUsername: '',
        conversationId: route.conversationId,
        createdAt: sentAt,
        tempId: tempId,
        wireId: sendToken,
        linkPreviewUrl: preview?['url'],
        linkPreviewTitle: preview?['title'],
        linkPreviewImageUrl: preview?['imageUrl'],
      );
      enc.cacheDecryption(localId, sent);
      await _persistDecryptedContent(sent);
      if (await enc.recordExists(localId) != true) {
        // Shown from RAM this session; nothing re-offers a sent message.
        E2ePersistentDiag.record('BOX_SENT_STORE_UNPROVEN', {'msgId': localId});
      }
      _addMessageToState(sent);
      return true;
    } finally {
      _boxInFlight.remove(tempId);
    }
  }
}
