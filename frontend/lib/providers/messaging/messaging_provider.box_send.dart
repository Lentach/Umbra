part of '../messaging_provider.dart';

/// A box send's plan (slice (c)): one address per live peer device that
/// has one, and — sibling queues part B — one self-queue per live other
/// device of ours. `addressed` names the peer devices addressed when some
/// live one was not (decision 101 A: the envelope's `ad`, so they relay it
/// to the rest); null when every live device was, and for receipts and
/// typing, which are never relayed.
typedef _BoxRoute = ({
  BoxOutbox outbox,
  List<ContactOutbound> targets,
  List<ContactOutbound> siblings,
  int conversationId,
  SenderListInfo senderListInfo,
  List<int>? addressed,
});

/// Decision 16's peer rule: a verified list naming [live] devices is
/// box-covered when it names one and every one of them has an address in
/// [addresses].
bool _everyLiveAddressed(
  List<int> live,
  Map<int, ContactOutbound> addresses,
) => live.isNotEmpty && live.every(addresses.containsKey);

/// The peer half of `_boxRoute`'s rule (decision 16 as amended by 101 A):
/// every live device has an address, or at least one addressed live device
/// relays (`rl`, [ContactOutbound.relays]) — it forwards the message to the
/// devices the sender could not address.
bool _boxCoversLive(List<int> live, Map<int, ContactOutbound> addresses) =>
    _everyLiveAddressed(live, addresses) ||
    live.any((d) => addresses[d]?.relays ?? false);

/// Why a box send could not build its frames ([MessagingBoxSend._sealBoxFrames]).
enum _BoxSealFailure { noSession, tooLong, calmHeld }

/// The box send, out of [MessagingBox]: [_boxRoute] decides whether a
/// message goes over the box at all, [_sendOverBox] sends it — sessions
/// pre-built, every frame sealed before the first goes out.
extension MessagingBoxSend on MessagingProvider {
  /// Where a message to [recipientId] goes over the box (slice (c), decision
  /// 16 as amended by 101 A): only when the peer is covered — EVERY live
  /// device of it has a box address, or at least one does and some
  /// addressed live device relays ([_boxCoversLive]) — and every live
  /// OTHER device of ours has a self-queue address (sibling queues part B,
  /// E5): one message is never split. Frames go to the addressed
  /// live devices only; when some live one is not, the route's `addressed`
  /// names them, so they relay to the rest. Null = no route, and ONLY
  /// on evidence: a verified list naming a device with no address; the
  /// caller then fails the row (the box is the only path).
  /// A list that cannot be verified THROWS (the caller fails the row for a
  /// retry).
  ///
  /// [addresses] is the outbox's answer for the peer, taken by the caller
  /// WITHOUT an await: a peer with none has no route at all.
  ///
  /// Both lists come from the verified cache: the box has no
  /// server bounce to catch a device we did not know about. Both are the
  /// ones THIS connect verified ([refreshBoxDeviceLists], decision 21); a
  /// send never looks one up, which would hand the server the pair (the
  /// peer's list) or the sender (the own list) at the time of the message.
  ///
  /// [peerOnly] (receipts and typing, slice (g), E61b): the peer half alone
  /// — no sent copy goes to our siblings, so their coverage is not asked
  /// and the route names none.
  ///
  /// Coverage is judged on every live device; the route then leaves out a
  /// device whose queue is full (E93a, [BoxDevicePause]) unless its probe is
  /// due. It may name no peer device at all: a new send then fails before
  /// anything is sealed ([MessagingBoxSend._peersAllPaused]), since a seal to a
  /// full queue moves that device's chain for nothing.
  Future<_BoxRoute?> _boxRoute(
    int recipientId,
    BoxOutbox outbox,
    Map<int, ContactOutbound> addresses, {
    bool peerOnly = false,
  }) async {
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
      if (!peerOnly)
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
    if (!_boxCoversLive(live, addresses)) {
      declined('peer_uncovered');
      return null;
    }
    final everyTarget = [for (final d in live) ?addresses[d]];
    final addressed = peerOnly || everyTarget.length == live.length
        ? null
        : [for (final t in everyTarget) t.peerDeviceId];
    final targets = [
      for (final t in everyTarget)
        if (peerOnly
            ? !_boxPaused.isPaused(recipientId, t.peerDeviceId)
            : _boxPaused.admit(recipientId, t.peerDeviceId))
          t,
    ];
    // No peer device to send to: nothing is sealed, so no sibling's probe
    // may be spent on it either.
    final none = targets.isEmpty;
    return (
      outbox: outbox,
      targets: targets,
      siblings: [
        for (final s in siblings)
          if (none
              ? !_boxPaused.isPaused(ownUserId, s.peerDeviceId)
              : _boxPaused.admit(ownUserId, s.peerDeviceId))
            s,
      ],
      conversationId: conversationId,
      senderListInfo: SenderListInfo(
        ownVersion: own.version,
        ownListHash: own.listHash,
        peerVersion: peer.version,
        peerListHash: peer.listHash,
      ),
      addressed: addressed,
    );
  }

  /// Whether [peerUserId] is a friend made over the box (owner decision
  /// 52): the server does not know the pair, so no request naming it
  /// (`requestSessionRebuild`) is ever made for it.
  bool _boxOnlyPeer(int peerUserId) =>
      boxFriends?.contactOf(peerUserId)?.boxOrigin != null ||
      _conversationsProvider?.getConversationById(
            localConversationIdFor(peerUserId),
          ) !=
          null;

  /// The session pre-build for [user] (decision 38, E38a), run by the box
  /// list refresh right after it verified [user]'s list — at a connect, a
  /// list change or a backoff retry, never at a send: every box-covered
  /// live device on that list with no usable session gets
  /// [EncryptionProvider.ensureSession], which fetches its pre-key bundle.
  /// Box-covered means a peer device the contact record holds an address
  /// for or, for our own account, a sibling with a self-queue address; this
  /// device is never one. One device at a time; every device is tried, then
  /// the first failure is rethrown so the refresh retries on its backoff.
  Future<void> _prebuildBoxSessions(int user) async {
    final enc = _encryptionProvider;
    final outbox = boxOutbox;
    final own = _currentUserId;
    if (enc == null || outbox == null || own == null) return;
    final list = enc.cachedDeviceList(user);
    // Dropped since the lookup: the invalidation started the next pass.
    if (list == null) throw StateError('device list dropped');
    final addressed = user == own
        ? outbox.siblingAddresses()
        : outbox.addressesFor(user);
    (Object, StackTrace)? failure;
    for (final device in list.liveDeviceIds) {
      if (user == own && device == enc.ownDeviceId) continue;
      if (!addressed.containsKey(device)) continue;
      if (await _hasUsableBoxSession(enc, user, device)) continue;
      _e2eFlowLog('BOX_SESSION_PREBUILD', {'userId': user, 'device': device});
      try {
        await enc.ensureSession(user, deviceId: device);
      } on Object catch (e, st) {
        _e2eFlowLog('BOX_SESSION_PREBUILD_FAILED', {
          'userId': user,
          'device': device,
          'error': e.runtimeType.toString(),
        });
        failure ??= (e, st);
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  /// Whether a box send may encrypt to [user]'s [device] as things stand: a
  /// session is held and no rebuild of it is pending. A box send never
  /// builds one (E38b).
  Future<bool> _hasUsableBoxSession(
    EncryptionProvider enc,
    int user,
    int device,
  ) async =>
      !enc.needsSessionRebuild(user, deviceId: device) &&
      await enc.hasSessionWith(user, deviceId: device);

  /// The quote a box reply carries (E18a), from the reply's preview: the
  /// quoted message's wire id and sender, its type, and — for a text — the
  /// preview's words as the snippet (`E2eEnvelope.build` cuts it to 256
  /// bytes). No words of a message that itself disappears: the reply would
  /// keep them for its own lifetime. Null when there is no preview, or it
  /// names no sender (a server snapshot's): the box could not name what it
  /// quotes.
  E2eReplyQuote? _boxQuoteOf(ReplyToPreview? replyTo) {
    final senderId = replyTo?.senderId;
    if (replyTo == null || senderId == null) return null;
    final words =
        replyTo.messageType == MessageType.text &&
        !replyTo.quotedDisappears &&
        !isEncryptedPreviewContent(
          replyTo.content,
          encryptedMessageLabel: kReplyPreviewLabels.encryptedMessageLabel,
        );
    return (
      wireId: replyTo.wireId,
      senderId: senderId,
      type: replyTo.messageType.name.toUpperCase(),
      snippet: words ? replyTo.content : '',
    );
  }

  /// Sends [content] along [route]: one Signal message per peer device, each
  /// sealed into that device's queue, and a SENT COPY — the same message
  /// naming the peer inside E2E (E5) — per sibling, sealed into its
  /// self-queue. Both carry the message's type, its own timer [ttl] and the
  /// quote of a reply's [replyTo] (item 3). The row is SENT once at least
  /// one PEER device's box took its frame (decision 93, E93a): our sent
  /// copies never decide it, and neither does a friend device that refused
  /// while another took it. A device whose answer was no answer or another
  /// transient refusal is owed the same frames by the in-RAM retry (E19l's,
  /// [_oweBoxFrames]); a device whose queue is full is paused instead
  /// ([BoxDevicePause]) and misses this one. No peer device taking it fails
  /// the row for a retry (decision 19), which re-seals under the same wire
  /// id, so a device that already holds the message drops the copy
  /// (`wireHeldByOther`). Every frame is built before the first goes out, so
  /// a seal that fails sends nothing at all. A device with no usable session
  /// fails the row before anything is encrypted, and nothing here fetches a
  /// pre-key bundle: a fetch timed by the send would name the sender at the
  /// moment of the box frame (decision 38, E38b); the refresh's next pass
  /// builds it.
  ///
  /// While it runs, the tempId is in [_boxInFlight]: an account-socket error
  /// cannot fail the row under it and a retry cannot start a second attempt
  /// (each would take its own local id and store a second copy). It joins
  /// [_boxTempIds] only just before the first frame goes out — the first
  /// moment a device may hold the message.
  ///
  /// An attachment (item 3 / media wiring) is already uploaded: [mediaUrl]
  /// is its `box:<id>`, and the frames carry the id with its key and
  /// metadata — the SAME id in the peer frames and every sent copy
  /// (decision 44).
  Future<bool> _sendOverBox(
    _BoxRoute route, {
    required int recipientId,
    required String content,
    required String tempId,
    required String sendToken,
    Map<String, String?>? linkPreview,
    String messageType = 'TEXT',
    int? ttl,
    ReplyToPreview? replyTo,
    String? mediaUrl,
    String? mediaKey,
    String? mediaIv,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
  }) async {
    _boxInFlight.add(tempId);
    try {
      if (_peersAllPaused(route, recipientId, tempId)) return false;
      final enc = _encryptionProvider!;
      // Whole ms: the envelope's `ts` and the stored `createdAt` must agree.
      final sentAt = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      );
      final quote = _boxQuoteOf(replyTo);
      final envelope = boxEnvelope(
        content,
        linkPreview: linkPreview,
        messageType: messageType,
        ttl: ttl,
        replyQuote: quote,
        senderListInfo: route.senderListInfo.toJson(),
        msgId: sendToken,
        sentAt: sentAt,
        sentTo: recipientId,
        boxMedia: mediaUrl?.substring(kBoxMediaUrlPrefix.length),
        mediaKey: mediaKey,
        mediaIv: mediaIv,
        mediaDuration: mediaDuration,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        mediaThumbHash: mediaThumbHash,
      );
      final ownUserId = _currentUserId!;
      final sealed = await _sealBoxFrames(
        route,
        recipientId: recipientId,
        json: envelope.json,
        copyJson: envelope.copyJson,
      );
      switch (sealed.failure) {
        case _BoxSealFailure.noSession:
          _e2eFlowLog('BOX_SEND_NO_SESSION', {
            'tempId': tempId,
            ...sealed.detail,
          });
          _markMessageFailed(tempId, 'Could not send. Try again.');
          return false;
        case _BoxSealFailure.calmHeld:
          _deferForCalmHold(recipientId, tempId);
          return false;
        case _BoxSealFailure.tooLong:
          _e2eFlowLog('BOX_SEND_TOO_LONG', {
            'tempId': tempId,
            ...sealed.detail,
          });
          _markMessageFailed(tempId, 'Message is too long to send.');
          return false;
        case null:
          break;
      }
      final frames = sealed.frames;
      final localId = await route.outbox.nextLocalId();
      if (localId == null) {
        _e2eFlowLog('BOX_SEND_NO_LOCAL_ID', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      _boxTempIds.add(tempId);
      final peerFrames = route.targets.length;
      final answers = await _deliverBoxFrames(
        route.outbox,
        recipientId,
        frames,
        peerFrames: peerFrames,
        message: true,
      );
      final owedPeers = <int>{};
      final owedSiblings = <int>{};
      var peerTaken = 0;
      for (var i = 0; i < answers.length; i++) {
        final peerFrame = i < peerFrames;
        if (answers[i] == BoxSendOutcome.taken && peerFrame) peerTaken++;
        if (answers[i] != BoxSendOutcome.failed) continue;
        (peerFrame ? owedPeers : owedSiblings).add(frames[i].$1.peerDeviceId);
      }
      _e2eFlowLog('BOX_SEND', {
        'tempId': tempId,
        'frames': frames.length,
        'accepted': answers.where((a) => a == BoxSendOutcome.taken).length,
        'peerTaken': peerTaken,
        'full': answers.where((a) => a == BoxSendOutcome.full).length,
      });
      if (peerTaken == 0) {
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      // Signed out, or switched to another account, while the frames were in
      // flight: local ids restart at the same base per account, so nothing of
      // this send may land in the next session's rows, cache or retries.
      if (_currentUserId != ownUserId) return true;
      if (owedPeers.isNotEmpty || owedSiblings.isNotEmpty) {
        _oweBoxFrames(
          'msg|${route.conversationId}|$sendToken',
          seq: ++_boxActionSendSeq,
          peer: recipientId,
          message: true,
          json: envelope.json,
          copyJson: envelope.copyJson,
          peerDevices: owedPeers,
          siblings: owedSiblings,
        );
      }
      final preview = envelope.linkPreview;
      // Status is the model's default, `sent`: a peer device took it.
      final sent = MessageModel(
        id: localId,
        content: content,
        senderId: ownUserId,
        senderUsername: '',
        conversationId: route.conversationId,
        createdAt: sentAt,
        messageType: _parseMessageTypeString(messageType) ?? MessageType.text,
        mediaUrl: mediaUrl,
        mediaKey: mediaKey,
        mediaIv: mediaIv,
        mediaDuration: mediaDuration,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        mediaThumbHash: mediaThumbHash,
        // Decision 41: the sender's copy counts from the send.
        disappearAfterSeconds: ttl,
        expiresAt: ttl == null ? null : sentAt.add(Duration(seconds: ttl)),
        tempId: tempId,
        wireId: sendToken,
        // The quote the wire carried (E18a): no words of a message that
        // itself disappears, in RAM or in the record.
        replyTo: replyTo != null && replyTo.quotedDisappears
            ? ReplyToPreview(
                id: replyTo.id,
                content: '',
                senderUsername: replyTo.senderUsername,
                messageType: replyTo.messageType,
                wireId: replyTo.wireId,
                senderId: replyTo.senderId,
                quotedDisappears: true,
              )
            : replyTo,
        linkPreviewUrl: preview?['url'],
        linkPreviewTitle: preview?['title'],
        linkPreviewImage: preview?['img'],
      );
      enc.cacheDecryption(localId, sent);
      await _persistDecryptedContent(sent);
      if (await enc.recordExists(localId) == true) {
        // A peer device took it and our copy is stored: no longer a message
        // that did not go out (decision 104).
        _boxUnsentTempIds.remove(tempId);
        await enc.dropBoxUnsent(ownUserId, tempId);
      } else {
        // Shown from RAM this session. The kept copy stays, so after a
        // restart it comes back red; its retry reuses the wire id and the
        // peer drops the repeat (decision 104).
        E2ePersistentDiag.record('BOX_SENT_STORE_UNPROVEN', {'msgId': localId});
      }
      // Another account signed in while the record was being stored.
      if (_currentUserId != ownUserId) return true;
      _addMessageToState(sent);
      // As a received message does ([_showBoxMessage]): a warm cache of the
      // chat on screen takes the sent row, or a resume (`loadCachedMessages`)
      // would drop the bubble until the records are read again, and close
      // the fullscreen player of a clip just sent.
      final viewing = _effectiveActiveConversationId ?? _openConversationId;
      if (sent.conversationId == viewing &&
          _conversationCache.containsKey(sent.conversationId)) {
        _updateCache(sent.conversationId);
      }
      return true;
    } finally {
      _boxInFlight.remove(tempId);
    }
  }

  /// Every frame of one box send along [route], built before the first goes
  /// out: [json] as its own Signal message per peer device — saying this
  /// device relays, and naming the route's `addressed` devices when some
  /// live one was not (decision 101 A) — [copyJson] per sibling, as it is.
  /// A device with no usable session fails it before anything is
  /// encrypted — a box send never fetches a pre-key bundle (decision 38,
  /// E38b) — and a Signal message over one frame fails it whole
  /// ([BoxFrame.maxSignalBytes]). `detail` names what failed, for the log.
  Future<
    ({
      List<(ContactOutbound, Uint8List)> frames,
      _BoxSealFailure? failure,
      Map<String, Object> detail,
    })
  >
  _sealBoxFrames(
    _BoxRoute route, {
    required int recipientId,
    required String json,
    required String copyJson,
  }) async {
    final enc = _encryptionProvider!;
    final ownUserId = _currentUserId!;
    final frames = <(ContactOutbound, Uint8List)>[];
    // A calm hold waits for the person's tap (option C): the session held
    // for this friend belongs to the key being replaced, so nothing is
    // sealed on it, be it a message, an action, a receipt or typing.
    if (_calmWaits(recipientId)) {
      return (
        frames: frames,
        failure: _BoxSealFailure.calmHeld,
        detail: {'peer': recipientId},
      );
    }
    final peerJson = E2eEnvelope.toFriend(
      json,
      relays: _vouchesRelay,
      addressed: route.addressed,
    );
    final sends = [
      for (final to in route.targets) (recipientId, to, peerJson),
      for (final to in route.siblings) (ownUserId, to, copyJson),
    ];
    for (final (userId, to, _) in sends) {
      if (await _hasUsableBoxSession(enc, userId, to.peerDeviceId)) continue;
      return (
        frames: frames,
        failure: _BoxSealFailure.noSession,
        detail: {'userId': userId, 'device': to.peerDeviceId},
      );
    }
    for (final (userId, to, body) in sends) {
      final frame = BoxFrame.fromSignalCiphertext(
        await enc.encrypt(userId, body, deviceId: to.peerDeviceId),
        senderDeviceId: enc.ownDeviceId,
      );
      if (frame == null) throw StateError('encrypt gave no Signal message');
      if (frame.signal.length > BoxFrame.maxSignalBytes) {
        return (
          frames: frames,
          failure: _BoxSealFailure.tooLong,
          detail: {'bytes': frame.signal.length},
        );
      }
      frames.add((to, frame.encode()));
    }
    return (frames: frames, failure: null, detail: const <String, Object>{});
  }

  /// Sends [frames] — the first [peerFrames] to [peer]'s devices, the rest
  /// our own siblings', as [_sealBoxFrames] builds them — all at once, each
  /// kept as [_boxFrameMode] says for a [message] or an action, and applies
  /// the answers to the pause ([_noteBoxAnswers]). A delivery that threw is
  /// a frame not taken, as `deliver` answers a failed seal: the frames other
  /// devices took still stand (E19l). The answers, in [frames]' order.
  Future<List<BoxSendOutcome>> _deliverBoxFrames(
    BoxOutbox outbox,
    int peer,
    List<(ContactOutbound, Uint8List)> frames, {
    required int peerFrames,
    required bool message,
  }) async {
    final answers = await Future.wait([
      for (var i = 0; i < frames.length; i++)
        outbox
            .deliver(
              frames[i].$1,
              frames[i].$2,
              mode: _boxFrameMode(message: message, toPeer: i < peerFrames),
            )
            .catchError((Object _) => BoxSendOutcome.failed),
    ]);
    _noteBoxAnswers(peer, frames, answers, peerFrames: peerFrames);
    return answers;
  }

  /// What the box answered each of [frames] — the first [peerFrames] to
  /// [peer]'s devices, the rest our own siblings', as [_sealBoxFrames]
  /// builds them — applied to the pause (E93a): a full queue pauses its
  /// device, a frame taken ends its pause.
  void _noteBoxAnswers(
    int peer,
    List<(ContactOutbound, Uint8List)> frames,
    List<BoxSendOutcome> answers, {
    required int peerFrames,
  }) {
    final own = _currentUserId;
    for (var i = 0; i < answers.length; i++) {
      final user = i < peerFrames ? peer : own;
      if (user == null) continue;
      _noteBoxAnswer(user, frames[i].$1.peerDeviceId, answers[i]);
    }
  }

  /// What the box answered one frame sealed to [device] of [user],
  /// applied to the pause (E93a).
  void _noteBoxAnswer(int user, int device, BoxSendOutcome answer) {
    switch (answer) {
      case BoxSendOutcome.taken:
        if (_boxPaused.resume(user, device)) {
          _e2eFlowLog('BOX_DEVICE_RESUMED', {
            'user': user,
            'device': device,
            'by': 'taken',
          });
        }
      case BoxSendOutcome.full:
        if (_boxPaused.full(user, device)) {
          _e2eFlowLog('BOX_DEVICE_FULL', {'user': user, 'device': device});
        }
      case BoxSendOutcome.failed:
        break;
    }
  }

  /// Whether [route] names no device of [peer]: every one is paused with
  /// its probe not yet due (E93a). Then [tempId] fails for a retry with
  /// nothing sealed — the box would refuse it, and the seal alone moves each
  /// device's chain — and never takes the old path (decision 15). A retry
  /// once a probe is due goes to that device.
  bool _peersAllPaused(_BoxRoute route, int peer, String tempId) {
    if (route.targets.isNotEmpty) return false;
    _e2eFlowLog('BOX_SEND_PEERS_FULL', {'tempId': tempId, 'peer': peer});
    _markMessageFailed(tempId, 'Could not send. Try again.');
    return true;
  }

  /// [tempId] waits for the tap on [peer]'s calm line: nothing was sealed or
  /// uploaded for it. The row fails for now, says why
  /// ([MessagingProvider.sendWaitsForCalmHold]) and is sent by
  /// [MessagingBox.confirmCalmHold] once the key is confirmed.
  void _deferForCalmHold(int peer, String tempId) {
    _calmDeferredSends[tempId] = peer;
    _e2eFlowLog('BOX_SEND_CALM_HELD', {'tempId': tempId, 'peer': peer});
    _markMessageFailed(tempId, 'Could not send. Try again.');
  }
}
