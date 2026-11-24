part of '../messaging_provider.dart';

/// The sibling side of the box read, out of [MessagingBox]: a delivery from
/// another device of this account (its `queue_handoff`, its ack, a sent
/// copy on our self-queue), and what this device encrypts for one of its
/// own.
extension MessagingBoxSiblingRead on MessagingProvider {
  /// Reads a delivery from sibling [BoxInboxEntry.senderDeviceId] (its
  /// `queue_handoff` on our request or self-queue, its ack, or — part B — a
  /// sent copy on our self-queue). Same contract as [MessagingBox.consumeBoxEntry].
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
      return _storeBoxMessage(
        unsaved,
        alreadyShown: true,
        receivedAt: entry.receivedAt,
      );
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
        await enc.preKeyWouldReplaceSession(entry.peerUserId, device, signal)) {
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
    // Decisions 101 B / 103: any frame from a sibling that decrypts on our
    // self-queue is that sibling heard, whatever it carries.
    if (viaSelf) _heardFromSibling(device);
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
        return await link.siblingAcked(device, sid) != SiblingWrite.retryLater;
      case E2eEnvelope.typeMessage:
        // A sent copy travels only into our self-queue.
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        return _takeSentCopy(link, msg, parsed);
      case E2eEnvelope.typeReact ||
          E2eEnvelope.typePin ||
          E2eEnvelope.typeEdit ||
          E2eEnvelope.typeDelete:
        // Our own action, as a sibling sent it (item 4, E19a): like a sent
        // copy, only through our self-queue, filed by the peer `to` names.
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        final chat = _sentCopyChat(link, msg, parsed);
        final conversationId = chat.conversationId;
        if (conversationId == null) return chat.finished;
        return _takeBoxAction(
          parsed,
          plaintext,
          actor: msg.senderId,
          // `_sentCopyChat` found the chat by `to`, so it is set.
          peer: parsed.sentTo!,
          conversationId: conversationId,
          receivedAt: msg.createdAt,
        );
      // Our own first contact, as a sibling made it (slice (f), E15e), the
      // end of one (E15j) or its chat's timer (E15k): only through our
      // self-queue, like every other copy.
      case E2eEnvelope.typeFriendRequestSent ||
          E2eEnvelope.typeFriendAccepted ||
          E2eEnvelope.typeFriendDeclined ||
          E2eEnvelope.typeGoodbye ||
          E2eEnvelope.typeTimer:
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        final to = parsed.sentTo;
        return switch (parsed.type) {
          E2eEnvelope.typeGoodbye when to != null => _takeGoodbye(
            to,
            block: E2eEnvelope.goodbyeBlocks(plaintext) ?? false,
          ),
          E2eEnvelope.typeTimer when to != null => Future.value(
            _takeBoxTimer(to, plaintext, msg.createdAt),
          ),
          E2eEnvelope.typeGoodbye || E2eEnvelope.typeTimer => Future.value(
            true,
          ),
          _ => _takeFirstContactCopy(parsed.type, plaintext),
        };
      // A sibling's daily `alive` (decision 103): heard above, and nothing
      // more. Only through our self-queue, like every copy.
      case E2eEnvelope.typeAlive:
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        _siblingReadsRelays(device);
        return true;
      // Catch-up sync (decision 102): a sibling's request, or its answer to
      // ours. Only through our self-queue, like every copy.
      case E2eEnvelope.typeSyncRequest || E2eEnvelope.typeSyncResponse:
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        _siblingReadsRelays(device);
        if (parsed.type == E2eEnvelope.typeSyncRequest) {
          return _takeSyncRequest(device, plaintext);
        }
        return _takeSyncResponse(device, plaintext);
      // A friend's message or action one of our devices read, relayed to
      // this one because the friend could not address it (decision 101 A).
      // Only through our self-queue: anyone can fill the request queue.
      case E2eEnvelope.typeRelay:
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        _siblingReadsRelays(device);
        return _takeRelayed(link, msg, plaintext);
      // A sibling's profile photo (decision 138): the account's own newest
      // reference. Only through our self-queue, like every copy.
      case E2eEnvelope.typeProfile:
        if (!viaSelf) {
          _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'request_queue'});
          return true;
        }
        return _takeOwnProfile(plaintext);
      // Receipts and typing go to the peer's devices only (E61b): a copy
      // on our own queues is not one we send, and is dropped.
      case E2eEnvelope.typeReceipt || E2eEnvelope.typeTyping:
        _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': parsed.type});
        return true;
      default:
        _e2eFlowLog('BOX_UNKNOWN_TYPE', {
          'msgId': entry.localId,
          't': parsed.type,
        });
        return true;
    }
  }

  /// The chat a sibling's SENT COPY — a message (E5) or an action (item 4) —
  /// belongs to: the conversation with the peer its `to` names. Without
  /// one, `finished` says whether the copy is done with — it names no peer
  /// or our own account, the peer is blocked, or it waited past the box TTL
  /// (E8) — or is kept for the next offer while this device holds no chat
  /// for that peer yet (the sibling may simply have befriended them first).
  ({int? conversationId, bool finished}) _sentCopyChat(
    BoxSiblingLink link,
    MessageModel msg,
    E2eEnvelopeFields parsed,
  ) {
    const done = (conversationId: null, finished: true);
    final to = parsed.sentTo;
    if (to == null || to == msg.senderId) {
      _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'no_peer'});
      return done;
    }
    final peer = link.contactOf(to);
    final conversationId = MessagingFirstContact._boxChatOf(peer);
    if (peer?.state == ContactState.blocked) {
      _e2eFlowLog('BOX_SIBLING_COPY_REFUSED', {'why': 'blocked'});
      return done;
    }
    if (conversationId == null) {
      if (DateTime.now().toUtc().difference(msg.createdAt) >
          kBoxRedeliveryWindow) {
        _e2eFlowLog('BOX_SIBLING_COPY_EXPIRED', {'peer': to});
        return done;
      }
      _e2eFlowLog('BOX_SIBLING_COPY_WAITING', {'peer': to});
      return (conversationId: null, finished: false);
    }
    return (conversationId: conversationId, finished: false);
  }

  /// Files a sibling's SENT COPY (E5) under the chat of the peer it names
  /// ([_sentCopyChat]), as OUR row: sent, from that sibling ([msg]'s
  /// origin), under the sender's wire id and clamped send time.
  Future<bool> _takeSentCopy(
    BoxSiblingLink link,
    MessageModel msg,
    E2eEnvelopeFields parsed,
  ) {
    final chat = _sentCopyChat(link, msg, parsed);
    final conversationId = chat.conversationId;
    if (conversationId == null) return Future.value(chat.finished);
    final receivedAt = msg.createdAt;
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
    return _withBoxExtras(
      _withEnvelope(row, parsed),
      parsed,
    ).then((copy) => _consumeBoxMessage(copy, receivedAt: receivedAt));
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
}
