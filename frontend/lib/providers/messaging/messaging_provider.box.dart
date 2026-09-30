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

/// The peer half of `_boxRoute`'s rule: a verified list naming [live]
/// devices is box-covered when it names one and every one of them has an
/// address in [addresses].
bool _everyLiveAddressed(
  List<int> live,
  Map<int, ContactOutbound> addresses,
) => live.isNotEmpty && live.every(addresses.containsKey);

/// A box attachment encrypted but not yet uploaded (item 3 / media wiring,
/// E17b), with the plaintext `recording` a voice note was read from: the
/// upload that succeeds deletes it, whichever attempt that is.
typedef _BoxMediaBody = ({
  Uint8List ciphertext,
  String key,
  String iv,
  String? recording,
});

/// A box message's quote and timer, read from its row when the send
/// started: an attachment's row may leave `_messages` during its upload
/// (the user opens another chat), and its frames must still quote and time
/// it (E18a/E18b).
typedef _BoxRowAtSend = ({ReplyToPreview? replyTo, int? ttl});

/// Why a box send could not build its frames ([MessagingBox._sealBoxFrames]).
enum _BoxSealFailure { noSession, tooLong }

/// The payload key of a box message's record holding when its countdown
/// started, whole ms (item 3, decision 41): the send for our own copies,
/// the first time this device showed it for a received one. Absent = not
/// started, so only the 1-day unread cap runs.
const String _boxCountdownFromKey = 'ttlFrom';

/// The payload key of a box message's record holding its tick (slice (g)):
/// OUR message's `delivered` or `read`, as a peer's receipt moved it (E61f;
/// absent = sent); a PEER's `read` once this device's read receipt was
/// taken (E61d; absent = delivered).
const String _boxTickKey = 'tick';

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
  }) async {
    final finished = await _readBox(
      msg,
      receivedAt,
      controlOnly: controlOnly,
    );
    if (finished) await _encryptionProvider?.removeRawReplay(msg.id);
    return finished;
  }

  /// Reads a friend's frame from our public request queue (item 5, E20c):
  /// only its `queue_handoff` is taken. Same finishing contract as
  /// [_consumeBox]; everything refused here is FINISHED, because anyone can
  /// fill a request queue and a real friend hands off again on its next
  /// connect.
  Future<bool> _consumeFriendRequest(
    BoxInboxEntry entry,
    String signal,
    ContactRecord? peer,
  ) async {
    final finished = await _readFriendRequest(entry, signal, peer);
    if (finished) await _encryptionProvider?.removeRawReplay(entry.localId);
    return finished;
  }

  Future<bool> _readFriendRequest(
    BoxInboxEntry entry,
    String signal,
    ContactRecord? peer,
  ) async {
    // A first contact's request carries its claim outside Signal (E15c).
    if (entry.carriedClaim != null) {
      return _readFirstContact(entry, signal, peer);
    }
    final enc = _encryptionProvider;
    final link = boxFriends;
    if (enc == null || link == null || !enc.isE2EReady) return false;
    final user = entry.peerUserId;
    final device = entry.senderDeviceId;
    void refused(String why) => _e2eFlowLog('BOX_FRIEND_HANDOFF_REFUSED', {
      'peer': user,
      'device': device,
      'why': why,
    });
    // An account we asked over the box hands its queues to our other
    // devices here: that is the accept of our request (E15d/E15e).
    if (peer?.state != ContactState.friend &&
        !MessagingFirstContact._boxPending(peer, ContactState.pendingOut)) {
      refused('not_friend');
      return true;
    }
    // A newly linked device of the friend announces itself (decision 50):
    // its frame carries the account's DAK-signed list OUTSIDE Signal,
    // judged here before anything below — the liveness check then reads
    // the adopted list. Under a DAK the server never served, the one
    // lookup of E50a decides instead.
    final revokedSome = await _adoptCarriedList(user, entry.carriedList);
    try {
      return await _readFriendHandoff(link, enc, entry, signal, refused);
    } finally {
      // After the read, whatever became of it: a revoke the frame carried
      // stands even when the handoff itself is refused (E50e), and a pass
      // started earlier could hand this very device our queue beside the
      // hand-back.
      if (revokedSome) link.friendDevicesChanged(user);
    }
  }

  Future<bool> _readFriendHandoff(
    BoxFriendLink link,
    EncryptionProvider enc,
    BoxInboxEntry entry,
    String signal,
    void Function(String why) refused,
  ) async {
    final user = entry.peerUserId;
    final device = entry.senderDeviceId;
    // A request queue is public: anyone can seal a frame naming a friend's
    // account. A PreKey message must carry that friend's pinned identity,
    // checked BEFORE Signal sees it — decrypting a stranger's would replace
    // the real session. With no identity pinned yet, nothing here can judge
    // it: our own handoff to that friend builds the session from the
    // server's bundle (the old path's trust), and the friend's next one is
    // read under it.
    switch (await enc.friendFrameIdentity(user, signal)) {
      case FriendFrameIdentity.matches:
        break;
      case FriendFrameIdentity.noAnchor:
        refused('no_anchor');
        link.handOffTo(user);
        return true;
      case FriendFrameIdentity.foreign:
        refused('foreign_identity');
        return true;
    }
    // Only a device the friend's VERIFIED list names live is ever given an
    // answer (E2); a list that cannot be verified now refuses too.
    if (!await _friendDeviceIsLive(user, device)) {
      refused('not_live');
      return true;
    }
    // A revoked device of the friend still holds its account identity, so a
    // PreKey message that would replace our session with that device is read
    // only when this device asked for it — it started that session to hand
    // off, or re-keyed it; otherwise it is answered by our re-key, built from
    // that device's real bundle (decision 37's rule). An account this
    // account asked over the box counts as asked: our request built the
    // session its accept may replace (slice (f), E15f).
    if (!link.awaitingFriendRekeyFrom(user, device) &&
        !MessagingFirstContact._boxPending(
          link.contactOf(user),
          ContactState.pendingOut,
        ) &&
        await enc.preKeyWouldReplaceSession(user, device, signal)) {
      refused('would_replace');
      await link.rekeyFriend(user, device);
      return true;
    }
    final String plaintext;
    try {
      plaintext = await enc.decrypt(
        user,
        signal,
        messageId: entry.localId,
        deviceId: device,
      );
    } on Object catch (e) {
      refused('decrypt_${e.runtimeType}');
      return true;
    }
    link.friendRekeyAnswered(user, device);
    return _takeFriendHandoff(link, user, device, plaintext);
  }

  /// Whether friend [userId]'s VERIFIED list names [deviceId] live: the held
  /// list, else one batched lookup. False when it cannot be verified. A
  /// friend made over the box is never looked up here: its lookup is a
  /// search that spends one-time pre-keys and names the pair (E15h), and
  /// this runs on frame reads.
  Future<bool> _friendDeviceIsLive(int userId, int deviceId) async {
    final enc = _encryptionProvider;
    if (enc == null) return false;
    try {
      final held = enc.cachedDeviceList(userId);
      if (held == null && _boxOnlyPeer(userId)) return false;
      final list =
          held ?? await enc.getVerifiedDeviceList(userId, batched: true);
      return list.isLiveDevice(deviceId);
    } on Object {
      return false;
    }
  }

  /// Adopts the device list friend [userId]'s device carried ([json]: the
  /// authorization record) — outside Signal on a request-queue handoff, or
  /// a `list_update` inside it (slice (e), E50a/E50b). A list that moved
  /// re-reads what the box derives from it: this connect's entry for the
  /// user and the session pre-build ([refreshBoxDeviceLists]). Never a
  /// server lookup unless the DAK is not the one the server served. True
  /// when a device the held list named live no longer is (a revoke: the
  /// caller runs the handoff pass, which rotates our queue, E50e).
  Future<bool> _adoptCarriedList(int userId, Object? json) async {
    final enc = _encryptionProvider;
    if (enc == null || json == null) return false;
    Object? auth = json;
    if (json is String) {
      try {
        auth = jsonDecode(json);
      } on FormatException {
        auth = null;
      }
    }
    final before = enc.cachedDeviceList(userId)?.liveDeviceIds ?? const [];
    final outcome = await enc.adoptCarriedDeviceList(userId, auth);
    _e2eFlowLog('BOX_LIST_CARRIED', {'peer': userId, 'outcome': outcome.name});
    if (outcome != CarriedListOutcome.adopted &&
        outcome != CarriedListOutcome.refetched) {
      return false;
    }
    _boxLists.invalidate(userId);
    refreshBoxDeviceLists();
    final after = enc.cachedDeviceList(userId)?.liveDeviceIds ?? const [];
    return before.any((d) => !after.contains(d));
  }

  /// The device ids friend [userId]'s HELD verified list names revoked —
  /// what the box's handoff pass rotates our queue away from (slice (e),
  /// E50e). Never a lookup: a list not held names nothing.
  Future<Set<int>?> friendRevokedDevices(int userId) async {
    final list = _encryptionProvider?.cachedDeviceList(userId);
    if (list == null) return null;
    return {
      for (final d in list.devices)
        if (d.revokedAtMs != null) d.deviceId,
    };
  }

  /// This account's device list as its authorization record — what a
  /// request-queue handoff carries (decision 50). Null when not enrolled or
  /// not verifiable now. The own list names only the caller.
  Future<Map<String, dynamic>?> ownDeviceList() async {
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (enc == null || own == null || !enc.isE2EReady) return null;
    try {
      final list =
          enc.cachedDeviceList(own) ?? await enc.getVerifiedDeviceList(own);
      return list.authorization;
    } on Object {
      return null;
    }
  }

  /// E50d: the own list was just verified; when it no longer names live a
  /// device the last fully announced own list did (a revoke), this
  /// surviving device sends it to every live device of every friend it
  /// holds an address for, and records it once the box took every frame
  /// (else the next connect's own lookup tries again). A list that only
  /// ADDED devices is recorded unsent: the new device's own handoff carries
  /// it (decision 50). The first list this device ever sees is recorded as
  /// the baseline.
  Future<void> _announceOwnListIfRevoked() async {
    final enc = _encryptionProvider;
    final own = _currentUserId;
    final link = boxFriends;
    if (enc == null || own == null || link == null || _announcingOwnList) {
      return;
    }
    final list = enc.cachedDeviceList(own);
    final version = list?.version;
    final auth = list?.authorization;
    if (list == null || version == null || auth == null) return;
    // A device the list no longer names live is not a survivor.
    if (!enc.ownDeviceIdConfirmed || !list.isLiveDevice(enc.ownDeviceId)) {
      return;
    }
    final live = list.liveDeviceIds;
    final last = enc.announcedOwnList;
    if (last != null && last.version >= version) return;
    final revoked = last != null && last.live.any((d) => !live.contains(d));
    if (!revoked) {
      await enc.recordAnnouncedOwnList(version, live);
      return;
    }
    _announcingOwnList = true;
    try {
      if (await link.announceOwnList(auth)) {
        await enc.recordAnnouncedOwnList(version, live);
      }
    } finally {
      _announcingOwnList = false;
    }
  }

  /// E50f: friend [peer]'s box frame from [device] shows its view of OUR
  /// list, [claimedVersion], older than ours: answered with our list into
  /// that device's queue — once per device and own version this session —
  /// so it stops addressing a device we revoked, or learns one we linked,
  /// without asking the server.
  void _answerStaleView(int peer, int device, int? claimedVersion) {
    final enc = _encryptionProvider;
    final own = _currentUserId;
    final link = boxFriends;
    if (enc == null || own == null || link == null || claimedVersion == null) {
      return;
    }
    final ours = enc.cachedDeviceList(own);
    final version = ours?.version;
    final auth = ours?.authorization;
    if (version == null || auth == null || claimedVersion >= version) return;
    if (!_staleViewsAnswered.add('$peer:$device:$version')) return;
    unawaited(
      link.sendListUpdate(peer, device, auth).then((sent) {
        _e2eFlowLog('BOX_LIST_UPDATE_ANSWERED', {
          'peer': peer,
          'device': device,
          'sent': sent,
        });
        // Not taken: the next frame from that device may ask again.
        if (!sent) _staleViewsAnswered.remove('$peer:$device:$version');
      }),
    );
  }

  /// Stores friend [userId]'s [device] address from its handoff
  /// ([BoxFriendLink.takeFriendHandoff]: store, ack, hand ours back). Once
  /// stored, the friend may be covered now: this connect's lookup of its
  /// list runs (traps: a peer covered mid-session fails every box send until
  /// the next connect otherwise), and the composer notice is re-read.
  Future<bool> _takeFriendHandoff(
    BoxFriendLink link,
    int userId,
    int device,
    String plaintext,
  ) async {
    final address = E2eEnvelope.parseQueueHandoff(plaintext);
    if (address == null) {
      _e2eFlowLog('BOX_FRIEND_HANDOFF_REFUSED', {
        'peer': userId,
        'device': device,
        'why': 'not_a_handoff',
      });
      return true;
    }
    // The first handoff of an account we asked over the box is its accept:
    // the record becomes a friend before the handoff is taken (E15d/E15e).
    if (!await _befriendOnHandoff(userId, plaintext)) return false;
    switch (await link.takeFriendHandoff(
      userId,
      device,
      sid: address.sid,
      sealPub: address.sealPub,
    )) {
      case FriendWrite.retryLater:
        return false;
      case FriendWrite.refused:
        _e2eFlowLog('BOX_FRIEND_HANDOFF_REFUSED', {
          'peer': userId,
          'device': device,
          'why': 'store',
        });
        return true;
      case FriendWrite.stored:
        refreshBoxDeviceLists();
        notifyListeners();
        return true;
    }
  }

  /// Encrypts [json] for friend [userId]'s [deviceId] and frames it as from
  /// THIS device — the [FriendEncrypt] the box's friend handoff uses (the
  /// box asks only for friends). Null when it cannot now: E2E not ready, a
  /// device the friend's VERIFIED list does not name live (the server's
  /// friends list says which devices exist, never who is handed our queue,
  /// E2), or no session could be built. [fresh] (a re-key) rebuilds the
  /// session from the device's bundle first, so the frame is a PreKey
  /// message. Runs at connect or in answer to an inbound frame, never timed
  /// by a send (decision 21).
  Future<BoxFrame?> encryptForFriend(
    int userId,
    int deviceId,
    String json, {
    bool fresh = false,
  }) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady) return null;
    if (!await _friendDeviceIsLive(userId, deviceId)) {
      _e2eFlowLog('BOX_FRIEND_NOT_LIVE', {'peer': userId, 'device': deviceId});
      return null;
    }
    try {
      // A session built where there was NONE, or a re-key's fresh one, makes
      // this device the one that asked: that device's own PreKey answer may
      // replace it (two friends starting, or re-keying each other, at once)
      // and is read for a while. Without it for a re-key, two devices that
      // re-key each other at once refuse each other for good. Accepted
      // residual (owner, decision 49): a revoked device of the friend can
      // provoke our re-key and replace that device's session in the window.
      final started =
          fresh || !await enc.hasSessionWith(userId, deviceId: deviceId);
      if (fresh) enc.markSessionRebuild(userId, deviceId: deviceId);
      await enc.ensureSession(userId, deviceId: deviceId);
      final frame = BoxFrame.fromSignalCiphertext(
        await enc.encrypt(userId, json, deviceId: deviceId),
        senderDeviceId: enc.ownDeviceId,
      );
      if (started && frame != null) {
        boxFriends?.friendSessionStarted(userId, deviceId);
      }
      return frame;
    } on Object catch (e) {
      _e2eFlowLog('BOX_FRIEND_ENCRYPT_FAILED', {
        'peer': userId,
        'device': deviceId,
        'error': e.runtimeType.toString(),
      });
      return null;
    }
  }

  /// The device ids friend [userId]'s VERIFIED list names live — the
  /// [FriendLiveDevices] the box's friend handoff hands to. Batched, so a
  /// connect's pass costs one lookup frame (E20a); null when it cannot be
  /// verified now.
  Future<Set<int>?> friendLiveDevices(int userId) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady) return null;
    try {
      final list =
          enc.cachedDeviceList(userId) ??
          await enc.getVerifiedDeviceList(userId, batched: true);
      return list.liveDeviceIds.toSet();
    } on Object {
      return null;
    }
  }

  /// Whether the chat with [peerUserId] shows the "older app" notice (owner
  /// decision 48): this device is on the box, [peerUserId] is a friend, and
  /// its messages still take the old path because some live device of the
  /// friend has handed us no queue — the peer half of [_boxRoute]'s rule,
  /// read from the same record and list. Never blocks a send.
  bool boxFriendPending(int peerUserId) {
    final link = boxFriends;
    if (link == null || boxOutbox == null || !link.onBox) return false;
    if (link.contactOf(peerUserId)?.state != ContactState.friend) return false;
    return !_boxCoversPeer(peerUserId);
  }

  /// Whether [peerUserId] is box-covered now, synchronously: the peer half
  /// of [_boxRoute]'s rule on the list held, whatever the box's state. With
  /// no list held, any address counts — covered as far as we know, as
  /// [_boxRoute] fails closed on a list it cannot verify.
  bool _boxCoversPeer(int peerUserId) {
    final addresses = boxOutbox?.addressesFor(peerUserId) ?? const {};
    if (addresses.isEmpty) return false;
    final list = _encryptionProvider?.cachedDeviceList(peerUserId);
    return list == null || _everyLiveAddressed(list.liveDeviceIds, addresses);
  }

  /// This device is on the box now (its request queue was published): the
  /// decision-48 notice may show in a chat already on screen.
  void onBoxReady() => notifyListeners();

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
      _withEnvelope(row, parsed, box: true),
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

  Future<bool> _readBox(
    MessageModel msg,
    DateTime receivedAt, {
    bool controlOnly = false,
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
    if (!await _originDeviceIsLive(msg, refetch: false)) {
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
    // A friend device that writes to us may have lost our handoff (item 5).
    boxFriends?.friendHeard(msg.senderId, msg.originDeviceId ?? 1);

    final E2eEnvelopeFields parsed;
    try {
      parsed = E2eEnvelope.parse(plaintext);
    } on Object {
      _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'msgId': msg.id});
      return true;
    }
    final link = boxFriends;
    switch (parsed.type) {
      // The friend's device handed us its queue — a hand-back over our own
      // queue for it (item 5, E20d) — or acknowledged ours. A hand-back rides
      // the session the handoff built, so it is a whisper message; one that
      // came in a PreKey message is taken only when this device asked for
      // that session (it started or re-keyed it): a revoked device of the
      // friend still holds this queue's sid and the account identity, and
      // would otherwise move a live device's address to its own queue.
      case E2eEnvelope.typeQueueHandoff when link != null:
        final device = msg.originDeviceId ?? 1;
        // An account we asked over the box answers from the session our
        // request built: its accept counts as asked (slice (f), E15f).
        if (msg.encryptedContent!.startsWith('${BoxFrameKind.preKey.byte}:') &&
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
            _withEnvelope(
              msg,
              parsed,
              box: true,
            ).copyWith(createdAt: createdAt),
            parsed,
          ),
          receivedAt: receivedAt,
        );
      case E2eEnvelope.typeReact ||
          E2eEnvelope.typePin ||
          E2eEnvelope.typeEdit ||
          E2eEnvelope.typeDelete:
        // The peer's action on a message of this chat (item 4, E19b).
        return _takeBoxAction(
          parsed,
          plaintext,
          actor: msg.senderId,
          peer: msg.senderId,
          conversationId: msg.conversationId,
          receivedAt: receivedAt,
        );
      default:
        // A type a newer peer speaks: nothing here can show it.
        _e2eFlowLog('BOX_UNKNOWN_TYPE', {'msgId': msg.id, 't': parsed.type});
        return true;
    }
  }

  /// What only a box message carries (item 3), on [row]: its own timer and
  /// a reply's quote. Never read for a server row, whose timer and quote the
  /// server holds.
  ///
  /// Decision 41: our own copy — a sibling's sent copy — counts from the
  /// send, like the sender's; a received one only from the first time this
  /// device shows it ([_startBoxCountdowns]), with the 1-day unread cap
  /// until then.
  Future<MessageModel> _withBoxExtras(
    MessageModel row,
    E2eEnvelopeFields parsed,
  ) async {
    final ttl = parsed.ttl;
    final quote = parsed.replyQuote;
    return row.copyWith(
      disappearAfterSeconds: ttl,
      expiresAt: ttl != null && row.senderId == _currentUserId
          ? row.createdAt.add(Duration(seconds: ttl))
          : null,
      replyTo: quote == null
          ? null
          : await _boxReplyTo(quote, row.conversationId),
    );
  }

  /// A box reply's [quote] as the row's preview (E18a). When this device
  /// holds the quoted message from that sender under that wire id in this
  /// chat, the preview is OUR copy — its id, type and words (none for a
  /// message that disappears or is not a text) — and the peer's snippet is
  /// never read, so a forged one shows only for a message we never had;
  /// otherwise it points at no row (id 0), and the snippet shows.
  Future<ReplyToPreview> _boxReplyTo(
    E2eReplyQuote quote,
    int conversationId,
  ) async {
    final conversation = _conversationsProvider?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    final sender = [
      ?conversation?.userOne,
      ?conversation?.userTwo,
    ].where((u) => u.id == quote.senderId).firstOrNull;
    final held = await _heldQuote(quote, conversationId);
    if (held == null) {
      return ReplyToPreview(
        id: 0,
        content: quote.snippet,
        senderUsername: sender?.username ?? '',
        messageType: _parseMessageTypeString(quote.type) ?? MessageType.text,
        wireId: quote.wireId,
        senderId: quote.senderId,
      );
    }
    final disappears =
        held.disappearAfterSeconds != null || held.expiresAt != null;
    const labels = kReplyPreviewLabels;
    return ReplyToPreview(
      id: held.id,
      content: disappears || held.messageType != MessageType.text
          ? ''
          : replyPreviewForMessageModel(
              held,
              encryption: _encryptionProvider,
              encryptedMessageLabel: labels.encryptedMessageLabel,
              voiceMessageLabel: labels.voiceMessageLabel,
              imageLabel: labels.imageLabel,
              gifLabel: labels.gifLabel,
              documentLabel: labels.documentLabel,
              pingLabel: labels.pingLabel,
              videoLabel: labels.videoLabel,
            ),
      senderUsername: sender?.username ?? '',
      messageType: held.messageType,
      wireId: quote.wireId,
      senderId: quote.senderId,
      quotedDisappears: disappears,
    );
  }

  /// The message [quote] names, held in [conversationId] — in the open
  /// chat, else rebuilt from its record: by sender AND wire id, since a
  /// wire id is unique per sender only. Null when there is no wire id, or
  /// no such message here.
  Future<MessageModel?> _heldQuote(
    E2eReplyQuote quote,
    int conversationId,
  ) async {
    final wireId = quote.wireId;
    if (wireId == null) return null;
    for (final m in _messages) {
      if (m.conversationId == conversationId &&
          m.senderId == quote.senderId &&
          m.wireId == wireId) {
        return m;
      }
    }
    final enc = _encryptionProvider;
    if (enc == null) return null;
    final id = await enc.wireHolder((senderId: quote.senderId, wireId: wireId));
    if (id == null) return null;
    final record = await enc.getDecryptedContent(id);
    // Another chat's message is never this one's quote.
    if (record == null ||
        record[PlaintextRecordCodec.conversationIdKey] != conversationId) {
      return null;
    }
    final createdAtMs = record[PlaintextRecordCodec.createdAtKey];
    final ttl = record[PlaintextRecordCodec.disappearAfterKey];
    final expiresAtMs = record[PlaintextRecordCodec.expiresAtKey];
    return _restoreFromPersistedPayload(
      MessageModel(
        id: id,
        content: '',
        senderId: quote.senderId,
        senderUsername: '',
        conversationId: conversationId,
        createdAt: createdAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
            : DateTime.now().toUtc(),
        disappearAfterSeconds: ttl is int ? ttl : null,
        expiresAt: expiresAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true)
            : null,
      ),
      record,
    );
  }

  /// The destruction stamp of box message [msg]'s record (decision 41): its
  /// deadline once its countdown runs, else — a received one not shown yet
  /// — 1 day after the send, the unread cap. The stamp is what the
  /// destruction gate honours (`EncryptionService._recordExpiryDeadlineMs`).
  DateTime? _boxRecordExpiry(MessageModel msg) {
    if (msg.expiresAt != null || msg.disappearAfterSeconds == null) {
      return msg.expiresAt;
    }
    return msg.createdAt.add(
      const Duration(seconds: kNeverReadRetentionSeconds),
    );
  }

  /// Starts the countdown of every received box message in
  /// [conversationId] that has a timer and has not started one (decision
  /// 41): the first time this device SHOWS it — the chat open and the app
  /// in the foreground, the moments an old-path read mark is sent. The row
  /// then goes at now + its timer, and its record is re-stamped with that
  /// deadline and when it started, so a restart keeps counting.
  void _startBoxCountdowns(int conversationId) {
    if (_conversationsProvider?.isClientVisible == false) return;
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    if (conversationId != viewing) return;
    final own = _currentUserId;
    // Whole ms: the stored start and the row's deadline must agree.
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );
    var started = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final ttl = m.disappearAfterSeconds;
      if (m.conversationId != conversationId ||
          !isLocalMessageId(m.id) ||
          m.senderId == own ||
          ttl == null ||
          m.expiresAt != null ||
          isMessageExpired(m, now)) {
        continue;
      }
      final shown = m.copyWith(expiresAt: now.add(Duration(seconds: ttl)));
      _messages[i] = shown;
      started = true;
      _encryptionProvider?.cacheDecryption(shown.id, shown);
      // An unsaved row's next store must not undo the start.
      if (_boxUnsaved.containsKey(shown.id)) _boxUnsaved[shown.id] = shown;
      unawaited(_persistDecryptedContent(shown));
    }
    if (!started) return;
    if (_conversationCache.containsKey(conversationId)) {
      _updateCache(conversationId);
    }
    notifyListeners();
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
    // A friend made over the box has no server to carry a re-key request
    // (decision 52): this device re-keys that device itself, over the box —
    // once per box session; the device's own refusal of our fresh session
    // re-keys us back, and the pair converges (decision 49).
    final friendLink = boxFriends;
    if (friendLink != null &&
        _boxOnlyPeer(msg.senderId) &&
        (decision.rule == DecryptionFailureRule.noSession ||
            decision.rule == DecryptionFailureRule.badMac)) {
      unawaited(friendLink.rekeyFriend(msg.senderId, msg.originDeviceId ?? 1));
    }
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

  Future<bool> _consumeBoxMessage(
    MessageModel decrypted, {
    required DateTime receivedAt,
  }) async {
    final enc = _encryptionProvider!;
    final wire = _wireKey(decrypted.senderId, decrypted.wireId);
    if (wire != null) {
      // Deleted for everyone before this copy came (item 4, E19c/E19g).
      if (await enc.boxTombstoned(wire)) {
        _e2eFlowLog('BOX_TOMBSTONED', {'msgId': decrypted.id});
        return true;
      }
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
    return _storeBoxMessage(
      decrypted,
      alreadyShown: false,
      receivedAt: receivedAt,
    );
  }

  /// Stores [msg]'s plaintext and shows it. True only once the record is
  /// PROVEN on disk (read back from the store, not the write's word — the
  /// save path swallows a refused commit): the entry leaves the journal only
  /// then, because its ciphertext's ratchet key is already spent. Until
  /// then the message is shown from RAM and the next offer retries the
  /// store alone.
  ///
  /// Once stored, its attachment starts downloading ([receivedAt]: when the
  /// box delivered it), off the read chain (E17c, decision 40), and the
  /// actions read before it land on it (item 4, E19k).
  Future<bool> _storeBoxMessage(
    MessageModel msg, {
    required bool alreadyShown,
    required DateTime receivedAt,
  }) async {
    final enc = _encryptionProvider!..cacheDecryption(msg.id, msg);
    await _persistDecryptedContent(msg);
    final stored = await enc.recordExists(msg.id) == true;
    // Held BEFORE it is shown: showing starts its countdown
    // ([_startBoxCountdowns]), which updates the held row, so the next
    // store keeps the start instead of resetting it to the unread cap.
    if (!stored) _boxUnsaved[msg.id] = msg;
    if (!alreadyShown) {
      _showBoxMessage(msg);
      // H1 (decision 81): shown for the first time, only here — a re-store
      // (`alreadyShown`) is the same message. A sibling's sent copy is ours.
      if (msg.senderId != _currentUserId) {
        boxHiddenNotifier.notifyIfHidden().ignore();
      }
    }
    if (stored) {
      _boxUnsaved.remove(msg.id);
      _owedBoxDelivered(msg);
      _prefetchBoxMedia(msg, receivedAt);
      try {
        await _applyParkedBoxActions(msg);
      } on Object catch (e) {
        // Stored all the same: the message is finished, its actions lost.
        _e2eFlowLog('BOX_PARKED_APPLY_FAILED', {'error': e.runtimeType});
      }
      return true;
    }
    E2ePersistentDiag.record('BOX_STORE_UNPROVEN', {'msgId': msg.id});
    return false;
  }

  /// Queues [msg]'s box attachment for download; never awaited.
  void _prefetchBoxMedia(MessageModel msg, DateTime receivedAt) {
    final id = boxMediaIdOf(msg.mediaUrl);
    final user = _currentUserId;
    if (id == null || user == null) return;
    boxMedia?.prefetch(user, id, receivedAt: receivedAt);
  }

  void _showBoxMessage(MessageModel msg) {
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    final inView = msg.conversationId == viewing;
    // A chat made over the box that was deleted here comes back with its
    // next message, as a server chat does (owner decision 52).
    if (isLocalConversationId(msg.conversationId)) {
      _conversationsProvider?.revealLocalChat(msg.conversationId);
    }
    // A sibling's sent ping is ours: nothing arrived, as for an old-path
    // self-sync copy.
    if (inView &&
        msg.messageType == MessageType.ping &&
        msg.senderId != _currentUserId &&
        _pingEffectFiredIds.add(msg.id)) {
      _showPingEffect = true;
    }
    _addMessageToState(msg);
    // Shown: a disappearing one starts counting now (decision 41).
    if (inView) _startBoxCountdowns(msg.conversationId);
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
    final now = DateTime.now();
    final live = [
      for (final row in rows)
        if (!_deletedMessageIds.contains(row.id) && !isMessageExpired(row, now))
          row,
    ];
    // An attachment whose download never finished (the app closed first)
    // is fetched again (E17c); its copy's presence is checked, not read.
    final user = _currentUserId;
    final media = boxMedia;
    if (user != null && media != null) {
      for (final row in live) {
        final id = boxMediaIdOf(row.mediaUrl);
        if (id == null) continue;
        unawaited(media.prefetchIfMissing(user, id, receivedAt: row.createdAt));
      }
    }
    final missing = [
      for (final row in live)
        if (!held.contains(row.id)) row,
    ];
    if (missing.isNotEmpty) {
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
    // Shown now: what it holds of the peer's is read (slice (g), E61d), and
    // seen here across a restart (decision 73).
    _sendBoxReadReceipt(conversationId);
    _markBoxChatSeen(conversationId);
    // Shown now: a disappearing one not started yet starts (decision 41).
    _startBoxCountdowns(conversationId);
    // The chat's E2E pin names one of these (item 4, E19f).
    await _resolveBoxPin(conversationId);
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
    // Its own timer (item 3), and its deadline once the countdown started;
    // an unstarted one runs on the 1-day cap until shown (decision 41).
    final storedTtl = record[PlaintextRecordCodec.disappearAfterKey];
    final ttl =
        storedTtl is int &&
            storedTtl >= kDisappearingMinSeconds &&
            storedTtl <= kDisappearingMaxSeconds
        ? storedTtl
        : null;
    final countdownFrom = record[_boxCountdownFromKey];
    final row = _restoreFromPersistedPayload(
      MessageModel(
        id: id,
        content: '',
        senderId: senderId,
        senderUsername: sender?.id == senderId ? sender!.username : '',
        conversationId: conversationId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          createdAtMs,
          isUtc: true,
        ),
        // Ours went out when the box took every frame (decision 20), and
        // is as far on as a peer's receipt moved it (slice (g), E61f); the
        // peer's is `read` once this device's read receipt was taken (E61d).
        deliveryStatus: switch ((
          senderId == _currentUserId,
          record[_boxTickKey],
        )) {
          (true, 'delivered') => MessageDeliveryStatus.delivered,
          (_, 'read') => MessageDeliveryStatus.read,
          (true, _) => MessageDeliveryStatus.sent,
          (false, _) => MessageDeliveryStatus.delivered,
        },
        disappearAfterSeconds: ttl,
        expiresAt: ttl != null && countdownFrom is int
            ? DateTime.fromMillisecondsSinceEpoch(
                countdownFrom + ttl * 1000,
                isUtc: true,
              )
            : null,
      ),
      record,
    );
    return _hasUsableDecryptedContent(row) ? row : null;
  }

  /// Hands the chat list what no `conversationsList` can name (decision
  /// 14): each chat's newest box message this device stores, and the
  /// peer's box messages this device has not shown yet (decision 73).
  /// Without the first, a chat moved onto the box shows its last SERVER row
  /// after a launch, and sorts by it, and a chat made over the box shows
  /// none; without the second, an unopened box message loses its badge at
  /// every restart. Never a message deleted for everyone here (its
  /// tombstone, should its record outlive the delete) or on this device,
  /// nor an expired one. The list keeps whichever last message is newer
  /// ([ConversationsProvider.applyNewerLastMessages]); unread is a peer
  /// row sent after its chat's seen mark ([EncryptionService.boxSeenMarks]).
  ///
  /// Run at E2E ready, but reads the records ONCE per session (the first
  /// E2E ready after a launch or a sign-in,
  /// [ConversationsProvider.claimStoredBoxPass]): a reconnect keeps the
  /// list's state, which live messages maintain, and on web every record
  /// read is an unseal.
  Future<void> applyStoredBoxLastMessages() async {
    final enc = _encryptionProvider;
    final user = _currentUserId;
    final convs = _conversationsProvider;
    if (enc == null || user == null || convs == null) return;
    if (!convs.claimStoredBoxPass()) return;
    // First, even with nothing stored: this install's first pass fixes
    // what a chat never shown here counts from.
    final seen = await enc.boxSeenMarks();
    final records = await enc.allLocalMessageRecords();
    if (records.isEmpty) return;
    final tombstoned = await enc.boxTombstoneSnapshot();
    if (_isDisposed ||
        convs != _conversationsProvider ||
        user != _currentUserId) {
      return;
    }
    final now = DateTime.now();
    final newest = <int, MessageModel>{};
    final unread = <int, Set<int>>{};
    for (final MapEntry(key: id, value: record) in records.entries) {
      final conversationId = record[PlaintextRecordCodec.conversationIdKey];
      if (conversationId is! int || _deletedMessageIds.contains(id)) continue;
      final row = _boxRowFrom(
        id,
        conversationId,
        record,
        convs.getConversationById(conversationId),
      );
      if (row == null || isMessageExpired(row, now)) continue;
      final wire = _wireKey(row.senderId, row.wireId);
      if (wire != null && tombstoned(wire)) continue;
      final held = newest[conversationId];
      if (held == null || row.createdAt.isAfter(held.createdAt)) {
        newest[conversationId] = row;
      }
      if (seen != null &&
          row.senderId != user &&
          row.createdAt.millisecondsSinceEpoch >
              (seen.chats[conversationId] ?? seen.base)) {
        (unread[conversationId] ??= {}).add(id);
      }
    }
    convs
      ..applyNewerLastMessages(newest)
      ..seedBoxUnread(unread);
  }

  /// [conversationId] is on screen with the app in the foreground: the send
  /// time of the newest peer box message it shows becomes this device's
  /// seen mark for it, so a restart counts only what was sent later
  /// (decision 73, E73a). Never `tick: read`: that is receipt state, set
  /// only once a peer took our `rcpt r` (E61d). Written when it moves on.
  void _markBoxChatSeen(int conversationId) {
    final own = _currentUserId;
    if (own == null || _conversationsProvider?.isClientVisible == false) {
      return;
    }
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    if (conversationId != viewing) return;
    DateTime? upTo;
    for (final m in _messages) {
      if (m.conversationId != conversationId ||
          !isLocalMessageId(m.id) ||
          m.senderId == own) {
        continue;
      }
      if (upTo == null || m.createdAt.isAfter(upTo)) upTo = m.createdAt;
    }
    if (upTo == null) return;
    final ms = upTo.millisecondsSinceEpoch;
    if ((_boxSeenMarked[conversationId] ?? -1) >= ms) return;
    _boxSeenMarked[conversationId] = ms;
    unawaited(_encryptionProvider?.markBoxChatSeen(conversationId, upTo));
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
  ///
  /// [peerOnly] (receipts and typing, slice (g), E61b): the peer half alone
  /// — no sent copy goes to our siblings, so their coverage is not asked
  /// and the route names none.
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
    if (!_everyLiveAddressed(live, addresses)) {
      declined('peer_uncovered');
      return null;
    }
    final targets = [for (final d in live) addresses[d]!];
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

  /// Whether [peerUserId] is a friend made over the box (owner decision
  /// 52): the server does not know the pair, so nothing sent to it may take
  /// the old path — a send the box cannot carry FAILS instead.
  bool _boxOnlyPeer(int peerUserId) =>
      boxFriends?.contactOf(peerUserId)?.boxOrigin != null ||
      _conversationsProvider?.getConversationById(
            localConversationIdFor(peerUserId),
          ) !=
          null;

  /// Whether media send [tempId] to [recipientId] tries the box first (item
  /// 3 / media wiring): the peer has box addresses and, as for a text, a
  /// reply's quote can be named. Synchronous on purpose: an uncovered
  /// peer's old path keeps exactly the turns it always had (traps: "image
  /// emits before caption"). A friend made over the box always goes there:
  /// it has no old path ([_sendMediaOverBox] fails what the box cannot carry).
  bool _boxMayCarryMedia(int recipientId, String tempId) {
    if (_boxOnlyPeer(recipientId)) return true;
    final outbox = boxOutbox;
    if (outbox == null || outbox.addressesFor(recipientId).isEmpty) {
      return false;
    }
    final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
    return row?.replyToMessageId == null || _boxQuoteOf(row?.replyTo) != null;
  }

  /// Sends attachment [tempId] to a peer the box covers (item 3 / media
  /// wiring, E17a): the route is decided BEFORE anything is uploaded, then
  /// the file is encrypted whole, padded to a ladder rung, uploaded ONCE and
  /// sent as frames carrying its id ([_uploadBoxMediaAndSend]).
  ///
  /// [bytes] is the plaintext of a first send, whose null answer is the old
  /// path — only on evidence ([_boxRoute]), with nothing encrypted for the
  /// box. Without [bytes] this is a retry of an upload that never succeeded
  /// (E17b): it uploads the SAME held ciphertext, key and IV, and a route
  /// gone since fails the row. A list that cannot be verified, a refused
  /// upload or no answer fails it too (decisions 19, 31), never the old
  /// path, and so does a reply whose quote cannot be named: it is never
  /// sent without it. Each of those holds the encrypted file for its retry.
  /// [recording] is a voice note's plaintext file, deleted once the upload
  /// succeeds.
  Future<bool?> _sendMediaOverBox({
    required int recipientId,
    required String tempId,
    required String messageType,
    Uint8List? bytes,
    String? recording,
    String content = '',
    int? effectiveExpiresIn,
    int? effectiveReplyToId,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
  }) async {
    // An account-socket error says nothing about the box: the row is not
    // failed under an upload in flight.
    _boxInFlight.add(tempId);
    try {
      // Before the first await: the row leaves [_messages] once the user
      // opens another chat, and the frames still quote and time it.
      final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
      final atSend = (
        replyTo: row?.replyTo,
        ttl: row == null ? effectiveExpiresIn : row.disappearAfterSeconds,
      );
      final outbox = boxOutbox;
      final addresses = outbox?.addressesFor(recipientId) ?? const {};
      // A friend made over the box has no old path to fall back to.
      final oldPath = bytes != null && !_boxOnlyPeer(recipientId);
      if (outbox == null || addresses.isEmpty) {
        if (oldPath) return null;
        _e2eFlowLog('BOX_RETRY_NO_ROUTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      final _BoxRoute? route;
      try {
        route = await _boxRoute(recipientId, outbox, addresses);
      } on Object {
        // The row fails for a retry, which uploads what is held here.
        if (bytes != null) await _holdBoxMedia(tempId, bytes, recording);
        rethrow;
      }
      if (route == null) {
        if (oldPath) return null;
        _e2eFlowLog('BOX_RETRY_NO_ROUTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      final body = bytes != null
          ? await _holdBoxMedia(tempId, bytes, recording)
          : _boxMediaBodies[tempId];
      if (body == null) throw StateError('no held attachment');
      if (effectiveReplyToId != null && _boxQuoteOf(atSend.replyTo) == null) {
        _e2eFlowLog('BOX_MEDIA_NO_QUOTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      // The key before any further await (the durability invariant).
      _pendingSendContent[tempId] = <String, dynamic>{
        'content': content,
        'messageType': messageType,
        'mediaKey': body.key,
        'mediaIv': body.iv,
        'mediaDuration': ?mediaDuration,
        'mediaWidth': ?mediaWidth,
        'mediaHeight': ?mediaHeight,
        'mediaThumbHash': ?mediaThumbHash,
      };
      return await _uploadBoxMediaAndSend(
        route,
        body,
        atSend,
        recipientId: recipientId,
        tempId: tempId,
        messageType: messageType,
        content: content,
        effectiveExpiresIn: effectiveExpiresIn,
        effectiveReplyToId: effectiveReplyToId,
        mediaDuration: mediaDuration,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        mediaThumbHash: mediaThumbHash,
      );
    } on Object catch (e) {
      _e2eFlowLog('BOX_MEDIA_SEND_FAILED', {
        'tempId': tempId,
        'error': e.runtimeType.toString(),
      });
      _markMessageFailed(tempId, 'Could not send. Try again.');
      return false;
    } finally {
      _boxInFlight.remove(tempId);
    }
  }

  /// Encrypts [bytes] once for the box and holds them under [tempId] for
  /// every attempt to come (E17b), with the voice note's [recording].
  Future<_BoxMediaBody> _holdBoxMedia(
    String tempId,
    Uint8List bytes,
    String? recording,
  ) async {
    final encrypted = await _mediaUpload.encrypt(bytes);
    return _boxMediaBodies[tempId] = (
      ciphertext: encrypted.ciphertext,
      key: encrypted.keyBase64,
      iv: encrypted.ivBase64,
      recording: recording,
    );
  }

  /// Uploads [body] ONCE, padded to a ladder rung, against the FIRST live
  /// peer device's queue, whose daily budget pays (decision 44), then sends
  /// the frames — the same id to every peer device and sibling, quoting and
  /// timed by [atSend] — through the box path of [_encryptAndSend]. The row
  /// names the id before anything else can fail, so a retry re-sends frames
  /// and never uploads again (E17b); the sender keeps its own copy
  /// (decision 40), which replaces a voice note's plaintext recording.
  Future<bool> _uploadBoxMediaAndSend(
    _BoxRoute route,
    _BoxMediaBody body,
    _BoxRowAtSend atSend, {
    required int recipientId,
    required String tempId,
    required String messageType,
    required String content,
    int? effectiveExpiresIn,
    int? effectiveReplyToId,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
  }) async {
    final answer = await route.outbox.uploadMedia(
      route.targets.first,
      frameMediaToRung(body.ciphertext),
    );
    final Uint8List id;
    switch (answer) {
      case BoxOk(:final value):
        id = value.id;
      case BoxRefused(:final code):
        // quota_exceeded / rate_limited included: 'Ponów' (decision 31).
        _e2eFlowLog('BOX_MEDIA_UPLOAD_REFUSED', {
          'tempId': tempId,
          'code': code.wire,
        });
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      case BoxUnknown(:final reason):
        _e2eFlowLog('BOX_MEDIA_UPLOAD_UNKNOWN', {
          'tempId': tempId,
          'reason': reason.name,
        });
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
    }
    _boxMediaBodies.remove(tempId);
    final url = boxMediaUrl(boxB64(id));
    final user = _currentUserId;
    // A copy that fails to write is downloaded like anyone's at a restore.
    if (user != null) boxMedia?.keep(user, id, body.ciphertext).ignore();
    final index = _messages.indexWhere((m) => m.tempId == tempId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        mediaUrl: url,
        mediaKey: body.key,
        mediaIv: body.iv,
        mediaDuration: mediaDuration,
        mediaWidth: mediaWidth,
        mediaHeight: mediaHeight,
        mediaThumbHash: mediaThumbHash,
      );
      notifyListeners();
    }
    final recording = body.recording;
    if (!kIsWeb && recording != null) {
      try {
        await file_utils.deleteFileIfExists(recording);
      } on Object catch (e) {
        // Left behind like the old path's on a failed delete; the send goes
        // on.
        _e2eFlowLog('BOX_RECORDING_NOT_DELETED', {
          'tempId': tempId,
          'error': e.runtimeType.toString(),
        });
      }
    }
    final pending = _pendingAfterUpload(tempId);
    if (pending == null) return false;
    pending['mediaUrl'] = url;
    return _encryptAndSend(
      recipientId: recipientId,
      content: content,
      tempId: tempId,
      effectiveExpiresIn: effectiveExpiresIn,
      effectiveReplyToId: effectiveReplyToId,
      messageType: messageType,
      mediaUrl: url,
      mediaDuration: mediaDuration,
      mediaKey: body.key,
      mediaIv: body.iv,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      mediaThumbHash: mediaThumbHash,
      boxRowAtSend: atSend,
    );
  }

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
  /// quote of a reply's [replyTo] (item 3). The row is SENT only once the
  /// box took every frame, the copies included (decision 20); anything less
  /// fails it for a retry (decision 19), which re-seals under the same wire
  /// id, so a device that already holds the message drops the copy
  /// (`wireHeldByOther`). Every frame is built before the first goes out, so
  /// nothing reaches some devices only. A device with no usable session
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

  /// Every frame of one box send along [route], built before the first goes
  /// out: [json] as its own Signal message per peer device, [copyJson] per
  /// sibling. A device with no usable session fails it before anything is
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
    final sends = [
      for (final to in route.targets) (recipientId, to, json),
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
}
