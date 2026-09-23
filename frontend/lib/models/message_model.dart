enum MessageDeliveryStatus { sending, sent, delivered, read, failed }

enum MessageType { text, ping, image, voice, gif, file, video }

/// Preview of a message being replied to (sent in payload).
class ReplyToPreview {
  final int id;
  final String content;
  final String senderUsername;
  final MessageType messageType;

  const ReplyToPreview({
    required this.id,
    required this.content,
    required this.senderUsername,
    required this.messageType,
  });

  factory ReplyToPreview.fromJson(Map<String, dynamic> json) {
    return ReplyToPreview(
      id: json['id'] as int,
      content: json['content'] as String? ?? '',
      senderUsername: json['senderUsername'] as String? ?? '',
      messageType: MessageModel._parseMessageType(
        json['messageType'] as String?,
      ),
    );
  }
}

class MessageModel {
  final int id;
  final String content;
  final int senderId;
  final String senderUsername;
  final int conversationId;
  final DateTime createdAt;
  final MessageDeliveryStatus deliveryStatus;
  final DateTime? expiresAt;

  /// TTL frozen at send; countdown starts when recipient reads.
  final int? disappearAfterSeconds;
  final MessageType messageType;
  final String? mediaUrl;
  final int? mediaDuration;

  /// Intrinsic encrypted media geometry from the E2E envelope — client-only.
  final int? mediaWidth;

  /// Intrinsic encrypted media geometry from the E2E envelope — client-only.
  final int? mediaHeight;

  /// Compact encrypted visual placeholder from the E2E envelope — client-only.
  final String? mediaThumbHash;
  final String? tempId; // For optimistic message matching
  final Map<String, List<int>> reactions; // emoji -> [userId]
  final int? replyToMessageId;
  final ReplyToPreview? replyTo;
  final String? linkPreviewUrl;
  final String? linkPreviewTitle;
  final String? linkPreviewImageUrl;
  final String? encryptedContent;

  /// Which of the SENDER's devices produced this row (spec §5.4). Null on
  /// pre-migration rows and legacy-client sends, which means device 1.
  ///
  /// Load-bearing on receive: the pairwise session is keyed by the address that
  /// produced the ciphertext, so decrypting an envelope from a peer's device 2
  /// against device 1's session is a Bad MAC.
  final int? originDeviceId;

  /// Why the server served no ciphertext for THIS device (spec §5.3 + §12
  /// amendment (viii)). `none_for_device` = the row predates this device's
  /// link, so render the honest placeholder, never a decrypt failure.
  /// `own_origin` = this device sent it, so no envelope exists for it by
  /// design and the plaintext lives in the local store. Null whenever a
  /// ciphertext WAS served.
  final String? envelopeStatus;

  /// The row's own send token, echoed only to the device that ORIGINATED it
  /// (spec §12 amendment (ix)) — the lost-ack reconcile key, since such a row
  /// carries no ciphertext this device could match on.
  final String? sendToken;

  /// The message's WIRE id (metadata-privacy PR2.1): the sender's `sendToken`
  /// for this send, which names the message independently of the server's
  /// row id. An own row gets it from the server's echo of our token
  /// ([MessageModel.fromJson] — origin device only); every other row gets it
  /// from `E2eEnvelope.msgId` at decrypt, or from the persisted record's
  /// `_wid` stamp. Null for rows sent by a client that predates it. Nothing
  /// reads it yet.
  final String? wireId;

  /// True when the server explicitly said this device has no ciphertext for
  /// this row. Such a row must never enter the decrypt pass.
  bool get hasNoEnvelopeForThisDevice => envelopeStatus != null;

  /// AES-256-GCM key (base64), from E2E envelope — client-only, not from REST.
  final String? mediaKey;

  /// AES-256-GCM IV (base64), from E2E envelope — client-only.
  final String? mediaIv;

  /// Server-stamped time of the last edit; null = never edited. From REST/WS payload.
  final DateTime? editedAt;

  /// True when this row is a SELF-SYNC copy: our own account sent it, but a
  /// DIFFERENT one of our devices produced it (spec §5.4 + §12 amendment (xi)).
  ///
  /// Such a row is an ordinary inbound message — a pairwise session between two
  /// of our own devices, which libsignal supports as a normal address pair —
  /// and it MUST decrypt. The two cases that are NOT self-sync, and must never
  /// be handed to the ratchet, are:
  ///  * `envelopeStatus == 'own_origin'` — the server says THIS device sent it,
  ///    so no envelope exists for us by design and the plaintext is local;
  ///  * `(originDeviceId ?? 1) == ownDeviceId` — the same case in legacy shape,
  ///    where an own row is served its own ciphertext with no marker.
  /// A Signal sender cannot decrypt its own output, so attempting either would
  /// render `[Decryption failed]` over the only plaintext copy we will ever have.
  ///
  /// [ownDeviceId] must be null unless the server has CONFIRMED which device
  /// this is (amendment (xii)); an unconfirmed value defaults to 1 and would
  /// mis-scope a real device 2. Null therefore answers false — the row keeps
  /// today's behaviour and is retried once `socketReady` lands.
  bool isSelfSyncRow(int? currentUserId, int? ownDeviceId) =>
      currentUserId != null &&
      ownDeviceId != null &&
      senderId == currentUserId &&
      envelopeStatus == null &&
      (originDeviceId ?? 1) != ownDeviceId;

  /// True if this message has E2E encrypted content that this device must
  /// decrypt: either another user sent it, or it is a self-sync copy of our own
  /// send produced by another of our devices ([isSelfSyncRow]).
  ///
  /// THE master gate: it feeds every decrypt entry point, live and historical,
  /// so a row it rejects is never decrypted anywhere. Pass [ownDeviceId] only
  /// when the server has confirmed it.
  bool needsDecryption(int? currentUserId, {int? ownDeviceId}) =>
      encryptedContent != null &&
      encryptedContent!.isNotEmpty &&
      (senderId != currentUserId || isSelfSyncRow(currentUserId, ownDeviceId));

  /// True if this message should show "Encrypted message" placeholder in list.
  bool get displayAsEncryptedPlaceholder =>
      encryptedContent != null &&
      encryptedContent!.isNotEmpty &&
      content == '[encrypted]';

  /// True when this is a TEXT message whose [content] is real plaintext —
  /// i.e. safe to offer "Copy" in the context menu. The bracket labels are
  /// the E2E placeholder / terminal states (same literals used by
  /// ChatMessageBubble._displayContent and reply_preview_helper.dart).
  bool get hasCopyablePlaintext =>
      messageType == MessageType.text &&
      content.isNotEmpty &&
      content != '[encrypted]' &&
      content != '[Decryption failed]' &&
      content != '[Encryption not initialized]' &&
      content != '[Message no longer stored on this device]' &&
      content != '[Sent before this device was linked]';

  MessageModel({
    required this.id,
    required this.content,
    required this.senderId,
    required this.senderUsername,
    required this.conversationId,
    required this.createdAt,
    this.deliveryStatus = MessageDeliveryStatus.sent,
    this.expiresAt,
    this.disappearAfterSeconds,
    this.messageType = MessageType.text,
    this.mediaUrl,
    this.mediaDuration,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaThumbHash,
    this.tempId,
    this.reactions = const {},
    this.replyToMessageId,
    this.replyTo,
    this.linkPreviewUrl,
    this.linkPreviewTitle,
    this.linkPreviewImageUrl,
    this.encryptedContent,
    this.envelopeStatus,
    this.originDeviceId,
    this.sendToken,
    this.wireId,
    this.mediaKey,
    this.mediaIv,
    this.editedAt,
  });

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      id: json['id'] as int,
      content: json['content'] as String? ?? '',
      senderId: json['senderId'] as int,
      senderUsername: json['senderUsername'] as String? ?? '',
      conversationId: json['conversationId'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      deliveryStatus: parseDeliveryStatus(json['deliveryStatus'] as String?),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      disappearAfterSeconds: json['disappearAfterSeconds'] != null
          ? (json['disappearAfterSeconds'] as num).toInt()
          : null,
      messageType: _parseMessageType(json['messageType'] as String?),
      mediaUrl: json['mediaUrl'] as String?,
      mediaDuration: json['mediaDuration'] != null
          ? (json['mediaDuration'] as num).round()
          : null,
      tempId: json['tempId'] as String?,
      reactions: _parseReactions(json['reactions']),
      replyToMessageId: json['replyToMessageId'] != null
          ? (json['replyToMessageId'] as num).toInt()
          : null,
      replyTo: json['replyTo'] != null
          ? ReplyToPreview.fromJson(json['replyTo'] as Map<String, dynamic>)
          : null,
      linkPreviewUrl: json['linkPreviewUrl'] as String?,
      linkPreviewTitle: json['linkPreviewTitle'] as String?,
      linkPreviewImageUrl: json['linkPreviewImageUrl'] as String?,
      encryptedContent: json['encryptedContent'] as String?,
      // Additive per-device fields (spec §12 (viii)/(ix)); absent on an older
      // server, and `fromJson` simply reads null.
      envelopeStatus: json['envelopeStatus'] as String?,
      originDeviceId: json['originDeviceId'] as int?,
      sendToken: json['sendToken'] as String?,
      // The server's echo of OUR token is our own wire id for the row; the
      // server never serves a wire id to anyone else, so every other row
      // reads null here and learns it from the envelope at decrypt.
      wireId: json['sendToken'] as String?,
      editedAt: json['editedAt'] != null
          ? DateTime.parse(json['editedAt'] as String)
          : null,
    );
  }

  static Map<String, List<int>> _parseReactions(dynamic raw) {
    if (raw == null || raw is! Map) return {};
    return raw.map(
      (k, v) =>
          MapEntry(k as String, (v as List).map((e) => e as int).toList()),
    );
  }

  // Public method for parsing delivery status from other files
  static MessageDeliveryStatus parseDeliveryStatus(String? status) {
    switch (status?.toUpperCase()) {
      case 'SENDING':
        return MessageDeliveryStatus.sending;
      case 'SENT':
        return MessageDeliveryStatus.sent;
      case 'DELIVERED':
        return MessageDeliveryStatus.delivered;
      case 'READ':
        return MessageDeliveryStatus.read;
      case 'FAILED':
        return MessageDeliveryStatus.failed;
      default:
        return MessageDeliveryStatus.sent;
    }
  }

  static MessageType _parseMessageType(String? type) {
    switch (type?.toUpperCase()) {
      case 'PING':
        return MessageType.ping;
      case 'IMAGE':
        return MessageType.image;
      case 'VOICE':
        return MessageType.voice;
      case 'GIF':
        return MessageType.gif;
      case 'FILE':
        return MessageType.file;
      case 'VIDEO':
        return MessageType.video;
      default:
        return MessageType.text;
    }
  }

  MessageModel copyWith({
    MessageType? messageType,
    String? content,
    MessageDeliveryStatus? deliveryStatus,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    String? mediaUrl,
    int? mediaDuration,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaThumbHash,
    Map<String, List<int>>? reactions,
    int? replyToMessageId,
    ReplyToPreview? replyTo,
    String? linkPreviewUrl,
    String? linkPreviewTitle,
    String? linkPreviewImageUrl,
    String? encryptedContent,
    String? envelopeStatus,
    int? originDeviceId,
    String? sendToken,
    String? wireId,
    String? mediaKey,
    String? mediaIv,
    DateTime? editedAt,
  }) {
    return MessageModel(
      id: id,
      content: content ?? this.content,
      senderId: senderId,
      senderUsername: senderUsername,
      conversationId: conversationId,
      createdAt: createdAt,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      expiresAt: expiresAt ?? this.expiresAt,
      disappearAfterSeconds:
          disappearAfterSeconds ?? this.disappearAfterSeconds,
      messageType: messageType ?? this.messageType,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaDuration: mediaDuration ?? this.mediaDuration,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
      mediaThumbHash: mediaThumbHash ?? this.mediaThumbHash,
      tempId: tempId,
      reactions: reactions ?? this.reactions,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyTo: replyTo ?? this.replyTo,
      linkPreviewUrl: linkPreviewUrl ?? this.linkPreviewUrl,
      linkPreviewTitle: linkPreviewTitle ?? this.linkPreviewTitle,
      linkPreviewImageUrl: linkPreviewImageUrl ?? this.linkPreviewImageUrl,
      encryptedContent: encryptedContent ?? this.encryptedContent,
      // Per-device facts of the row, preserved across every merge: dropping
      // them would resurrect a decrypt attempt on a row that has no ciphertext
      // for this device, or lose the origin device's reconcile key.
      envelopeStatus: envelopeStatus ?? this.envelopeStatus,
      originDeviceId: originDeviceId ?? this.originDeviceId,
      sendToken: sendToken ?? this.sendToken,
      wireId: wireId ?? this.wireId,
      mediaKey: mediaKey ?? this.mediaKey,
      mediaIv: mediaIv ?? this.mediaIv,
      editedAt: editedAt ?? this.editedAt,
    );
  }
}
