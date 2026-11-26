part of '../messaging_provider.dart';
// This part IS MessagingProvider: the protected members it calls are its own.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Box deliveries (metadata-privacy PR3.1 slice (b)): the ONE dispatcher. A
/// journaled delivery is decrypted here, NOW — unlike a server row, nothing
/// can serve its ciphertext again — and routed on the envelope's `t`.
///
/// The send side lives in [MessagingBoxSend] (`box_send.dart`). The B3 hold of
/// a foreign friend frame ([_holdForeignFrame], [_holdBehindForeignFrame])
/// stays here.
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
    // A device that sends to us reads its own queues again (E93a). Only on
    // a queue whose sid that device was handed: our sibling's on a
    // self-queue, a friend's on its contact queue. Anyone may write to the
    // public request queue and claim any account and device there.
    final own = _currentUserId;
    final fromItsQueue = entry.peerUserId == own
        ? entry.viaSelfQueue
        : !entry.viaRequestQueue;
    if (fromItsQueue &&
        _boxPaused.resume(entry.peerUserId, entry.senderDeviceId)) {
      _e2eFlowLog('BOX_DEVICE_RESUMED', {
        'user': entry.peerUserId,
        'device': entry.senderDeviceId,
        'by': 'heard',
      });
    }
    // One of this account's OWN devices (PR3.1 sibling queues): read before
    // the contact-record refusals — the own account has no contact record.
    if (own != null && entry.peerUserId == own) {
      return _runDecryptSerialized(
        own,
        () => _consumeSiblingBox(entry, signal),
      );
    }
    // A friend's queue handoff from our public REQUEST queue (item 5), or a
    // first contact's request (slice (f)): the only things read from it,
    // under their own checks.
    if (entry.viaRequestQueue) {
      return _runDecryptSerialized(
        entry.peerUserId,
        () => _consumeFriendRequest(entry, signal, peer),
      );
    }
    // A friendship made over the box keys its chat by its local id, which a
    // restored contact backup (no `legacy`) must still find.
    final conversationId = MessagingFirstContact._boxChatOf(peer);
    // The chat list still hangs off server conversation ids (release N).
    // A contact this account blocked gets nothing read; a friend without a
    // conversation yet gets only its queue handoff and ack read (item 5: a
    // friendship moves onto the box before anyone writes in it).
    final refusal = switch (peer) {
      null => 'no_contact',
      ContactRecord(state: ContactState.blocked) => 'blocked',
      _ => null,
    };
    if (refusal != null) {
      _e2eFlowLog('BOX_DROPPED', {
        'peer': entry.peerUserId,
        'reason': refusal,
      });
      _clearCalmHold(entry.peerUserId);
      return Future.value(true);
    }
    final msg = MessageModel(
      id: entry.localId,
      content: '',
      senderId: entry.peerUserId,
      senderUsername: peer!.username,
      conversationId: conversationId ?? 0,
      createdAt: entry.receivedAt,
      encryptedContent: signal,
      originDeviceId: entry.senderDeviceId,
      deliveryStatus: MessageDeliveryStatus.delivered,
    );
    return _runDecryptSerialized(
      entry.peerUserId,
      () => _consumeBox(
        msg,
        entry.receivedAt,
        controlOnly: conversationId == null,
        peer: peer,
      ),
    );
  }

  /// Reads [msg]; a delivery it is FINISHED with — stored, a duplicate, an
  /// unknown type, empty, refused for good — is never offered again, so its
  /// raw replay row (plaintext, keyed by the local id) goes with it, whatever
  /// the exit. [controlOnly]: the chat has no conversation, so only a queue
  /// handoff or its ack is taken.
  Future<bool> _consumeBox(
    MessageModel msg,
    DateTime receivedAt, {
    bool controlOnly = false,
    ContactRecord? peer,
  }) async {
    final finished = await _readBox(
      msg,
      receivedAt,
      controlOnly: controlOnly,
      peer: peer,
    );
    if (finished) await _encryptionProvider?.removeRawReplay(msg.id);
    return finished;
  }

  Future<bool> _readBox(
    MessageModel msg,
    DateTime receivedAt, {
    bool controlOnly = false,
    ContactRecord? peer,
  }) async {
    // Read and shown earlier, but its plaintext record never committed: only
    // the store is owed, never a second decrypt or a second display.
    final unsaved = _boxUnsaved[msg.id];
    if (unsaved != null &&
        unsaved.senderId == msg.senderId &&
        unsaved.conversationId == msg.conversationId) {
      return _storeBoxMessage(
        unsaved,
        alreadyShown: true,
        receivedAt: receivedAt,
      );
    }
    final enc = _encryptionProvider;
    if (enc == null) return false;
    // Stored by an earlier offer whose journal update did not land: done.
    if (await enc.recordExists(msg.id) == true) return true;
    // Not ready: hand it back at once. The E2E-ready drain offers it again,
    // and waiting here would hold every read queued behind it.
    if (!enc.isE2EReady) return false;
    // Accept-side revocation (spec §12 (e)/(xxvii)), as for a server row —
    // against the list HELD: a lookup timed by a box frame would name the
    // pair at that moment (E50f). A device the list does not name yet is
    // announced by its own handoff (decision 50) before it can write here.
    // Never held for good, as a sibling's (E8): a revoked, possibly stolen,
    // device keeps our old queue's sid for 30 d (E50e) and claims any device
    // id. A list naming it REVOKED is a verdict, finished at once; an absent
    // or undecided one waits only while the box could still redeliver it.
    if (!await _originDeviceIsLive(msg)) {
      final device = msg.originDeviceId ?? 1;
      final revoked =
          enc
              .cachedDeviceList(msg.senderId)
              ?.devices
              .any((d) => d.deviceId == device && d.revokedAtMs != null) ??
          false;
      if (revoked) {
        _e2eFlowLog('BOX_REVOKED_ORIGIN', {
          'peer': msg.senderId,
          'device': device,
        });
        return true;
      }
      return DateTime.now().toUtc().difference(receivedAt) >
          kBoxRedeliveryWindow;
    }

    // A friend's device that lost its storage re-minted its identity and
    // hands us its new queue in a PreKey message (decision 88). Judged
    // BEFORE the decrypt, which moves the session and erases the evidence.
    // Only for a friend the held list says is NOT enrolled: single-device
    // by construction, so no revoked device of it exists to mint a key of
    // its own, and its identity changes only by that re-mint. An enrolled
    // account never re-mints on a login (it gates).
    final preKey = msg.encryptedContent!.startsWith(
      '${BoxFrameKind.preKey.byte}:',
    );
    var newIdentity =
        preKey &&
        enc.cachedDeviceList(msg.senderId)?.enrolled == false &&
        await enc.preKeyFromNewIdentity(
          msg.senderId,
          msg.originDeviceId ?? 1,
          msg.encryptedContent!,
        );
    // B3 (decision 143): a PreKey frame under an identity other than the
    // friend's pinned one is NEVER decrypted before its key is confirmed.
    // Decision 152 (option C): for an unverified friend with warnings OFF it
    // waits CALMLY (a neutral line, no network) until the user taps; anything
    // else is the visible hold at once. Anyone who holds the friend's queue
    // address (a hostile server, a revoked device) can seal one.
    if (preKey) {
      switch (await enc.friendFrameIdentity(
        msg.senderId,
        msg.encryptedContent!,
      )) {
        case FriendFrameIdentity.matches || FriendFrameIdentity.noAnchor:
          // Accepted earlier as a re-mint: that judgement stands (the accept
          // dropped the list it reads).
          newIdentity = newIdentity || (_boxHeld[msg.id] ?? false);
          _boxHeld.remove(msg.id);
          // Only a frame of the key that WAITS calmly settles that hold (the
          // anchor reached it); a frame of the pinned key leaves it alone.
          if (_calmHolds[msg.senderId]?.identity ==
              preKeyIdentityOf(msg.encryptedContent!)) {
            _calmHolds.remove(msg.senderId);
            _takeCalmDeferred(msg.senderId); // settled: a plain Retry remains
          }
        case FriendFrameIdentity.foreign:
          return _holdForeign(
            msg,
            enc,
            peer,
            remint: newIdentity,
            receivedAt: receivedAt,
          );
      }
    }
    final String plaintext;
    try {
      plaintext = await enc.decrypt(
        msg.senderId,
        msg.encryptedContent!,
        messageId: msg.id,
        deviceId: msg.originDeviceId ?? 1,
      );
    } on Object catch (e) {
      // A whisper of a friend with a frame held rides the session that frame
      // would build: it cannot read yet, and must neither be finished, nor
      // ask the friend to re-key, nor repair anything. Held in arrival
      // order behind it. (One that DOES read — the friend's real session,
      // while the held frame is a forgery — proceeds below.)
      if (!preKey &&
          enc.peersWithHeldMessages.contains(msg.senderId) &&
          _classifyDecryptError(e) != DecryptionFailureKind.duplicate) {
        return _holdBehindForeignFrame(msg, peer);
      }
      return _boxDecryptFailed(msg, e);
    }
    _boxHeld.remove(msg.id);
    _rebuildRequestedPeers.remove(msg.senderId);
    // A friend device that writes to us may have lost our handoff (item 5).
    boxFriends?.friendHeard(msg.senderId, msg.originDeviceId ?? 1);

    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(plaintext);
    } on Object {
      _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'msgId': msg.id});
      return true;
    }
    // Whether that device relays to the siblings a sender cannot address
    // (101 A, E101b): every frame says it, so a missing `rl` takes it back.
    final origin = msg.originDeviceId;
    if (origin != null) {
      _noteFriendRelays(msg.senderId, origin, relays: parsed.relays);
    }
    final link = boxFriends;
    switch (parsed.type) {
      // The friend's device handed us its queue — a hand-back over our own
      // queue for it (item 5, E20d) — or acknowledged ours. A hand-back rides
      // the session the handoff built, so it is a whisper message; one that
      // came in a PreKey message is taken only when this device asked for
      // that session (it started or re-keyed it): a revoked device of the
      // friend still holds this queue's sid and the account identity, and
      // would otherwise move a live device's address to its own queue. A
      // non-enrolled friend's device under an identity new to this session
      // is not that device: it lost its storage, and the queue we gave it is
      // the only place it can reach us from (decision 88).
      case E2eEnvelope.typeQueueHandoff when link != null:
        final device = msg.originDeviceId ?? 1;
        // An account we asked over the box answers from the session our
        // request built: its accept counts as asked (slice (f), E15f).
        if (preKey &&
            !newIdentity &&
            !link.awaitingFriendRekeyFrom(msg.senderId, device) &&
            !MessagingFirstContact._boxPending(
              link.contactOf(msg.senderId),
              ContactState.pendingOut,
            )) {
          _e2eFlowLog('BOX_FRIEND_HANDOFF_REFUSED', {
            'peer': msg.senderId,
            'device': device,
            'why': 'prekey_unasked',
          });
          return true;
        }
        if (newIdentity) {
          _e2eFlowLog('BOX_FRIEND_HANDOFF_NEW_IDENTITY', {
            'peer': msg.senderId,
            'device': device,
          });
        }
        link.friendRekeyAnswered(msg.senderId, device);
        return _takeFriendHandoff(link, msg.senderId, device, plaintext);
      case E2eEnvelope.typeQueueHandoffAck when link != null:
        final sid = E2eEnvelope.parseQueueHandoffAck(plaintext);
        if (sid == null) {
          _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'msgId': msg.id});
          return true;
        }
        return switch (await link.friendAcked(
          msg.senderId,
          msg.originDeviceId ?? 1,
          sid,
        )) {
          FriendWrite.retryLater => false,
          FriendWrite.stored || FriendWrite.refused => true,
        };
      // The friend's device list, from one of its live devices (slice (e):
      // a revoke announced by a survivor, E50d, or its answer to our stale
      // view, E50f). Adopted only under the DAK the server served (E50a);
      // a revoke rotates our queue away from that device (E50e).
      case E2eEnvelope.typeListUpdate:
        final auth = E2eEnvelope.carriedDeviceList(plaintext);
        if (auth == null) {
          _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'msgId': msg.id});
          return true;
        }
        if (await _adoptCarriedList(msg.senderId, auth)) {
          link?.friendDevicesChanged(msg.senderId);
        }
        return true;
      // A friend made over the box ended the friendship (E15j), or set the
      // chat's timer (E15k). A friendship the server knows keeps the
      // server's events for both.
      case E2eEnvelope.typeGoodbye:
        return _takeGoodbye(msg.senderId, block: false);
      case E2eEnvelope.typeTimer:
        return _takeBoxTimer(msg.senderId, plaintext, receivedAt);
      // A friend's new photo (decision 138): its reference, taken only from
      // a friend and only when newer than the one held. Needs no chat.
      case E2eEnvelope.typeProfile:
        return _takeFriendProfile(msg.senderId, plaintext);
      // The peer's receipt or typing (slice (g), E61b): shown in its chat,
      // never held for a chat this device has not linked yet.
      case E2eEnvelope.typeReceipt || E2eEnvelope.typeTyping:
        if (controlOnly) return true;
        return _takeBoxSignal(msg, parsed.type, plaintext);
      case _ when controlOnly:
        // No conversation to show it in yet (release N's chat list hangs off
        // server conversation ids). A friend always has one on the server,
        // so this device's link to it is only late (found in the item-5
        // drive: the first box message after a friendship made elsewhere):
        // held for a later offer — the plaintext waits in the replay cache —
        // never dropped. Anyone else's is dropped, as before.
        final friend =
            link?.contactOf(msg.senderId)?.state == ContactState.friend;
        _e2eFlowLog(friend ? 'BOX_HELD' : 'BOX_DROPPED', {
          'peer': msg.senderId,
          'reason': 'no_conversation',
        });
        return !friend;
      case E2eEnvelope.typeMessage:
        // Decision 13: the sender's clock, never past our own receive time.
        final sentAt = parsed.sentAt;
        final createdAt = sentAt == null || sentAt.isAfter(receivedAt)
            ? receivedAt
            : sentAt;
        return _consumeBoxMessage(
          await _withBoxExtras(
            _withEnvelope(msg, parsed).copyWith(createdAt: createdAt),
            parsed,
          ),
          receivedAt: receivedAt,
          // Read here first: on to the siblings the friend could not
          // address (decision 101 A).
          relay: () => _relayFriendFrame(msg, parsed, plaintext),
        );
      case E2eEnvelope.typeReact ||
          E2eEnvelope.typePin ||
          E2eEnvelope.typeEdit ||
          E2eEnvelope.typeDelete:
        // The peer's action on a message of this chat (item 4, E19b).
        final taken = await _takeBoxAction(
          parsed,
          plaintext,
          actor: msg.senderId,
          peer: msg.senderId,
          conversationId: msg.conversationId,
          receivedAt: receivedAt,
        );
        _relayFriendAction(msg, parsed, plaintext);
        return taken;
      default:
        // A type a newer peer speaks: nothing here can show it.
        _e2eFlowLog('BOX_UNKNOWN_TYPE', {'msgId': msg.id, 't': parsed.type});
        return true;
    }
  }

  /// A friend's PreKey frame under a FOREIGN identity (never decrypted).
  /// Unparseable: finished, never held (S5). Eligible (warnings OFF, friend
  /// not verified, anchor pinned, a held list saying NOT enrolled, and no
  /// other key already waiting): the CALM hold — no network, no red bar, no
  /// candidate; the line is tappable. Anything else: today's visible hold.
  Future<bool> _holdForeign(
    MessageModel msg,
    EncryptionProvider enc,
    ContactRecord? peer, {
    required bool remint,
    required DateTime receivedAt,
  }) async {
    if (peer != null && peer.state != ContactState.friend) {
      return _dropHeld(msg);
    }
    final identity = preKeyIdentityOf(msg.encryptedContent!);
    if (identity == null) {
      _e2eFlowLog('BOX_FOREIGN_FRAME_UNPARSEABLE', {'peer': msg.senderId});
      return true;
    }
    final held = _calmHolds[msg.senderId];
    if ((held == null || held.identity == identity) &&
        await enc.calmHoldEligible(msg.senderId)) {
      // One object per peer, updated in place: a tap in flight holds it, and
      // a replaced one would leave that tap's answer with nothing to settle.
      if (held == null) {
        _calmHolds[msg.senderId] = CalmHold(
          identity: identity,
          device: msg.originDeviceId ?? 1,
          firstReceivedAt: receivedAt,
          ciphertext: msg.encryptedContent!,
          state: CalmHoldState.waiting,
        );
      } else if (receivedAt.isBefore(held.firstReceivedAt)) {
        held.firstReceivedAt = receivedAt;
      }
      final fresh = !_boxHeld.containsKey(msg.id);
      _boxHeld[msg.id] = remint;
      enc.holdCalm(msg.senderId);
      if (fresh) {
        _e2eFlowLog('BOX_FOREIGN_IDENTITY_CALM', {
          'peer': msg.senderId,
          'device': msg.originDeviceId ?? 1,
        });
      }
      notifyListeners();
      return false;
    }
    if (_calmHolds.remove(msg.senderId) != null) {
      _refuseCalmDeferred(msg.senderId, enc);
    }
    return _holdForeignFrame(msg, enc, peer, remint: remint);
  }

  /// What a calm hold of [peerId] shows, or null when none waits.
  CalmHoldState? calmHoldState(int peerId) => _calmHolds[peerId]?.state;

  /// The tap on a calm hold (a person's act): confirms the waiting key from a
  /// fresh served bundle. Single flight: a second tap while it runs is
  /// ignored. Confirmed -> the held frames drain; refused -> the visible hold;
  /// transient -> the line stays and is tappable again.
  Future<void> confirmCalmHold(int peerId) async {
    final hold = _calmHolds[peerId];
    final enc = _encryptionProvider;
    if (hold == null || enc == null) return;
    if (hold.state == CalmHoldState.checking) return;
    hold.state = CalmHoldState.checking;
    notifyListeners();
    // Verified or warnings ON since the hold began: the visible hold, and
    // no request at all (a lookup spends one of the friend's pre-keys).
    if (!await enc.calmHoldEligible(peerId)) {
      if (!identical(_calmHolds[peerId], hold)) return;
      _calmHolds.remove(peerId);
      _refuseCalmDeferred(peerId, enc);
      await enc.holdForeignFrame(peerId, hold.ciphertext);
      notifyListeners();
      return;
    }
    final result = await enc.confirmCalmKey(
      peerId,
      hold.device,
      hold.identity,
      noteAtMs: hold.firstReceivedAt.millisecondsSinceEpoch - 1,
    );
    if (!identical(_calmHolds[peerId], hold)) return;
    switch (result) {
      case CalmConfirm.confirmed:
        // The hold ends, but the friend's handoff is not read yet: until it
        // is, the address is still the old queue, so sends keep waiting.
        _calmDraining.add(peerId);
        _calmHolds.remove(peerId);
      case CalmConfirm.refused:
        _calmHolds.remove(peerId);
        // The red hold takes over, and so does its refusal for what waited.
        _refuseCalmDeferred(peerId, enc);
        await enc.holdForeignFrame(peerId, hold.ciphertext);
      case CalmConfirm.transient:
        hold.state = CalmHoldState.failed;
    }
    notifyListeners();
    if (result == CalmConfirm.confirmed) {
      // The held frames are read FIRST: the friend's handoff names the queue
      // its new install reads, and a row sent before it goes to the old one.
      final before = _boxQueuesOf(peerId);
      var drained = false;
      try {
        await enc.drainReleasedFrames(peerId).timeout(calmDrainBound);
        drained = true;
      } on Object catch (e) {
        _e2eFlowLog('CALM_DRAIN_INCOMPLETE', {'peer': peerId, 'error': '$e'});
      } finally {
        _calmDraining.remove(peerId);
      }
      // Whatever happened, the rows stop waiting here.
      final rows = _takeCalmDeferred(peerId);
      // A drain that failed before the friend's handoff was read leaves the
      // send target at the OLD queue: those rows stay ordinary failed rows
      // (their own Retry), never written there on the person's behalf. A
      // drain that COMPLETED without a handoff releases them to the address
      // already known (by design: the friend sent none).
      if (!drained && setEquals(_boxQueuesOf(peerId), before)) return;
      for (final tempId in rows) {
        await retryFailedMessage(tempId);
        // In order, or not at all: a later row never goes ahead of an
        // earlier one that failed (it stays failed, with its own Retry).
        final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
        if (row?.deliveryStatus == MessageDeliveryStatus.failed) break;
      }
    }
  }

  /// The queues the box would send [peerId]'s messages to now.
  Set<String> _boxQueuesOf(int peerId) => {
    for (final to in (boxOutbox?.addressesFor(peerId) ?? const {}).values)
      to.sid,
  };

  /// What waited for [peerId]'s calm line when it turns into the visible
  /// hold: those rows read as refused for a key change (as under a red-hold
  /// refusal), and the chat names it for them ([peersRefusedIdentity]).
  void _refuseCalmDeferred(int peerId, EncryptionProvider enc) {
    final rows = _takeCalmDeferred(peerId);
    if (rows.isEmpty) return;
    _identityRefusedSendTempIds.addAll(rows);
    enc.markRefusedIdentity(peerId);
  }

  /// Removes and returns, in the order written, what was held back for
  /// [peerId]'s calm line (a row no longer loaded just stays failed).
  List<String> _takeCalmDeferred(int peerId) {
    return [
      for (final MapEntry(:key, :value) in _calmDeferredSends.entries)
        if (value == peerId) key,
    ]..forEach(_calmDeferredSends.remove);
  }

  /// Holds friend frame [msg] (a PreKey message under a foreign identity)
  /// until the user decides (plan B3, decision 143): returns false, so the
  /// journal row stays unconsumed — it is acked already, never pruned
  /// unconsumed, and not bound by [kBoxRedeliveryWindow] — and the next
  /// offer (a connect, E2E ready, or the accept) judges it again. Returns at
  /// once: nothing here waits for the user, so no read queued behind it
  /// stalls. A peer this account no longer calls a friend has its frame
  /// finished (unfriend and block discard what was held).
  Future<bool> _holdForeignFrame(
    MessageModel msg,
    EncryptionProvider enc,
    ContactRecord? peer, {
    required bool remint,
  }) async {
    if (peer != null && peer.state != ContactState.friend) {
      return _dropHeld(msg);
    }
    await enc.holdForeignFrame(msg.senderId, msg.encryptedContent!);
    final fresh = !_boxHeld.containsKey(msg.id);
    _boxHeld[msg.id] = remint;
    if (fresh) _logBoxHeld(msg);
    return false;
  }

  Future<bool> _holdBehindForeignFrame(
    MessageModel msg,
    ContactRecord? peer,
  ) async {
    if (peer != null && peer.state != ContactState.friend) {
      return _dropHeld(msg);
    }
    if (!_boxHeld.containsKey(msg.id)) {
      _boxHeld[msg.id] = false;
      _logBoxHeld(msg);
    }
    return false;
  }

  bool _dropHeld(MessageModel msg) {
    _boxHeld.remove(msg.id);
    _clearCalmHold(msg.senderId);
    _e2eFlowLog('BOX_HELD_DISCARDED', {
      'peer': msg.senderId,
      'device': msg.originDeviceId ?? 1,
    });
    return true;
  }

  /// The friendship with [peerId] ended (unfriend, block, their goodbye): a
  /// calm line and the marks that keep its frames held go with it.
  void _clearCalmHold(int peerId) {
    if (_calmHolds.remove(peerId) != null) {
      _takeCalmDeferred(peerId); // stay failed, with their own Retry
      _encryptionProvider?.releaseCalm(peerId);
      notifyListeners();
    }
  }

  /// Called when [peerId] stops being a friend.
  void onFriendshipEnded(int peerId) => _clearCalmHold(peerId);

  /// Once per held frame per run (the caller's `_boxHeld` mark): peer and
  /// device only, never key material or content.
  void _logBoxHeld(MessageModel msg) {
    _e2eFlowLog('BOX_FOREIGN_IDENTITY_HELD', {
      'peer': msg.senderId,
      'device': msg.originDeviceId ?? 1,
    });
  }
}

/// The line a calm hold shows ([MessagingBox.calmHoldState]).
enum CalmHoldState { waiting, checking, failed }

/// One friend's calm hold: the key its held frames claim, the device that sent
/// the first, when the first arrived (the note is stamped just before it) and
/// a ciphertext to turn into the visible hold when the key is refused.
class CalmHold {
  CalmHold({
    required this.identity,
    required this.device,
    required this.firstReceivedAt,
    required this.ciphertext,
    required this.state,
  });

  final String identity;
  final int device;
  DateTime firstReceivedAt;
  final String ciphertext;
  CalmHoldState state;
}
