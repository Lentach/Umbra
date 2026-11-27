part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The answer to a request kept over the box, out of
/// [MessagingFirstContact] (E15d, decisions 53–55): the accept — one
/// lookup, the kept frames checked and opened, the friendship stored —
/// the decline, and a `pendingOut` record befriended on the account's
/// first handoff.
extension MessagingFirstContactAccept on MessagingProvider {
  // ---------- Accept (E15d, decision 53), decline (decision 54) ----------

  /// Accepts [userId]'s request kept over the box: one `searchUsers` of the
  /// handle it claims (decision 53), whose answer must name that account
  /// and serve the very key the kept frame carries; only then is the frame
  /// decrypted. [FirstContactAccept.unverified] drops the request.
  Future<FirstContactAccept> acceptBoxFriendRequest(int userId) =>
      _acceptBoxRequest(userId);

  Future<FirstContactAccept> _acceptBoxRequest(
    int userId, {
    FirstContactPeer? served,
  }) async {
    final enc = _encryptionProvider;
    final link = boxFirstContact;
    final friends = boxFriends;
    if (enc == null || link == null || friends == null || !enc.isE2EReady) {
      return FirstContactAccept.failed;
    }
    final record = friends.contactOf(userId);
    if (!MessagingFirstContact._boxPending(record, ContactState.pendingIn)) {
      return FirstContactAccept.failed;
    }
    // Our own profile rides the accept (decision 55): without it nothing is
    // decrypted, since a decrypt spends the frame's one-time pre-key.
    await _refreshOwnPhotoIfStale();
    if (link.firstContact.ownProfile == null) return FirstContactAccept.failed;
    var peer = served;
    FirstContactClaim? asked;
    if (peer == null) {
      final lookup = lookupHandle;
      if (lookup == null) return FirstContactAccept.failed;
      // ONE search per accept (decision 53), of the name the request shows.
      asked = (username: record!.username, tag: record.tag);
      final answer = await lookup('${asked.username}#${asked.tag}');
      // No answer, or an empty one — the handle may be gone, or the answer
      // was another search's (the server correlates none): nothing is
      // decided, the request stays until it expires.
      if (answer == null || answer.isEmpty) return FirstContactAccept.failed;
      peer = FirstContactPeer.fromSearchEntry(answer.first);
    }
    final looked = asked;
    Future<FirstContactAccept> unverified(String why) async {
      _firstContactLog('BOX_REQUEST_UNVERIFIED', userId, {'why': why});
      E2ePersistentDiag.record('BOX_REQUEST_UNVERIFIED', {
        'peer': userId,
        'why': why,
      });
      // Frame and claim are unauthenticated: only the frames under the
      // name just looked up go, and a request other frames still claim
      // stays, shown under their name, for another accept (review).
      if (looked == null ||
          !await link.firstContact.dropClaim(userId, looked)) {
        await _dropBoxRequest(link, userId);
      }
      onBoxContactsChanged?.call();
      return FirstContactAccept.unverified;
    }

    if (peer == null || peer.userId != userId) return unverified('lookup');
    final identity = peer.identityKey;
    if (identity == null) return unverified('identity');
    final VerifiedDeviceList list;
    try {
      list = await enc.adoptServedAccount(
        userId,
        identityKey: identity,
        authorization: peer.authorization,
        // A pendingIn record is no friendship (decision 112): a key pinned
        // for the account is a leftover, replaced only when a kept frame
        // carries the very key served, so the request vouches for it.
        replaceStaleAnchor: _keptCarries(record!, identity),
      );
    } on DeviceListVerificationException {
      // The answer does not vouch for itself, or another key is pinned.
      return unverified('served_list');
    } on Object {
      // Storage or readiness: nothing about the request was decided.
      return FirstContactAccept.failed;
    }
    final opened = await _openKept(enc, record, list);
    if (opened.offered.isEmpty) {
      // A frame that would not decrypt may heal (the store, the session);
      // only when every kept frame is under another key or device is the
      // request somebody else's.
      return opened.failed ? FirstContactAccept.failed : unverified('no_frame');
    }
    final made = await _befriendServed(link, peer, opened.offered);
    if (!made) return FirstContactAccept.failed;
    await _dropKeptReplays(enc, record);
    await _relayFriendship(userId, served: peer);
    _afterBoxFriendship(userId, outgoing: false);
    return FirstContactAccept.accepted;
  }

  /// The replay rows of [record]'s kept requests hold their plaintext (a
  /// queue and a profile); once the friendship is stored they are done with.
  Future<void> _dropKeptReplays(
    EncryptionProvider enc,
    ContactRecord record,
  ) async {
    for (final kept in record.boxOrigin?.kept ?? const <KeptRequest>[]) {
      final id = kept.localId;
      if (id != null) await enc.removeRawReplay(id);
    }
  }

  /// Whether one of [record]'s kept request frames is sealed under
  /// [identity] — the served key the accept would pin in place of a stale
  /// one (decision 112). A key no kept frame carries vouches for nothing.
  bool _keptCarries(ContactRecord record, String identity) {
    final String key;
    try {
      key = base64Encode(base64Decode(base64.normalize(identity)));
    } on FormatException {
      return false;
    }
    return (record.boxOrigin?.kept ?? const <KeptRequest>[]).any(
      (kept) =>
          friendFrameIdentity(kept.signal, key) == FriendFrameIdentity.matches,
    );
  }

  /// Decrypts [record]'s kept requests that the served account vouches for:
  /// from a device its verified [list] names live, and carrying the account
  /// anchor [EncryptionProvider.adoptServedAccount] just pinned (a frame
  /// under another key is somebody else's and stays unread). By device: the
  /// queue each offers and the profile it carries; `failed` when a vouched
  /// frame's decrypt threw.
  Future<
    ({
      Map<int, ({String sid, String sealPub, E2eProfile? profile})> offered,
      bool failed,
    })
  >
  _openKept(
    EncryptionProvider enc,
    ContactRecord record,
    VerifiedDeviceList list,
  ) async {
    final userId = record.userId;
    final offered =
        <int, ({String sid, String sealPub, E2eProfile? profile})>{};
    var failed = false;
    for (final kept in record.boxOrigin?.kept ?? const <KeptRequest>[]) {
      if (!list.isLiveDevice(kept.deviceId) ||
          await enc.friendFrameIdentity(userId, kept.signal) !=
              FriendFrameIdentity.matches) {
        _firstContactLog('BOX_REQUEST_FRAME_SKIPPED', userId, {
          'device': kept.deviceId,
        });
        continue;
      }
      try {
        // Replayed under the delivery's local id: an accept that fails after
        // this point reads the same plaintext again (review).
        final plaintext = await _runDecryptSerialized(
          userId,
          () => enc.decrypt(
            userId,
            kept.signal,
            messageId: kept.localId,
            deviceId: kept.deviceId,
          ),
        );
        final request = E2eEnvelope.parseFriendRequest(plaintext);
        if (request != null) offered[kept.deviceId] = request;
      } on Object catch (e) {
        failed = true;
        _firstContactLog('BOX_REQUEST_FRAME_SKIPPED', userId, {
          'device': kept.deviceId,
          'error': e.runtimeType.toString(),
        });
      }
    }
    return (offered: offered, failed: failed);
  }

  /// [peer] is a friend over the box now: the record as the server's answer
  /// has it (name, addresses, bundles; the photo as the request's
  /// authenticated profile states it, decision 55), and each device's
  /// [offered] queue is taken — stored, acked, ours handed back with our
  /// profile — before the pass covers its other devices.
  Future<bool> _befriendServed(
    BoxFirstContactLink link,
    FirstContactPeer peer,
    Map<int, ({String sid, String sealPub, E2eProfile? profile})> offered,
  ) async {
    await _refreshOwnPhotoIfStale();
    final me = link.firstContact.ownProfile;
    if (me == null) return false;
    final stated = offered.values
        .map((o) => o.profile?.avatarUrl)
        .whereType<String>()
        .firstOrNull;
    final theirs = _newestPhoto(offered.values.map((o) => o.profile?.avatar));
    if (!await link.firstContact.befriend(
      peer.userId,
      profile: peer.profile,
      avatarUrl: MessagingFirstContact._ownServerAvatar(stated),
      avatar: theirs,
      addresses: peer.addresses,
      bundles: peer.servedBundles,
    )) {
      return false;
    }
    if (theirs != null) profilePhotos?.fetch(theirs);
    for (final MapEntry(key: device, value: queue) in offered.entries) {
      await link.acceptFirstContact(
        peer.userId,
        device,
        sid: queue.sid,
        sealPub: queue.sealPub,
        profile: me,
        // The identity the accept just pinned and the kept request frame
        // carries (`_openKept` read only frames under it).
        learnedUnder: peer.identityKey,
      );
    }
    link.firstContactFriend(peer.userId);
    return true;
  }

  /// Declines [userId]'s request kept over the box: gone here, and on our
  /// siblings; the requester is told nothing (decision 54).
  Future<void> declineBoxFriendRequest(int userId) async {
    final link = boxFirstContact;
    final record = link?.firstContact.contactOf(userId);
    if (link == null || !MessagingFirstContact._boxPending(record, ContactState.pendingIn)) return;
    if (!await _dropBoxRequest(link, userId)) return;
    onBoxContactsChanged?.call();
    await _relayToAllSiblings(
      jsonEncode(E2eEnvelope.buildFriendDeclined(userId)),
      peer: userId,
    );
  }

  /// Ends [userId]'s box request here. A record still holding a queue of
  /// ours — our own earlier request lapsed into theirs — is hidden at once
  /// and its queue deleted now; one the box did not confirm deleted stays
  /// hidden for the next expiry pass (the record holds its only auth key).
  Future<bool> _dropBoxRequest(BoxFirstContactLink link, int userId) async {
    if (!await link.firstContact.decline(userId)) return false;
    if (link.firstContact.contactOf(userId)?.queues.isNotEmpty ?? false) {
      await link.retireFirstContact(userId);
    }
    return true;
  }

  /// A friendship over the box began here: the lists, the chat list and the
  /// box lists re-read, and the screen is told.
  void _afterBoxFriendship(int userId, {required bool outgoing}) {
    _firstContactLog('BOX_FRIENDSHIP_MADE', userId, {'outgoing': outgoing});
    onBoxContactsChanged?.call();
    onBoxFriendshipMade?.call(userId, outgoing: outgoing);
    _conversationsProvider?.refreshChats();
    refreshBoxDeviceLists();
    notifyListeners();
  }

  /// A `pendingOut` record over the box — the requester's, or a sibling's
  /// copy of it — becomes a friend on the first `queue_handoff` its account
  /// hands us (E15d, E15e), before the handoff is taken. True when [userId]
  /// is a friend now or was one; false: the store could not take it yet.
  Future<bool> _befriendOnHandoff(int userId, String plaintext) async {
    final link = boxFirstContact;
    final record = boxFriends?.contactOf(userId);
    if (link == null || !MessagingFirstContact._boxPending(record, ContactState.pendingOut)) {
      return true;
    }
    final theirs = E2eEnvelope.profileOf(plaintext);
    if (!await link.firstContact.befriend(
      userId,
      avatarUrl: MessagingFirstContact._ownServerAvatar(theirs?.avatarUrl),
      avatar: theirs?.avatar,
    )) {
      return false;
    }
    final photo = theirs?.avatar;
    if (photo != null) profilePhotos?.fetch(photo);
    link.firstContactFriend(userId);
    await _relayFriendship(userId);
    _afterBoxFriendship(userId, outgoing: true);
    return true;
  }
}
