part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The friend side of the box read, out of [MessagingBox]: a friend's
/// `queue_handoff` on our public request queue, the device lists a friend's
/// frame is checked against, and what this device encrypts for a friend's
/// device.
extension MessagingBoxFriendRead on MessagingProvider {
  /// Reads a friend's frame from our public request queue (item 5, E20c):
  /// only its `queue_handoff` is taken. Same finishing contract as
  /// [MessagingBox._consumeBox]; everything refused here is FINISHED, because anyone can
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
    String? sessionIdentity;
    try {
      plaintext = await enc.decrypt(
        user,
        signal,
        messageId: entry.localId,
        deviceId: device,
        onIdentity: (identity) => sessionIdentity = identity,
      );
    } on Object catch (e) {
      refused('decrypt_${e.runtimeType}');
      return true;
    }
    link.friendRekeyAnswered(user, device);
    _noteFriendRelaysIn(user, device, plaintext);
    return _takeFriendHandoff(
      link,
      user,
      device,
      plaintext,
      learnedUnder: _frameIdentity(signal, sessionIdentity),
    );
  }

  /// Whether friend [userId]'s VERIFIED list names [deviceId] live: the held
  /// list, else one lookup. False when it cannot be verified. A
  /// friend is never looked up here (E114e): its lookup is a search that
  /// spends one-time pre-keys and names the pair (E15h), and this runs on
  /// frame reads — a frame never times a lookup.
  Future<bool> _friendDeviceIsLive(int userId, int deviceId) async {
    final enc = _encryptionProvider;
    if (enc == null) return false;
    try {
      final held = enc.cachedDeviceList(userId);
      if (held == null &&
          (enc.listIsByHandle(userId) || _boxOnlyPeer(userId))) {
        return false;
      }
      final list = held ?? await enc.getVerifiedDeviceList(userId);
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
    String plaintext, {
    required String? learnedUnder,
  }) async {
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
    // A handoff learned under a foreign identity is refused BEFORE it can
    // befriend a pendingOut request (the store refuses it again, with the
    // same rule, once the record is a friend).
    final anchor = _encryptionProvider?.accountAnchorSync(userId);
    if (learnedUnder != null && anchor != null && learnedUnder != anchor) {
      _e2eFlowLog('BOX_FRIEND_HANDOFF_REFUSED', {
        'peer': userId,
        'device': device,
        'why': 'learned_under_other_identity',
      });
      return true;
    }
    if (!await _befriendOnHandoff(userId, plaintext)) return false;
    switch (await link.takeFriendHandoff(
      userId,
      device,
      sid: address.sid,
      sealPub: address.sealPub,
      learnedUnder: learnedUnder,
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

  /// The account identity (base64) that authenticated a friend frame
  /// [signal]: a PreKey message carries it, a whisper's is the remote
  /// identity of the session it was decrypted on, handed back by the decrypt
  /// itself in its serialized step ([sessionIdentity]). Null when neither
  /// can say; the handoff is then stored untagged, never refused.
  String? _frameIdentity(String signal, String? sessionIdentity) =>
      preKeyIdentityOf(signal) ?? sessionIdentity;

  /// Encrypts [json] for friend [userId]'s [deviceId] and frames it as from
  /// THIS device — the [FriendEncrypt] the box's friend handoff uses (the
  /// box asks only for friends). Null when it cannot now: E2E not ready, a
  /// device the friend's VERIFIED list does not name live (a list says which
  /// devices exist, never who is handed our queue, E2), or no session could
  /// be built. [fresh] (a re-key) rebuilds the
  /// session from the device's bundle first, so the frame is a PreKey
  /// message. Runs at connect or in answer to an inbound frame, never timed
  /// by a send (decision 21).
  Future<BoxFrame?> encryptForFriend(
    int userId,
    int deviceId,
    String json, {
    bool fresh = false,
    FriendPermit? permit,
  }) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady) return null;
    // The permit is taken BEFORE anything is sealed (the gate: a calm hold,
    // an unjudged journal, a stale address all refuse it). The box passes its
    // own; a direct caller gets one here, now. A closed gate seals nothing,
    // and the write itself refuses a frame that carries none.
    permit ??= _friendPermit(userId);
    if (permit == null) {
      _e2eFlowLog('BOX_FRIEND_NO_PERMIT', {'peer': userId, 'device': deviceId});
      return null;
    }
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
      // A frame to a friend's device says whether this device relays
      // (decision 101 A, E101b).
      final frame = BoxFrame.fromSignalCiphertext(
        await enc.encrypt(
          userId,
          E2eEnvelope.toFriend(json, relays: _vouchesRelay),
          deviceId: deviceId,
          admit: permit.admitsSession,
        ),
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

  /// A permit to seal for friend [userId] (optionally toward [to]), from the
  /// box's gate; null while it is closed. A stand-in outbox that is not the
  /// box session has no gate and gives an open permit.
  FriendPermit? _friendPermit(
    int userId, {
    Iterable<ContactOutbound> to = const [],
    bool goodbye = false,
  }) {
    // A calm hold waits for the person's tap (option C): the session held
    // belongs to the key being replaced, so nothing is sealed on it.
    if (_calmHolds.containsKey(userId)) {
      _e2eFlowLog('BOX_FRIEND_CALM_HELD', {'peer': userId});
      return null;
    }
    final outbox = boxOutbox;
    if (outbox case final BoxFriendGateOutbox gate) {
      return gate.permitFor(userId, to: to, goodbye: goodbye);
    }
    return FriendPermit.ungated(userId);
  }

  /// Takes a permit for friend [user]'s [device] at [to], BEFORE Signal
  /// seals [json] under it: a closed gate seals nothing and moves no ratchet.
  Future<({BoxFrame? frame, FriendPermit? permit})> _sealFriend(
    int user,
    int device,
    ContactOutbound to,
    String json, {
    bool exemptJournal = false,
  }) async {
    final permit = _friendPermit(user, to: [to], goodbye: exemptJournal);
    if (permit == null) return (frame: null, permit: null);
    final frame = await encryptForFriend(user, device, json, permit: permit);
    return (frame: frame, permit: permit);
  }

  /// [BoxOutbox.deliver] for a friend's queue, under [permit] when the outbox
  /// is the box session (a stand-in outbox has no gate).
  Future<BoxSendOutcome> _deliverFriend(
    BoxOutbox outbox,
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
    FriendPermit? permit,
  }) {
    if (outbox case final BoxFriendGateOutbox gate) {
      return gate.deliverFriend(to, body, mode: mode, permit: permit);
    }
    return outbox.deliver(to, body, mode: mode);
  }

  /// The device ids friend [userId]'s VERIFIED list names live — the
  /// [FriendLiveDevices] the box's friend handoff hands to; null when it
  /// cannot be verified now.
  Future<Set<int>?> friendLiveDevices(int userId) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady) return null;
    try {
      final list =
          enc.cachedDeviceList(userId) ??
          await enc.getVerifiedDeviceList(userId);
      return list.liveDeviceIds.toSet();
    } on Object {
      return null;
    }
  }

  /// Whether the chat with [peerUserId] shows the "older app" notice (owner
  /// decision 48): this device is on the box, [peerUserId] is a friend, and
  /// its messages cannot go out because some live device of the
  /// friend has handed us no queue — the peer half of [MessagingBoxSend._boxRoute]'s rule,
  /// read from the same record and list. Never blocks a send.
  bool boxFriendPending(int peerUserId) {
    final link = boxFriends;
    if (link == null || boxOutbox == null || !link.onBox) return false;
    if (link.contactOf(peerUserId)?.state != ContactState.friend) return false;
    return !_boxCoversPeer(peerUserId);
  }

  /// Whether [peerUserId] is box-covered now, synchronously: the peer half
  /// of [MessagingBoxSend._boxRoute]'s rule on the list held, whatever the box's state. With
  /// no list held, any address counts — covered as far as we know, as
  /// [MessagingBoxSend._boxRoute] fails closed on a list it cannot verify.
  bool _boxCoversPeer(int peerUserId) {
    final addresses = boxOutbox?.addressesFor(peerUserId) ?? const {};
    if (addresses.isEmpty) return false;
    final list = _encryptionProvider?.cachedDeviceList(peerUserId);
    return list == null || _boxCoversLive(list.liveDeviceIds, addresses);
  }

  /// This device is on the box now (its request queue was published): the
  /// decision-48 notice may show in a chat already on screen, and an
  /// absence that just ended asks a sibling to catch up (decision 102).
  void onBoxReady() {
    notifyListeners();
    unawaited(catchUpTick());
    // Decision 138: the migration and the weekly upload need a box that
    // takes an upload.
    unawaited(syncOwnPhoto());
  }
}
