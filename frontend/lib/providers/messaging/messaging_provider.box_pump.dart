part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Why an own message waits to be sent ([MessageModel.waitingToSend]); the row
/// draws its words from it.
enum SendWaitReason {
  /// A calm hold is pending for the friend: the person has not tapped the
  /// line about the new device yet.
  calmLineUntapped,

  /// Anything else the gate waits for (a stale address, the journal, the box).
  other,
}

/// One message waiting to be sent: its record (null for an attachment whose
/// bytes live only in RAM) and its place in the friend's order.
typedef _Waiter = ({
  String tempId,
  int conversationId,
  int order,
  Map<String, dynamic>? record,
});

/// How one waiting message's attempt ended.
enum _WaiterResult {
  /// Went out (or was already stored): the next one goes.
  sent,

  /// Can never go (too long, quote gone, friendship ended): an ordinary
  /// failed row now; the next one goes.
  never,

  /// Failed for a reason that passes (box down, no session, list not
  /// verified, gate closed): it stays waiting and the pump stops, so nothing
  /// overtakes it.
  passing,
}

/// The send pump (invariant slice 3a): a message the friend write gate
/// refused WAITS, persisted (`q` in its `boxunsent` record), and one
/// single-flight pump per friend sends the oldest while the gate is open.
/// It is kicked by STATE CHANGES only (an address stored, a calm hold ended,
/// an anchor move, the journal judged, box / E2E ready, a finished list
/// refresh, conversations loaded, a new waiting message); a missed kick is
/// healed by the next. No timer, no timeout and no "end of drain" anywhere.
extension MessagingBoxPump on MessagingProvider {
  /// Why [row] waits now (read live: the calm line may be tapped meanwhile).
  SendWaitReason sendWaitReason(MessageModel row) {
    final own = _currentUserId;
    if (own == null) return SendWaitReason.other;
    final friend = _friendOfConversation(row.conversationId, own);
    return friend != null && hasCalmHold(friend)
        ? SendWaitReason.calmLineUntapped
        : SendWaitReason.other;
  }

  int? _friendOfConversation(int conversationId, int own) {
    final conv = _conversationsProvider?.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    return conv == null ? null : conv_helpers.getOtherUserId(conv, own);
  }

  // ---------- Kicks ----------

  /// A state change that may open the gate for [friend]: its pump looks
  /// again. Synchronous and cheap; a kick while the pump runs makes it look
  /// once more when it is done.
  void kickSendPump(int friend) {
    final own = _currentUserId;
    if (own == null || _isDisposed) return;
    final key = (own, friend);
    if (!_pumping.add(key)) {
      _pumpAgain.add(key);
      return;
    }
    unawaited(_runPump(own, friend));
  }

  /// A state change that concerns every friend (E2E ready, the journal
  /// judged, conversations loaded, a finished list refresh): kicks each
  /// friend that has a waiting message or an owed timer.
  void kickSendPumps() => unawaited(_kickAllPumps());

  Future<void> _kickAllPumps() async {
    final own = _currentUserId;
    final enc = _encryptionProvider;
    if (own == null || enc == null || _isDisposed) return;
    final waiting = await enc.boxUnsentWaiting(own);
    if (!_pumpLive(own)) return;
    // One kick per friend that has something waiting or an owed timer.
    <int>{
      for (final e in waiting.values)
        ?_friendOfConversation(e['c'] as int, own),
      for (final w in _ramWaiting.values)
        ?_friendOfConversation(w.conversationId, own),
      for (final (o, f) in _timerOwed)
        if (o == own) f,
    }.forEach(kickSendPump);
  }

  bool _pumpLive(int own) => !_isDisposed && _currentUserId == own;

  Future<void> _runPump(int own, int friend) async {
    final key = (own, friend);
    try {
      do {
        _pumpAgain.remove(key);
        await _pumpOnce(own, friend);
      } while (_pumpAgain.contains(key) && _pumpLive(own));
    } on Object catch (e) {
      _e2eFlowLog('BOX_PUMP_ERROR', {
        'peer': friend,
        'error': e.runtimeType.toString(),
      });
    } finally {
      _pumping.remove(key);
      _pumpAgain.remove(key);
    }
  }

  /// Whether the gate is open for [friend] now: a permit for the addresses a
  /// send would write to, the LIVE devices' (a calm hold, the journal and a
  /// stale address of a live device close it; a stale address of a device
  /// that is not live is no target and must not hold the line). Without a
  /// held list every stored address counts.
  bool _gateOpenFor(int friend) {
    final addresses = boxOutbox?.addressesFor(friend) ?? const {};
    final list = _encryptionProvider?.cachedDeviceList(friend);
    final targets = [
      for (final MapEntry(:key, :value) in addresses.entries)
        if (list == null || list.isLiveDevice(key)) value,
    ];
    if (targets.isEmpty) return false;
    return _friendPermit(friend, to: targets) != null;
  }

  /// `while the gate is open for the friend and a waiting message exists:
  /// send the oldest`, re-checking the account after every await.
  Future<void> _pumpOnce(int own, int friend) async {
    while (_pumpLive(own)) {
      final enc = _encryptionProvider;
      if (enc == null || !enc.isE2EReady || boxOutbox == null) return;
      if (!_gateOpenFor(friend)) return;
      await _sendOwedTimer(own, friend);
      if (!_pumpLive(own)) return;
      final next = await _nextWaiter(own, friend);
      if (!_pumpLive(own) || next == null) return;
      // The state may have moved during the read.
      if (!_gateOpenFor(friend)) return;
      switch (await _sendWaiter(own, friend, next)) {
        case _WaiterResult.sent:
          continue;
        case _WaiterResult.never:
          await _endWaiting(own, next.tempId);
        case _WaiterResult.passing:
          return;
      }
    }
  }

  /// The chat timer a closed gate refused is sent once, now, as it stands.
  Future<void> _sendOwedTimer(int own, int friend) async {
    if (!_timerOwed.remove((own, friend))) return;
    final conv = _conversationsProvider?.conversations
        .where((c) => conv_helpers.getOtherUserId(c, own) == friend)
        .firstOrNull;
    if (conv == null) return;
    await sendBoxChatTimer(friend, conv.disappearingTimer, DateTime.now());
  }

  /// The friend's waiting messages, oldest first: the record's `at` (or the
  /// place it was given when it joined the end), then its tempId.
  Future<_Waiter?> _nextWaiter(int own, int friend) async {
    final enc = _encryptionProvider;
    if (enc == null) return null;
    final records = await enc.boxUnsentWaiting(own);
    final all = <_Waiter>[
      for (final MapEntry(:key, :value) in records.entries)
        (
          tempId: key,
          conversationId: value['c'] as int,
          order: (value['qa'] as int?) ?? (value['at'] as int),
          record: value,
        ),
      for (final MapEntry(:key, :value) in _ramWaiting.entries)
        (
          tempId: key,
          conversationId: value.conversationId,
          order: value.at,
          record: null,
        ),
    ]..sort(_byWaitingOrder);
    for (final w in all) {
      if (_refusingChats.contains(w.conversationId)) continue;
      if (_friendOfConversation(w.conversationId, own) == friend) return w;
    }
    return null;
  }

  static int _byWaitingOrder(_Waiter a, _Waiter b) {
    final c = a.order.compareTo(b.order);
    if (c != 0) return c;
    // `temp_<millis>_<n>_<user>`: two sends in one millisecond differ in <n>.
    int seq(String t) => int.tryParse(t.split('_').elementAtOrNull(2) ?? '') ?? 0;
    final s = seq(a.tempId).compareTo(seq(b.tempId));
    return s != 0 ? s : a.tempId.compareTo(b.tempId);
  }

  Future<_WaiterResult> _sendWaiter(int own, int friend, _Waiter w) async {
    final tempId = w.tempId;
    final contact = boxFriends?.contactOf(friend);
    if (contact != null && contact.state != ContactState.friend) {
      return _WaiterResult.never;
    }
    if (_pumpOwned.contains(tempId) ||
        _boxInFlight.contains(tempId) ||
        _emittedSendTempIds.contains(tempId)) {
      return _WaiterResult.passing;
    }
    final rec = w.record;
    if (rec == null) return _sendRamWaiter(own, friend, w);
    final wire = rec['w'];
    final type = rec['type'];
    final content = rec['content'];
    if (wire is! String || type is! String || content is! String) {
      return _WaiterResult.never;
    }
    // Stored already (the app died between the store and the drop): the
    // record goes, the message is not sent again.
    if (await _ownCopyStored(own, w.conversationId, wire)) {
      if (_pumpLive(own)) await _dropWaiter(own, w);
      return _WaiterResult.sent;
    }
    if (!_pumpLive(own)) return _WaiterResult.passing;
    // The one synchronous flip a Retry shares: from here on nobody else may
    // seal this row.
    if (!_claimWaiter(tempId)) {
      if (!_userDeletedTempIds.contains(tempId)) return _WaiterResult.passing;
      // The person deleted it after the pump read its record: the record
      // goes (again, harmless) and the line goes on without it.
      await _encryptionProvider?.dropBoxUnsent(own, tempId);
      return _WaiterResult.sent;
    }
    try {
      _sendNeverGoes.remove(tempId);
      _sendTokenByTempId[tempId] = wire;
      _boxTempIds.add(tempId);
      _boxUnsentTempIds.add(tempId);
      final ttl = rec['ttl'] is int ? rec['ttl'] as int : null;
      final reply = rec['reply'];
      final ok = await _encryptAndSend(
        recipientId: friend,
        content: content,
        tempId: tempId,
        effectiveExpiresIn: ttl,
        effectiveReplyToId: rec['replyId'] is int ? rec['replyId'] as int : null,
        messageType: type,
        mediaUrl: rec['mediaUrl'] as String?,
        mediaDuration: rec['mediaDuration'] as int?,
        mediaKey: rec['mediaKey'] as String?,
        mediaIv: rec['mediaIv'] as String?,
        mediaWidth: rec['mediaWidth'] as int?,
        mediaHeight: rec['mediaHeight'] as int?,
        mediaThumbHash: rec['mediaThumbHash'] as String?,
        boxRowAtSend: (
          replyTo: reply is Map<String, dynamic>
              ? ReplyToPreview.fromJson(reply)
              : null,
          ttl: ttl,
        ),
        waitingRecord: rec,
      );
      if (!_pumpLive(own)) return _WaiterResult.passing;
      if (ok) {
        // The kept copy stays when the stored one could not be proven: it
        // must not be sent again.
        await _encryptionProvider?.setBoxUnsentWaiting(
          own,
          tempId,
          waiting: false,
        );
        return _WaiterResult.sent;
      }
      if (_sendNeverGoes.remove(tempId)) return _WaiterResult.never;
      _setRowWaiting(tempId, waiting: true);
      return _WaiterResult.passing;
    } finally {
      _pumpOwned.remove(tempId);
      _boxInFlight.remove(tempId);
    }
  }

  /// An attachment whose bytes live only in RAM goes through the row's own
  /// retry path; it needs its row and its held bytes, or it can never go.
  Future<_WaiterResult> _sendRamWaiter(int own, int friend, _Waiter w) async {
    final tempId = w.tempId;
    final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
    if (row == null || !_boxMediaBodies.containsKey(tempId)) {
      return _WaiterResult.never;
    }
    _pumpOwned.add(tempId);
    try {
      _sendNeverGoes.remove(tempId);
      final ok = await _retryNow(tempId);
      if (!_pumpLive(own)) return _WaiterResult.passing;
      if (ok) {
        _ramWaiting.remove(tempId);
        return _WaiterResult.sent;
      }
      if (_sendNeverGoes.remove(tempId)) return _WaiterResult.never;
      _setRowWaiting(tempId, waiting: true);
      return _WaiterResult.passing;
    } finally {
      _pumpOwned.remove(tempId);
    }
  }

  /// Takes [tempId] for the pump in ONE synchronous step: the row flips to
  /// `sending`, so a Retry (which needs a failed row) and a second pump
  /// attempt both stand aside.
  bool _claimWaiter(String tempId) {
    if (_userDeletedTempIds.contains(tempId) ||
        _boxInFlight.contains(tempId) ||
        _emittedSendTempIds.contains(tempId)) {
      return false;
    }
    _pumpOwned.add(tempId);
    _boxInFlight.add(tempId);
    _setRow(
      tempId,
      status: MessageDeliveryStatus.sending,
      waiting: false,
    );
    return true;
  }

  Future<bool> _ownCopyStored(int own, int conversationId, String wire) async {
    final rows = await _localBoxRows(conversationId);
    return rows.any((r) => r.senderId == own && r.wireId == wire);
  }

  /// The record and the row of [w] go: its message is stored already.
  Future<void> _dropWaiter(int own, _Waiter w) async {
    final tempId = w.tempId;
    await _encryptionProvider?.dropBoxUnsent(own, tempId);
    _ramWaiting.remove(tempId);
    _boxUnsentTempIds.remove(tempId);
    _boxTempIds.remove(tempId);
    _sendTokenByTempId.remove(tempId);
    final before = _messages.length;
    _messages.removeWhere((m) => m.tempId == tempId && m.id < 0);
    if (_messages.length != before) {
      if (_conversationCache.containsKey(w.conversationId)) {
        _updateCache(w.conversationId);
      }
      notifyListeners();
    }
  }

  // ---------- Joining the waiting list ----------

  /// Whether [friend]'s chat has a waiting message or a running pump: a send
  /// then joins the END of the line instead of overtaking.
  Future<bool> _friendQueueBusy(int own, int friend, int conversationId) async {
    if (_pumping.contains((own, friend))) return true;
    if (_ramWaiting.values.any((w) => w.conversationId == conversationId)) {
      return true;
    }
    final waiting = await _encryptionProvider?.boxUnsentWaiting(own);
    return waiting?.values.any((e) => e['c'] == conversationId) ?? false;
  }

  /// [tempId] to [friend] waits: nothing was sealed or uploaded for it. The
  /// row fails (so delete works), says it waits, and the pump sends it when
  /// the gate opens. [toEnd] gives it a new place at the end of the line (a
  /// Retry on an ordinary failed row while the gate is closed).
  Future<void> _holdForGate(
    int friend,
    String tempId, {
    bool toEnd = false,
  }) async {
    final own = _currentUserId;
    _e2eFlowLog('BOX_SEND_WAITS', {'tempId': tempId, 'peer': friend});
    _markMessageFailed(tempId, 'Could not send. Try again.');
    _setRowWaiting(tempId, waiting: true);
    if (own == null) return;
    if (_boxUnsentTempIds.contains(tempId)) {
      _ramWaiting.remove(tempId);
      await _encryptionProvider?.setBoxUnsentWaiting(
        own,
        tempId,
        waiting: true,
        queuedAt: toEnd ? DateTime.now().millisecondsSinceEpoch : null,
      );
    } else {
      final row = _messages.where((m) => m.tempId == tempId).firstOrNull;
      final conversationId =
          row?.conversationId ??
          _conversationsProvider?.conversations
              .where((c) => conv_helpers.getOtherUserId(c, own) == friend)
              .firstOrNull
              ?.id;
      if (conversationId != null) {
        _ramWaiting[tempId] = (
          conversationId: conversationId,
          at: (toEnd ? DateTime.now() : row?.createdAt ?? DateTime.now())
              .millisecondsSinceEpoch,
        );
      }
    }
    // The pump's own refusal does not kick itself: that would spin.
    if (_currentUserId == own && !_pumpOwned.contains(tempId)) {
      kickSendPump(friend);
    }
  }

  /// Retry on a failed row, decided SYNCHRONOUSLY (the status flip of an
  /// ordinary retry must stay in the same step): a waiting row only kicks the
  /// pump; an ordinary one joins the end of the line while the gate is closed
  /// or a line exists (a pump running, a waiting row of the chat on screen).
  /// Null when the retry is an ordinary one; else the work taken over.
  Future<void>? _retryJoinsLine(MessageModel row, int friend) {
    final own = _currentUserId;
    if (own == null) return null;
    if (row.waitingToSend) {
      kickSendPump(friend);
      return Future<void>.value();
    }
    final addresses = boxOutbox?.addressesFor(friend) ?? const {};
    final closed = _friendPermit(friend, to: addresses.values) == null;
    final busy =
        _pumping.contains((own, friend)) ||
        _ramWaiting.values.any((w) => w.conversationId == row.conversationId) ||
        _messages.any(
          (m) => m.waitingToSend && m.conversationId == row.conversationId,
        );
    if ((closed || busy) && !_pumpOwned.contains(row.tempId)) {
      return _holdForGate(friend, row.tempId!, toEnd: true);
    }
    return null;
  }

  // ---------- Rows ----------

  void _setRowWaiting(String tempId, {required bool waiting}) => _setRow(
    tempId,
    status: MessageDeliveryStatus.failed,
    waiting: waiting,
  );

  void _setRow(
    String tempId, {
    required MessageDeliveryStatus status,
    required bool waiting,
  }) {
    final idx = _messages.indexWhere((m) => m.tempId == tempId);
    if (idx == -1) return;
    _messages[idx] = _messages[idx].copyWith(
      deliveryStatus: status,
      waitingToSend: waiting,
    );
    notifyListeners();
  }

  /// [tempId] stops waiting and stays an ordinary failed row.
  Future<void> _endWaiting(int own, String tempId) async {
    _ramWaiting.remove(tempId);
    _setRowWaiting(tempId, waiting: false);
    await _encryptionProvider?.setBoxUnsentWaiting(
      own,
      tempId,
      waiting: false,
    );
  }

  /// The loaded rows and RAM-only attachments that waited for [friend] stop
  /// waiting NOW (synchronously, like the deferral list this replaces), and
  /// become ordinary failed rows. [conversationIds] adds chats already taken
  /// off the list. Returns their tempIds and the chats of the friend.
  ({Set<int> ids, List<String> ended}) _endLoadedWaiting(
    int friend,
    Iterable<int> conversationIds,
  ) {
    final own = _currentUserId;
    if (own == null) return (ids: const <int>{}, ended: const <String>[]);
    final ids = <int>{
      ...conversationIds,
      for (final c in [...?_conversationsProvider?.conversations])
        if (conv_helpers.getOtherUserId(c, own) == friend) c.id,
    };
    final ended = <String>{};
    for (final MapEntry(:key, :value) in _ramWaiting.entries.toList()) {
      if (ids.contains(value.conversationId)) {
        _ramWaiting.remove(key);
        ended.add(key);
      }
    }
    for (final m in _messages) {
      if (m.waitingToSend && ids.contains(m.conversationId)) {
        ended.add(m.tempId!);
      }
    }
    for (final t in ended) {
      _setRowWaiting(t, waiting: false);
    }
    return (ids: ids, ended: ended.toList());
  }

  /// The waiting records of the chats [ids] stop waiting; returns their
  /// tempIds.
  Future<List<String>> _endStoredWaiting(Set<int> ids) async {
    final own = _currentUserId;
    final enc = _encryptionProvider;
    if (own == null || enc == null || ids.isEmpty) return const [];
    final ended = <String>[];
    final waiting = await enc.boxUnsentWaiting(own);
    for (final MapEntry(:key, :value) in waiting.entries) {
      if (!ids.contains(value['c'])) continue;
      ended.add(key);
      await enc.setBoxUnsentWaiting(own, key, waiting: false);
    }
    if (_currentUserId == own) {
      for (final t in ended) {
        _setRowWaiting(t, waiting: false);
      }
    }
    return ended;
  }

  /// The friendship with [friend] ended: everything that waited for it
  /// becomes an ordinary failed row, the person's to delete or retry.
  Future<void> _endWaitingOfFriend(
    int friend,
    Iterable<int> conversationIds,
  ) async {
    final loaded = _endLoadedWaiting(friend, conversationIds);
    await _endStoredWaiting(loaded.ids);
  }
}
