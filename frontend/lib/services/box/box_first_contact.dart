import 'dart:async';
import 'dart:convert';

import '../../utils/message_ids.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';

/// What the messaging side needs from the box session for a first contact
/// (metadata-privacy slice (f)). `BoxSession` is the one implementation.
abstract interface class BoxFirstContactLink {
  /// The contact records a first contact makes ([BoxFirstContact]).
  BoxFirstContact get firstContact;

  /// This device's inbound queue for [userId] (a `pendingOut` record, E15b),
  /// created, stored and subscribed now — the address our request offers.
  /// Null when the box or the store refused.
  Future<ContactQueue?> firstContactQueue(int userId);

  /// [userId] became a friend over the box: the item-5 handoff pass runs and
  /// covers its devices from the request addresses the record holds (E15d).
  void firstContactFriend(int userId);

  /// A pending request of [userId]'s expired (E15i): this device's queues
  /// for it are deleted from the box, then the record is forgotten.
  Future<void> retireFirstContact(int userId);
}

/// What a first contact's request CLAIMS its sender is, carried outside
/// Signal (`BoxFrame.carriedClaim`): unauthenticated until the accept-time
/// lookup (decision 53).
typedef FirstContactClaim = ({String username, String tag});

/// One device of an account as a search answer serves it: its CLAIMED
/// pre-key [bundle] (wire.md "First contact") and its [request] address,
/// null until that device publishes one (an app that predates the box).
typedef FirstContactDevice = ({
  int deviceId,
  Map<String, dynamic> bundle,
  ContactOutbound? request,
});

/// An account as `searchUsersResult` serves it to a first contact — or as a
/// sibling relays that answer (E15e, [toSiblingJson]): the server's word,
/// so what the old path would trust (the bundle's identity, the list the
/// `authorization` record signs).
class FirstContactPeer {
  const FirstContactPeer({
    required this.userId,
    required this.profile,
    required this.devices,
    this.avatarUrl,
    this.authorization,
  });

  static final RegExp _boxId32 = RegExp(r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$');

  /// Null for an entry naming no device (the server served nothing to
  /// reach, amendment (xlv)) or not shaped as the wire says.
  static FirstContactPeer? fromSearchEntry(Object? json) {
    if (json case {
      'id': final int userId,
      'username': final String username,
      'tag': final String tag,
      'devices': final List<Object?> rawDevices,
    }) {
      final devices = <FirstContactDevice>[];
      for (final raw in rawDevices) {
        if (raw case {
          'deviceId': final int deviceId,
          'bundle': final Map<String, dynamic> bundle,
        } when bundle['identityPublicKey'] is String) {
          final (sid, sealPub) = (raw['requestSid'], raw['sealPub']);
          devices.add((
            deviceId: deviceId,
            bundle: bundle,
            request:
                sid is String &&
                    sealPub is String &&
                    _boxId32.hasMatch(sid) &&
                    _boxId32.hasMatch(sealPub)
                ? ContactOutbound(peerDeviceId: deviceId, sid: sid, sealPub: sealPub)
                : null,
          ));
        }
      }
      if (devices.isEmpty) return null;
      final map = json as Map<String, dynamic>;
      final authorization = map['authorization'];
      final avatar = map['profilePictureUrl'];
      return FirstContactPeer(
        userId: userId,
        profile: (username: username, tag: tag),
        devices: devices,
        avatarUrl: avatar is String ? avatar : null,
        authorization: authorization is Map<String, dynamic>
            ? authorization
            : null,
      );
    }
    return null;
  }

  final int userId;
  final FirstContactClaim profile;
  final String? avatarUrl;
  final List<FirstContactDevice> devices;

  /// The byte-exact `deviceList` record; null for an account never enrolled.
  final Map<String, dynamic>? authorization;

  /// The identity key every device's bundle carries; null when they
  /// disagree (§3: one identity per account — anything else is refused).
  String? get identityKey {
    final keys = {
      for (final d in devices) d.bundle['identityPublicKey'] as String,
    };
    return keys.length == 1 ? keys.single : null;
  }

  /// Every served device has a request address (E15a's peer half).
  bool get allOnBox => devices.every((d) => d.request != null);

  /// The request addresses the served devices published.
  List<ContactOutbound> get addresses => [
    for (final d in devices) ?d.request,
  ];

  /// The answer as a sibling gets it (E15e), in the search entry's own
  /// shape: every bundle WITHOUT its one-time pre-key, which the searcher's
  /// own session already spent — a sibling builds from the signed pre-key.
  Map<String, dynamic> toSiblingJson() => {
    'id': userId,
    'username': profile.username,
    'tag': profile.tag,
    'profilePictureUrl': ?avatarUrl,
    'authorization': authorization,
    'devices': [
      for (final d in devices)
        {
          'deviceId': d.deviceId,
          'bundle': {
            for (final MapEntry(:key, :value) in d.bundle.entries)
              if (key != 'oneTimePreKeyId' && key != 'oneTimePreKeyPublic')
                key: value,
          },
          'requestSid': d.request?.sid,
          'sealPub': d.request?.sealPub,
        },
    ],
  };
}

/// First contact over request queues (metadata-privacy PR3.1 slice (f),
/// owner decisions 52–55, engineering calls E15a–E15k in
/// `docs/plans/2026-09-25-metadata-pr31-remainder.md` § Item 7).
///
/// This half owns the contact records a request makes: a stranger's request
/// is KEPT undecrypted as a `pendingIn` record ([keep], E15c) — libsignal's
/// PreKey decrypt would pin whatever identity key the frame brings, so the
/// frame waits for the accept-time check — capped at [maxKept]; a decline
/// forgets it and tells nobody ([decline], decision 54); a pending request
/// either way ends [lifetime] after it began ([expired] / [forget], E15i).
class BoxFirstContact {
  BoxFirstContact({required ContactStore store, DateTime Function()? now})
    : _store = store,
      _now = now ?? DateTime.now;

  final ContactStore _store;
  final DateTime Function() _now;

  /// The most box requests kept at once: the request queue's own cap, so a
  /// flood evicts the oldest here as it does on the box.
  static const int maxKept = 50;

  /// A pending request ends after the box TTL: the queue it offers retires
  /// then (E15i).
  static const Duration lifetime = Duration(days: 30);

  static const int _maxUsername = 64;
  static const int _maxTag = 16;

  /// The claim in [raw], or null for anything but `{u, g}` with two
  /// non-empty strings in bounds.
  static FirstContactClaim? parseClaim(String? raw) {
    if (raw == null) return null;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json case {
      'u': final String username,
      'g': final String tag,
    } when username.isNotEmpty &&
        username.length <= _maxUsername &&
        tag.isNotEmpty &&
        tag.length <= _maxTag) {
      return (username: username, tag: tag);
    }
    return null;
  }

  /// The claim this account's own request carries.
  static String encodeClaim(FirstContactClaim claim) =>
      jsonEncode({'u': claim.username, 'g': claim.tag});

  static bool _boxRequest(ContactRecord record) =>
      record.state == ContactState.pendingIn &&
      record.boxOrigin != null &&
      record.legacy.requestId == null;

  /// Keeps [userId]'s device [deviceId]'s request [signal] undecrypted
  /// under the [claim] it carries. False — nothing written — for an account
  /// this device already stands with otherwise: a friend, a blocked one,
  /// one we asked (the caller reads that as an accept, E15f), or one whose
  /// request the server carries (the old path's own).
  Future<bool> keep({
    required int userId,
    required int deviceId,
    required String signal,
    required FirstContactClaim claim,
  }) async {
    final at = _now();
    var kept = false;
    final ok = await _store.update(userId, (current) {
      final state = current?.state;
      if (current != null &&
          state != ContactState.former &&
          !_boxRequest(current)) {
        return null;
      }
      final request = KeptRequest(deviceId: deviceId, signal: signal, at: at);
      final origin = current?.boxOrigin;
      final base =
          current ??
          ContactRecord(
            userId: userId,
            username: claim.username,
            tag: claim.tag,
            state: ContactState.pendingIn,
          );
      kept = true;
      return base.copyWith(
        state: ContactState.pendingIn,
        username: claim.username,
        tag: claim.tag,
        boxOrigin: origin != null && state == ContactState.pendingIn
            ? origin.copyWith(
                kept: [
                  for (final k in origin.kept)
                    if (k.deviceId != deviceId) k,
                  request,
                ],
              )
            : ContactBoxOrigin(at: at, kept: [request]),
      );
    });
    if (!ok || !kept) return false;
    await _trim();
    return true;
  }

  /// Drops the oldest box requests beyond [maxKept].
  Future<void> _trim() async {
    final requests = [
      for (final r in _store.all)
        if (_boxRequest(r)) r,
    ];
    if (requests.length <= maxKept) return;
    requests.sort((a, b) => a.boxOrigin!.at.compareTo(b.boxOrigin!.at));
    await forget([
      for (final r in requests.take(requests.length - maxKept)) r.userId,
    ]);
  }

  /// The user declined [userId]'s request: it is forgotten, and nothing is
  /// sent anywhere (decision 54). False for a request the server carries.
  Future<bool> decline(int userId) async {
    final record = _store.byUserId(userId);
    if (record == null || !_boxRequest(record)) return false;
    await forget([userId]);
    return true;
  }

  /// The pending box requests, either way, that began more than [lifetime]
  /// ago.
  Future<List<int>> expired() async {
    await _store.settled;
    final cutoff = _now().subtract(lifetime);
    return [
      for (final r in _store.all)
        if ((r.state == ContactState.pendingIn ||
                r.state == ContactState.pendingOut) &&
            r.boxOrigin != null &&
            r.legacy.requestId == null &&
            r.boxOrigin!.at.isBefore(cutoff))
          r.userId,
    ];
  }

  /// Removes the records of [userIds] still pending over the box; anything
  /// else a record became meanwhile is left alone. Decided on disk state
  /// inside the store's lock (a sweep: `reconcile`'s mutate never erases).
  Future<void> forget(Iterable<int> userIds) {
    final ids = userIds.toSet();
    if (ids.isEmpty) return Future.value();
    return _store.reconcile(
      const [],
      (_, current) => current,
      sweep: (record) =>
          ids.contains(record.userId) && _pendingOverBox(record)
          ? null
          : record,
    );
  }

  static bool _pendingOverBox(ContactRecord record) =>
      (record.state == ContactState.pendingIn ||
          record.state == ContactState.pendingOut) &&
      record.boxOrigin != null &&
      record.legacy.requestId == null;

  /// This account asked [userId] over the box (E15b) — or a sibling did and
  /// said so (E15e): a `pendingOut` record under [profile], holding the
  /// peer devices' request [addresses] from the search answer. False for a
  /// friend, a blocked account, and a request the server carries.
  Future<bool> asked({
    required int userId,
    required FirstContactClaim profile,
    required List<ContactOutbound> addresses,
  }) async {
    var asked = false;
    final ok = await _store.update(userId, (current) {
      final state = current?.state;
      if (current != null &&
          state != ContactState.former &&
          !(state == ContactState.pendingOut &&
              current.boxOrigin != null &&
              current.legacy.requestId == null)) {
        return null;
      }
      asked = true;
      final base =
          current ??
          ContactRecord(
            userId: userId,
            username: profile.username,
            tag: profile.tag,
            state: ContactState.pendingOut,
          );
      return base.copyWith(
        state: ContactState.pendingOut,
        username: profile.username,
        tag: profile.tag,
        boxOrigin: ContactBoxOrigin(
          at: state == ContactState.pendingOut ? current!.boxOrigin!.at : _now(),
          addresses: addresses,
        ),
      );
    });
    return ok && asked;
  }

  /// [userId]'s pending box request — either way — became a friendship
  /// (E15d, E15e, E15f): `friend` under its local chat id (decision 52),
  /// with the VERIFIED [profile] and [avatarUrl] when the accept looked it
  /// up, and the peer's request [addresses] when known; the kept frames go.
  /// False for anything that is not a pending box request.
  Future<bool> befriend(
    int userId, {
    FirstContactClaim? profile,
    String? avatarUrl,
    List<ContactOutbound>? addresses,
  }) async {
    var befriended = false;
    final ok = await _store.update(userId, (current) {
      final origin = current?.boxOrigin;
      if (current == null || origin == null || !_pendingOverBox(current)) {
        return null;
      }
      befriended = true;
      return current.copyWith(
        state: ContactState.friend,
        username: profile?.username,
        tag: profile?.tag,
        avatarUrl: avatarUrl,
        legacy: current.legacy.copyWith(
          conversationId: localConversationIdFor(userId),
          conversationCreatedAt: _now(),
        ),
        boxOrigin: ContactBoxOrigin(
          at: origin.at,
          addresses: addresses ?? origin.addresses,
        ),
      );
    });
    return ok && befriended;
  }
}
