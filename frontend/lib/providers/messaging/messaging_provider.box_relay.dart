part of '../messaging_provider.dart';

/// Multi-device while a linked device is offline (owner decision 101 A): a
/// friend's box message needs an address for at least ONE live device of
/// ours that relays (`rl`), and every device of ours it was addressed to
/// forwards it — `t: 'relay'`, quiet, through the sibling's self-queue —
/// to each live sibling the friend could not address (the envelope's `ad`).
/// The sibling reads it as if from the friend: dedup by `(sender, wireId)`
/// against a direct copy, the sender rules of E19b with the friend as the
/// authenticated sender, E19k parking. A relayed frame is never relayed
/// again.
extension MessagingBoxRelay on MessagingProvider {
  /// An authenticated frame from friend [user]'s [device] carried `rl`: it
  /// relays, so a message addressed to it covers its siblings. Kept on that
  /// device's address once ([BoxFriendLink.friendRelays]); never awaited by
  /// the read.
  void _noteFriendRelays(int user, int device) {
    final link = boxFriends;
    if (link == null) return;
    final held = link
        .contactOf(user)
        ?.outbound
        .where((o) => o.peerDeviceId == device)
        .firstOrNull;
    if (held?.relays ?? false) return;
    link.friendRelays(user, device).ignore();
  }

  /// [_noteFriendRelays] for a frame read outside [MessagingBox._readBox]
  /// (a handoff on our request queue), whose envelope is not parsed yet.
  void _noteFriendRelaysIn(int user, int device, String plaintext) {
    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(plaintext);
    } on Object {
      return;
    }
    if (parsed.relays) _noteFriendRelays(user, device);
  }

  /// Friend [msg]'s action [plaintext] ([parsed]) was read and taken here:
  /// relayed like a message ([_relayFriendFrame]) unless it was not the
  /// friend's to take — an edit or delete of someone else's message (E19b)
  /// — or is not an action at all.
  void _relayFriendAction(
    MessageModel msg,
    E2eEnvelopeFields parsed,
    String plaintext,
  ) {
    if (parsed.addressed == null) return;
    final action = E2eEnvelope.parseAction(plaintext);
    if (action == null) return;
    final senderOnly =
        action.type == E2eEnvelope.typeEdit ||
        action.type == E2eEnvelope.typeDelete;
    if (senderOnly && action.targetSender != msg.senderId) return;
    _relayFriendFrame(msg, parsed, plaintext);
  }

  /// Friend [msg]'s message or action [plaintext] ([parsed]), read here
  /// for the first time: when its `ad` says some device of ours was not
  /// addressed, it goes to every LIVE sibling of the own verified list
  /// (never this device) missing from `ad` that has a self-queue address.
  /// Best effort and off the read: nothing here fails it.
  void _relayFriendFrame(
    MessageModel msg,
    E2eEnvelopeFields parsed,
    String plaintext,
  ) {
    final addressed = parsed.addressed;
    final enc = _encryptionProvider;
    final own = _currentUserId;
    final outbox = boxOutbox;
    if (addressed == null || enc == null || own == null || outbox == null) {
      return;
    }
    final friend = msg.senderId;
    // The list held: a lookup timed by a box frame would tell the server
    // when this account reads (E50f).
    final ownList = enc.cachedDeviceList(own);
    if (ownList == null) {
      _e2eFlowLog('BOX_RELAY_SKIPPED', {'peer': friend, 'why': 'no_own_list'});
      return;
    }
    final selfQueues = outbox.siblingAddresses();
    final missing = [
      for (final d in ownList.liveDeviceIds)
        if (d != enc.ownDeviceId && !addressed.contains(d)) d,
    ];
    final targets = [for (final d in missing) ?selfQueues[d]];
    if (targets.length != missing.length) {
      _e2eFlowLog('BOX_RELAY_SKIPPED', {
        'peer': friend,
        'why': 'no_self_queue',
        'devices': missing.length - targets.length,
      });
    }
    if (targets.isEmpty) return;
    final json = E2eEnvelope.buildRelay(
      user: friend,
      device: msg.originDeviceId ?? 1,
      envelope: plaintext,
    );
    _sendRelays(own, friend, targets, json).ignore();
  }

  /// Seals [json] for each sibling in [targets] and hands it to its
  /// self-queue, quiet (decision 91: a relay never wakes our closed
  /// device). Like a send, it never fetches a pre-key bundle (E38b) and
  /// never seals to a paused device (E93a): every seal moves that device's
  /// chain, and an offline sibling's full queue would otherwise take one
  /// step per friend message.
  Future<void> _sendRelays(
    int own,
    int friend,
    List<ContactOutbound> targets,
    String json,
  ) async {
    final enc = _encryptionProvider;
    final outbox = boxOutbox;
    if (enc == null || outbox == null) return;
    void failed(int device, String why) =>
        E2ePersistentDiag.record('BOX_RELAY_FAILED', {
          'peer': friend,
          'device': device,
          'why': why,
        });
    try {
      final frames = <(ContactOutbound, Uint8List)>[];
      for (final to in targets) {
        final device = to.peerDeviceId;
        if (!await _hasUsableBoxSession(enc, own, device)) {
          failed(device, 'no_session');
          continue;
        }
        if (!_boxPaused.admit(own, device)) {
          _e2eFlowLog('BOX_RELAY_SKIPPED', {
            'peer': friend,
            'device': device,
            'why': 'paused',
          });
          continue;
        }
        final frame = await encryptForOwnDevice(device, json);
        if (frame == null) {
          failed(device, 'encrypt');
        } else if (frame.signal.length > BoxFrame.maxSignalBytes) {
          failed(device, 'too_long');
        } else {
          frames.add((to, frame.encode()));
        }
      }
      if (frames.isEmpty) return;
      final answers = await Future.wait([
        for (final (to, body) in frames)
          outbox
              .deliver(to, body, mode: BoxSendMode.quiet)
              .catchError((Object _) => BoxSendOutcome.failed),
      ]);
      _noteBoxAnswers(own, frames, answers, peerFrames: 0);
      for (var i = 0; i < answers.length; i++) {
        final device = frames[i].$1.peerDeviceId;
        _e2eFlowLog('BOX_RELAY_SENT', {
          'peer': friend,
          'device': device,
          'outcome': answers[i].name,
        });
        if (answers[i] == BoxSendOutcome.failed) failed(device, 'deliver');
      }
    } on Object catch (e) {
      _e2eFlowLog('BOX_RELAY_FAILED', {
        'peer': friend,
        'error': e.runtimeType.toString(),
      });
    }
  }

  /// A friend's message or action sibling [msg]'s device read and relayed
  /// to us ([plaintext], the `relay` envelope; only from our self-queue,
  /// checked by the caller). Read as if it came from the friend `u` on its
  /// device `d`, serialized with that friend's own reads so a direct copy
  /// read at the same time dedups by `(u, wireId)`. Same finishing contract
  /// as [MessagingBox.consumeBoxEntry]: refused for good is finished; a
  /// friend whose chat this device has not linked yet is held while the box
  /// could still redeliver it, as a sent copy is.
  Future<bool> _takeRelayed(
    BoxSiblingLink link,
    MessageModel msg,
    String plaintext,
  ) async {
    void refused(String why, [int? peer]) => _e2eFlowLog('BOX_RELAY_REFUSED', {
      'device': msg.originDeviceId,
      'peer': ?peer,
      'why': why,
    });
    final relay = E2eEnvelope.parseRelay(plaintext);
    if (relay == null) {
      refused('unreadable');
      return true;
    }
    final user = relay.user;
    if (user == msg.senderId) {
      refused('own_account', user);
      return true;
    }
    final peer = link.contactOf(user);
    if (peer == null || peer.state != ContactState.friend) {
      refused(peer?.state.name ?? 'no_contact', user);
      return true;
    }
    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(relay.envelope);
    } on Object {
      refused('unreadable', user);
      return true;
    }
    // A message or an action only; a relay inside a relay is never read.
    final action = E2eEnvelope.actionTypes.contains(parsed.type);
    if (!action && parsed.type != E2eEnvelope.typeMessage) {
      refused('type_${parsed.type}', user);
      return true;
    }
    final conversationId = MessagingFirstContact._boxChatOf(peer);
    if (conversationId == null) {
      if (DateTime.now().toUtc().difference(msg.createdAt) >
          kBoxRedeliveryWindow) {
        refused('expired', user);
        return true;
      }
      _e2eFlowLog('BOX_RELAY_WAITING', {'peer': user});
      return false;
    }
    return _runDecryptSerialized(
      user,
      () => _readRelayed(
        msg,
        parsed,
        relay.envelope,
        peer: peer,
        device: relay.device,
        conversationId: conversationId,
        action: action,
      ),
    );
  }

  /// [_takeRelayed]'s read, on the friend's decrypt chain: the paths a
  /// frame from [peer]'s [device] takes in [MessagingBox._readBox], under
  /// this delivery's local id ([msg]).
  Future<bool> _readRelayed(
    MessageModel msg,
    E2eEnvelopeFields parsed,
    String envelope, {
    required ContactRecord peer,
    required int device,
    required int conversationId,
    required bool action,
  }) async {
    final receivedAt = msg.createdAt;
    final user = peer.userId;
    // Read and shown earlier, its record never committed: only the store
    // is owed.
    final unsaved = _boxUnsaved[msg.id];
    if (unsaved != null && unsaved.senderId == user) {
      return _storeBoxMessage(
        unsaved,
        alreadyShown: true,
        receivedAt: receivedAt,
      );
    }
    final enc = _encryptionProvider;
    if (enc == null) return false;
    if (await enc.recordExists(msg.id) == true) return true;
    if (action) {
      return _takeBoxAction(
        parsed,
        envelope,
        actor: user,
        peer: user,
        conversationId: conversationId,
        receivedAt: receivedAt,
      );
    }
    // Decision 13: the sender's clock, never past our own receive time.
    final sentAt = parsed.sentAt;
    final row = MessageModel(
      id: msg.id,
      content: '',
      senderId: user,
      senderUsername: peer.username,
      conversationId: conversationId,
      createdAt: sentAt == null || sentAt.isAfter(receivedAt)
          ? receivedAt
          : sentAt,
      encryptedContent: msg.encryptedContent,
      originDeviceId: device,
      deliveryStatus: MessageDeliveryStatus.delivered,
    );
    return _consumeBoxMessage(
      await _withBoxExtras(_withEnvelope(row, parsed, box: true), parsed),
      receivedAt: receivedAt,
    );
  }
}
