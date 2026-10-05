part of '../messaging_provider.dart';

/// First contact over the request queues (metadata-privacy PR3.1 slice (f),
/// owner decisions 52–55, engineering calls E15a–E15k in
/// `docs/plans/2026-09-25-metadata-pr31-remainder.md` § Item 7): the Signal
/// half. The records live in `BoxFirstContact`, the box half in `BoxSession`.
///
/// * A request goes over the box only when every device on both sides is on
///   it (E15a), else the old path as today — never split. It is one
///   claim-bearing PreKey frame per target device (E15b), and our siblings
///   are told over the self-queues (E15e).
/// * A stranger's request is KEPT undecrypted (E15c): a PreKey decrypt pins
///   whatever identity key the frame brings. The accept looks the handle up
///   once (decision 53), checks the kept frame's key against the one the
///   server serves, and only then decrypts it (E15d).
/// * Both asking at once is an accept (E15f); a decline tells nobody but our
///   siblings (decision 54); the request and the accept carry each side's
///   profile (decision 55).
/// * A friendship made this way ends with a `goodbye` and deleted queues
///   (E15j), and its chat's timer setting travels between the devices
///   (E15k).
extension MessagingFirstContact on MessagingProvider {
  /// Whether [record] is a request pending over the box in [state]
  /// (`pendingIn` or `pendingOut`): no request the server carries.
  static bool _boxPending(ContactRecord? record, ContactState state) =>
      record != null &&
      record.state == state &&
      record.boxOrigin != null &&
      record.legacy.requestId == null;

  /// The chat of a box delivery's [record]: its server conversation, else —
  /// a friendship made over the box, whose contact backup restores no
  /// `legacy` — its local id (decision 52).
  static int? _boxChatOf(ContactRecord? record) =>
      record?.legacy.conversationId ??
      (record != null &&
              record.state == ContactState.friend &&
              record.boxOrigin != null
          ? localConversationIdFor(record.userId)
          : null);

  void _firstContactLog(String step, int peer, [Map<String, Object?>? more]) =>
      _e2eFlowLog(step, {'peer': peer, ...?more});

  // ---------- Send (E15a, E15b, E15e) ----------

  /// Sends a friend request to the account [entry] names — one raw
  /// `searchUsersResult` entry — over the box. [FirstContactSend.oldPath]
  /// when a device on either side is not on the box (E15a): the caller then
  /// sends it the old way. [FirstContactSend.sent] once at least one target
  /// device took its frame: the others learn of the friendship from the
  /// accepting device's siblings copy (E15e) and the handoff pass.
  Future<FirstContactSend> sendBoxFriendRequest(
    Map<String, dynamic> entry,
  ) async {
    final enc = _encryptionProvider;
    final link = boxFirstContact;
    final friends = boxFriends;
    final outbox = boxOutbox;
    final own = _currentUserId;
    final peer = FirstContactPeer.fromSearchEntry(entry);
    if (enc == null ||
        link == null ||
        friends == null ||
        outbox == null ||
        own == null ||
        peer == null ||
        peer.userId == own) {
      return FirstContactSend.oldPath;
    }
    if (!friends.onBox || !peer.allOnBox) return FirstContactSend.oldPath;
    // Only a request the box would carry needs E2E: the old path above
    // needs none, so it stays open while E2E starts or after its init fails.
    if (!enc.isE2EReady) return FirstContactSend.failed;
    final userId = peer.userId;
    final record = friends.contactOf(userId);
    if (_boxPending(record, ContactState.pendingIn)) {
      // They asked us over the box first: this is an accept, with the
      // answer in hand as the check (E15f from our side).
      return switch (await _acceptBoxRequest(userId, served: peer)) {
        FirstContactAccept.accepted => FirstContactSend.sent,
        _ => FirstContactSend.failed,
      };
    }
    final fresh = record == null || record.state == ContactState.former;
    if (!fresh && !_boxPending(record, ContactState.pendingOut)) {
      // A friend, a blocked account, a request the server carries: not a
      // first contact, the old path decides as today.
      return FirstContactSend.oldPath;
    }
    final mine = await ownLiveDevices();
    if (mine == null) return FirstContactSend.failed;
    final siblingAddresses = outbox.siblingAddresses();
    final siblings = [
      for (final d in mine.live)
        if (d != mine.self) d,
    ];
    if (siblings.any((d) => !siblingAddresses.containsKey(d))) {
      return FirstContactSend.oldPath;
    }
    final identity = peer.identityKey;
    if (identity == null) {
      _firstContactLog('BOX_REQUEST_REFUSED', userId, {'why': 'identity'});
      return FirstContactSend.failed;
    }
    final VerifiedDeviceList list;
    try {
      list = await enc.adoptServedAccount(
        userId,
        identityKey: identity,
        authorization: peer.authorization,
      );
    } on Object catch (e) {
      _firstContactLog('BOX_REQUEST_REFUSED', userId, {
        'why': 'served_list',
        'error': e.runtimeType.toString(),
      });
      return FirstContactSend.failed;
    }
    final served = {for (final d in peer.devices) d.deviceId: d};
    final targets = list.liveDeviceIds;
    // Every device the verified list names live must be one the answer
    // served with a request address; anything short of that is the old
    // path's (decision 16's all-or-nothing).
    if (targets.isEmpty || targets.any((d) => served[d]?.request == null)) {
      return FirstContactSend.oldPath;
    }
    final me = link.firstContact.ownProfile;
    if (me == null) return FirstContactSend.failed;
    final asked = await link.firstContact.asked(
      userId: userId,
      profile: peer.profile,
      addresses: [for (final d in targets) served[d]!.request!],
      bundles: peer.servedBundles,
      avatarUrl: peer.avatarUrl,
    );
    if (!asked) return FirstContactSend.failed;
    // Our own devices first, all of them (E15e, decision 16): a sibling
    // that never learns of the request never hands the account a queue,
    // and then the account can never write to us over the box. Nothing has
    // reached the peer yet, so a copy that did not go undoes the request.
    final relayed = await _relayToSiblings(
      siblings,
      siblingAddresses,
      jsonEncode(
        E2eEnvelope.buildFriendRelay(
          E2eEnvelope.typeFriendRequestSent,
          peer.toSiblingJson(),
        ),
      ),
      peer: userId,
    );
    if (!relayed) {
      if (fresh) await link.retireFirstContact(userId);
      onBoxContactsChanged?.call();
      return FirstContactSend.failed;
    }
    final queue = await link.firstContactQueue(userId);
    if (queue == null) {
      if (fresh) await link.retireFirstContact(userId);
      return FirstContactSend.failed;
    }
    final request = jsonEncode(
      E2eEnvelope.buildFriendRequest(
        sid: queue.sid,
        sealPub: queue.sealPub,
        profile: me,
      ),
    );
    final claim = BoxFirstContact.encodeClaim((
      username: me.username,
      tag: me.tag,
    ));
    var delivered = 0;
    for (final d in targets) {
      if (await _sendRequestFrame(enc, outbox, own, userId, served[d]!, (
        request: request,
        claim: claim,
      ))) {
        delivered++;
        // This device started that session: the device's answer may come
        // as a PreKey message replacing it (item 5's "asked" rule).
        friends.friendSessionStarted(userId, d);
      }
    }
    if (delivered == 0) {
      // Nothing reached the peer: the request did not happen. Our
      // siblings' copies lapse with the request (decision 54).
      if (fresh) await link.retireFirstContact(userId);
      onBoxContactsChanged?.call();
      return FirstContactSend.failed;
    }
    _firstContactLog('BOX_REQUEST_SENT', userId, {
      'devices': targets.length,
      'delivered': delivered,
    });
    onBoxContactsChanged?.call();
    return FirstContactSend.sent;
  }

  /// One claim-bearing PreKey frame for [device] (E15b): a FRESH session
  /// from the bundle this very answer served, the envelope inside Signal,
  /// the claim outside it. True only when the box took it.
  Future<bool> _sendRequestFrame(
    EncryptionProvider enc,
    BoxOutbox outbox,
    int own,
    int userId,
    FirstContactDevice device,
    ({String request, String claim}) payload,
  ) async {
    final to = device.request;
    if (to == null) return false;
    try {
      await enc.buildSessionFromServedBundle(
        userId,
        device.deviceId,
        device.bundle,
      );
      final frame = BoxFrame.fromSignalCiphertext(
        await enc.encrypt(userId, payload.request, deviceId: device.deviceId),
        senderDeviceId: enc.ownDeviceId,
      );
      if (frame == null || frame.kind != BoxFrameKind.preKey) return false;
      return await outbox.deliver(
            to,
            BoxFrame(
              kind: frame.kind,
              senderDeviceId: frame.senderDeviceId,
              senderUserId: own,
              signal: frame.signal,
              carriedClaim: payload.claim,
            ).encode(),
          ) ==
          BoxSendOutcome.taken;
    } on Object catch (e) {
      _firstContactLog('BOX_REQUEST_FRAME_FAILED', userId, {
        'device': device.deviceId,
        'error': e.runtimeType.toString(),
      });
      return false;
    }
  }

  /// Sends [json] to each of our [devices] through its self-queue in
  /// [addresses] (E15e/E15j/E15k). True only when the box took every copy;
  /// a copy it did not take is also in the durable log.
  Future<bool> _relayToSiblings(
    Iterable<int> devices,
    Map<int, ContactOutbound> addresses,
    String json, {
    required int peer,
  }) async {
    final outbox = boxOutbox;
    if (outbox == null) return devices.isEmpty;
    var all = true;
    for (final device in devices) {
      final to = addresses[device];
      var taken = false;
      if (to != null) {
        try {
          final frame = await encryptForOwnDevice(device, json);
          taken =
              frame != null &&
              await outbox.deliver(to, frame.encode()) == BoxSendOutcome.taken;
          // `avoid_catching_errors` is waived here: a copy too big for one
          // frame or seal is refused with an ArgumentError, and a refused
          // copy is a failed one, recorded below.
          // ignore: avoid_catching_errors
        } on ArgumentError {
          taken = false;
        }
      }
      if (!taken) {
        all = false;
        E2ePersistentDiag.record('BOX_SIBLING_COPY_FAILED', {
          'peer': peer,
          'device': device,
        });
      }
    }
    return all;
  }

  /// Our live siblings and their self-queue addresses; null when the own
  /// list cannot be verified now.
  Future<({List<int> devices, Map<int, ContactOutbound> addresses})?>
  _siblingTargets() async {
    final outbox = boxOutbox;
    final mine = await ownLiveDevices();
    if (outbox == null || mine == null) return null;
    return (
      devices: [
        for (final d in mine.live)
          if (d != mine.self) d,
      ],
      addresses: outbox.siblingAddresses(),
    );
  }

  Future<bool> _relayToAllSiblings(String json, {required int peer}) async {
    final siblings = await _siblingTargets();
    if (siblings == null) return false;
    return _relayToSiblings(
      siblings.devices,
      siblings.addresses,
      json,
      peer: peer,
    );
  }

  /// Tells our siblings [userId] is a friend over the box now (E15e): the
  /// `friend_accepted` copy, sent by EVERY device that becomes the friend
  /// (the accepter, the requester on the accept, a sibling on the
  /// account's handoff), so one that missed an earlier copy still befriends
  /// and hands the account its queue — decision 16 keeps the account from
  /// writing to us until every one of our devices has. A sibling already a
  /// friend ignores it. Built from what this device holds: the record's
  /// addresses, bundles and profile, and the account's kept list.
  Future<void> _relayFriendship(int userId, {FirstContactPeer? served}) async {
    final record = boxFirstContact?.firstContact.contactOf(userId);
    final origin = record?.boxOrigin;
    final peer =
        served ??
        (record == null || origin == null
            ? null
            : FirstContactPeer.fromSearchEntry({
                'id': userId,
                'username': record.username,
                'tag': record.tag,
                'profilePictureUrl': ?record.avatarUrl,
                'authorization': _encryptionProvider
                    ?.cachedDeviceList(userId)
                    ?.authorization,
                'devices': [
                  for (final MapEntry(key: device, value: bundle)
                      in origin.bundles.entries)
                    {
                      'deviceId': device,
                      'bundle': bundle,
                      'requestSid': origin.addresses
                          .where((a) => a.peerDeviceId == device)
                          .firstOrNull
                          ?.sid,
                      'sealPub': origin.addresses
                          .where((a) => a.peerDeviceId == device)
                          .firstOrNull
                          ?.sealPub,
                    },
                ],
              }));
    if (peer == null) return;
    await _relayToAllSiblings(
      jsonEncode(
        E2eEnvelope.buildFriendRelay(
          E2eEnvelope.typeFriendAccepted,
          peer.toSiblingJson(),
        ),
      ),
      peer: userId,
    );
  }

  /// A photo path a profile carried (decision 55), on OUR server.
  static String? _ownServerAvatar(String? path) =>
      path == null ? null : '${AppConfig.baseUrl}$path';

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
    if (_boxPending(peer, ContactState.pendingOut) &&
        BoxFirstContact.shownPending(peer!, now)) {
      return _takeCrossedRequest(link, enc, entry, signal);
    }
    final state = peer?.state;
    if (state != null &&
        !_boxPending(peer, ContactState.pendingIn) &&
        !_boxPending(peer, ContactState.pendingOut)) {
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
    final me = link.firstContact.ownProfile;
    if (offered == null || me == null) {
      refused('not_a_request');
      return true;
    }
    if (!await link.firstContact.befriend(
      user,
      avatarUrl: _ownServerAvatar(offered.profile?.avatarUrl),
    )) {
      return false;
    }
    await link.acceptFirstContact(
      user,
      device,
      sid: offered.sid,
      sealPub: offered.sealPub,
      profile: me,
    );
    link.firstContactFriend(user);
    await _relayFriendship(user);
    _afterBoxFriendship(user, outgoing: true);
    return true;
  }

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
    if (!_boxPending(record, ContactState.pendingIn)) {
      return FirstContactAccept.failed;
    }
    // Our own profile rides the accept (decision 55): without it nothing is
    // decrypted, since a decrypt spends the frame's one-time pre-key.
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
      );
    } on DeviceListVerificationException {
      // The answer does not vouch for itself, or another key is pinned.
      return unverified('served_list');
    } on Object {
      // Storage or readiness: nothing about the request was decided.
      return FirstContactAccept.failed;
    }
    final opened = await _openKept(enc, record!, list);
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
    final me = link.firstContact.ownProfile;
    if (me == null) return false;
    final stated = offered.values
        .map((o) => o.profile?.avatarUrl)
        .whereType<String>()
        .firstOrNull;
    if (!await link.firstContact.befriend(
      peer.userId,
      profile: peer.profile,
      avatarUrl: _ownServerAvatar(stated) ?? peer.avatarUrl,
      addresses: peer.addresses,
      bundles: peer.servedBundles,
    )) {
      return false;
    }
    for (final MapEntry(key: device, value: queue) in offered.entries) {
      await link.acceptFirstContact(
        peer.userId,
        device,
        sid: queue.sid,
        sealPub: queue.sealPub,
        profile: me,
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
    if (link == null || !_boxPending(record, ContactState.pendingIn)) return;
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
    _conversationsProvider?.refreshLocalChats();
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
    if (link == null || !_boxPending(record, ContactState.pendingOut)) {
      return true;
    }
    if (!await link.firstContact.befriend(
      userId,
      avatarUrl: _ownServerAvatar(E2eEnvelope.profileOf(plaintext)?.avatarUrl),
    )) {
      return false;
    }
    link.firstContactFriend(userId);
    await _relayFriendship(userId);
    _afterBoxFriendship(userId, outgoing: true);
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
        avatarUrl: peer.avatarUrl,
      )) {
        onBoxContactsChanged?.call();
      }
      return true;
    }
    // We accepted on another device. A request this device kept too is
    // opened as there; with none, the pass covers the account's devices.
    final offered = _boxPending(record, ContactState.pendingIn)
        ? (await _openKept(enc, record!, list)).offered
        : const <int, ({String sid, String sealPub, E2eProfile? profile})>{};
    if (!_boxPending(record, ContactState.pendingIn) &&
        !await link.firstContact.asked(
          userId: userId,
          profile: peer.profile,
          addresses: peer.addresses,
          bundles: peer.servedBundles,
          avatarUrl: peer.avatarUrl,
        )) {
      // A request the server carries, a blocked account: not ours to make.
      return true;
    }
    if (!await _befriendServed(link, peer, offered)) return false;
    if (record != null) await _dropKeptReplays(enc, record);
    _afterBoxFriendship(userId, outgoing: false);
    return true;
  }

  // ---------- The end of a friendship (E15j) ----------

  /// Ends the friendship made over the box with [userId] — or, for a
  /// [block], any request pending over the box with it: our siblings are
  /// told FIRST, then a `goodbye` goes to each of its devices this device
  /// holds an address for (best effort), then our queues for it are deleted
  /// and the record goes or stays `blocked`. Throws [StateError] — nothing
  /// ended, nothing sent to the peer — when a sibling's copy did not go: a
  /// sibling that never hears of it would keep writing into queues the
  /// peer deletes (review). The chat and its history are the caller's
  /// (`FriendsProvider` removes them right after, while the chat row still
  /// names the peer).
  Future<void> endBoxFriendship(int userId, {required bool block}) async {
    final link = boxFirstContact;
    final friends = boxFriends;
    final outbox = boxOutbox;
    final record = friends?.contactOf(userId);
    if (link == null || record?.boxOrigin == null) return;
    if (!await _relayToAllSiblings(
      jsonEncode(E2eEnvelope.buildGoodbye(sentTo: userId, block: block)),
      peer: userId,
    )) {
      throw StateError('box end of $userId: a sibling was not told');
    }
    if (record!.state == ContactState.friend && outbox != null) {
      final goodbye = jsonEncode(E2eEnvelope.buildGoodbye());
      for (final MapEntry(key: device, value: to)
          in outbox.addressesFor(userId).entries) {
        final frame = await encryptForFriend(userId, device, goodbye);
        final sent =
            frame != null &&
            await outbox.deliver(to, frame.encode()) == BoxSendOutcome.taken;
        if (!sent) {
          _firstContactLog('BOX_GOODBYE_NOT_SENT', userId, {'device': device});
        }
      }
    }
    await link.endBoxFriendship(userId, block: block);
    _afterBoxFriendshipEnded(userId);
  }

  /// A `goodbye` read from [userId] — a friend made over the box — or a
  /// sibling's copy of ours: the same local end, with no goodbye sent.
  Future<bool> _takeGoodbye(int userId, {required bool block}) async {
    final link = boxFirstContact;
    if (link == null) return false;
    if (link.firstContact.contactOf(userId)?.boxOrigin == null) {
      // A friendship the server knows ends on the server's unfriend.
      _firstContactLog('BOX_GOODBYE_IGNORED', userId);
      return true;
    }
    await link.endBoxFriendship(userId, block: block);
    // The chat goes, and its history with it, while its row still names the
    // peer: a list refresh first would drop the row and leave the history
    // on disk for a later friendship to show again (review).
    onBoxFriendshipEnded?.call(userId);
    _afterBoxFriendshipEnded(userId);
    return true;
  }

  /// The lists re-read the store; the chat list is left to the removal
  /// above (or the caller's), never refreshed first.
  void _afterBoxFriendshipEnded(int userId) {
    _firstContactLog('BOX_FRIENDSHIP_ENDED', userId);
    onBoxContactsChanged?.call();
    notifyListeners();
  }

  // ---------- The chat's timer setting (E15k) ----------

  /// Our chat with [peerUserId] — a friendship made over the box — got the
  /// timer [seconds] (null = off) at [at]: every device of the friend this
  /// device holds an address for, and our siblings, are told. Best effort;
  /// the latest write wins on every device.
  Future<void> sendBoxChatTimer(
    int peerUserId,
    int? seconds,
    DateTime at,
  ) async {
    final outbox = boxOutbox;
    if (outbox == null ||
        boxFriends?.contactOf(peerUserId)?.boxOrigin == null) {
      return;
    }
    final timer = jsonEncode(E2eEnvelope.buildTimer(ttl: seconds, sentAt: at));
    for (final MapEntry(key: device, value: to)
        in outbox.addressesFor(peerUserId).entries) {
      final frame = await encryptForFriend(peerUserId, device, timer);
      if (frame == null ||
          await outbox.deliver(to, frame.encode()) != BoxSendOutcome.taken) {
        _firstContactLog('BOX_TIMER_NOT_SENT', peerUserId, {'device': device});
      }
    }
    await _relayToAllSiblings(
      jsonEncode(
        E2eEnvelope.buildTimer(ttl: seconds, sentAt: at, sentTo: peerUserId),
      ),
      peer: peerUserId,
    );
  }

  /// A timer setting read for the chat with [peerUserId] (from the friend,
  /// or a sibling's copy): applied when newer than the one held, its time
  /// clamped to our own receive time (decision 13).
  bool _takeBoxTimer(int peerUserId, String plaintext, DateTime receivedAt) {
    final timer = E2eEnvelope.parseTimer(plaintext);
    if (timer == null || boxFriends?.contactOf(peerUserId)?.boxOrigin == null) {
      _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'t': E2eEnvelope.typeTimer});
      return true;
    }
    final at = timer.sentAt.isAfter(receivedAt) ? receivedAt : timer.sentAt;
    final convs = _conversationsProvider;
    if (convs != null) {
      unawaited(convs.applyLocalChatTimer(peerUserId, timer.ttl, at));
    }
    return true;
  }

  // ---------- A box friend's list (E15h) ----------

  /// The `authorization` record of [userId] — a friendship made over the
  /// box, whose list this device does not hold — from one `searchUsers` of
  /// its handle: `getDeviceList` would name the pair, and the server refuses
  /// it for a pair it does not know anyway. Its fresh bundles and addresses
  /// are kept. Throws when no answer names that account.
  Future<Map<String, dynamic>?> lookupBoxPeerList(int userId) async {
    final link = boxFirstContact;
    final lookup = lookupHandle;
    final record = link?.firstContact.contactOf(userId);
    if (link == null || lookup == null || record == null) {
      throw StateError('box peer $userId: no lookup');
    }
    final answer = await lookup('${record.username}#${record.tag}');
    final peer = answer == null || answer.isEmpty
        ? null
        : FirstContactPeer.fromSearchEntry(answer.first);
    if (peer == null || peer.userId != userId) {
      throw StateError('box peer $userId: no search answer');
    }
    await link.firstContact.refreshServed(peer);
    return peer.authorization;
  }
}
