import '../../models/user_model.dart';

/// Where a peer stands with this account. Exactly one per record.
///
/// [former]: a server list stopped naming the peer, but the record holds
/// queue material no server can re-supply ([ContactRecord.queues] private
/// halves, [ContactRecord.outbound] send addresses). Absence from a list is
/// INFERRED, not an event, so the record is kept, hidden from every list, and
/// becomes whatever the next list names it again. A build older than
/// metadata-privacy PR1.2 cannot read this state: it counts the row
/// undetermined (and its contact backup then refuses to upload).
enum ContactState { friend, pendingIn, pendingOut, blocked, former }

/// An inbound queue THIS device owns for the peer (design §4.2): the peer's
/// devices send into it, this device alone can subscribe / ack / delete it.
/// Private halves never leave the device — this record is the only copy.
///
/// Binary fields are base64url, no padding: [rid]/[sid] 32 B and [nid] 16 B
/// as the box answered `createQueue`; [authPriv] the Ed25519 key as
/// seed(32) ‖ public(32) (`BoxAuthKey.bytes`); [sealPriv]/[sealPub] raw
/// 32-byte X25519 halves (`QueueSealKeyPair`). Frozen: PR2.3 backs these
/// bytes up verbatim, so a representation change is a backup-format break.
class ContactQueue {
  const ContactQueue({
    required this.rid,
    required this.sid,
    required this.nid,
    required this.authPriv,
    required this.sealPriv,
    required this.sealPub,
    this.ackedBy = const [],
    this.handedAt = const {},
    this.retiredAt,
  });

  factory ContactQueue.fromJson(Map<String, dynamic> j) => ContactQueue(
    rid: j['rid'] as String,
    sid: j['sid'] as String,
    nid: j['nid'] as String,
    authPriv: j['authPriv'] as String,
    sealPriv: j['sealPriv'] as String,
    sealPub: j['sealPub'] as String,
    ackedBy: [
      for (final d in j['ackedBy'] as List<dynamic>? ?? const [])
        if (d is int) d,
    ],
    handedAt: {
      for (final MapEntry(:key, :value)
          in (j['handedAt'] as Map<String, dynamic>? ?? const {}).entries)
        if (int.tryParse(key) case final int device when value is int)
          device: DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
    },
    retiredAt: j['retiredAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(
            j['retiredAt'] as int,
            isUtc: true,
          )
        : null,
  );

  final String rid;
  final String sid;
  final String nid;
  final String authPriv;
  final String sealPriv;
  final String sealPub;

  /// The peer's device ids that acknowledged this queue's handoff (item 5,
  /// E20e): the migration hands it again ([handedAt] paces that) to every live
  /// device of the peer NOT named here. Additive to the frozen shape above:
  /// a build that predates it drops the key on its next write, which only
  /// costs one more handoff.
  final List<int> ackedBy;

  /// When this queue was last handed to each of the peer's devices that has
  /// not acknowledged it (item 5, review): a handoff to a device that never
  /// answers is sent again only after `kFriendHandoffResend`, since every
  /// one is a blob left in that device's queue. Additive, like [ackedBy].
  final Map<int, DateTime> handedAt;

  /// When this queue stopped being the one handed out, because the peer
  /// revoked a device that held it (slice (e), E50e): a newer queue leads
  /// [ContactRecord.queues], and this one stays subscribed and read until
  /// the box TTL has passed, then is deleted. Null for the current queue.
  /// Additive, like [ackedBy].
  final DateTime? retiredAt;

  /// This queue, retired at [at] (E50e).
  ContactQueue retired(DateTime at) => ContactQueue(
    rid: rid,
    sid: sid,
    nid: nid,
    authPriv: authPriv,
    sealPriv: sealPriv,
    sealPub: sealPub,
    ackedBy: ackedBy,
    handedAt: handedAt,
    retiredAt: at,
  );

  /// This queue, acknowledged by the peer's [deviceId] as well.
  ContactQueue withAck(int deviceId) => ackedBy.contains(deviceId)
      ? this
      : _with(ackedBy: [...ackedBy, deviceId]);

  /// This queue, handed to the peer's [deviceId] at [at].
  ContactQueue withHanded(int deviceId, DateTime at) =>
      _with(handedAt: {...handedAt, deviceId: at});

  /// This queue, its last handoff to the peer's [deviceId] forgotten: that
  /// device is heard from, so the day between handoffs no longer applies.
  ContactQueue withoutHanded(int deviceId) => handedAt.containsKey(deviceId)
      ? _with(handedAt: {...handedAt}..remove(deviceId))
      : this;

  ContactQueue _with({List<int>? ackedBy, Map<int, DateTime>? handedAt}) =>
      ContactQueue(
        rid: rid,
        sid: sid,
        nid: nid,
        authPriv: authPriv,
        sealPriv: sealPriv,
        sealPub: sealPub,
        ackedBy: ackedBy ?? this.ackedBy,
        handedAt: handedAt ?? this.handedAt,
        retiredAt: retiredAt,
      );

  Map<String, dynamic> toJson() => {
    'rid': rid,
    'sid': sid,
    'nid': nid,
    'authPriv': authPriv,
    'sealPriv': sealPriv,
    'sealPub': sealPub,
    if (ackedBy.isNotEmpty) 'ackedBy': ackedBy,
    if (handedAt.isNotEmpty)
      'handedAt': {
        for (final MapEntry(:key, :value) in handedAt.entries)
          '$key': value.millisecondsSinceEpoch,
      },
    if (retiredAt != null) 'retiredAt': retiredAt!.millisecondsSinceEpoch,
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

/// A first contact's request THIS device holds undecrypted until the
/// accept-time check (metadata-privacy slice (f), E15c): libsignal's PreKey
/// decrypt would pin whatever identity key the frame brings, so its bytes
/// wait here. [signal] is `"{type}:{base64}"`, readable by this device alone
/// (the requester sealed one per device), so no backup carries it.
class KeptRequest {
  const KeptRequest({
    required this.deviceId,
    required this.signal,
    required this.at,
    this.localId,
    this.claim,
  });

  /// Null for a shape this build cannot read: the request is then absent.
  static KeptRequest? fromJson(Object? raw) => switch (raw) {
    {
      'dev': final int deviceId,
      'sig': final String signal,
      'at': final int at,
    } =>
      KeptRequest(
        deviceId: deviceId,
        signal: signal,
        at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
        localId: (raw as Map)['lid'] as int?,
        claim: switch (raw) {
          {'u': final String username, 'g': final String tag} => (
            username: username,
            tag: tag,
          ),
          _ => null,
        },
      ),
    _ => null,
  };

  /// The requesting device.
  final int deviceId;
  final String signal;

  /// When this device took the frame in.
  final DateTime at;

  /// The local id its delivery was journaled under: the key its decrypt's
  /// plaintext is replayed under, so an accept that fails after the
  /// decrypt reads it again instead of a spent ratchet (review).
  final int? localId;

  /// The handle this frame claims, unauthenticated like the frame: a
  /// later frame never renames the record, so the accept looks each
  /// distinct claim up until one answer names the account (review).
  final ({String username, String tag})? claim;

  Map<String, dynamic> toJson() => {
    'dev': deviceId,
    'sig': signal,
    'at': at.millisecondsSinceEpoch,
    'lid': ?localId,
    if (claim case final c?) ...{'u': c.username, 'g': c.tag},
  };
}

/// How a friendship made over the box began (metadata-privacy slice (f),
/// decisions 52–55): its presence is what marks the record as one the server
/// knows nothing of — its chat is `localConversationIdFor(userId)`, and no
/// server list may sweep it (E15g).
///
/// [at]: when the request was sent or first received; a pending one ends 30 d
/// later (E15i). [addresses]: each peer device's REQUEST queue from the
/// search answer ([ContactOutbound.sid] is the request sid) — where the
/// handoff pass reaches a device no queue handoff came from yet, since the
/// server's friends list never names this peer. [kept]: requests held
/// undecrypted on the receiving device ([KeptRequest]). [bundles]: each peer
/// device's pre-key bundle as a search answer served it, WITHOUT its
/// one-time pre-key — what a session with that device is built from, since
/// a bundle fetch would name the pair to the server (E15b/E15e).
class ContactBoxOrigin {
  const ContactBoxOrigin({
    required this.at,
    this.addresses = const [],
    this.kept = const [],
    this.bundles = const {},
  });

  /// Null for a shape this build cannot read.
  static ContactBoxOrigin? fromJson(Object? raw) {
    if (raw case {'at': final int at}) {
      final json = raw as Map<String, dynamic>;
      return ContactBoxOrigin(
        at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
        addresses: [
          for (final a in json['addr'] as List<dynamic>? ?? const [])
            ContactOutbound.fromJson(a as Map<String, dynamic>),
        ],
        kept: [
          for (final k in json['kept'] as List<dynamic>? ?? const [])
            ?KeptRequest.fromJson(k),
        ],
        bundles: {
          if (json['bundles'] case final Map<String, dynamic> bundles)
            for (final MapEntry(:key, :value) in bundles.entries)
              if ((int.tryParse(key), value) case (
                final int deviceId,
                final Map<String, dynamic> bundle,
              ))
                deviceId: bundle,
        },
      );
    }
    return null;
  }

  static const String keptKey = 'kept';

  final DateTime at;
  final List<ContactOutbound> addresses;
  final List<KeptRequest> kept;
  final Map<int, Map<String, dynamic>> bundles;

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    if (addresses.isNotEmpty) 'addr': [for (final a in addresses) a.toJson()],
    if (kept.isNotEmpty) keptKey: [for (final k in kept) k.toJson()],
    if (bundles.isNotEmpty)
      'bundles': {
        for (final MapEntry(:key, :value) in bundles.entries) '$key': value,
      },
  };

  ContactBoxOrigin copyWith({
    List<ContactOutbound>? addresses,
    List<KeptRequest>? kept,
    Map<int, Map<String, dynamic>>? bundles,
  }) => ContactBoxOrigin(
    at: at,
    addresses: addresses ?? this.addresses,
    kept: kept ?? this.kept,
    bundles: bundles ?? this.bundles,
  );
}

/// The chat's E2E pin (metadata-privacy item 4, decision 45, E19f): ONE
/// last-writer-wins register — the pinned message as its sender and wire id
/// (`(s, w)` names the same box message on every device), or none, written
/// at [at], the action's clamped send time. A pin and an unpin travel from
/// the peer's queue and from a sibling's self-queue with no order between
/// the two, so [supersedes] is a total order every device applies alike.
class BoxPin {
  const BoxPin({required this.at, this.senderId, this.wireId});

  /// Null for a shape this build cannot read: the register is then empty.
  static BoxPin? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final ts = raw['ts'];
    final s = raw['s'];
    final w = raw['w'];
    if (ts is! int || (s == null) != (w == null)) return null;
    if (s != null && (s is! int || w is! String)) return null;
    return BoxPin(
      at: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      senderId: s as int?,
      wireId: w as String?,
    );
  }

  final DateTime at;
  final int? senderId;
  final String? wireId;

  bool get pinned => senderId != null && wireId != null;

  /// The pinned message, or null when unpinned.
  ({int senderId, String wireId})? get wire =>
      pinned ? (senderId: senderId!, wireId: wireId!) : null;

  bool names(({int senderId, String wireId}) message) => wire == message;

  /// Whether this write replaces [current]: a newer [at] wins; on a tie an
  /// unpin beats a pin, then the greater `s:w` wins; an equal write changes
  /// nothing.
  bool supersedes(BoxPin? current) {
    if (current == null) return true;
    final byTime = at.compareTo(current.at);
    if (byTime != 0) return byTime > 0;
    if (pinned != current.pinned) return !pinned;
    if (!pinned) return false;
    return '$senderId:$wireId'.compareTo(
          '${current.senderId}:${current.wireId}',
        ) >
        0;
  }

  Map<String, dynamic> toJson() => {
    's': ?senderId,
    'w': ?wireId,
    'ts': at.millisecondsSinceEpoch,
  };
}

/// Per-contact settings that used to live only on the server's
/// `conversations` row. Local from now on; the server copy still overwrites
/// while the old path exists. [boxPin] is the exception: it is E2E and only
/// the devices write it (item 4).
class ContactSettings {
  const ContactSettings({
    this.disappearingTimer,
    this.muted = false,
    this.mutedUntil,
    this.pinnedMessageId,
    this.boxPin,
    this.timerAt,
    this.chatHidden = false,
  });

  factory ContactSettings.fromJson(Map<String, dynamic> j) => ContactSettings(
    disappearingTimer: j['disappearingTimer'] as int?,
    muted: j['muted'] as bool? ?? false,
    mutedUntil: j['mutedUntil'] == null
        ? null
        : DateTime.parse(j['mutedUntil'] as String),
    pinnedMessageId: j['pinnedMessageId'] as int?,
    boxPin: BoxPin.fromJson(j[boxPinKey]),
    timerAt: switch (j['timerAt']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      _ => null,
    },
    chatHidden: j['chatHidden'] as bool? ?? false,
  );

  /// Seconds; null = off.
  final int? disappearingTimer;
  final bool muted;
  final DateTime? mutedUntil;
  final int? pinnedMessageId;

  /// The chat's E2E pin register ([BoxPin]); null = never written.
  final BoxPin? boxPin;

  /// When [disappearingTimer] was last set, for a chat made over the box
  /// only (slice (f), E15k): the setting travels between the devices, and
  /// the latest write wins, as the E2E pin does. Null: never set over the
  /// box.
  final DateTime? timerAt;

  /// A chat made over the box that the user deleted on this device (slice
  /// (f), decision 52): its history went, and the row stays out of the
  /// list until its next message or the user opens it again. A server
  /// chat's delete is the server's.
  final bool chatHidden;

  /// Its key: [ContactRecord.toBackupJson] drops it (E19f).
  static const String boxPinKey = 'boxPin';

  Map<String, dynamic> toJson() => {
    if (disappearingTimer != null) 'disappearingTimer': disappearingTimer,
    if (muted) 'muted': true,
    if (mutedUntil != null) 'mutedUntil': mutedUntil!.toIso8601String(),
    if (pinnedMessageId != null) 'pinnedMessageId': pinnedMessageId,
    if (boxPin != null) boxPinKey: boxPin!.toJson(),
    if (timerAt != null) 'timerAt': timerAt!.millisecondsSinceEpoch,
    if (chatHidden) 'chatHidden': true,
  };

  ContactSettings copyWith({
    int? disappearingTimer,
    bool clearDisappearingTimer = false,
    bool? muted,
    DateTime? mutedUntil,
    bool clearMutedUntil = false,
    int? pinnedMessageId,
    bool clearPinnedMessageId = false,
    BoxPin? boxPin,
    DateTime? timerAt,
    bool? chatHidden,
  }) => ContactSettings(
    disappearingTimer: clearDisappearingTimer
        ? null
        : disappearingTimer ?? this.disappearingTimer,
    muted: muted ?? this.muted,
    mutedUntil: clearMutedUntil ? null : mutedUntil ?? this.mutedUntil,
    pinnedMessageId: clearPinnedMessageId
        ? null
        : pinnedMessageId ?? this.pinnedMessageId,
    boxPin: boxPin ?? this.boxPin,
    timerAt: timerAt ?? this.timerAt,
    chatHidden: chatHidden ?? this.chatHidden,
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
    this.boxOrigin,
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
      boxOrigin: ContactBoxOrigin.fromJson(j['box']),
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

  /// Set when the friendship was made over the box (slice (f)); null for
  /// every friendship the server knows of.
  final ContactBoxOrigin? boxOrigin;

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
    if (boxOrigin != null) 'box': boxOrigin!.toJson(),
  };

  /// The half of this record another device of the same account could hold —
  /// the PR2.4 server backup's unit.
  ///
  /// [queues] is dropped because its private halves are THIS device's alone
  /// and a restored device re-mints them anyway (the identity died with the
  /// same storage); [legacy] because the server re-supplies those ids in the
  /// first list, so a backed-up one could only outlive the row it names.
  /// The E2E pin ([ContactSettings.boxPin]) is dropped too: a pin would move
  /// the backup's `rev`/`updatedAt` — a per-pin activity clock on the
  /// server (item 4, E19f).
  /// The kept requests of a friendship made over the box go too: their
  /// Signal bytes are this device's alone (E15c).
  Map<String, dynamic> toBackupJson() {
    final json = toJson()
      ..remove('queues')
      ..remove('legacy')
      ..['settings'] = (settings.toJson()..remove(ContactSettings.boxPinKey));
    if (boxOrigin case final origin?) {
      json['box'] = origin.toJson()..remove(ContactBoxOrigin.keptKey);
    }
    return json;
  }

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
    ContactBoxOrigin? boxOrigin,
    bool clearBoxOrigin = false,
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
    boxOrigin: clearBoxOrigin ? null : boxOrigin ?? this.boxOrigin,
  );

  /// Profile fields from a fresh server [user], everything else kept.
  ContactRecord withProfile(UserModel user) => copyWith(
    username: user.username,
    tag: user.tag,
    avatarUrl: user.profilePictureUrl,
    clearAvatarUrl: user.profilePictureUrl == null,
  );
}
