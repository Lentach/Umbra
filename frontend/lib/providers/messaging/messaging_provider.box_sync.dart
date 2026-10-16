part of '../messaging_provider.dart';

/// Decision 102: catch-up sync between this account's own devices. No
/// queue is where history waits (the cap stays 128): a device that comes
/// back after an absence asks ONE live sibling, quietly through that
/// sibling's self-queue, for the box messages since it was last on the box;
/// the sibling answers with one encrypted box media blob of its records,
/// imported here deduped by `(sender, wire id)`.
extension MessagingBoxSync on MessagingProvider {
  /// One presence tick: while this device is on the box it stamps that it
  /// is ([BoxCatchUp.load]/[BoxCatchUp.save]), and the first tick after a
  /// gap longer than [kCatchUpAbsence] owes a catch-up from the last stamp
  /// ([catchUpSince]). An owed catch-up stays owed — persisted, so a
  /// restart keeps it — until one sibling's box took the request, or this
  /// device has no live sibling to ask. Run at box ready, at every list
  /// refresh and by the heartbeat; never more than one at a time, and at
  /// most one request per absence.
  Future<void> catchUpTick() async {
    final user = _currentUserId;
    if (user == null || _isDisposed || !(boxFriends?.onBox ?? false)) return;
    final catchUp = boxCatchUp;
    if (!catchUp.claimTick()) return;
    try {
      catchUp.keepBeating(() => unawaited(catchUpTick()));
      final now = clock.now().toUtc();
      final mark = await catchUp.load(user);
      final since = catchUpSince(lastOnline: mark.at, now: now);
      final owed = switch ((mark.owed, since)) {
        (final held?, final fresh?) => fresh.isBefore(held) ? fresh : held,
        (final held, final fresh) => held ?? fresh,
      };
      if (user != _currentUserId) return;
      await catchUp.save(user, (at: now, owed: owed));
      if (owed == null) return;
      if (await _askSiblingToCatchUp(user, catchUpFloor(owed, now)) &&
          user == _currentUserId) {
        await catchUp.save(user, (at: now, owed: null));
      }
    } on Object catch (e) {
      _e2eFlowLog('BOX_SYNC_TICK_FAILED', {'error': e.runtimeType.toString()});
    } finally {
      catchUp.endTick();
    }
  }

  /// Sends one `sync_req {since}` to the first sibling in
  /// [catchUpResponders]' order whose box takes it: true when one did, or
  /// when there is no live sibling to ask (nothing will ever answer); false
  /// when it should be tried again (E2E or the own list not ready, no
  /// sibling with a self-queue address and a usable session yet, a send
  /// that failed, every sibling's queue full). A sibling whose queue is full
  /// has not read it for a while: the next one is asked, and a paused one
  /// (E93a) is not sealed to until it reads its queue again.
  Future<bool> _askSiblingToCatchUp(int user, DateTime since) async {
    final outbox = boxOutbox;
    final enc = _encryptionProvider;
    if (outbox == null || enc == null || !enc.isE2EReady) return false;
    // This connect's own lookup, when the refresh runs one: never a second.
    try {
      await _boxLists.readyFor(user);
    } on Object {
      // Looked up below, or the ask waits for the next tick.
    }
    final mine = await ownLiveDevices();
    if (mine == null || _isDisposed) return false;
    final siblings = [
      for (final d in mine.live)
        if (d != mine.self) d,
    ];
    if (siblings.isEmpty) {
      _e2eFlowLog('BOX_SYNC_NO_SIBLING', const {});
      return true;
    }
    final addresses = outbox.siblingAddresses();
    final order = catchUpResponders(
      siblings: siblings,
      addressed: addresses.keys.toSet(),
      lastHeard: siblingLastHeardAt,
    );
    final json = jsonEncode(BoxCatchUpEnvelope.request(since));
    var anyFull = false;
    for (final device in order) {
      // A paused sibling (E93a) does not read its queue: asking it would
      // move its chain for an answer that is not coming.
      if (_boxPaused.isPaused(user, device)) {
        anyFull = true;
        continue;
      }
      if (!await _hasUsableBoxSession(enc, user, device)) continue;
      final outcome = await _sendCatchUpFrame(device, addresses[device]!, json);
      _noteBoxAnswer(user, device, outcome);
      switch (outcome) {
        case BoxSendOutcome.taken:
          _e2eFlowLog('BOX_SYNC_ASKED', {
            'device': device,
            'since': since.millisecondsSinceEpoch,
          });
          return true;
        case BoxSendOutcome.full:
          anyFull = true;
        case BoxSendOutcome.failed:
          return false;
      }
    }
    // None asked (no address or session yet, every queue full or paused):
    // still owed. A paused sibling costs the next ticks nothing, and the
    // first tick after its pause ends asks it.
    _e2eFlowLog('BOX_SYNC_NOT_ASKED', {
      'siblings': siblings.length,
      'asked': order.length,
      'full': anyFull,
    });
    return false;
  }

  /// [json] to own sibling [device] through its self-queue [to], quiet: it
  /// never wakes the sibling (decision 91).
  Future<BoxSendOutcome> _sendCatchUpFrame(
    int device,
    ContactOutbound to,
    String json,
  ) async {
    final outbox = boxOutbox;
    if (outbox == null) return BoxSendOutcome.failed;
    try {
      final frame = await encryptForOwnDevice(device, json);
      if (frame == null) return BoxSendOutcome.failed;
      return await outbox.deliver(
        to,
        frame.encode(),
        mode: BoxSendMode.quiet,
      );
    } on Object catch (e) {
      _e2eFlowLog('BOX_SYNC_SEND_FAILED', {
        'device': device,
        'error': e.runtimeType.toString(),
      });
      return BoxSendOutcome.failed;
    }
  }

  /// Sibling [device]'s `sync_req`, read from our self-queue (the reader
  /// checked the device live): answered off the reader's chain — reading
  /// every record and uploading the blob would stall every chat — once per
  /// sibling per [kCatchUpAbsence]. Always finished: the requester asks
  /// again after its next absence.
  bool _takeSyncRequest(int device, String plaintext) {
    final since = BoxCatchUpEnvelope.parseRequest(plaintext);
    if (since == null) {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {
        'device': device,
        't': E2eEnvelope.typeSyncRequest,
      });
      return true;
    }
    final now = clock.now().toUtc();
    if (!boxCatchUp.mayAnswer(device, now)) {
      _e2eFlowLog('BOX_SYNC_REQUEST_REPEATED', {'device': device});
      return true;
    }
    unawaited(_answerCatchUp(device, catchUpFloor(since, now)));
    return true;
  }

  /// Seals every box message record held here since [since] (both
  /// directions, every box chat; [catchUpRecords]) into one blob under a
  /// fresh AES-256-GCM key, uploads it framed on its rung against sibling
  /// [device]'s self-queue (whose budget pays; 14-d TTL, D8), and sends it
  /// the pointer, key and IV as a quiet `sync_resp`. Nothing to send sends
  /// nothing: the requester expects no answer.
  Future<void> _answerCatchUp(int device, DateTime since) async {
    final outbox = boxOutbox;
    final enc = _encryptionProvider;
    final user = _currentUserId;
    final to = outbox?.siblingAddresses()[device];
    if (outbox == null || enc == null || user == null || to == null) {
      _e2eFlowLog('BOX_SYNC_NO_ROUTE', {'device': device});
      return;
    }
    try {
      // No session, no answer (E38b: a box frame never builds one); checked
      // before the upload, which would otherwise be paid for nothing.
      if (!await _hasUsableBoxSession(enc, user, device)) {
        _e2eFlowLog('BOX_SYNC_NO_SESSION', {'device': device});
        return;
      }
      final now = clock.now().toUtc();
      final records = catchUpRecords(
        userId: user,
        records: await enc.allLocalMessageRecords(),
        since: since,
        now: now,
        tombstoned: await enc.boxTombstoneSnapshot(),
        usable: (id, record) => _catchUpRow(id, record, now) != null,
      );
      if (records.isEmpty || user != _currentUserId) {
        _e2eFlowLog('BOX_SYNC_NOTHING', {'device': device});
        return;
      }
      final sealed = await boxCatchUp.crypto.encrypt(
        encodeCatchUpPayload(user, records),
      );
      final Uint8List id;
      switch (await outbox.uploadMedia(
        to,
        frameMediaToRung(sealed.ciphertext),
      )) {
        case BoxOk(:final value):
          id = value.id;
        case BoxRefused(:final code):
          _e2eFlowLog('BOX_SYNC_UPLOAD_REFUSED', {
            'device': device,
            'code': code.wire,
          });
          return;
        case BoxUnknown(:final reason):
          _e2eFlowLog('BOX_SYNC_UPLOAD_UNKNOWN', {
            'device': device,
            'reason': reason.name,
          });
          return;
      }
      final json = jsonEncode(
        BoxCatchUpEnvelope.response(
          media: boxB64(id),
          key: sealed.keyBase64,
          iv: sealed.ivBase64,
          since: since,
          count: records.length,
        ),
      );
      final outcome = await _sendCatchUpFrame(device, to, json);
      _noteBoxAnswer(user, device, outcome);
      _e2eFlowLog('BOX_SYNC_ANSWERED', {
        'device': device,
        'count': records.length,
        'outcome': outcome.name,
      });
    } on Object catch (e) {
      E2ePersistentDiag.record('BOX_SYNC_ANSWER_FAILED', {
        'device': device,
        'error': e.runtimeType.toString(),
      });
    }
  }

  /// Sibling [device]'s `sync_resp`, read from our self-queue: the blob is
  /// downloaded, opened and imported ON the reader's chain (at most
  /// [kCatchUpMaxBytes]), so no box message stored meanwhile can race the
  /// wire-id dedup. Kept for the next offer only when it may still work
  /// (no answer from the box, the store could not say what it holds or
  /// hand out ids); a blob that is gone, damaged or not ours is finished.
  Future<bool> _takeSyncResponse(int device, String plaintext) async {
    final response = BoxCatchUpEnvelope.parseResponse(plaintext);
    final id = response == null
        ? null
        : boxB64Decode(response.media, kBoxMediaIdBytes);
    if (response == null || id == null) {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {
        'device': device,
        't': E2eEnvelope.typeSyncResponse,
      });
      return true;
    }
    final outbox = boxOutbox;
    final user = _currentUserId;
    if (outbox == null || user == null) return false;
    if (boxCatchUp.imported(response.media)) {
      _e2eFlowLog('BOX_SYNC_REPEATED', {'device': device});
      return true;
    }
    final Uint8List framed;
    switch (await outbox.downloadMedia(id)) {
      case BoxOk(:final value):
        framed = value;
      case BoxRefused(code: BoxCode.rateLimited) || BoxUnknown():
        return false;
      case BoxRefused(:final code):
        _e2eFlowLog('BOX_SYNC_GONE', {'device': device, 'code': code.wire});
        return true;
    }
    final body = unframeMedia(framed);
    final List<BoxCatchUpRecord>? records;
    try {
      records = body == null
          ? null
          : decodeCatchUpPayload(
              user,
              await boxCatchUp.crypto.decrypt(
                Uint8List.fromList(body),
                response.key,
                response.iv,
              ),
            );
    } on Object {
      _e2eFlowLog('BOX_SYNC_UNREADABLE', {'device': device});
      return true;
    }
    if (records == null) {
      _e2eFlowLog('BOX_SYNC_UNREADABLE', {'device': device});
      return true;
    }
    final stored = await _importCatchUp(user, records);
    if (stored == null) return false;
    boxCatchUp.markImported(response.media);
    _e2eFlowLog('BOX_SYNC_IMPORTED', {
      'device': device,
      'offered': records.length,
      'stored': stored,
    });
    return true;
  }

  /// [records] stored as this device's own box messages: each one this
  /// device does not hold by its wire id, has not deleted for everyone
  /// (E19g), and whose plaintext is usable and not expired, under a FRESH
  /// local id from the box's allocator (one block, E64f) — through the
  /// store path a box message takes (`_persistDecryptedContent`, proven by
  /// read-back), then its attachment prefetch and parked actions (E19k).
  /// History, so nothing rings: no card, no sound, no delivered receipt;
  /// the chat list takes each chat's newest and the badge what this device
  /// has not seen (decision 73), and the chat on screen merges its rows.
  /// Null when it cannot tell what it holds or get ids: nothing written.
  Future<int?> _importCatchUp(int user, List<BoxCatchUpRecord> records) async {
    final enc = _encryptionProvider;
    final convs = _conversationsProvider;
    if (enc == null || convs == null) return null;
    final now = clock.now().toUtc();
    final tombstoned = await enc.boxTombstoneSnapshot();
    final fresh = <BoxCatchUpRecord>[];
    final seen = <WireKey>{};
    for (final entry in records) {
      final wire = entry.wire;
      // Never rebuilt under the RESPONDER's id here: that id may name another
      // record on this device. Usability is judged under the fresh id below.
      if (!seen.add(wire) ||
          entry.record['senderId'] != wire.senderId ||
          tombstoned(wire) ||
          _catchUpDead(entry.record, now)) {
        continue;
      }
      // Id 0 names no record: any holder at all is one.
      final held = await enc.wireHeldByOther(wire, 0);
      if (held == null) return null;
      if (!held) fresh.add(entry);
    }
    if (fresh.isEmpty) return 0;
    final first = await convs.contactStore?.allocateLocalIds(fresh.length);
    if (first == null || user != _currentUserId) {
      _e2eFlowLog('BOX_SYNC_NO_IDS', {'count': fresh.length});
      return null;
    }
    final moved = {
      for (final (i, entry) in fresh.indexed) entry.id: first + i,
    };
    final stored = <MessageModel>[];
    for (final entry in fresh) {
      final id = moved[entry.id]!;
      final rebuilt = _catchUpRow(id, entry.record, now);
      if (rebuilt == null) continue;
      final row = rebuilt.copyWith(
        replyTo: await _catchUpQuote(rebuilt.replyTo, moved),
      );
      enc.cacheDecryption(id, row);
      await _persistDecryptedContent(row);
      if (await enc.recordExists(id) != true) {
        E2ePersistentDiag.record('BOX_SYNC_STORE_UNPROVEN', {'msgId': id});
        continue;
      }
      stored.add(row);
      _prefetchBoxMedia(row, now);
      try {
        await _applyParkedBoxActions(row);
      } on Object catch (e) {
        _e2eFlowLog('BOX_PARKED_APPLY_FAILED', {'error': e.runtimeType});
      }
    }
    if (stored.isNotEmpty && !_isDisposed && convs == _conversationsProvider) {
      await _showCatchUp(user, convs, stored);
    }
    return stored.length;
  }

  /// [stored] shown quietly: each known chat's newest becomes its last
  /// message when newer, the peer's rows this device has not seen add to
  /// its badge (decision 73's rule), and the chat on screen merges its
  /// stored rows (countdowns, seen mark and read receipt as on entry).
  Future<void> _showCatchUp(
    int user,
    ConversationsProvider convs,
    List<MessageModel> stored,
  ) async {
    final marks = await _encryptionProvider?.boxSeenMarks();
    final newest = <int, MessageModel>{};
    final unread = <int, Set<int>>{};
    for (final row in stored) {
      final chat = row.conversationId;
      if (convs.getConversationById(chat) == null) continue;
      final held = newest[chat];
      if (held == null || row.createdAt.isAfter(held.createdAt)) {
        newest[chat] = row;
      }
      if (marks != null &&
          row.senderId != user &&
          row.createdAt.millisecondsSinceEpoch >
              (marks.chats[chat] ?? marks.base)) {
        (unread[chat] ??= {}).add(row.id);
      }
    }
    convs
      ..applyNewerLastMessages(newest)
      ..seedBoxUnread(unread);
    final viewing = _effectiveActiveConversationId ?? _paginationConversationId;
    if (newest.containsKey(viewing)) await _mergeLocalBoxRows(viewing);
  }

  /// An imported reply's quote, re-pointed at this device's copy: the
  /// quoted message imported with it, else the one held here by its wire
  /// id, else none (id 0, the snippet shows). A server id is the same
  /// everywhere and stays.
  Future<ReplyToPreview?> _catchUpQuote(
    ReplyToPreview? quote,
    Map<int, int> moved,
  ) async {
    if (quote == null || !isLocalMessageId(quote.id)) return quote;
    var id = moved[quote.id];
    final wireId = quote.wireId;
    final senderId = quote.senderId;
    if (id == null && wireId != null && senderId != null) {
      id = await _encryptionProvider?.wireHolder((
        senderId: senderId,
        wireId: wireId,
      ));
    }
    return ReplyToPreview(
      id: id ?? 0,
      content: quote.content,
      senderUsername: quote.senderUsername,
      messageType: quote.messageType,
      wireId: wireId,
      senderId: senderId,
      quotedDisappears: quote.quotedDisappears,
    );
  }

  /// A box message record as the row [id] it would show as, or null when
  /// it has no chat, no usable plaintext, or is expired at [now].
  MessageModel? _catchUpRow(
    int id,
    Map<String, dynamic> record,
    DateTime now,
  ) {
    final chat = record[PlaintextRecordCodec.conversationIdKey];
    if (chat is! int || _catchUpDead(record, now)) return null;
    final row = _boxRowFrom(
      id,
      chat,
      record,
      _conversationsProvider?.getConversationById(chat),
    );
    return row == null || isMessageExpired(row, now) ? null : row;
  }

  /// Whether [record]'s destruction stamp (its countdown's deadline, or a
  /// received one's 1-day unread cap, decision 41) has passed at [now].
  bool _catchUpDead(Map<String, dynamic> record, DateTime now) {
    final deadline = record[PlaintextRecordCodec.expiresAtKey];
    return deadline is int && deadline <= now.millisecondsSinceEpoch;
  }
}
