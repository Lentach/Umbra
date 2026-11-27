part of '../messaging_provider.dart';

/// What a friendship over the box keeps in step afterwards, out of
/// [MessagingFirstContact] (E15h, E15k, E114a-b): the chat's timer
/// setting, and a friend's device list and request-queue addresses from
/// one handle lookup.
extension MessagingFirstContactFriend on MessagingProvider {
  // ---------- The chat's timer setting (E15k) ----------

  /// Our chat with [peerUserId] — a friend the box carries, whoever made the
  /// friendship (decision 107) — got the timer [seconds] (null = off) at
  /// [at]: every device of the friend this device holds an address for, and
  /// our siblings, are told. Best effort; the latest write wins on every
  /// device.
  Future<void> sendBoxChatTimer(
    int peerUserId,
    int? seconds,
    DateTime at,
  ) async {
    final outbox = boxOutbox;
    if (outbox == null ||
        !(boxFriends?.contactOf(peerUserId)?.onBoxRoute ?? false)) {
      return;
    }
    final timer = jsonEncode(E2eEnvelope.buildTimer(ttl: seconds, sentAt: at));
    for (final MapEntry(key: device, value: to)
        in outbox.addressesFor(peerUserId).entries) {
      final sealed = await _sealFriend(peerUserId, device, to, timer);
      // A setting, not a message: quiet, no wake (decision 91). A closed gate
      // leaves it unsent and OWED: the pump sends the current timer once
      // when the gate opens.
      if (sealed.permit == null) {
        final own = _currentUserId;
        if (own != null) _timerOwed.add((own, peerUserId));
      }
      if (sealed.frame == null ||
          await _deliverFriend(
                outbox,
                to,
                sealed.frame!.encode(),
                mode: BoxSendMode.quiet,
                permit: sealed.permit,
              ) !=
              BoxSendOutcome.taken) {
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
    if (timer == null ||
        !(boxFriends?.contactOf(peerUserId)?.onBoxRoute ?? false)) {
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

  // ---------- A friend's list and addresses (E15h, E114a-b) ----------

  /// The `authorization` record of [userId] — a friend whose list this device
  /// does not hold, whether the friendship was made over the box or before it
  /// (decision 114) — from one `searchUsers` of its handle: `getDeviceList`
  /// would name the pair, and once Phase 4 is through the server refuses it
  /// for a pair it does not know anyway. Its request queues are kept for this
  /// process (`takeServedAddresses`, where the handoff goes until that device
  /// hands us its own queue), for every friend alike; on a friendship made
  /// over the box its fresh bundles are kept too. The
  /// answer's identity becomes the account anchor when none is held — a
  /// friend restored from the contact backup, which carries no keys, as
  /// first contact pinned it (E38d). Throws when no answer names that
  /// account.
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
    link.takeServedAddresses(userId, peer.addresses);
    final enc = _encryptionProvider;
    final identity = peer.identityKey;
    if (enc != null && identity != null) {
      try {
        // Pins only when no anchor is held; a pinned key that differs is a
        // key change, which stays a human's call ((xlvi)), and the caller's
        // check under the held anchor decides as before.
        await enc.adoptServedAccount(
          userId,
          identityKey: identity,
          authorization: peer.authorization,
        );
      } on DeviceListVerificationException catch (e) {
        // Judged again by the caller under whatever anchor is held.
        _e2eFlowLog('BOX_LIST_LOOKUP_NOT_ADOPTED', {
          'userId': userId,
          'reason': e.reason,
        });
      }
    }
    return peer.authorization;
  }

  /// One handle lookup of friend [userId] for the request queues of its
  /// devices (`BoxFriendHandoff.addressLookup`, E114b): [lookupBoxPeerList]
  /// keeps them, and the list it serves is adopted like any other. Completes
  /// false, having asked nothing, while E2E is not ready (the caller asks
  /// again later); throws when the lookup is spent (the first of a process,
  /// then one per event that owes it, E114m) or answers nothing — the caller
  /// then adds no address.
  Future<bool> lookupFriendAddresses(int userId) async {
    final enc = _encryptionProvider;
    if (enc == null || !enc.isE2EReady) return false;
    await enc.getVerifiedDeviceList(userId, forceRefresh: true);
    return true;
  }
}
