import 'dart:convert';

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
});

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

  /// The box's one spelling of a 32-byte id or key: unpadded base64url whose
  /// last char carries no spare bits (wire.md "First contact").
  static final RegExp _boxId32 = RegExp(r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$');

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
    );
  }

  /// A [typeQueueHandoff] envelope handing over the self-queue [sid] and the
  /// key its seal layer expects.
  static Map<String, dynamic> buildQueueHandoff({
    required String sid,
    required String sealPub,
  }) => {_keyType: typeQueueHandoff, _keySid: sid, _keySealPub: sealPub};

  /// A [typeQueueHandoffAck] envelope acknowledging the handed-over [sid].
  static Map<String, dynamic> buildQueueHandoffAck({required String sid}) => {
    _keyType: typeQueueHandoffAck,
    _keySid: sid,
  };

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
