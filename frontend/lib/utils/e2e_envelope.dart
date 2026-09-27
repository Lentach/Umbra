import 'dart:convert';

import 'message_expiry.dart';

/// One parsed [E2eEnvelope].
typedef E2eEnvelopeFields = ({
  String content,
  String messageType,
  String? mediaUrl,
  int? mediaDuration,
  String? mediaKey,
  String? mediaIv,
  int? mediaWidth,
  int? mediaHeight,
  String? mediaThumbHash,
  String? linkPreviewUrl,
  String? linkPreviewTitle,
  String? linkPreviewImageUrl,
  Object? senderListInfo,
  String? msgId,
  String type,
  DateTime? sentAt,
  int? sentTo,
  int? ttl,
  E2eReplyQuote? replyQuote,
  String? boxMedia,
});

/// A box reply's quote (metadata-privacy item 3, E18a): the quoted
/// message's wire id and sender — a wire id is unique per sender only — its
/// message type, and the snippet a device that does not hold it shows.
typedef E2eReplyQuote = ({
  String? wireId,
  int senderId,
  String type,
  String snippet,
});

/// A box message action (metadata-privacy item 4, E19a/E19e): its type,
/// the target message — named by its sender and wire id, since a wire id is
/// unique per sender only — and, per type, the reaction's emoji and whether
/// a reaction or pin is put on (true) or taken off (false).
typedef E2eBoxAction = ({
  String type,
  int targetSender,
  String targetWire,
  String? emoji,
  bool? on,
});

/// A profile carried inside E2E (metadata-privacy slice (f), decision 55):
/// the sender's name and tag and its photo's server path. Authenticated by
/// the Signal session, still only the sender's own word.
typedef E2eProfile = ({String username, String tag, String? avatarUrl});

/// E2E encrypted message envelope format. Single source of truth for build/parse.
class E2eEnvelope {
  E2eEnvelope._();

  static const String _keyContent = 'content';
  static const String _keyMessageType = 'messageType';
  static const String _keyMediaUrl = 'mediaUrl';
  static const String _keyMediaDuration = 'mediaDuration';
  static const String _keyMediaKey = 'mediaKey';
  static const String _keyMediaIv = 'mediaIv';
  static const String _keyMediaWidth = 'mediaWidth';
  static const String _keyMediaHeight = 'mediaHeight';
  static const String _keyMediaThumbHash = 'mediaThumbHash';
  static const int _maximumMediaDimension = 32768;
  static const String _keyLinkPreview = 'linkPreview';
  static const String _keyUrl = 'url';
  static const String _keyTitle = 'title';
  static const String _keyImageUrl = 'imageUrl';

  /// The §5.2 layer-2 device-list cross-check (spec §12 amendment (xv)). Lives
  /// INSIDE the E2E plaintext: the server never sees it. Unknown keys are
  /// ignored by [parse], so an older peer simply omits it (the `linkPreview`
  /// precedent, root `CLAUDE.md` §7).
  static const String _keySenderListInfo = 'senderListInfo';

  /// The message's WIRE id (metadata-privacy PR2.1): the sender's `sendToken`
  /// for this send, carried inside the E2E plaintext so every receiving
  /// device learns it — the server withholds the token from everyone but the
  /// origin device. It names the message independently of any server row id,
  /// which the box path (PR3.1) will not have. An edit never carries one: it
  /// re-encrypts an existing message and must not claim a wire identity.
  static const String _keyMsgId = 'msgId';

  /// The sender's own minting shape (`_sendTokenFor`): its charset is the
  /// client's, its length the server's `sendToken` bound (8..64).
  static final RegExp _msgIdShape = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  /// What the box dispatcher routes on (metadata-privacy PR3.1, decision
  /// 13). Absent = a chat message, which is every old-path envelope.
  static const String _keyType = 't';
  static const String typeMessage = 'msg';

  /// A sibling hands this account's other devices its box SELF-queue
  /// address (metadata-privacy PR3.1 sibling queues, owner decisions 26/27):
  /// `{t, sid, sealPub}`, sent into each sibling's REQUEST queue until that
  /// sibling acknowledges it.
  static const String typeQueueHandoff = 'queue_handoff';

  /// The acknowledgement of one handoff: `{t, sid}` naming the self-queue sid
  /// it stored, sent back into the handing device's self-queue.
  static const String typeQueueHandoffAck = 'queue_handoff_ack';
  static const String _keySid = 'sid';
  static const String _keySealPub = 'sealPub';

  /// A device's account device list, carried to a friend's LIVE device
  /// inside E2E over a normal queue (metadata-privacy slice (e), E50b):
  /// `{t, auth}`, where `auth` is the authorization record exactly as
  /// `getDeviceList` serves it. Sent by every surviving device after a
  /// revoke (E50d) and in answer to a frame that shows a stale view of our
  /// list (E50f). A newly linked device's list rides OUTSIDE Signal, in its
  /// handoff's list-bearing request-queue frame (`BoxFrame.carriedList`,
  /// decision 50): it must be judged before Signal sees the frame.
  static const String typeListUpdate = 'list_update';
  static const String _keyAuth = 'auth';

  /// First contact (metadata-privacy slice (f), E15b): `{t, sid, sealPub, p}`
  /// — the queue the requester made for this account and its profile `p`
  /// (decision 55) — inside Signal, in the claim-bearing PreKey frame on each
  /// target device's request queue. The accept is a [typeQueueHandoff]
  /// carrying the accepter's `p` too.
  static const String typeFriendRequest = 'friend_request';
  static const String _keyProfile = 'p';
  static const String _keyProfileUsername = 'u';
  static const String _keyProfileTag = 'g';
  static const String _keyProfileAvatar = 'a';

  /// A photo is only ever a file on OUR server's avatar path: the server
  /// serves `<its base>/media/avatars/<file>` (`LocalStorageService
  /// .uploadAvatar`). Only that PATH is kept — the reader puts its own
  /// server in front — so a peer can never make the app fetch from a host
  /// it picked.
  static final RegExp _avatarPath = RegExp(
    r'^/media/avatars/[A-Za-z0-9._-]{1,128}$',
  );

  /// What a device tells its own siblings about a first contact, over the
  /// self-queues (E15e): `{t, peer}`, where `peer` is the search answer for
  /// the other account as this device holds it (`FirstContactPeer
  /// .toSiblingJson`). [typeFriendRequestSent]: this account asked it;
  /// [typeFriendAccepted]: this account accepted its request.
  static const String typeFriendRequestSent = 'friend_request_sent';
  static const String typeFriendAccepted = 'friend_accepted';
  static const String _keyPeer = 'peer';

  /// `{t, to}`: this account declined `to`'s request (E15e; decision 54: the
  /// requester is told nothing, only our siblings are).
  static const String typeFriendDeclined = 'friend_declined';

  /// The end of a friendship made over the box (E15j): `{t}` to each of the
  /// friend's devices; `{t, to, b?}` to our siblings, `b` when it is a block.
  static const String typeGoodbye = 'goodbye';
  static const String _keyBlock = 'b';

  /// The timer SETTING of a chat made over the box (E15k): `{t, ttl, ts}`,
  /// `ttl` null = off; to our siblings with `to`. Last writer wins on `ts`.
  static const String typeTimer = 'timer';

  /// The box's one spelling of a 32-byte id or key: unpadded base64url whose
  /// last char carries no spare bits (wire.md "First contact").
  static final RegExp _boxId32 = RegExp(
    r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$',
  );

  /// When the sender sent it, whole ms since the epoch (decision 13): a box
  /// message has no server `createdAt`. Peer-claimed, so the receiver clamps
  /// it to its own receive time.
  static const String _keySentAt = 'ts';

  /// `DateTime`'s own range; also keeps the value an exact integer on web.
  static const int _maxEpochMs = 8640000000000000;

  /// Who a SENT COPY was sent to (metadata-privacy PR3.1 sibling queues part
  /// B, E5): the peer's user id, set only on the copy a sender hands its own
  /// other devices, so a sibling files it under the right chat. Inside the
  /// E2E plaintext: the box sees no account at all.
  static const String _keySentTo = 'to';

  /// A box message's own timer in seconds (metadata-privacy item 3, E18b,
  /// decision 42): the chat's setting stays a server column, and each box
  /// message carries the one it was sent under. Only the timer sheet's range
  /// counts; anything else is no timer.
  static const String _keyTtl = 'ttl';

  /// A box reply's quote ([E2eReplyQuote], E18a): `{w?, s, k, x}`.
  static const String _keyReplyQuote = 're';
  static const String _keyQuoteWireId = 'w';
  static const String _keyQuoteSender = 's';
  static const String _keyQuoteType = 'k';
  static const String _keyQuoteSnippet = 'x';

  /// The most UTF-8 bytes a quote's snippet carries (E18a/E18c): enough to
  /// recognise the quoted message, small enough that the longest text the
  /// composer takes still fits one box frame with it.
  static const int maxQuoteSnippetBytes = 256;

  /// A box attachment's 32-byte id (E17a), spelled as the box spells one.
  static const String _keyBoxMedia = 'boxMedia';

  /// The box message actions (item 4, E19a): a reaction, a pin or unpin,
  /// an edit, a delete-for-everyone of the message `tg` names.
  static const String typeReact = 'react';
  static const String typePin = 'pin';
  static const String typeEdit = 'edit';
  static const String typeDelete = 'del';
  static const Set<String> actionTypes = {
    typeReact,
    typePin,
    typeEdit,
    typeDelete,
  };
  static const String _keyTarget = 'tg';
  static const String _keyTargetSender = 's';
  static const String _keyTargetWire = 'w';
  static const String _keyEmoji = 'e';
  static const String _keyOn = 'on';

  /// The most UTF-8 bytes a reaction's emoji may take: room for the longest
  /// ZWJ sequences with skin tones, not for text.
  static const int maxReactionEmojiBytes = 64;

  static Map<String, dynamic> build(
    String content, {
    String messageType = 'TEXT',
    String? mediaUrl,
    int? mediaDuration,
    String? mediaKey,
    String? mediaIv,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
    Map<String, String?>? linkPreview,
    Map<String, dynamic>? senderListInfo,
    String? msgId,
    String? type,
    DateTime? sentAt,
    int? sentTo,
    int? ttl,
    E2eReplyQuote? replyQuote,
    String? boxMedia,
  }) {
    final envelope = <String, dynamic>{_keyContent: content};
    if (type != null) envelope[_keyType] = type;
    if (sentAt != null) envelope[_keySentAt] = sentAt.millisecondsSinceEpoch;
    if (sentTo != null) envelope[_keySentTo] = sentTo;
    if (messageType != 'TEXT') envelope[_keyMessageType] = messageType;
    if (mediaUrl != null) envelope[_keyMediaUrl] = mediaUrl;
    if (mediaDuration != null) envelope[_keyMediaDuration] = mediaDuration;
    if (mediaKey != null) envelope[_keyMediaKey] = mediaKey;
    if (mediaIv != null) envelope[_keyMediaIv] = mediaIv;
    if (_areValidMediaDimensions(mediaWidth, mediaHeight)) {
      envelope[_keyMediaWidth] = mediaWidth;
      envelope[_keyMediaHeight] = mediaHeight;
    }
    if (mediaThumbHash != null && mediaThumbHash.isNotEmpty) {
      envelope[_keyMediaThumbHash] = mediaThumbHash;
    }
    if (linkPreview != null) envelope[_keyLinkPreview] = linkPreview;
    if (senderListInfo != null && senderListInfo.isNotEmpty) {
      envelope[_keySenderListInfo] = senderListInfo;
    }
    if (msgId != null) envelope[_keyMsgId] = msgId;
    if (_isValidTtl(ttl)) envelope[_keyTtl] = ttl;
    if (replyQuote != null && _isUserId(replyQuote.senderId)) {
      final wireId = replyQuote.wireId;
      envelope[_keyReplyQuote] = {
        if (wireId != null && _msgIdShape.hasMatch(wireId))
          _keyQuoteWireId: wireId,
        _keyQuoteSender: replyQuote.senderId,
        _keyQuoteType: replyQuote.type,
        _keyQuoteSnippet: _cutToBytes(
          replyQuote.snippet,
          maxQuoteSnippetBytes,
        ),
      };
    }
    if (boxMedia != null && _boxId32.hasMatch(boxMedia)) {
      envelope[_keyBoxMedia] = boxMedia;
    }
    return envelope;
  }

  static E2eEnvelopeFields parse(String jsonStr) {
    final envelope = jsonDecode(jsonStr) as Map<String, dynamic>;
    final content = envelope[_keyContent] as String? ?? '';
    final messageType = envelope[_keyMessageType] as String? ?? 'TEXT';
    final mediaUrl = envelope[_keyMediaUrl] as String?;
    final rawDuration = envelope[_keyMediaDuration];
    final mediaDuration = rawDuration is num ? rawDuration.round() : null;
    final mediaWidth = envelope[_keyMediaWidth];
    final mediaHeight = envelope[_keyMediaHeight];
    final validDimensions = _areValidMediaDimensions(mediaWidth, mediaHeight);
    final rawThumbHash = envelope[_keyMediaThumbHash];
    final mediaThumbHash = rawThumbHash is String ? rawThumbHash : null;
    final lp = envelope[_keyLinkPreview] as Map<String, dynamic>?;
    // Peer data bound for this device's disk (the `_wid` record stamp):
    // anything outside the minting shape is dropped, never the message.
    final rawMsgId = envelope[_keyMsgId];
    final rawType = envelope[_keyType];
    final rawSentAt = envelope[_keySentAt];
    final rawSentTo = envelope[_keySentTo];
    final rawTtl = envelope[_keyTtl];
    final rawBoxMedia = envelope[_keyBoxMedia];
    return (
      content: content,
      messageType: messageType,
      mediaUrl: mediaUrl,
      mediaDuration: mediaDuration,
      mediaKey: envelope[_keyMediaKey] as String?,
      mediaIv: envelope[_keyMediaIv] as String?,
      mediaWidth: validDimensions ? mediaWidth as int : null,
      mediaHeight: validDimensions ? mediaHeight as int : null,
      mediaThumbHash:
          validDimensions && mediaThumbHash != null && mediaThumbHash.isNotEmpty
          ? mediaThumbHash
          : null,
      linkPreviewUrl: lp?[_keyUrl] as String?,
      linkPreviewTitle: lp?[_keyTitle] as String?,
      linkPreviewImageUrl: lp?[_keyImageUrl] as String?,
      senderListInfo: envelope[_keySenderListInfo],
      msgId: rawMsgId is String && _msgIdShape.hasMatch(rawMsgId)
          ? rawMsgId
          : null,
      // A non-string t matches no type: it is never read as a message.
      type: rawType == null ? typeMessage : (rawType is String ? rawType : ''),
      sentAt: rawSentAt is int && rawSentAt > 0 && rawSentAt <= _maxEpochMs
          ? DateTime.fromMillisecondsSinceEpoch(rawSentAt, isUtc: true)
          : null,
      // A user id (a Postgres int4); anything else names no one.
      sentTo: rawSentTo is int && rawSentTo > 0 && rawSentTo <= 0x7fffffff
          ? rawSentTo
          : null,
      ttl: rawTtl is int && _isValidTtl(rawTtl) ? rawTtl : null,
      replyQuote: _parseReplyQuote(envelope[_keyReplyQuote]),
      boxMedia: rawBoxMedia is String && _boxId32.hasMatch(rawBoxMedia)
          ? rawBoxMedia
          : null,
    );
  }

  /// A quote a peer sent: dropped whole unless its sender, type and snippet
  /// are sound — it is shown and stored, never the reason a message is lost.
  /// A wire id outside the minting shape is dropped alone: the snippet still
  /// shows (a quoted message older than PR2.1 has none).
  static E2eReplyQuote? _parseReplyQuote(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final senderId = raw[_keyQuoteSender];
    final type = raw[_keyQuoteType];
    final snippet = raw[_keyQuoteSnippet];
    final wireId = raw[_keyQuoteWireId];
    if (senderId is! int || !_isUserId(senderId)) return null;
    if (type is! String || snippet is! String) return null;
    if (utf8.encode(snippet).length > maxQuoteSnippetBytes) return null;
    return (
      wireId: wireId is String && _msgIdShape.hasMatch(wireId) ? wireId : null,
      senderId: senderId,
      type: type,
      snippet: snippet,
    );
  }

  static bool _isValidTtl(int? ttl) =>
      ttl != null &&
      ttl >= kDisappearingMinSeconds &&
      ttl <= kDisappearingMaxSeconds;

  /// A user id (a Postgres int4).
  static bool _isUserId(int id) => id > 0 && id <= 0x7fffffff;

  /// [text] cut to at most [maxBytes] UTF-8 bytes, only ever between two
  /// code points.
  static String _cutToBytes(String text, int maxBytes) {
    var bytes = 0;
    var end = 0;
    for (final rune in text.runes) {
      bytes += rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      if (bytes > maxBytes) return text.substring(0, end);
      end += rune < 0x10000 ? 1 : 2;
    }
    return text;
  }

  /// A [typeQueueHandoff] envelope handing over the queue [sid] and the key
  /// its seal layer expects; an accept (slice (f), E15d) carries the
  /// accepter's [profile] too (decision 55).
  static Map<String, dynamic> buildQueueHandoff({
    required String sid,
    required String sealPub,
    E2eProfile? profile,
  }) => {
    _keyType: typeQueueHandoff,
    _keySid: sid,
    _keySealPub: sealPub,
    if (profile != null) _keyProfile: _profileJson(profile),
  };

  /// A [typeFriendRequest] envelope (E15b): our queue [sid]/[sealPub] for
  /// the account asked, and our [profile].
  static Map<String, dynamic> buildFriendRequest({
    required String sid,
    required String sealPub,
    required E2eProfile profile,
  }) => {
    _keyType: typeFriendRequest,
    _keySid: sid,
    _keySealPub: sealPub,
    _keyProfile: _profileJson(profile),
  };

  /// The queue a [typeFriendRequest] envelope offers and the profile it
  /// carries (null when absent or not sound); null for any other type or
  /// an address not spelled as the box spells a 32-byte id.
  static ({String sid, String sealPub, E2eProfile? profile})?
  parseFriendRequest(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope == null || envelope[_keyType] != typeFriendRequest) {
      return null;
    }
    final sid = envelope[_keySid];
    final sealPub = envelope[_keySealPub];
    if (sid is! String || !_boxId32.hasMatch(sid)) return null;
    if (sealPub is! String || !_boxId32.hasMatch(sealPub)) return null;
    return (sid: sid, sealPub: sealPub, profile: _profileOf(envelope));
  }

  /// The profile `p` any envelope carries (a request, an accept's handoff);
  /// null when absent or not sound. Its photo is the PATH of a file on our
  /// server's avatar route (host and query dropped), or null.
  static E2eProfile? profileOf(String jsonStr) {
    final envelope = _object(jsonStr);
    return envelope == null ? null : _profileOf(envelope);
  }

  static E2eProfile? _profileOf(Map<String, dynamic> envelope) {
    if (envelope[_keyProfile]
        case {
              _keyProfileUsername: final String username,
              _keyProfileTag: final String tag,
            } &&
            final Map<String, dynamic> raw
        when username.isNotEmpty &&
            username.length <= 64 &&
            tag.isNotEmpty &&
            tag.length <= 16) {
      final avatar = raw[_keyProfileAvatar];
      final path = avatar is String ? Uri.tryParse(avatar)?.path : null;
      return (
        username: username,
        tag: tag,
        avatarUrl: path != null && _avatarPath.hasMatch(path) ? path : null,
      );
    }
    return null;
  }

  static Map<String, dynamic> _profileJson(E2eProfile profile) => {
    _keyProfileUsername: profile.username,
    _keyProfileTag: profile.tag,
    _keyProfileAvatar: ?profile.avatarUrl,
  };

  /// A sibling copy of a first contact (E15e): [type] is
  /// [typeFriendRequestSent] or [typeFriendAccepted], [peer] the search
  /// answer for the other account.
  static Map<String, dynamic> buildFriendRelay(
    String type,
    Map<String, dynamic> peer,
  ) => {_keyType: type, _keyPeer: peer};

  /// The search answer a [typeFriendRequestSent] or [typeFriendAccepted]
  /// envelope relays; null for any other type. Checked by its reader.
  static Map<String, dynamic>? relayedPeer(String jsonStr) {
    final envelope = _object(jsonStr);
    final type = envelope?[_keyType];
    if (type != typeFriendRequestSent && type != typeFriendAccepted) {
      return null;
    }
    final peer = envelope![_keyPeer];
    return peer is Map<String, dynamic> ? peer : null;
  }

  /// A [typeFriendDeclined] envelope: we declined [userId]'s request.
  static Map<String, dynamic> buildFriendDeclined(int userId) => {
    _keyType: typeFriendDeclined,
    _keySentTo: userId,
  };

  /// A [typeGoodbye] envelope; to a sibling it names the friend [sentTo]
  /// and whether it is a [block].
  static Map<String, dynamic> buildGoodbye({int? sentTo, bool block = false}) =>
      {
        _keyType: typeGoodbye,
        _keySentTo: ?sentTo,
        if (block) _keyBlock: true,
      };

  /// Whether [jsonStr]'s [typeGoodbye] is a block (a sibling copy only);
  /// null for any other type.
  static bool? goodbyeBlocks(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope == null || envelope[_keyType] != typeGoodbye) return null;
    return envelope[_keyBlock] == true;
  }

  /// A [typeTimer] envelope: the chat's timer [ttl] (null = off) as set at
  /// [sentAt]; a sibling copy names the peer in [sentTo].
  static Map<String, dynamic> buildTimer({
    required int? ttl,
    required DateTime sentAt,
    int? sentTo,
  }) => {
    _keyType: typeTimer,
    _keyTtl: ttl,
    _keySentAt: sentAt.millisecondsSinceEpoch,
    _keySentTo: ?sentTo,
  };

  /// The setting a [typeTimer] envelope carries; null for any other type,
  /// a `ttl` outside the timer sheet's range, or no sound `ts`.
  static ({int? ttl, DateTime sentAt})? parseTimer(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope case {
      _keyType: typeTimer,
      _keyTtl: final int? ttl,
      _keySentAt: final int ts,
    } when (ttl == null || _isValidTtl(ttl)) && ts > 0 && ts <= _maxEpochMs) {
      return (
        ttl: ttl,
        sentAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      );
    }
    return null;
  }

  /// A [typeListUpdate] envelope carrying this account's device list [auth].
  static Map<String, dynamic> buildListUpdate(Map<String, dynamic> auth) => {
    _keyType: typeListUpdate,
    _keyAuth: auth,
  };

  /// A [typeQueueHandoffAck] envelope acknowledging the handed-over [sid].
  static Map<String, dynamic> buildQueueHandoffAck({required String sid}) => {
    _keyType: typeQueueHandoffAck,
    _keySid: sid,
  };

  /// A box message action envelope (item 4, E19a/E19e): `t`, the target
  /// `tg: {s, w}`, the sender's `ts`, and per type the reaction's `e`, the
  /// `on` of a reaction or pin, an edit's new `content`; a SENT COPY names
  /// the peer in [sentTo]. Never a `msgId`: an action is not a message.
  static Map<String, dynamic> buildAction(
    String type, {
    required int targetSender,
    required String targetWire,
    required DateTime sentAt,
    String? emoji,
    bool? on,
    String content = '',
    int? sentTo,
    Map<String, dynamic>? senderListInfo,
  }) => {
    _keyType: type,
    _keySentAt: sentAt.millisecondsSinceEpoch,
    _keyTarget: {_keyTargetSender: targetSender, _keyTargetWire: targetWire},
    if (type == typeEdit) _keyContent: content,
    _keyEmoji: ?emoji,
    _keyOn: ?on,
    _keySentTo: ?sentTo,
    if (senderListInfo != null && senderListInfo.isNotEmpty)
      _keySenderListInfo: senderListInfo,
  };

  /// The action a peer's envelope carries; null — the whole action dropped
  /// — for any other type or a target, emoji or `on` that is not sound. An
  /// edit's words are [parse]'s `content`, its time `sentAt`.
  static E2eBoxAction? parseAction(String jsonStr) {
    final envelope = _object(jsonStr);
    final type = envelope?[_keyType];
    if (envelope == null || type is! String || !actionTypes.contains(type)) {
      return null;
    }
    final target = envelope[_keyTarget];
    if (target is! Map<String, dynamic>) return null;
    final sender = target[_keyTargetSender];
    final wire = target[_keyTargetWire];
    if (sender is! int || !_isUserId(sender)) return null;
    if (wire is! String || !_msgIdShape.hasMatch(wire)) return null;
    final on = envelope[_keyOn];
    if ((type == typeReact || type == typePin) && on is! bool) return null;
    final emoji = envelope[_keyEmoji];
    if (type == typeReact &&
        (emoji is! String ||
            emoji.isEmpty ||
            utf8.encode(emoji).length > maxReactionEmojiBytes)) {
      return null;
    }
    return (
      type: type,
      targetSender: sender,
      targetWire: wire,
      emoji: type == typeReact ? emoji as String : null,
      on: on is bool ? on : null,
    );
  }

  /// The address a [typeQueueHandoff] envelope carries; null for any other
  /// type or an address not spelled as the box spells a 32-byte id — a
  /// sibling's claim is stored and later sent to, so it is never guessed at.
  static ({String sid, String sealPub})? parseQueueHandoff(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope == null || envelope[_keyType] != typeQueueHandoff) return null;
    final sid = envelope[_keySid];
    final sealPub = envelope[_keySealPub];
    if (sid is! String || !_boxId32.hasMatch(sid)) return null;
    if (sealPub is! String || !_boxId32.hasMatch(sealPub)) return null;
    return (sid: sid, sealPub: sealPub);
  }

  /// The sid a [typeQueueHandoffAck] envelope acknowledges; null otherwise.
  static String? parseQueueHandoffAck(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope == null || envelope[_keyType] != typeQueueHandoffAck) {
      return null;
    }
    final sid = envelope[_keySid];
    return sid is String && _boxId32.hasMatch(sid) ? sid : null;
  }

  /// The device list a [typeListUpdate] envelope carries (E50b); null for
  /// any other type, or one not carried as an object. What it holds is
  /// checked by the adoption, never here.
  static Map<String, dynamic>? carriedDeviceList(String jsonStr) {
    final envelope = _object(jsonStr);
    if (envelope == null || envelope[_keyType] != typeListUpdate) return null;
    final auth = envelope[_keyAuth];
    return auth is Map<String, dynamic> ? auth : null;
  }

  static Map<String, dynamic>? _object(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static bool _areValidMediaDimensions(Object? width, Object? height) =>
      width is int &&
      height is int &&
      width > 0 &&
      height > 0 &&
      width <= _maximumMediaDimension &&
      height <= _maximumMediaDimension;
}
