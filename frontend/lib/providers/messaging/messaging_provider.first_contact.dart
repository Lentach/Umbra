part of '../messaging_provider.dart';

/// First contact over the request queues (metadata-privacy PR3.1 slice (f),
/// owner decisions 52–55, engineering calls E15a–E15k in
/// `docs/plans/2026-09-25-metadata-pr31-remainder.md` § Item 7): the Signal
/// half. The records live in `BoxFirstContact`, the box half in `BoxSession`.
///
/// * A request goes over the box only when every device on both sides is on
///   it (E15a), never split — else it fails. It is one
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
  /// `searchUsersResult` entry — over the box, the only way a request goes.
  /// [FirstContactSend.failed] when a device on either side is not on the
  /// box (E15a) or the request cannot be built. [FirstContactSend.sent] once
  /// at least one target device took its frame: the others learn of the
  /// friendship from the accepting device's siblings copy (E15e) and the
  /// handoff pass.
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
      return FirstContactSend.failed;
    }
    if (!friends.onBox || !peer.allOnBox) return FirstContactSend.failed;
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
      // A friend, a blocked account: not a first contact.
      return FirstContactSend.failed;
    }
    final mine = await ownLiveDevices();
    if (mine == null) return FirstContactSend.failed;
    final siblingAddresses = outbox.siblingAddresses();
    final siblings = [
      for (final d in mine.live)
        if (d != mine.self) d,
    ];
    if (siblings.any((d) => !siblingAddresses.containsKey(d))) {
      return FirstContactSend.failed;
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
        // No record, or a former one: the account is no contact now, so a
        // key pinned for it is a leftover (decision 112).
        replaceStaleAnchor: fresh,
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
    // served with a request address (decision 16's all-or-nothing): there is
    // no other way to ask.
    if (targets.isEmpty || targets.any((d) => served[d]?.request == null)) {
      return FirstContactSend.failed;
    }
    // An upload older than a week is made again FIRST (decision 138): the
    // `av` this request carries must name a file the box still holds.
    await _refreshOwnPhotoIfStale();
    final me = link.firstContact.ownProfile;
    if (me == null) return FirstContactSend.failed;
    final asked = await link.firstContact.asked(
      userId: userId,
      profile: peer.profile,
      addresses: [for (final d in targets) served[d]!.request!],
      bundles: peer.servedBundles,
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
      if (fresh) await _retireUnansweredRequest(link, friends, userId);
      onBoxContactsChanged?.call();
      return FirstContactSend.failed;
    }
    final queue = await link.firstContactQueue(userId);
    if (queue == null) {
      if (fresh) await _retireUnansweredRequest(link, friends, userId);
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
    var busy = false;
    for (final d in targets) {
      switch (await _sendRequestFrame(enc, link, own, userId, served[d]!, (
        request: request,
        claim: claim,
      ))) {
        case BoxRequestSend.taken:
          delivered++;
          // This device started that session: the device's answer may come
          // as a PreKey message replacing it (item 5's "asked" rule).
          friends.friendSessionStarted(userId, d);
        case BoxRequestSend.busy:
          busy = true;
        case BoxRequestSend.failed:
          break;
      }
    }
    if (delivered == 0) {
      // Nothing reached the peer: the request did not happen. Our
      // siblings' copies lapse with the request (decision 54).
      if (fresh) await _retireUnansweredRequest(link, friends, userId);
      onBoxContactsChanged?.call();
      // The box is full (plan D2): the sender is told to try later.
      return busy ? FirstContactSend.busy : FirstContactSend.failed;
    }
    _firstContactLog('BOX_REQUEST_SENT', userId, {
      'devices': targets.length,
      'delivered': delivered,
    });
    onBoxContactsChanged?.call();
    return FirstContactSend.sent;
  }

  /// Undoes a request of ours that did not go out — unless the awaits of the
  /// send let the account's crossing request in meanwhile: it is a friend
  /// now (E15f) and the queue is its, not a leftover of the ask.
  Future<void> _retireUnansweredRequest(
    BoxFirstContactLink link,
    BoxFriendLink friends,
    int userId,
  ) async {
    await _crossingsInFlight[userId];
    if (!_boxPending(friends.contactOf(userId), ContactState.pendingOut)) {
      return;
    }
    await link.retireFirstContact(userId);
  }

  /// One claim-bearing PreKey frame for [device] (E15b): a FRESH session
  /// from the bundle this very answer served, the envelope inside Signal,
  /// the claim outside it. [BoxRequestSend.taken] only when the box took it.
  Future<BoxRequestSend> _sendRequestFrame(
    EncryptionProvider enc,
    BoxFirstContactLink link,
    int own,
    int userId,
    FirstContactDevice device,
    ({String request, String claim}) payload,
  ) async {
    final to = device.request;
    if (to == null) return BoxRequestSend.failed;
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
      if (frame == null || frame.kind != BoxFrameKind.preKey) {
        return BoxRequestSend.failed;
      }
      return await link.deliverRequest(
        to,
        BoxFrame(
          kind: frame.kind,
          senderDeviceId: frame.senderDeviceId,
          senderUserId: own,
          signal: frame.signal,
          carriedClaim: payload.claim,
        ).encode(),
      );
    } on Object catch (e) {
      _firstContactLog('BOX_REQUEST_FRAME_FAILED', userId, {
        'device': device.deviceId,
        'error': e.runtimeType.toString(),
      });
      return BoxRequestSend.failed;
    }
  }

  /// A photo path a profile carried (decision 55), on OUR server.
  static String? _ownServerAvatar(String? path) =>
      path == null ? null : '${AppConfig.baseUrl}$path';
}
