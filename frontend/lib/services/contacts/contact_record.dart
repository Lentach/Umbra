import '../../models/user_model.dart';

/// Where a peer stands with this account. Exactly one per record.
enum ContactState { friend, pendingIn, pendingOut, blocked }

/// An inbound queue THIS device owns for the peer (design §4.2): the peer's
/// devices send into it, this device alone can subscribe / ack / delete it.
/// Private halves never leave the device — this record is the only copy.
///
/// Binary fields are base64url, no padding. Frozen: PR2.3/PR2.4 back these
/// bytes up verbatim, so a representation change is a backup-format break.
class ContactQueue {
  const ContactQueue({
    required this.rid,
    required this.sid,
    required this.authPriv,
    required this.sealPriv,
    required this.sealPub,
  });

  factory ContactQueue.fromJson(Map<String, dynamic> j) => ContactQueue(
    rid: j['rid'] as String,
    sid: j['sid'] as String,
    authPriv: j['authPriv'] as String,
    sealPriv: j['sealPriv'] as String,
    sealPub: j['sealPub'] as String,
  );

  final String rid;
  final String sid;
  final String authPriv;
  final String sealPriv;
  final String sealPub;

  Map<String, dynamic> toJson() => {
    'rid': rid,
    'sid': sid,
    'authPriv': authPriv,
    'sealPriv': sealPriv,
    'sealPub': sealPub,
  };
}

/// How to reach ONE of the peer's devices: the send capability for the queue
/// that device created for us, and the key its seal layer expects.
class ContactOutbound {
  const ContactOutbound({
    required this.peerDeviceId,
    required this.sid,
    required this.sealPub,
  });

  factory ContactOutbound.fromJson(Map<String, dynamic> j) => ContactOutbound(
    peerDeviceId: j['peerDeviceId'] as int,
    sid: j['sid'] as String,
    sealPub: j['sealPub'] as String,
  );

  final int peerDeviceId;
  final String sid;
  final String sealPub;

  Map<String, dynamic> toJson() => {
    'peerDeviceId': peerDeviceId,
    'sid': sid,
    'sealPub': sealPub,
  };
}

/// Per-contact settings that used to live only on the server's
/// `conversations` row. Local from now on; the server copy still overwrites
/// while the old path exists.
class ContactSettings {
  const ContactSettings({
    this.disappearingTimer,
    this.muted = false,
    this.mutedUntil,
    this.pinnedMessageId,
  });

  factory ContactSettings.fromJson(Map<String, dynamic> j) => ContactSettings(
    disappearingTimer: j['disappearingTimer'] as int?,
    muted: j['muted'] as bool? ?? false,
    mutedUntil: j['mutedUntil'] == null
        ? null
        : DateTime.parse(j['mutedUntil'] as String),
    pinnedMessageId: j['pinnedMessageId'] as int?,
  );

  /// Seconds; null = off.
  final int? disappearingTimer;
  final bool muted;
  final DateTime? mutedUntil;
  final int? pinnedMessageId;

  Map<String, dynamic> toJson() => {
    if (disappearingTimer != null) 'disappearingTimer': disappearingTimer,
    if (muted) 'muted': true,
    if (mutedUntil != null) 'mutedUntil': mutedUntil!.toIso8601String(),
    if (pinnedMessageId != null) 'pinnedMessageId': pinnedMessageId,
  };

  ContactSettings copyWith({
    int? disappearingTimer,
    bool clearDisappearingTimer = false,
    bool? muted,
    DateTime? mutedUntil,
    bool clearMutedUntil = false,
    int? pinnedMessageId,
    bool clearPinnedMessageId = false,
  }) => ContactSettings(
    disappearingTimer: clearDisappearingTimer
        ? null
        : disappearingTimer ?? this.disappearingTimer,
    muted: muted ?? this.muted,
    mutedUntil: clearMutedUntil ? null : mutedUntil ?? this.mutedUntil,
    pinnedMessageId: clearPinnedMessageId
        ? null
        : pinnedMessageId ?? this.pinnedMessageId,
  );
}

/// Server-side ids the old path still needs to address this contact. Every
/// field goes with Phase 4; kept in one place so the deletion is one line.
class ContactLegacy {
  const ContactLegacy({
    this.conversationId,
    this.conversationCreatedAt,
    this.requestId,
    this.requestCreatedAt,
  });

  factory ContactLegacy.fromJson(Map<String, dynamic> j) => ContactLegacy(
    conversationId: j['conversationId'] as int?,
    conversationCreatedAt: j['conversationCreatedAt'] == null
        ? null
        : DateTime.parse(j['conversationCreatedAt'] as String),
    requestId: j['requestId'] as int?,
    requestCreatedAt: j['requestCreatedAt'] == null
        ? null
        : DateTime.parse(j['requestCreatedAt'] as String),
  );

  final int? conversationId;
  final DateTime? conversationCreatedAt;
  final int? requestId;
  final DateTime? requestCreatedAt;

  Map<String, dynamic> toJson() => {
    if (conversationId != null) 'conversationId': conversationId,
    if (conversationCreatedAt != null)
      'conversationCreatedAt': conversationCreatedAt!.toIso8601String(),
    if (requestId != null) 'requestId': requestId,
    if (requestCreatedAt != null)
      'requestCreatedAt': requestCreatedAt!.toIso8601String(),
  };

  ContactLegacy copyWith({
    int? conversationId,
    bool clearConversation = false,
    DateTime? conversationCreatedAt,
    int? requestId,
    bool clearRequest = false,
    DateTime? requestCreatedAt,
  }) => ContactLegacy(
    conversationId: clearConversation
        ? null
        : conversationId ?? this.conversationId,
    conversationCreatedAt: clearConversation
        ? null
        : conversationCreatedAt ?? this.conversationCreatedAt,
    requestId: clearRequest ? null : requestId ?? this.requestId,
    requestCreatedAt: clearRequest
        ? null
        : requestCreatedAt ?? this.requestCreatedAt,
  );
}

/// One contact, whole: who they are, where we stand, how to reach them, and
/// the queue material only this device holds. ONE record = ONE loss domain —
/// there is no state where a friend is known but unreachable, or reachable
/// but unknown.
///
/// Format `v: 1`. Readers must reject a higher `v` (skip the record, keep the
/// rest) rather than guess.
class ContactRecord {
  const ContactRecord({
    required this.userId,
    required this.username,
    required this.tag,
    required this.state,
    this.avatarUrl,
    this.devices = const [],
    this.outbound = const [],
    this.settings = const ContactSettings(),
    this.queues = const [],
    this.legacy = const ContactLegacy(),
  });

  factory ContactRecord.fromUser(UserModel user, ContactState state) =>
      ContactRecord(
        userId: user.id,
        username: user.username,
        tag: user.tag,
        avatarUrl: user.profilePictureUrl,
        state: state,
      );

  /// Throws [FormatException] on a shape this version cannot read. Callers
  /// treat that as UNDETERMINED for this one record, never as "no contact".
  factory ContactRecord.fromJson(Map<String, dynamic> j) {
    final v = j['v'] as int?;
    if (v == null || v > currentVersion) {
      throw FormatException('contact record v=$v unsupported');
    }
    return ContactRecord(
      userId: j['userId'] as int,
      username: j['username'] as String,
      tag: j['tag'] as String,
      avatarUrl: j['avatarUrl'] as String?,
      state: ContactState.values.byName(j['state'] as String),
      devices: (j['devices'] as List<dynamic>? ?? const [])
          .map((d) => d as int)
          .toList(growable: false),
      outbound: (j['outbound'] as List<dynamic>? ?? const [])
          .map((o) => ContactOutbound.fromJson(o as Map<String, dynamic>))
          .toList(growable: false),
      settings: ContactSettings.fromJson(
        j['settings'] as Map<String, dynamic>? ?? const {},
      ),
      queues: (j['queues'] as List<dynamic>? ?? const [])
          .map((q) => ContactQueue.fromJson(q as Map<String, dynamic>))
          .toList(growable: false),
      legacy: ContactLegacy.fromJson(
        j['legacy'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  static const int currentVersion = 1;

  final int userId;
  final String username;
  final String tag;
  final String? avatarUrl;
  final ContactState state;

  /// The peer's device ids as last learned (design §4.2 announcements will
  /// keep this current; today the server list does).
  final List<int> devices;
  final List<ContactOutbound> outbound;
  final ContactSettings settings;
  final List<ContactQueue> queues;
  final ContactLegacy legacy;

  Map<String, dynamic> toJson() => {
    'v': currentVersion,
    'userId': userId,
    'username': username,
    'tag': tag,
    if (avatarUrl != null) 'avatarUrl': avatarUrl,
    'state': state.name,
    if (devices.isNotEmpty) 'devices': devices,
    if (outbound.isNotEmpty)
      'outbound': outbound.map((o) => o.toJson()).toList(),
    'settings': settings.toJson(),
    if (queues.isNotEmpty) 'queues': queues.map((q) => q.toJson()).toList(),
    'legacy': legacy.toJson(),
  };

  /// The half of this record another device of the same account could hold —
  /// the PR2.4 server backup's unit.
  ///
  /// [queues] is dropped because its private halves are THIS device's alone
  /// and a restored device re-mints them anyway (the identity died with the
  /// same storage); [legacy] because the server re-supplies those ids in the
  /// first list, so a backed-up one could only outlive the row it names.
  Map<String, dynamic> toBackupJson() => toJson()
    ..remove('queues')
    ..remove('legacy');

  UserModel toUser() => UserModel(
    id: userId,
    username: username,
    tag: tag,
    profilePictureUrl: avatarUrl,
  );

  ContactRecord copyWith({
    String? username,
    String? tag,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    ContactState? state,
    List<int>? devices,
    List<ContactOutbound>? outbound,
    ContactSettings? settings,
    List<ContactQueue>? queues,
    ContactLegacy? legacy,
  }) => ContactRecord(
    userId: userId,
    username: username ?? this.username,
    tag: tag ?? this.tag,
    avatarUrl: clearAvatarUrl ? null : avatarUrl ?? this.avatarUrl,
    state: state ?? this.state,
    devices: devices ?? this.devices,
    outbound: outbound ?? this.outbound,
    settings: settings ?? this.settings,
    queues: queues ?? this.queues,
    legacy: legacy ?? this.legacy,
  );

  /// Profile fields from a fresh server [user], everything else kept.
  ContactRecord withProfile(UserModel user) => copyWith(
    username: user.username,
    tag: user.tag,
    avatarUrl: user.profilePictureUrl,
    clearAvatarUrl: user.profilePictureUrl == null,
  );
}
