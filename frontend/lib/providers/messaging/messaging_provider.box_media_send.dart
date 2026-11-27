part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

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

/// A box attachment's send, out of [MessagingBox]: encrypted once, held,
/// uploaded once, then sent as frames ([MessagingBoxSend._sendOverBox]).
extension MessagingBoxMediaSend on MessagingProvider {
  /// Sends attachment [tempId] to a peer over the box (item 3 / media
  /// wiring, E17a) — the only path an attachment has: the route is decided
  /// BEFORE anything is uploaded, then the file is encrypted whole, padded
  /// to a ladder rung, uploaded ONCE and sent as frames carrying its id
  /// ([_uploadBoxMediaAndSend]).
  ///
  /// A peer with no route, a list that cannot be verified, a refused upload
  /// or no answer fails the row ('Ponów', decisions 19, 31) — never an
  /// upload to the server. So does a reply whose quote cannot be named: it
  /// is never sent without it. Each of those holds the encrypted file for
  /// its retry (E17b); a route that is simply absent holds it too, so the
  /// retry uploads once the peer has one. [bytes] is the plaintext of a first
  /// send; without it this is a retry of an upload that never succeeded: it
  /// uploads the SAME held ciphertext, key and IV. [recording] is a voice
  /// note's plaintext file, deleted once the upload succeeds.
  Future<bool> _sendMediaOverBox({
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
    // The row is not failed under an upload in flight.
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
      // A send to a friend that has a line of waiting messages, or a pump
      // running, joins the END of it (no overtaking); the held bytes wait in
      // this process.
      final owner = _currentUserId;
      final conversationId =
          row?.conversationId ??
          _conversationsProvider?.conversations
              .where(
                (c) => conv_helpers.getOtherUserId(c, owner) == recipientId,
              )
              .firstOrNull
              ?.id;
      if (owner != null &&
          conversationId != null &&
          !_pumpOwned.contains(tempId) &&
          await _friendQueueBusy(owner, recipientId, conversationId)) {
        if (bytes != null) await _holdBoxMedia(tempId, bytes, recording);
        await _holdForGate(recipientId, tempId);
        return false;
      }
      if (outbox == null || addresses.isEmpty) {
        if (bytes != null) await _holdBoxMedia(tempId, bytes, recording);
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
        if (bytes != null) await _holdBoxMedia(tempId, bytes, recording);
        _e2eFlowLog('BOX_RETRY_NO_ROUTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
      final body = bytes != null
          ? await _holdBoxMedia(tempId, bytes, recording)
          : _boxMediaBodies[tempId];
      if (body == null) throw StateError('no held attachment');
      // After the hold: the retry uploads what is held here.
      if (_peersAllPaused(route, recipientId, tempId)) return false;
      // Before the upload: a closed gate (a calm hold, a stale address) takes
      // no file for the old key either.
      if (_friendPermit(recipientId, to: route.targets) == null) {
        await _holdForGate(recipientId, tempId);
        return false;
      }
      if (effectiveReplyToId != null && _boxQuoteOf(atSend.replyTo) == null) {
        _sendNeverGoes.add(tempId);
        _e2eFlowLog('BOX_MEDIA_NO_QUOTE', {'tempId': tempId});
        _markMessageFailed(tempId, 'Could not send. Try again.');
        return false;
      }
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
    final encrypted = await _mediaCrypto.encrypt(bytes);
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
    // The upload is a write to the friend's queue (its budget pays): it takes
    // its own permit, in the step before it.
    final permit = _friendPermit(recipientId, to: [route.targets.first]);
    if (permit == null) {
      await _holdForGate(recipientId, tempId);
      return false;
    }
    final outbox = route.outbox;
    final framed = frameMediaToRung(body.ciphertext);
    final answer = switch (outbox) {
      final BoxFriendGateOutbox gate => await gate.uploadMediaFriend(
        route.targets.first,
        framed,
        permit: permit,
      ),
      _ => await outbox.uploadMedia(route.targets.first, framed),
    };
    final Uint8List id;
    final Uint8List? secret;
    switch (answer) {
      case BoxOk(:final value):
        id = value.id;
        secret = value.deleteSecret;
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
    // Plan D3: the secret stays on this device, beside the copy; it is not
    // in the record and never in an envelope.
    if (user != null && secret != null) {
      boxMedia?.keepDeleteSecret(user, id, secret).ignore();
    }
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
}
