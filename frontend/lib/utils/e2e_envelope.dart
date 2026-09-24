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

  /// When the sender sent it, whole ms since the epoch (decision 13): a box
  /// message has no server `createdAt`. Peer-claimed, so the receiver clamps
  /// it to its own receive time.
  static const String _keySentAt = 'ts';

  /// `DateTime`'s own range; also keeps the value an exact integer on web.
  static const int _maxEpochMs = 8640000000000000;

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
  }) {
    final envelope = <String, dynamic>{_keyContent: content};
    if (type != null) envelope[_keyType] = type;
    if (sentAt != null) envelope[_keySentAt] = sentAt.millisecondsSinceEpoch;
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
    );
  }

  static bool _areValidMediaDimensions(Object? width, Object? height) =>
      width is int &&
      height is int &&
      width > 0 &&
      height > 0 &&
      width <= _maximumMediaDimension &&
      height <= _maximumMediaDimension;
}
