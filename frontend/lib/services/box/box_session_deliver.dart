part of 'box_session.dart';

/// The sends and handoff stores behind a [BoxSession]'s [BoxOutbox],
/// [BoxSiblingLink] and [BoxFriendLink] members (those stay in the class: an
/// extension cannot implement an interface).
extension BoxSessionDeliver on BoxSession {
  /// The box's answer to [body] sealed to [to]; null when nothing was sent
  /// (a bad address, a failed seal, a disposed session).
  Future<BoxResult<void>?> _sealAndSend(
    ContactOutbound to,
    Uint8List body,
    BoxSendMode? mode, {
    FriendPermit? permit,
    bool request = false,
  }) async {
    final sid = boxB64Decode(to.sid, kBoxSidBytes);
    final sealPub = boxB64Decode(to.sealPub, 32);
    if (_disposed || sid == null || sealPub == null) return null;
    // Friend lane only: a self-queue or sibling address is never gated. A
    // write that carries a permit is a friend write whatever the stored
    // addresses say now (the handoff may have replaced the one it was sealed
    // for: then it is refused, not let through as "nobody's"). A
    // first-contact request takes the permit its own sealed PreKey made.
    final friend = permit?.friend ?? _friendOfSid(to.sid);
    final p = friend == null || !request ? permit : _gate.requestPermit(friend);
    if (friend != null && _gate.refusalOf(p, to.sid) != null) return null;
    final blob = await _seal.seal(sealPub, body);
    if (blob == null || _disposed) return null;
    // After the last await, in the step of the write.
    if (friend != null && _gate.refusalOf(p, to.sid) != null) {
      E2eDiagLog.add('BOX_FRIEND_WRITE_REFUSED', {'why': 'at_write'});
      return null;
    }
    return _box.send(sid, blob, mode: mode);
  }

  /// Encrypts [envelope] for sibling [to] and seals it into its self-queue
  /// as a normal frame; true only when the box took it.
  Future<bool> _sendToSibling(
    ContactOutbound to,
    Map<String, dynamic> envelope,
  ) async {
    final encrypt = _swap.encrypt;
    if (_disposed || encrypt == null) return false;
    final frame = await encrypt(to.peerDeviceId, jsonEncode(envelope));
    return frame != null &&
        await deliver(to, frame.encode()) == BoxSendOutcome.taken;
  }

  /// Sibling [deviceId] acked [sid], which is not our current self-queue: it
  /// learned an older handoff after the newer one (they travel through
  /// different queues, which the box does not order), and would send into a
  /// queue that is retiring or gone. Its ack is forgotten, so the
  /// swap hands it the current queue — asked again now, and on every
  /// connect until it acks. The re-hand leaves only after the stale handoff
  /// was read, so it cannot be overtaken by it.
  Future<SiblingWrite> _staleAck(int deviceId, String sid) async {
    final self = _store.selfQueue;
    if (self == null || self.sid == sid || _store.siblingsUnsupported) {
      return SiblingWrite.refused;
    }
    final forgot = await _store.forgetSiblingAck(deviceId);
    if (forgot != SiblingWrite.stored) return forgot;
    E2eDiagLog.add('BOX_SIBLING_STALE_ACK', {'device': deviceId});
    _swap.handAgain();
    return SiblingWrite.stored;
  }

  /// Store → ack → hand-back (item 5): [userId]'s [deviceId] address, on a
  /// record already `friend`; our hand-back carries [profile] when this is
  /// the accept of a first contact (slice (f), decision 55).
  ///
  /// [learnedUnder]: the account identity (base64) that authenticated the
  /// frame the address came from; it becomes the address's `idk`. A handoff
  /// learned under another identity than the friend's pinned anchor is
  /// FINISHED and stores nothing (an old device of the friend, read on a
  /// session of the old identity, must not replace a current address). Null
  /// means the frame's identity is unknown: nothing is refused and an
  /// address of another sid is stored untagged (tagged at the next pin).
  Future<FriendWrite> _takeHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
    required String? learnedUnder,
    E2eProfile? profile,
  }) async {
    if (_disposed) return FriendWrite.retryLater;
    final anchor = _anchorOf?.call(userId);
    if (learnedUnder != null && anchor != null && learnedUnder != anchor) {
      E2eDiagLog.add('BOX_FRIEND_HANDOFF_REFUSED', {
        'peer': userId,
        'device': deviceId,
        'why': 'learned_under_other_identity',
      });
      return FriendWrite.refused;
    }
    var friend = false;
    final committed = await _store.update(userId, (current) {
      if (current == null || current.state != ContactState.friend) return null;
      friend = true;
      final held = current.outbound
          .where((o) => o.peerDeviceId == deviceId)
          .firstOrNull;
      // What the device last said about relaying (decision 101 A, E101b)
      // holds on its new queue; the frame that said it may be this handoff.
      final relays = _friendRelays[(userId, deviceId)] ?? held?.relays ?? false;
      final idk = learnedUnder ?? (held?.sid == sid ? held?.idk : null);
      // The same queue re-announced under a NEW identity is re-tagged, so
      // the shortcut compares the tag too.
      if (held?.sid == sid &&
          held?.sealPub == sealPub &&
          held?.relays == relays &&
          held?.idk == idk) {
        return null;
      }
      return current.copyWith(
        outbound: [
          for (final o in current.outbound)
            if (o.peerDeviceId != deviceId) o,
          ContactOutbound(
            peerDeviceId: deviceId,
            sid: sid,
            sealPub: sealPub,
            idk: idk,
            relays: relays,
          ),
        ],
      );
    });
    if (!committed) return FriendWrite.retryLater;
    if (!friend) return FriendWrite.refused;
    _friends.noteRoutes();
    final acked = await _sendToFriend(
      userId,
      deviceId,
      E2eEnvelope.buildQueueHandoffAck(sid: sid),
    );
    final ours = _store.byUserId(userId)?.queues.firstOrNull;
    bool? handedBack;
    if (ours == null || !ours.ackedBy.contains(deviceId)) {
      handedBack = false;
      final ensured = await _keys.ensureInbound(userId);
      if (ensured case InboundQueueCreated(:final queue)) {
        if (ours == null) _registerPush();
        handedBack = await _sendToFriend(
          userId,
          deviceId,
          E2eEnvelope.buildQueueHandoff(
            sid: queue.sid,
            sealPub: queue.sealPub,
            profile: profile,
          ),
        );
        if (handedBack) _friends.noteHanded(userId, deviceId, queue.sid);
      }
    }
    E2eDiagLog.add('BOX_FRIEND_HANDOFF', {
      'device': deviceId,
      'acked': acked,
      'handedBack': ?handedBack,
      if (profile != null) 'accept': true,
    });
    return FriendWrite.stored;
  }

  /// Encrypts [envelope] for [userId]'s [deviceId] and sends it to where
  /// that device takes it (the queue it handed us, else its request queue);
  /// true only when the box took it.
  Future<bool> _sendToFriend(
    int userId,
    int deviceId,
    Map<String, dynamic> envelope,
  ) async {
    final encrypt = _friends.encrypt;
    final target = _friends.targetOf(userId, deviceId);
    if (_disposed || encrypt == null || target == null) return false;
    final permit = _friends.gate?.permitFor(userId, to: [target.to]);
    if (permit == null) return false;
    final frame = await encrypt(
      userId,
      deviceId,
      jsonEncode(envelope),
      permit: permit,
    );
    return frame != null &&
        await _friends.send(target, frame, permit: permit) is BoxOk;
  }
}
