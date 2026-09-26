part of '../messaging_provider.dart';

/// A box message action NO device took (metadata-privacy item 4, E19a,
/// E19l): its optimistic state is already undone, and the chat screen says
/// so. A reaction reports through its own `Future<bool>`.
enum BoxActionFailure { pin, edit, delete }

/// A received react, pin or edit, as live receipt and the park both apply
/// it (E19b, E19k): the AUTHENTICATED `actor`, the clamped `at`, and per
/// type the reaction's `emoji` and `on`, a pin's `on`, an edit's `content`.
typedef _BoxActionTake = ({
  int actor,
  String type,
  DateTime at,
  String? emoji,
  bool? on,
  String content,
});

/// [take] as the park keeps it ([EncryptionService.parkBoxAction]).
Map<String, Object?> _parkedJson(_BoxActionTake take) => {
  'a': take.actor,
  't': take.type,
  'ts': take.at.millisecondsSinceEpoch,
  'e': ?take.emoji,
  'on': ?take.on,
  if (take.type == E2eEnvelope.typeEdit) 'c': take.content,
};

/// A parked action read back; null for one that is not sound.
_BoxActionTake? _parkedFrom(Map<String, dynamic> json) {
  final actor = json['a'];
  final type = json['t'];
  final ts = json['ts'];
  final emoji = json['e'];
  final on = json['on'];
  final content = json['c'];
  if (actor is! int || type is! String || ts is! int) return null;
  final sound = switch (type) {
    E2eEnvelope.typeReact => emoji is String && on is bool,
    E2eEnvelope.typePin => on == true,
    E2eEnvelope.typeEdit => content is String,
    _ => false,
  };
  if (!sound) return null;
  return (
    actor: actor,
    type: type,
    at: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    emoji: emoji is String ? emoji : null,
    on: on is bool ? on : null,
    content: content is String ? content : '',
  );
}

/// One box action's retry key (E19l): per chat, type and target, so a
/// later action of that type on that target supersedes what an earlier one
/// still owes.
String _boxActionKey(int conversationId, String type, WireKey target) =>
    '$conversationId|$type|${target.senderId}:${target.wireId}';

/// Waits between the retries of a box action some device did not take
/// (E19l); the last repeats.
const List<Duration> _boxActionRetryDelays = [
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
  Duration(minutes: 30),
];

/// How long a box action is sent again: the box TTL, past which a device
/// could no longer hold the target either.
const Duration _boxActionRetryLife = Duration(days: 30);

/// The frames of ONE box action some device took and some did not (E19l):
/// its envelopes exactly as first sent — same `ts`, same payload, since
/// every action is idempotent or last-writer-wins by `(s, w)` and `ts` —
/// and the devices still owed them.
class _BoxActionRetry {
  _BoxActionRetry({
    required this.seq,
    required this.owner,
    required this.peer,
    required this.json,
    required this.copyJson,
    required this.since,
  });

  /// The send it retries ([MessagingProvider._boxActionSendSeq]).
  final int seq;
  final int owner;
  final int peer;
  final String json;
  final String copyJson;
  final DateTime since;
  final Set<int> peerDevices = {};
  final Set<int> siblings = {};
  int attempts = 0;
  Timer? timer;
  bool running = false;

  bool get owesNothing => peerDevices.isEmpty && siblings.isEmpty;
}

/// [reactions] with [reactor]'s one reaction set to [emoji], or taken off
/// every emoji when [emoji] is null — one reaction per user, as the server
/// keeps them on the old path (E19e).
Map<String, List<int>> _reactorSet(
  Map<String, List<int>> reactions,
  int reactor,
  String? emoji,
) {
  final next = <String, List<int>>{};
  for (final MapEntry(:key, :value) in reactions.entries) {
    final users = [
      for (final u in value)
        if (u != reactor) u,
    ];
    if (users.isNotEmpty) next[key] = users;
  }
  if (emoji != null) next[emoji] = [...?next[emoji], reactor];
  return next;
}

/// The emoji [reactor] reacted with, if any.
String? _reactionOf(Map<String, List<int>> reactions, int reactor) {
  for (final MapEntry(:key, :value) in reactions.entries) {
    if (value.contains(reactor)) return key;
  }
  return null;
}

/// Now, in whole ms: an action's `ts` and the state it leaves here must
/// agree with what every other device reads from the envelope.
DateTime _wholeMsNow() => DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch,
  isUtc: true,
);

/// Reactions, pin, edit and delete-for-everyone of a BOX message (item 4,
/// decisions 45–46, E19a–E19d): each travels as an E2E envelope
/// `t: react|pin|edit|del` naming its target by `tg: {s, w}` — the sender
/// and wire id, the one name every device shares for a box message — along
/// the route a box message takes. An old-path row keeps its server events.
extension MessagingBoxActions on MessagingProvider {
  /// Sends one action on [target], a message of [conversationId], exactly
  /// as a box message travels (E19a): a Signal message per live peer device
  /// and a SENT COPY naming the peer per live sibling, all built before the
  /// first goes out. True when at least ONE device took its frame (E19l):
  /// the action then stands, and every device that refused or stayed silent
  /// is owed the same envelopes by a retry. False — nothing was taken — for
  /// a route that is gone or cannot be verified, a missing session, or a
  /// refusal or silence everywhere; nothing ever goes to the server instead
  /// (decisions 19, 25, 46).
  Future<bool> _sendBoxAction(
    int conversationId,
    String type,
    WireKey target, {
    required DateTime sentAt,
    String? emoji,
    bool? on,
    String content = '',
  }) async {
    void failed(String why) =>
        _e2eFlowLog('BOX_ACTION_FAILED', {'t': type, 'why': why});
    final send = ++_boxActionSendSeq;
    final own = _currentUserId;
    final outbox = boxOutbox;
    final conversation = _conversationsProvider?.getConversationById(
      conversationId,
    );
    if (own == null || outbox == null || conversation == null) {
      failed('no_box');
      return false;
    }
    final peer = conv_helpers.getOtherUserId(conversation, own);
    final addresses = outbox.addressesFor(peer);
    if (addresses.isEmpty) {
      failed('no_route');
      return false;
    }
    final _BoxRoute? route;
    try {
      route = await _boxRoute(peer, outbox, addresses);
    } on Object {
      failed('unverified');
      return false;
    }
    if (route == null) {
      failed('no_route');
      return false;
    }
    String build({int? to}) => jsonEncode(
      E2eEnvelope.buildAction(
        type,
        targetSender: target.senderId,
        targetWire: target.wireId,
        sentAt: sentAt,
        emoji: emoji,
        on: on,
        content: content,
        sentTo: to,
        senderListInfo: route!.senderListInfo.toJson(),
      ),
    );
    final json = build();
    final copyJson = build(to: peer);
    final sealed = await _sealBoxFrames(
      route,
      recipientId: peer,
      json: json,
      copyJson: copyJson,
    );
    if (sealed.failure != null) {
      failed(sealed.failure!.name);
      return false;
    }
    final accepted = await Future.wait([
      for (final (to, body) in sealed.frames) route.outbox.deliver(to, body),
    ]);
    _e2eFlowLog('BOX_ACTION_SEND', {
      't': type,
      'frames': sealed.frames.length,
      'accepted': accepted.where((ok) => ok).length,
    });
    if (!accepted.contains(true)) return false;
    final key = _boxActionKey(conversationId, type, target);
    // A newer action of this type on this target, taken already, owns
    // every device's state: this one is owed to nobody any more.
    if ((_boxActionSends[key] ?? 0) > send) return true;
    _boxActionSends[key] = send;
    _dropBoxActionRetry(key);
    if (accepted.contains(false)) {
      final retry = _BoxActionRetry(
        seq: send,
        owner: own,
        peer: peer,
        json: json,
        copyJson: copyJson,
        since: clock.now(),
      );
      for (var i = 0; i < accepted.length; i++) {
        if (accepted[i]) continue;
        // `_sealBoxFrames` builds the peer devices' frames first.
        final device = sealed.frames[i].$1.peerDeviceId;
        (i < route.targets.length ? retry.peerDevices : retry.siblings).add(
          device,
        );
      }
      _boxActionRetries[key] = retry;
      _scheduleBoxActionRetry(key, retry);
    }
    return true;
  }

  /// Sends [key]'s owed frames again, to the devices that have not taken
  /// them — never to one taken already (E19l). Given up past 30 d, or when
  /// another account signed in.
  Future<void> _retryBoxAction(String key) async {
    final retry = _boxActionRetries[key];
    if (retry == null || retry.running) return;
    retry.timer?.cancel();
    retry.timer = null;
    if (retry.owner != _currentUserId ||
        clock.now().difference(retry.since) >= _boxActionRetryLife) {
      _e2eFlowLog('BOX_ACTION_RETRY_EXPIRED', {'seq': retry.seq});
      _dropBoxActionRetry(key);
      return;
    }
    retry.running = true;
    try {
      await _resendBoxAction(retry);
    } on Object catch (e) {
      _e2eFlowLog('BOX_ACTION_RETRY_FAILED', {'error': e.runtimeType});
    } finally {
      retry.running = false;
    }
    // Superseded, or every retry dropped, while it ran.
    if (!identical(_boxActionRetries[key], retry)) return;
    if (retry.owesNothing) {
      _boxActionRetries.remove(key);
      return;
    }
    retry.attempts++;
    _scheduleBoxActionRetry(key, retry);
  }

  /// One pass of [retry]: this connect's route, narrowed to the devices
  /// still owed and still live (a device gone from the list is owed nothing
  /// more), sealed afresh from the SAME envelopes.
  Future<void> _resendBoxAction(_BoxActionRetry retry) async {
    final outbox = boxOutbox;
    if (outbox == null) return;
    final route = await _boxRoute(
      retry.peer,
      outbox,
      outbox.addressesFor(retry.peer),
    );
    if (route == null) return;
    final targets = [
      for (final t in route.targets)
        if (retry.peerDevices.contains(t.peerDeviceId)) t,
    ];
    final siblings = [
      for (final s in route.siblings)
        if (retry.siblings.contains(s.peerDeviceId)) s,
    ];
    retry.peerDevices.retainAll({for (final t in targets) t.peerDeviceId});
    retry.siblings.retainAll({for (final s in siblings) s.peerDeviceId});
    if (retry.owesNothing) return;
    final sealed = await _sealBoxFrames(
      (
        outbox: route.outbox,
        targets: targets,
        siblings: siblings,
        conversationId: route.conversationId,
        senderListInfo: route.senderListInfo,
      ),
      recipientId: retry.peer,
      json: retry.json,
      copyJson: retry.copyJson,
    );
    if (sealed.failure != null) return;
    final accepted = await Future.wait([
      for (final (to, body) in sealed.frames) route.outbox.deliver(to, body),
    ]);
    for (var i = 0; i < accepted.length; i++) {
      if (!accepted[i]) continue;
      final device = sealed.frames[i].$1.peerDeviceId;
      (i < targets.length ? retry.peerDevices : retry.siblings).remove(device);
    }
    _e2eFlowLog('BOX_ACTION_RETRY', {
      'frames': sealed.frames.length,
      'accepted': accepted.where((ok) => ok).length,
    });
  }

  void _scheduleBoxActionRetry(String key, _BoxActionRetry retry) {
    final wait =
        _boxActionRetryDelays[retry.attempts < _boxActionRetryDelays.length
            ? retry.attempts
            : _boxActionRetryDelays.length - 1];
    retry.timer?.cancel();
    retry.timer = Timer(wait, () => _retryBoxAction(key).ignore());
  }

  /// Every owed box action, sent again now: the box is ready again.
  void _retryBoxActionsNow() {
    for (final key in _boxActionRetries.keys.toList()) {
      _retryBoxAction(key).ignore();
    }
  }

  void _dropBoxActionRetry(String key) =>
      _boxActionRetries.remove(key)?.timer?.cancel();

  /// Logout, dispose: nothing owed survives the session (decision 19).
  void _dropBoxActionRetries() {
    for (final retry in _boxActionRetries.values) {
      retry.timer?.cancel();
    }
    _boxActionRetries.clear();
    _boxActionSends.clear();
  }

  void _boxActionFailed(BoxActionFailure failure) {
    if (!_boxActionFailures.isClosed) _boxActionFailures.add(failure);
  }

  /// The box message [wire] names in [conversationId]: the open chat's row,
  /// an unsaved one, a cached one, else rebuilt from its record. Only a
  /// LOCAL id counts — an old-path row keeps its server events (decision
  /// 46) — and only in this chat (E19b).
  Future<MessageModel?> _heldBoxTarget(WireKey wire, int conversationId) async {
    bool names(MessageModel m) =>
        m.conversationId == conversationId &&
        m.senderId == wire.senderId &&
        m.wireId == wire.wireId &&
        isLocalMessageId(m.id) &&
        !_deletedMessageIds.contains(m.id);
    for (final rows in [
      _messages,
      _boxUnsaved.values,
      ?_conversationCache[conversationId],
    ]) {
      for (final m in rows) {
        if (names(m)) return m;
      }
    }
    final enc = _encryptionProvider;
    if (enc == null) return null;
    final id = await enc.wireHolder(wire);
    if (id == null || !isLocalMessageId(id) || _deletedMessageIds.contains(id)) {
      return null;
    }
    final record = await enc.getDecryptedContent(id);
    if (record == null ||
        record[PlaintextRecordCodec.conversationIdKey] != conversationId) {
      return null;
    }
    return _boxRowFrom(
      id,
      conversationId,
      record,
      _conversationsProvider?.getConversationById(conversationId),
    );
  }

  /// Shows [updated] — a held box row an action changed — wherever it is
  /// displayed; RAM only.
  void _showBoxRow(MessageModel updated) {
    final i = _messages.indexWhere((m) => m.id == updated.id);
    if (i != -1) _messages[i] = updated;
    _patchMessageInCache(updated.conversationId, updated.id, (_) => updated);
    if (_boxUnsaved.containsKey(updated.id)) _boxUnsaved[updated.id] = updated;
    _encryptionProvider?.cacheDecryption(updated.id, updated);
    _maybeUpdateLastEdited(updated.conversationId, updated.id, updated);
    _reEnrichAllReplyQuotes();
    notifyListeners();
  }

  /// [_showBoxRow], then its record — the copy a restart reads (E19d).
  Future<void> _replaceBoxRow(MessageModel updated) async {
    _showBoxRow(updated);
    await _persistDecryptedContent(updated);
  }

  /// One received action (E19b). [actor] is the AUTHENTICATED sender — the
  /// peer whose session decrypted it, or our own account for a sibling's
  /// sent copy — [peer] the other party of [conversationId], the chat it
  /// arrived for; `tg` is resolved only there. Always finished: an action
  /// that is not the actor's to take is dropped, and a react, pin or edit
  /// whose target is not held YET is parked until it lands (E19k).
  Future<bool> _takeBoxAction(
    E2eEnvelopeFields parsed,
    String plaintext, {
    required int actor,
    required int peer,
    required int conversationId,
    required DateTime receivedAt,
  }) async {
    final action = E2eEnvelope.parseAction(plaintext);
    if (action == null) {
      _e2eFlowLog('BOX_ACTION_UNREADABLE', {'t': parsed.type});
      return true;
    }
    // Decision 13: the sender's clock, never past our receive time.
    final sentAt = parsed.sentAt;
    final at = sentAt == null || sentAt.isAfter(receivedAt)
        ? receivedAt
        : sentAt;
    final wire = (senderId: action.targetSender, wireId: action.targetWire);
    void dropped(String why) =>
        _e2eFlowLog('BOX_ACTION_DROPPED', {'t': action.type, 'why': why});
    final type = action.type;
    if ((type == E2eEnvelope.typeDelete || type == E2eEnvelope.typeEdit) &&
        actor != wire.senderId) {
      dropped('not_sender');
      return true;
    }
    if (type == E2eEnvelope.typeDelete) {
      await _applyBoxDelete(conversationId, wire);
      return true;
    }
    if (type == E2eEnvelope.typePin && action.on == false) {
      // An unpin applies whatever it names (E19f).
      if (!_takeBoxPin(conversationId, BoxPin(at: at))) dropped('stale');
      return true;
    }
    final take = (
      actor: actor,
      type: type,
      at: at,
      emoji: action.emoji,
      on: action.on,
      content: parsed.content,
    );
    final target = await _heldBoxTarget(wire, conversationId);
    if (target != null) {
      await _applyBoxAction(take, target, wire);
      return true;
    }
    await _parkBoxAction(
      take,
      wire,
      conversationId: conversationId,
      peer: peer,
      receivedAt: receivedAt,
    );
    return true;
  }

  /// Applies a react, pin or edit [take] to [target], the held box message
  /// [wire] names — at receipt or from the park, by the same rules (E19b,
  /// E19c, E19e): an edit TEXT only, from its sender (checked before),
  /// within 15 min of the send, within decision 18, last writer wins on
  /// `ts`; one reaction per reactor; a pin into the register.
  Future<void> _applyBoxAction(
    _BoxActionTake take,
    MessageModel target,
    WireKey wire,
  ) async {
    void dropped(String why) =>
        _e2eFlowLog('BOX_ACTION_DROPPED', {'t': take.type, 'why': why});
    final at = take.at;
    switch (take.type) {
      case E2eEnvelope.typeEdit:
        final content = take.content;
        final lastEdit = target.editedAt;
        if (target.messageType != MessageType.text) {
          dropped('not_text');
        } else if (content.trim().isEmpty ||
            !isMessageWithinByteLimit(content)) {
          dropped('content');
        } else if (!at.isBefore(target.createdAt.add(kMessageEditWindow))) {
          dropped('window');
        } else if (lastEdit != null && !at.isAfter(lastEdit)) {
          dropped('stale');
        } else {
          await _replaceBoxRow(target.copyWith(content: content, editedAt: at));
        }
      case E2eEnvelope.typeReact:
        final actor = take.actor;
        final before = _reactionOf(target.reactions, actor);
        final emoji = take.emoji!;
        final after = take.on! ? emoji : (before == emoji ? null : before);
        if (after != before) {
          await _replaceBoxRow(
            target.copyWith(
              reactions: _reactorSet(target.reactions, actor, after),
            ),
          );
        }
      case E2eEnvelope.typePin:
        final applied = _takeBoxPin(
          target.conversationId,
          BoxPin(at: at, senderId: wire.senderId, wireId: wire.wireId),
          shown: target,
        );
        if (!applied) dropped('stale');
    }
  }

  /// Parks [take] until its target [wire] is stored in [conversationId]
  /// (E19k) — unless it can never land here: `s` is neither party of the
  /// chat, or [wire] is known already, yet not as a box message of this
  /// chat (a server row — decision 46 —, another chat's, one deleted here)
  /// or was deleted for everyone.
  Future<void> _parkBoxAction(
    _BoxActionTake take,
    WireKey wire, {
    required int conversationId,
    required int peer,
    required DateTime receivedAt,
  }) async {
    final enc = _encryptionProvider;
    if (enc == null) return;
    bool names(MessageModel m) =>
        m.senderId == wire.senderId && m.wireId == wire.wireId;
    if ((wire.senderId != peer && wire.senderId != _currentUserId) ||
        _messages.any(names) ||
        (_conversationCache[conversationId]?.any(names) ?? false) ||
        await enc.wireHolder(wire) != null ||
        await enc.boxTombstoned(wire)) {
      _e2eFlowLog('BOX_ACTION_DROPPED', {'t': take.type, 'why': 'no_target'});
      return;
    }
    await enc.parkBoxAction(
      conversationId,
      wire,
      _parkedJson(take),
      receivedAt: receivedAt,
    );
    _e2eFlowLog('BOX_ACTION_PARKED', {'t': take.type});
    // Stored while this was parked, after its own store read the park:
    // applied here instead (twice is harmless — each rule is idempotent).
    final target = await _heldBoxTarget(wire, conversationId);
    if (target != null) await _applyBoxAction(take, target, wire);
  }

  /// Applies what was parked for [msg] — a box message just PROVEN stored,
  /// a peer's or a sibling's sent copy — by the rules of live receipt,
  /// oldest `ts` first, then drops it (E19k).
  Future<void> _applyParkedBoxActions(MessageModel msg) async {
    final enc = _encryptionProvider;
    final wire = _wireKey(msg.senderId, msg.wireId);
    if (enc == null || wire == null || !isLocalMessageId(msg.id)) return;
    final conversationId = msg.conversationId;
    final parked = await enc.parkedBoxActions(conversationId, wire);
    if (parked.isEmpty) return;
    final takes = [for (final json in parked) ?_parkedFrom(json)]
      ..sort((a, b) => a.at.compareTo(b.at));
    for (final take in takes) {
      // The row as it is NOW: each action builds on the one before.
      final target = await _heldBoxTarget(wire, conversationId);
      if (target == null) break;
      await _applyBoxAction(take, target, wire);
    }
    await enc.dropParkedBoxActions(conversationId, wire);
  }

  /// Sets [conversationId]'s E2E pin to [next] when it is newer than the one
  /// held (E19b, the rule in [BoxPin.supersedes]), showing [shown] for a
  /// pin. False when [next] lost.
  bool _takeBoxPin(int conversationId, BoxPin next, {MessageModel? shown}) {
    final convs = _conversationsProvider;
    if (convs == null || !next.supersedes(convs.boxPinOf(conversationId))) {
      return false;
    }
    convs.applyBoxPin(conversationId, next, shown: shown);
    return true;
  }

  /// Shows [conversationId]'s E2E pin once its chat opens: the pin is kept
  /// by `(s, w)` on the contact record, and the message it names is found
  /// here, on this device (E19f).
  Future<void> _resolveBoxPin(int conversationId) async {
    final convs = _conversationsProvider;
    final pin = convs?.boxPinOf(conversationId);
    final wire = pin?.wire;
    if (convs == null || pin == null || wire == null) return;
    final shownId = convs.getConversationById(conversationId)?.pinnedMessageId;
    if (shownId != null && isLocalMessageId(shownId)) return;
    final target = await _heldBoxTarget(wire, conversationId);
    if (target == null) return;
    convs.applyBoxPin(conversationId, pin, shown: target);
  }

  /// Delete-for-everyone of [wire] in [conversationId] (E19c), on the
  /// sender's devices and every receiver alike: a tombstone first, so a copy
  /// arriving later is dropped; then the record, its box media copy and the
  /// row; every reply's quote words; and a pin naming it.
  Future<void> _applyBoxDelete(int conversationId, WireKey wire) async {
    await _encryptionProvider?.addBoxTombstone(wire);
    final target = await _heldBoxTarget(wire, conversationId);
    if (target != null) {
      _boxUnsaved.remove(target.id);
      // The local path of delete-for-me: purge (media copy included via
      // `onBoxMediaDestroyed`) and drop the row — no server event.
      _handleMessageDeleted({
        'messageId': target.id,
        'conversationId': conversationId,
      });
    }
    await _clearBoxQuotes(conversationId, wire);
    final convs = _conversationsProvider;
    final pin = convs?.boxPinOf(conversationId);
    if (convs != null && pin != null && pin.names(wire)) {
      // Unpinned AT the pin's own time: a copy of that pin arriving again
      // ties, and a tie keeps it unpinned.
      convs.applyBoxPin(conversationId, BoxPin(at: pin.at));
    }
  }

  /// Takes the words of the quote [wire] out of every reply to it in
  /// [conversationId] — in RAM and in the records — so a snippet never
  /// outlives a message deleted for everyone (E19c, the item-3 residual).
  Future<void> _clearBoxQuotes(int conversationId, WireKey wire) async {
    bool quotes(ReplyToPreview? r) =>
        r != null &&
        r.senderId == wire.senderId &&
        r.wireId == wire.wireId &&
        (r.id != 0 || r.content.isNotEmpty);
    MessageModel cleared(MessageModel m) {
      final r = m.replyTo!;
      return m.copyWith(
        replyTo: ReplyToPreview(
          id: 0,
          content: '',
          senderUsername: r.senderUsername,
          messageType: r.messageType,
          wireId: r.wireId,
          senderId: r.senderId,
          quotedDisappears: r.quotedDisappears,
        ),
      );
    }

    final shown = <int, MessageModel>{};
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.conversationId != conversationId || !quotes(m.replyTo)) continue;
      shown[m.id] = _messages[i] = cleared(m);
    }
    final cached = _conversationCache[conversationId];
    if (cached != null) {
      for (var i = 0; i < cached.length; i++) {
        if (quotes(cached[i].replyTo)) cached[i] = cleared(cached[i]);
      }
    }
    for (final MapEntry(key: id, value: m) in _boxUnsaved.entries.toList()) {
      if (m.conversationId == conversationId && quotes(m.replyTo)) {
        _boxUnsaved[id] = cleared(m);
      }
    }
    if (shown.isNotEmpty) notifyListeners();
    final enc = _encryptionProvider;
    if (enc == null) return;
    final records = await enc.localMessageRecords(conversationId);
    final conversation = _conversationsProvider?.getConversationById(
      conversationId,
    );
    for (final MapEntry(key: id, value: record) in records.entries) {
      final raw = record['replyTo'];
      if (raw is! Map<String, dynamic> ||
          !quotes(ReplyToPreview.fromJson(raw))) {
        continue;
      }
      final row =
          shown[id] ?? _boxRowFrom(id, conversationId, record, conversation);
      if (row == null || row.replyTo == null) continue;
      await _persistDecryptedContent(
        quotes(row.replyTo) ? cleared(row) : row,
      );
    }
  }

  /// A reaction of ours on box message [messageId] (E19a/E19d): shown at
  /// once, sent over the box, kept in the record once ANY device took it
  /// (the rest are retried, E19l); taken back when none did. [on] false
  /// takes [emoji] off.
  Future<bool> _reactOverBox(
    int messageId,
    String emoji, {
    required bool on,
  }) async {
    final own = _currentUserId;
    final target = messageById(messageId);
    final wire = target == null ? null : _wireKey(target.senderId, target.wireId);
    if (own == null || target == null || wire == null) return false;
    final before = _reactionOf(target.reactions, own);
    final after = on ? emoji : (before == emoji ? null : before);
    if (after == before) return true;
    _showBoxRow(
      target.copyWith(reactions: _reactorSet(target.reactions, own, after)),
    );
    final sent = await _sendBoxAction(
      target.conversationId,
      E2eEnvelope.typeReact,
      wire,
      sentAt: _wholeMsNow(),
      emoji: emoji,
      on: on,
    );
    // The row as it is NOW: another reaction may have landed meanwhile.
    final current = await _heldBoxTarget(wire, target.conversationId);
    if (current != null) {
      final settled = current.copyWith(
        reactions: _reactorSet(current.reactions, own, sent ? after : before),
      );
      if (sent) {
        await _replaceBoxRow(settled);
      } else {
        _showBoxRow(settled);
      }
    }
    return sent;
  }

  /// Sends the edit of our box message [original] to [content], applied
  /// optimistically at [at] by `editMessage` (E19c): kept in the record once
  /// ANY device took it (the rest are retried, E19l), reverted and reported
  /// when none did. [original] is the very snapshot `editMessage` parked in
  /// `_pendingEdits`: a later edit of the same row parks its own, and this
  /// one must never settle or revert that one.
  Future<void> _editOverBox(
    MessageModel original,
    String content,
    DateTime at,
  ) async {
    final wire = _wireKey(original.senderId, original.wireId)!;
    final sent = await _sendBoxAction(
      original.conversationId,
      E2eEnvelope.typeEdit,
      wire,
      sentAt: at,
      content: content,
    );
    final ours = identical(_pendingEdits[original.id], original);
    if (!sent) {
      // A newer edit of this row is in flight: it owns the row now.
      if (ours) _revertPendingEdit(original.id, 'Box edit failed');
      _boxActionFailed(BoxActionFailure.edit);
      return;
    }
    if (ours) _pendingEdits.remove(original.id);
    final current = await _heldBoxTarget(wire, original.conversationId);
    final lastEdit = current?.editedAt;
    // Last writer wins here too (E19b): an older edit whose frames settled
    // after a newer one must not overwrite it, as it cannot on the peers.
    // Equal is THIS edit: `editMessage` already showed it at [at].
    if (current != null && (lastEdit == null || !at.isBefore(lastEdit))) {
      await _replaceBoxRow(current.copyWith(content: content, editedAt: at));
    }
  }

  /// Delete-for-everyone of our box message [messageId] (E19c): nothing is
  /// removed until a device took it — the delete is irreversible here, so a
  /// failure has nothing to undo — and a failure is reported. Once ANY
  /// device took it the delete completes here, and the devices that did
  /// not are retried (E19l): those that took it already applied it.
  Future<void> _deleteOverBox(int messageId) async {
    final target = messageById(messageId);
    final wire = target == null ? null : _wireKey(target.senderId, target.wireId);
    if (target == null || wire == null || target.senderId != _currentUserId) {
      _boxActionFailed(BoxActionFailure.delete);
      return;
    }
    final sent = await _sendBoxAction(
      target.conversationId,
      E2eEnvelope.typeDelete,
      wire,
      sentAt: _wholeMsNow(),
    );
    if (!sent) {
      _boxActionFailed(BoxActionFailure.delete);
      return;
    }
    await _applyBoxDelete(target.conversationId, wire);
  }

  /// Pins box message [messageId] (decision 45): shown at once, sent over
  /// the box, then kept once ANY device took it (the rest are retried,
  /// E19l); a server pin still held in this chat is cleared with ONE
  /// `unpinMessage`. A pin NO device took restores what it displaced.
  Future<void> _pinOverBox(int conversationId, int messageId) async {
    final convs = _conversationsProvider;
    final target = messageById(messageId);
    final wire = target == null ? null : _wireKey(target.senderId, target.wireId);
    if (convs == null || target == null || wire == null) {
      _boxActionFailed(BoxActionFailure.pin);
      return;
    }
    final at = _wholeMsNow();
    convs.setPinnedPreviewOptimistic(conversationId, messageId, target);
    final sent = await _sendBoxAction(
      conversationId,
      E2eEnvelope.typePin,
      wire,
      sentAt: at,
      on: true,
    );
    if (!sent ||
        !_takeBoxPin(
          conversationId,
          BoxPin(at: at, senderId: wire.senderId, wireId: wire.wireId),
          shown: target,
        )) {
      convs.onPinMessageFailed({'conversationId': conversationId});
      if (!sent) _boxActionFailed(BoxActionFailure.pin);
      return;
    }
    // Peeked, not taken: the entry goes only when `messageUnpinned` answers,
    // so a socket down right now leaves it for the next box pin to clear.
    if (convs.serverPinOf(conversationId) != null) {
      _emit?.call('unpinMessage', {'conversationId': conversationId});
    }
  }

  /// Unpins [conversationId]'s E2E pin [pin] (decision 45), as [_pinOverBox]
  /// pins.
  Future<void> _unpinOverBox(int conversationId, BoxPin pin) async {
    final convs = _conversationsProvider!;
    final at = _wholeMsNow();
    convs.setUnpinnedOptimistic(conversationId);
    final sent = await _sendBoxAction(
      conversationId,
      E2eEnvelope.typePin,
      pin.wire!,
      sentAt: at,
      on: false,
    );
    if (!sent || !_takeBoxPin(conversationId, BoxPin(at: at))) {
      convs.onPinMessageFailed({'conversationId': conversationId});
      if (!sent) _boxActionFailed(BoxActionFailure.pin);
    }
  }
}
