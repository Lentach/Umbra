part of '../messaging_provider.dart';

/// The receiving side of a first contact, out of [MessagingFirstContact]
/// (E15c, E15e, E15f): a stranger's request read from our request queue,
/// kept undecrypted or — when it crosses our own — taken as its accept,
/// and a sibling's copy of a first contact read from our self-queue.
extension MessagingFirstContactReceive on MessagingProvider {
  // ---------- Receive a request (E15c, E15f) ----------

  /// A claim-bearing frame from our request queue: a first contact's
  /// request. Same finishing contract as [_readFriendRequest]; everything
  /// refused is finished.
  Future<bool> _readFirstContact(
    BoxInboxEntry entry,
    String signal,
    ContactRecord? peer,
  ) async {
    final link = boxFirstContact;
    final enc = _encryptionProvider;
    if (link == null || enc == null || !enc.isE2EReady) return false;
    final user = entry.peerUserId;
    final device = entry.senderDeviceId;
    void refused(String why) => _firstContactLog(
      'BOX_FIRST_CONTACT_REFUSED',
      user,
      {'device': device, 'why': why},
    );
    final claim = BoxFirstContact.parseClaim(entry.carriedClaim);
    if (claim == null) {
      refused('claim');
      return true;
    }
    if (!signal.startsWith('${BoxFrameKind.preKey.byte}:')) {
      refused('not_prekey');
      return true;
    }
    // Our own request still shown to us (decision 54): theirs is its accept
    // (E15f). One that lapsed is not an ask any more: theirs is a new
    // request, kept like any other.
    final now = DateTime.now().toUtc();
    if (MessagingFirstContact._boxPending(peer, ContactState.pendingOut) &&
        BoxFirstContact.shownPending(peer!, now)) {
      return _takeCrossedRequest(link, enc, entry, signal);
    }
    final state = peer?.state;
    if (state != null &&
        !MessagingFirstContact._boxPending(peer, ContactState.pendingIn) &&
        !MessagingFirstContact._boxPending(peer, ContactState.pendingOut)) {
      // A friend, a blocked account, a request the server carries — or a
      // `former` contact, whose queues an unauthenticated frame must never
      // turn into a request (E15c: no record here, or one we asked).
      refused(state.name);
      return true;
    }
    final kept = await link.firstContact.keep(
      userId: user,
      deviceId: device,
      signal: signal,
      claim: claim,
      localId: entry.localId,
    );
    _firstContactLog('BOX_FIRST_CONTACT_KEPT', user, {
      'device': device,
      'kept': kept,
    });
    if (kept) onBoxContactsChanged?.call();
    return true;
  }

  /// E15f: a request from an account we asked over the box is its accept,
  /// as the old path's auto-accept. Its PreKey identity must be the anchor
  /// our own search pinned, so it is decrypted at once — the session our
  /// request built counts as asked, so a crossing PreKey replaces it (item
  /// 5's rule, decision 49).
  Future<bool> _takeCrossedRequest(
    BoxFirstContactLink link,
    EncryptionProvider enc,
    BoxInboxEntry entry,
    String signal,
  ) async {
    // Registered before the first await: a send of ours failing meanwhile
    // waits for this accept instead of retiring the queue it is making.
    final user = entry.peerUserId;
    final done = Completer<void>();
    _crossingsInFlight[user] = done.future;
    try {
      return await _finishCrossedRequest(link, enc, entry, signal);
    } finally {
      if (identical(_crossingsInFlight[user], done.future)) {
        _crossingsInFlight.remove(user)?.ignore();
      }
      done.complete();
    }
  }

  Future<bool> _finishCrossedRequest(
    BoxFirstContactLink link,
    EncryptionProvider enc,
    BoxInboxEntry entry,
    String signal,
  ) async {
    final user = entry.peerUserId;
    final device = entry.senderDeviceId;
    void refused(String why) => _firstContactLog(
      'BOX_FIRST_CONTACT_REFUSED',
      user,
      {'device': device, 'why': why},
    );
    if (await enc.friendFrameIdentity(user, signal) !=
        FriendFrameIdentity.matches) {
      refused('foreign_identity');
      return true;
    }
    if (!await _friendDeviceIsLive(user, device)) {
      refused('not_live');
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
    final offered = E2eEnvelope.parseFriendRequest(plaintext);
    await _refreshOwnPhotoIfStale();
    final me = link.firstContact.ownProfile;
    if (offered == null || me == null) {
      refused('not_a_request');
      return true;
    }
    final theirs = offered.profile?.avatar;
    if (!await link.firstContact.befriend(
      user,
      avatarUrl: MessagingFirstContact._ownServerAvatar(offered.profile?.avatarUrl),
      avatar: theirs,
    )) {
      return false;
    }
    if (theirs != null) profilePhotos?.fetch(theirs);
    await link.acceptFirstContact(
      user,
      device,
      sid: offered.sid,
      sealPub: offered.sealPub,
      profile: me,
      learnedUnder: await _frameIdentity(enc, user, device, signal),
    );
    link.firstContactFriend(user);
    await _relayFriendship(user);
    _afterBoxFriendship(user, outgoing: true);
    return true;
  }

  // ---------- Sibling copies (E15e) ----------

  /// A sibling's copy of a first contact, read from our self-queue:
  /// `friend_request_sent` (we asked), `friend_accepted` (we accepted),
  /// `friend_declined` (we declined).
  Future<bool> _takeFirstContactCopy(String type, String plaintext) async {
    final link = boxFirstContact;
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (link == null || enc == null || own == null) return false;
    if (type == E2eEnvelope.typeFriendDeclined) {
      final to = E2eEnvelope.parse(plaintext).sentTo;
      if (to != null && await _dropBoxRequest(link, to)) {
        onBoxContactsChanged?.call();
      }
      return true;
    }
    final peer = FirstContactPeer.fromSearchEntry(
      E2eEnvelope.relayedPeer(plaintext),
    );
    final identity = peer?.identityKey;
    if (peer == null || identity == null || peer.userId == own) {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {'t': type});
      return true;
    }
    final userId = peer.userId;
    final record = link.firstContact.contactOf(userId);
    if (record?.state == ContactState.friend) return true;
    final VerifiedDeviceList list;
    try {
      // An own device relays the server's answer: the anchor is staged
      // from it, so the account's first PreKey frame can be judged here.
      list = await enc.adoptServedAccount(
        userId,
        identityKey: identity,
        authorization: peer.authorization,
      );
    } on DeviceListVerificationException catch (e) {
      _firstContactLog('BOX_SIBLING_COPY_REFUSED', userId, {
        'why': 'served_list',
        'reason': e.reason,
      });
      return true;
    } on Object {
      // Nothing decided: the copy is offered again (self-queue only).
      return false;
    }
    if (type == E2eEnvelope.typeFriendRequestSent) {
      if (await link.firstContact.asked(
        userId: userId,
        profile: peer.profile,
        addresses: peer.addresses,
        bundles: peer.servedBundles,
      )) {
        onBoxContactsChanged?.call();
      }
      return true;
    }
    // We accepted on another device. A request this device kept too is
    // opened as there; with none, the pass covers the account's devices.
    final offered = MessagingFirstContact._boxPending(record, ContactState.pendingIn)
        ? (await _openKept(enc, record!, list)).offered
        : const <int, ({String sid, String sealPub, E2eProfile? profile})>{};
    if (!MessagingFirstContact._boxPending(record, ContactState.pendingIn) &&
        !await link.firstContact.asked(
          userId: userId,
          profile: peer.profile,
          addresses: peer.addresses,
          bundles: peer.servedBundles,
        )) {
      // A request the server carries, a blocked account: not ours to make.
      return true;
    }
    if (!await _befriendServed(link, peer, offered)) return false;
    if (record != null) await _dropKeptReplays(enc, record);
    _afterBoxFriendship(userId, outgoing: false);
    return true;
  }
}
