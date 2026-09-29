import 'dart:async';
import 'dart:convert';

import '../../utils/e2e_envelope.dart';
import '../../utils/message_ids.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_friends.dart';

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

  /// The accept of [userId]'s request from its [deviceId] (E15d): the queue
  /// its request offered is stored as that device's address, acked, and
  /// ours handed into it with our [profile] (decision 55) — the item-5
  /// handoff's store → ack → hand-back, on a record already `friend`.
  Future<FriendWrite> acceptFirstContact(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
    required E2eProfile profile,
  });

  /// A pending request of [userId]'s expired (E15i): this device's queues
  /// for it are deleted from the box, then the record is forgotten — kept
  /// when a queue could not be deleted now, so the next run tries again.
  Future<void> retireFirstContact(int userId);

  /// The end of a friendship made over the box (E15j): every queue this
  /// device holds for [userId] is deleted from the box (best effort: one the
  /// box does not answer is left to its reaper), then the record goes — or,
  /// for a [block], stays as `blocked`, so the box drops its frames.
  Future<void> endBoxFriendship(int userId, {required bool block});
}

/// How a friend request sent from a search answer went (E15a): over the box,
/// or — some device on either side is not on the box — back to the old
/// path, which the caller then takes as today; [failed]: the box could not
/// take every frame, and nothing is sent the old way (a request never goes
/// out on both paths).
enum FirstContactSend { sent, oldPath, failed }

/// How accepting a box request went (E15d, decision 53): [unverified] — the
/// accept-time lookup did not vouch for the key the request carries, so it
/// was dropped unaccepted; [failed] — nothing could be decided now (no
/// answer, the box or E2E not ready), and the request stays.
enum FirstContactAccept { accepted, unverified, failed }

/// What a first contact's request CLAIMS its sender is, carried outside
/// Signal (`BoxFrame.carriedClaim`): unauthenticated until the accept-time
/// lookup (decision 53).
typedef FirstContactClaim = ({String username, String tag});

/// One device of an account as a search answer serves it: its CLAIMED
/// pre-key `bundle` (wire.md "First contact") and its `request` address,
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

  static final RegExp _boxId32 = RegExp(
    r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$',
  );

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
                ? ContactOutbound(
                    peerDeviceId: deviceId,
                    sid: sid,
                    sealPub: sealPub,
                  )
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

  /// Every served device's bundle WITHOUT its one-time pre-key, by device:
  /// what the contact record keeps to build a session later with no bundle
  /// fetch ([ContactBoxOrigin.bundles]). The searcher's own first session
  /// spends the one-time pre-key; any later one builds from the signed
  /// pre-key.
  Map<int, Map<String, dynamic>> get servedBundles => {
    for (final d in devices)
      d.deviceId: {
        for (final MapEntry(:key, :value) in d.bundle.entries)
          if (key != 'oneTimePreKeyId' && key != 'oneTimePreKeyPublic')
            key: value,
      },
  };

  /// The answer as a sibling gets it (E15e), in the search entry's own
  /// shape: every bundle as [servedBundles] keeps it.
  Map<String, dynamic> toSiblingJson() {
    final bundles = servedBundles;
    return {
      'id': userId,
      'username': profile.username,
      'tag': profile.tag,
      'profilePictureUrl': ?avatarUrl,
      'authorization': authorization,
      'devices': [
        for (final d in devices)
          {
            'deviceId': d.deviceId,
            'bundle': bundles[d.deviceId],
            'requestSid': d.request?.sid,
            'sealPub': d.request?.sealPub,
          },
      ],
    };
  }
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

  /// [userId]'s record as the store holds it now.
  ContactRecord? contactOf(int userId) => _store.byUserId(userId);

  /// This account's own profile as a request and an accept carry it
  /// (decision 55): the store's self row, seeded from the auth profile.
  /// Null before the store knows it.
  E2eProfile? get ownProfile {
    final self = _store.self;
    return self == null
        ? null
        : (
            username: self.username,
            tag: self.tag,
            avatarUrl: self.profilePictureUrl,
          );
  }

  /// A fresh search answer for [peer], a friendship or request made over
  /// the box (the list lookup of E15h): its devices' request addresses and
  /// served bundles replace the held ones, so a later session builds from
  /// the newest signed pre-key. Anything else a record is, is left alone.
  Future<bool> refreshServed(FirstContactPeer peer) => _store.update(
    peer.userId,
    (current) {
      final origin = current?.boxOrigin;
      if (current == null || origin == null) return null;
      return current.copyWith(
        boxOrigin: origin.copyWith(
          addresses: peer.addresses,
          bundles: peer.servedBundles,
        ),
      );
    },
  );

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
    if (json
        case {
          'u': final String username,
          'g': final String tag,
        }
        when username.isNotEmpty &&
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

  /// The most frames kept per requesting device: a re-sent request joins
  /// the earlier one, and a forged frame naming the account never REPLACES
  /// the real one (review), while a flood from one "device" stays bounded.
  static const int maxFramesPerDevice = 3;

  /// The most frames one request keeps, whichever devices they claim (the
  /// device id is an unauthenticated header, 1..100): the newest stay, as a
  /// device's own do. Forged frames may crowd a real one out (decision 57);
  /// they may not fill this device's storage (G5, BOX-KEPT-STORAGE).
  static const int maxFramesPerRequest = 6;

  /// The most Signal bytes one kept frame may carry. A real request — a
  /// PreKey message around the largest profile a request can hold — is
  /// about 800 B (measured on real Signal, G5); a larger frame is no
  /// request of ours and is not kept.
  static const int maxKeptSignalBytes = 4096;

  /// The Signal bytes every kept request together may hold; past it the
  /// oldest requests go, as past [maxKept].
  static const int maxKeptBytes = 256 * 1024;

  /// Keeps [userId]'s device [deviceId]'s request [signal] undecrypted
  /// under the [claim] it carries, with the journal's [localId] as the id
  /// its later decrypt is replayed under (an accept that fails after the
  /// decrypt reads the same plaintext again, never a spent ratchet). The
  /// frame and its claim are unauthenticated: a record that exists keeps
  /// its name and its frames, and the new one joins them — the newest
  /// [maxFramesPerDevice] of a device, [maxFramesPerRequest] of the request.
  /// False — nothing written — for a frame of more than
  /// [maxKeptSignalBytes], and for an account this device already stands
  /// with otherwise (E15c): a friend, a blocked one, one we asked (the
  /// caller reads that as an accept, E15f), one whose request the server
  /// carries, and a `former` contact — its queues are material no server
  /// can re-supply, and an unauthenticated frame must never be able to make
  /// it a request someone then declines or lets expire.
  Future<bool> keep({
    required int userId,
    required int deviceId,
    required String signal,
    required FirstContactClaim claim,
    int? localId,
  }) async {
    if (_signalBytes(signal) > maxKeptSignalBytes) return false;
    final at = _now();
    var kept = false;
    final ok = await _store.update(userId, (current) {
      final state = current?.state;
      // A request we sent that is no longer shown (decision 54: it expired
      // on our side) is not an ask any more: their request is a new one,
      // and the record keeps the old request's queues so they can still
      // be deleted (review of the 60-d sent lifetime).
      final lapsedAsk =
          current != null &&
          _pendingOverBox(current) &&
          state == ContactState.pendingOut &&
          !shownPending(current, at);
      if (current != null && !_boxRequest(current) && !lapsedAsk) return null;
      final request = KeptRequest(
        deviceId: deviceId,
        signal: signal,
        at: at,
        localId: localId,
        claim: claim,
      );
      final origin = current?.boxOrigin;
      kept = true;
      if (current != null &&
          origin != null &&
          state == ContactState.pendingIn) {
        if (origin.kept.any((k) => k.signal == signal)) return null;
        final own = origin.kept.where((k) => k.deviceId == deviceId).length;
        var drop = own + 1 - maxFramesPerDevice;
        final joined = [
          for (final k in origin.kept)
            if (k.deviceId != deviceId || drop-- <= 0) k,
          request,
        ];
        final excess = joined.length - maxFramesPerRequest;
        return current.copyWith(
          boxOrigin: origin.copyWith(
            kept: excess > 0 ? joined.sublist(excess) : joined,
          ),
        );
      }
      // A new request — or theirs after ours lapsed, which keeps the name
      // our own search verified.
      return (current ??
              ContactRecord(
                userId: userId,
                username: claim.username,
                tag: claim.tag,
                state: ContactState.pendingIn,
              ))
          .copyWith(
            state: ContactState.pendingIn,
            boxOrigin: ContactBoxOrigin(at: at, kept: [request]),
          );
    });
    if (!ok || !kept) return false;
    await _trim();
    return true;
  }

  /// Drops the oldest box requests beyond [maxKept], and beyond
  /// [maxKeptBytes] of kept Signal bytes.
  Future<void> _trim() async {
    int bytesOf(ContactRecord r) =>
        r.boxOrigin!.kept.fold(0, (sum, k) => sum + _signalBytes(k.signal));
    final requests = [
      for (final r in _store.all)
        if (_boxRequest(r)) r,
    ]..sort((a, b) => a.boxOrigin!.at.compareTo(b.boxOrigin!.at));
    var count = requests.length;
    var bytes = requests.fold(0, (sum, r) => sum + bytesOf(r));
    final evicted = <int>[];
    for (final r in requests) {
      if (count <= maxKept && bytes <= maxKeptBytes) break;
      evicted.add(r.userId);
      count--;
      bytes -= bytesOf(r);
    }
    if (evicted.isNotEmpty) await drop(evicted);
  }

  /// The Signal bytes of a `"{type}:{base64}"` frame, from its length.
  static int _signalBytes(String signal) {
    final chars = signal.length - signal.indexOf(':') - 1;
    final padding = signal.endsWith('==')
        ? 2
        : signal.endsWith('=')
        ? 1
        : 0;
    return chars * 3 ~/ 4 - padding;
  }

  /// The user declined [userId]'s request: it goes, and nothing is sent
  /// anywhere (decision 54). False for a request the server carries.
  Future<bool> decline(int userId) async {
    final record = _store.byUserId(userId);
    if (record == null || !_boxRequest(record)) return false;
    await drop([userId]);
    return true;
  }

  /// An accept looked [claim] up and the answer did not vouch for it: the
  /// frames under that claim go (a frame with none is under the record's
  /// name). True when the request stays — other frames claim another name,
  /// which the record now shows, for another accept; false when nothing of
  /// it is left to keep (the caller then drops the request).
  Future<bool> dropClaim(int userId, FirstContactClaim claim) async {
    var remains = false;
    await _store.update(userId, (current) {
      final origin = current?.boxOrigin;
      if (current == null || origin == null || !_boxRequest(current)) {
        return null;
      }
      final shown = (username: current.username, tag: current.tag);
      final left = [
        for (final k in origin.kept)
          if ((k.claim ?? shown) != claim) k,
      ];
      final next = left.firstOrNull?.claim;
      if (next == null) return null;
      remains = true;
      return current.copyWith(
        username: next.username,
        tag: next.tag,
        boxOrigin: origin.copyWith(kept: left),
      );
    });
    return remains;
  }

  /// Ends the box requests of [userIds], either way. A record still holding
  /// a queue of ours — our request's, or our earlier one that lapsed into
  /// theirs — is not forgotten: it holds the only copy of that queue's auth
  /// key. It turns `former` instead, hidden from every list and refusing
  /// new frames, until the box confirmed the queue deleted ([expired] lists
  /// it at once).
  Future<void> drop(Iterable<int> userIds) async {
    final ids = userIds.toSet();
    await _store.reconcile(
      const [],
      (_, current) => current,
      sweep: (record) {
        if (!ids.contains(record.userId) || !_pendingOverBox(record)) {
          return record;
        }
        if (record.queues.isEmpty) return null;
        return record.copyWith(
          state: ContactState.former,
          boxOrigin: ContactBoxOrigin(at: record.boxOrigin!.at),
        );
      },
    );
  }

  /// A request THIS device SENT stays until an accept sent on its last day
  /// could still be read: [lifetime] plus the box TTL, so the queue it
  /// offered is never deleted under an accept in flight (E15i, review;
  /// traps: never delete a queue anyone may still send into). The requests
  /// screen stops showing it after [lifetime] ([shownPending]).
  static const Duration sentLifetime = Duration(days: 60);

  /// Whether [record], a pending box request, is still shown to the user
  /// at [now]: until [lifetime] after it began (decision 54).
  static bool shownPending(ContactRecord record, DateTime now) {
    final at = record.boxOrigin?.at;
    return at != null && !now.isAfter(at.add(lifetime));
  }

  /// The box records whose queues are due for deletion: a pending request
  /// received more than [lifetime] ago, one sent more than [sentLifetime]
  /// ago, and a dropped one still holding a queue ([drop]).
  Future<List<int>> expired() async {
    await _store.settled;
    final now = _now();
    return [
      for (final r in _store.all)
        if (_droppedHolding(r) ||
            _pendingOverBox(r) &&
                r.boxOrigin!.at.isBefore(
                  now.subtract(
                    r.state == ContactState.pendingOut
                        ? sentLifetime
                        : lifetime,
                  ),
                ))
          r.userId,
    ];
  }

  /// Removes the records of [userIds] still pending over the box, or
  /// dropped ([drop]), that hold no queue of ours any more — a record is
  /// the only holder of its queues' auth keys, so one still holding a
  /// queue stays for the next retire; anything else a record became
  /// meanwhile is left alone. Decided on disk state inside the store's
  /// lock (a sweep: `reconcile`'s mutate never erases).
  Future<void> forget(Iterable<int> userIds) {
    final ids = userIds.toSet();
    if (ids.isEmpty) return Future.value();
    return _store.reconcile(
      const [],
      (_, current) => current,
      sweep: (record) =>
          ids.contains(record.userId) &&
              record.queues.isEmpty &&
              (_pendingOverBox(record) || _dropped(record))
          ? null
          : record,
    );
  }

  static bool _dropped(ContactRecord record) =>
      record.state == ContactState.former && record.boxOrigin != null;

  /// A dropped request or an ended box friendship (former or blocked) still
  /// holding a queue the box did not confirm deleted.
  static bool _droppedHolding(ContactRecord record) =>
      (record.state == ContactState.former ||
          record.state == ContactState.blocked) &&
      record.boxOrigin != null &&
      record.queues.isNotEmpty;

  static bool _pendingOverBox(ContactRecord record) =>
      (record.state == ContactState.pendingIn ||
          record.state == ContactState.pendingOut) &&
      record.boxOrigin != null &&
      record.legacy.requestId == null;

  /// This account asked [userId] over the box (E15b) — or a sibling did and
  /// said so (E15e): a `pendingOut` record under [profile], holding the
  /// peer devices' request [addresses] and served [bundles] from the search
  /// answer. False for a friend, a blocked account, and a request the
  /// server carries.
  Future<bool> asked({
    required int userId,
    required FirstContactClaim profile,
    required List<ContactOutbound> addresses,
    Map<int, Map<String, dynamic>> bundles = const {},
    String? avatarUrl,
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
      // Asking again keeps the request's age only while it is still shown:
      // a re-send after it lapsed (decision 54) is a new request, and its
      // queue must live its own full span (review).
      final now = _now();
      final keepAge =
          state == ContactState.pendingOut && shownPending(current!, now);
      return base.copyWith(
        state: ContactState.pendingOut,
        username: profile.username,
        tag: profile.tag,
        avatarUrl: avatarUrl,
        // A `former` record swept from a server request still names it: a
        // box request never does (every box rule reads `requestId == null`).
        legacy: base.legacy.copyWith(clearRequest: true),
        boxOrigin: ContactBoxOrigin(
          at: keepAge ? current.boxOrigin!.at : now,
          addresses: addresses,
          bundles: bundles,
        ),
      );
    });
    return ok && asked;
  }

  /// [userId]'s pending box request — either way — became a friendship
  /// (E15d, E15e, E15f): `friend` under its local chat id (decision 52),
  /// with the VERIFIED [profile] and [avatarUrl] when the accept looked it
  /// up, and the peer's request [addresses] and served [bundles] when
  /// known; the kept frames go. False for anything that is not a pending
  /// box request.
  Future<bool> befriend(
    int userId, {
    FirstContactClaim? profile,
    String? avatarUrl,
    List<ContactOutbound>? addresses,
    Map<int, Map<String, dynamic>>? bundles,
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
          bundles: bundles ?? origin.bundles,
        ),
      );
    });
    return ok && befriended;
  }
}
