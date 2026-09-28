part of '../messaging_provider.dart';

/// How often typing `on` goes into one chat at most (E61e): a friend with
/// three devices then costs ~540 sends per 15 min, under the box's 1 500
/// per-IP `send` throttle.
const Duration _boxTypingEvery = Duration(seconds: 5);

/// How long a peer's typing shows after its last frame (E61e).
const Duration _boxTypingShown = Duration(seconds: 6);

/// While recording, voice `on` goes again this often: `off` is live and may
/// be lost, so the receiver lets `on` expire ([_boxVoiceShown]).
const Duration _boxVoiceEvery = Duration(seconds: 5);

/// How long a peer's voice indicator shows after its last `on`.
const Duration _boxVoiceShown = Duration(seconds: 12);

/// How [MessagingProvider._boxReadReported] names one peer message.
String _boxWireKey(int peer, String wireId) => '$peer|$wireId';

/// Receipts and typing of a box chat (metadata-privacy slice (g), decisions
/// 61–62, E61a–E61f): envelopes `rcpt` and `typ` inside E2E, sent only to
/// the live PEER devices of a box-covered friend's chat — never a sent copy
/// to our siblings, never the old path, no retry, no failure surface —
/// receipts `quiet` (stored, never wake a device), typing `live` (only to a
/// socket subscribed now). All of it only while the device-local switch
/// [MessagingProvider.receiptsAndTyping] is on; off, nothing is sent and
/// everything received is ignored. An old-path chat keeps the server's
/// ticks and typing.
extension MessagingBoxReceipts on MessagingProvider {
  /// The inbox read everything queued so far — the end of one drain: one
  /// `rcpt d` per peer naming its box messages this device took (E61d). A
  /// message is stored once, so it is owed once; one already reported read
  /// is not reported delivered after it.
  void onBoxReadsIdle() {
    if (_boxDeliveredOwed.isEmpty) return;
    final owed = Map.of(_boxDeliveredOwed);
    _boxDeliveredOwed.clear();
    if (!receiptsAndTyping()) return;
    for (final MapEntry(key: peer, value: wires) in owed.entries) {
      _sendBoxReceipt(peer, E2eReceiptKind.delivered, [
        for (final wire in wires)
          if (!_boxReadReported.contains(_boxWireKey(peer, wire))) wire,
      ]);
    }
  }

  /// [msg], a peer's box message, is stored here: owed in the next `rcpt d`
  /// to its sender ([onBoxReadsIdle]). A sibling's sent copy is ours and
  /// owes nothing.
  void _owedBoxDelivered(MessageModel msg) {
    final wire = msg.wireId;
    final peer = msg.senderId;
    if (wire == null || peer == _currentUserId || !receiptsAndTyping()) return;
    (_boxDeliveredOwed[peer] ??= <String>{}).add(wire);
  }

  /// This device shows [conversationId] and marks it read: one `rcpt r` to
  /// the peer naming its box messages shown here that this device has not
  /// reported read (E61d). Only for the chat on screen with the app in the
  /// foreground — the moments a box message's countdown starts (decision
  /// 41). A message is reported once a device took the receipt: its row is
  /// then `read`, kept in its record, so no later launch names it again;
  /// one no device took is named again the next time the chat is shown.
  void _sendBoxReadReceipt(int conversationId) {
    final own = _currentUserId;
    if (own == null || !receiptsAndTyping()) return;
    if (_conversationsProvider?.isClientVisible == false) return;
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    if (conversationId != viewing) return;
    final conversation = _conversationsProvider?.getConversationById(
      conversationId,
    );
    if (conversation == null) return;
    final peer = conv_helpers.getOtherUserId(conversation, own);
    final wires = <String>[];
    for (final m in _messages) {
      final wire = m.wireId;
      if (wire == null ||
          m.conversationId != conversationId ||
          m.senderId != peer ||
          !isLocalMessageId(m.id) ||
          m.deliveryStatus == MessageDeliveryStatus.read) {
        continue;
      }
      // In flight or reported: a second show before it settles names it
      // no second time, and the drain's `rcpt d` leaves it out.
      if (_boxReadReported.add(_boxWireKey(peer, wire))) wires.add(wire);
    }
    unawaited(_reportBoxRead(conversationId, peer, wires));
  }

  /// Sends [wires] as `rcpt r` to [peer]; each frame some device took marks
  /// its messages `read` in [conversationId] and in their records, and one
  /// no device took leaves them to the next show.
  Future<void> _reportBoxRead(
    int conversationId,
    int peer,
    List<String> wires,
  ) async {
    for (final chunk in _receiptChunks(wires)) {
      final taken = await _sendBoxSignal(
        peer,
        E2eEnvelope.buildReceipt(E2eReceiptKind.read, chunk),
        BoxSendMode.quiet,
      );
      if (!taken) {
        for (final wire in chunk) {
          _boxReadReported.remove(_boxWireKey(peer, wire));
        }
        continue;
      }
      for (final wire in chunk) {
        // The row as it is NOW: its countdown may have started meanwhile.
        final row = await _heldBoxTarget((
          senderId: peer,
          wireId: wire,
        ), conversationId);
        if (row == null || row.deliveryStatus == MessageDeliveryStatus.read) {
          continue;
        }
        await _replaceBoxRow(
          row.copyWith(deliveryStatus: MessageDeliveryStatus.read),
        );
      }
    }
  }

  /// [wireIds] to [peer] as [kind] receipts; quiet (E61a).
  void _sendBoxReceipt(int peer, E2eReceiptKind kind, List<String> wireIds) {
    for (final chunk in _receiptChunks(wireIds)) {
      unawaited(
        _sendBoxSignal(
          peer,
          E2eEnvelope.buildReceipt(kind, chunk),
          BoxSendMode.quiet,
        ),
      );
    }
  }

  /// [wireIds] in frames of at most [E2eEnvelope.maxReceiptWireIds].
  Iterable<List<String>> _receiptChunks(List<String> wireIds) sync* {
    const most = E2eEnvelope.maxReceiptWireIds;
    for (var i = 0; i < wireIds.length; i += most) {
      final end = i + most < wireIds.length ? i + most : wireIds.length;
      yield wireIds.sublist(i, end);
    }
  }

  /// The composer changed in [conversationId], a box chat with [peer]:
  /// typing `on`, at most once per [_boxTypingEvery] per chat (E61e).
  void _sendBoxTyping(int peer, int conversationId) {
    if (!receiptsAndTyping()) return;
    final now = clock.now();
    final last = _boxTypingSentAt[conversationId];
    if (last != null && now.difference(last) < _boxTypingEvery) return;
    _boxTypingSentAt[conversationId] = now;
    unawaited(
      _sendBoxSignal(
        peer,
        E2eEnvelope.buildTyping(E2eTypingKind.text, on: true),
        BoxSendMode.live,
      ),
    );
  }

  /// A voice recording to [peer] in [conversationId] started or stopped:
  /// sent on every change, and `on` again every [_boxVoiceEvery] while it
  /// runs (E61e).
  void _sendBoxRecordingVoice(
    int peer,
    int conversationId, {
    required bool isRecording,
  }) {
    _boxVoiceResends.remove(conversationId)?.cancel();
    if (!receiptsAndTyping()) return;
    void send({required bool on}) => unawaited(
      _sendBoxSignal(
        peer,
        E2eEnvelope.buildTyping(E2eTypingKind.voice, on: on),
        BoxSendMode.live,
      ),
    );
    send(on: isRecording);
    if (!isRecording) return;
    _boxVoiceResends[conversationId] = Timer.periodic(_boxVoiceEvery, (t) {
      if (!receiptsAndTyping()) {
        t.cancel();
        _boxVoiceResends.remove(conversationId);
        return;
      }
      send(on: true);
    });
  }

  /// Every voice timer — our re-sends and the peer's indicators — stops:
  /// a connect, a disconnect, logout, dispose.
  void _cancelBoxVoiceTimers() {
    for (final t in [..._boxVoiceResends.values, ..._boxVoiceTimers.values]) {
      t.cancel();
    }
    _boxVoiceResends.clear();
    _boxVoiceTimers.clear();
  }

  /// Sends [envelope] once to every live device of [peer] — the peer half
  /// of [_boxRoute] — kept as [mode] (E61b). Best effort: whatever fails is
  /// logged and dropped, never retried here, never the old path, never
  /// thrown. True when at least one device's box took its frame.
  Future<bool> _sendBoxSignal(
    int peer,
    Map<String, dynamic> envelope,
    BoxSendMode mode,
  ) async {
    final type = envelope['t'];
    void dropped(String why) =>
        _e2eFlowLog('BOX_SIGNAL_DROPPED', {'t': type, 'why': why});
    final outbox = boxOutbox;
    final addresses = outbox?.addressesFor(peer) ?? const {};
    if (outbox == null || addresses.isEmpty) {
      dropped('no_route');
      return false;
    }
    try {
      final route = await _boxRoute(peer, outbox, addresses, peerOnly: true);
      if (route == null) {
        dropped('no_route');
        return false;
      }
      final json = jsonEncode(envelope);
      final sealed = await _sealBoxFrames(
        route,
        recipientId: peer,
        json: json,
        copyJson: json,
      );
      final failure = sealed.failure;
      if (failure != null) {
        dropped(failure.name);
        return false;
      }
      final accepted = await Future.wait([
        for (final (to, body) in sealed.frames)
          route.outbox.deliver(to, body, mode: mode),
      ]);
      _e2eFlowLog('BOX_SIGNAL_SEND', {
        't': type,
        'frames': sealed.frames.length,
        'accepted': accepted.where((ok) => ok).length,
      });
      return accepted.contains(true);
    } on Object catch (e) {
      dropped(e.runtimeType.toString());
      return false;
    }
  }

  /// A `rcpt` or `typ` from [msg]'s sender, the peer of [msg]'s chat.
  /// Always finished: with the switch off it is ignored, and a malformed
  /// one is dropped whole.
  Future<bool> _takeBoxSignal(
    MessageModel msg,
    String type,
    String plaintext,
  ) async {
    void dropped(String why) =>
        _e2eFlowLog('BOX_SIGNAL_DROPPED', {'t': type, 'why': why});
    if (!receiptsAndTyping()) {
      dropped('switch_off');
      return true;
    }
    final conversationId = msg.conversationId;
    if (type == E2eEnvelope.typeTyping) {
      final typing = E2eEnvelope.parseTyping(plaintext);
      if (typing == null) {
        dropped('unreadable');
        return true;
      }
      _showBoxTyping(conversationId, typing);
      return true;
    }
    final receipt = E2eEnvelope.parseReceipt(plaintext);
    final own = _currentUserId;
    if (receipt == null || own == null) {
      dropped('unreadable');
      return true;
    }
    await _takeBoxReceipt(conversationId, own, receipt);
    return true;
  }

  /// Moves each of OUR box messages [receipt] names in [conversationId]
  /// forward only — sent, delivered, read — kept in its record so a restart
  /// keeps it (E61f). A message not held here is dropped, never parked.
  Future<void> _takeBoxReceipt(
    int conversationId,
    int own,
    E2eReceipt receipt,
  ) async {
    final to = switch (receipt.kind) {
      E2eReceiptKind.delivered => MessageDeliveryStatus.delivered,
      E2eReceiptKind.read => MessageDeliveryStatus.read,
    };
    for (final wireId in receipt.wireIds) {
      final target = await _heldBoxTarget((
        senderId: own,
        wireId: wireId,
      ), conversationId);
      if (target == null ||
          _deliveryStatusRank(target.deliveryStatus) >=
              _deliveryStatusRank(to)) {
        continue;
      }
      await _replaceBoxRow(target.copyWith(deliveryStatus: to));
    }
  }

  /// The peer's [typing] in [conversationId], in the state the chat reads
  /// (E61e): text shows until [_boxTypingShown] after its last frame, voice
  /// from `on` to `off` or until [_boxVoiceShown] after its last `on` (an
  /// `off` is live and may be lost). The peer's next message clears both.
  void _showBoxTyping(int conversationId, E2eTyping typing) {
    switch (typing.kind) {
      case E2eTypingKind.text:
        _typingTimers.remove(conversationId)?.cancel();
        _typingStatus[conversationId] = typing.on;
        if (typing.on) {
          _typingTimers[conversationId] = Timer(_boxTypingShown, () {
            _typingStatus[conversationId] = false;
            _typingTimers.remove(conversationId);
            notifyListeners();
          });
        }
      case E2eTypingKind.voice:
        _boxVoiceTimers.remove(conversationId)?.cancel();
        if (typing.on) {
          _partnerRecordingVoice[conversationId] = true;
          _boxVoiceTimers[conversationId] = Timer(_boxVoiceShown, () {
            _boxVoiceTimers.remove(conversationId);
            _partnerRecordingVoice.remove(conversationId);
            notifyListeners();
          });
        } else {
          _partnerRecordingVoice.remove(conversationId);
        }
    }
    notifyListeners();
  }
}
