import 'dart:async';
import 'dart:convert';

import '../../models/user_model.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../encryption/content_kv.dart';
import '../encryption/content_kv_opener_stub.dart'
    if (dart.library.io) '../encryption/content_kv_opener_io.dart'
    show contactStoreAccepts;
import '../encryption/session_cross_context_lock.dart';
import 'contact_record.dart';

/// The store could not be opened for this session. [stage] names the first
/// check that failed; the caller records it and runs WITHOUT local contacts
/// (the server lists still fill the UI while the legacy path exists).
class ContactStoreUnavailable implements Exception {
  const ContactStoreUnavailable(this.stage);

  final String stage;

  @override
  String toString() => 'ContactStoreUnavailable($stage)';
}

/// The client-owned contact list (metadata-privacy design §4.1): one
/// [ContactRecord] per peer, persisted under the account's `e2e_<uid>_`
/// namespace in the platform content store, so the app knows its contacts
/// with no server round trip — and, after Phase 4, with no server copy at
/// all.
///
/// Storage rules, each load-bearing:
///  * The backend is the SAME [ContentKv] the message cache uses, handed in
///    by `EncryptionService.contentKv` — never a second opener call. That keeps the
///    memo, the rejected-open retry and the test seams in one place, and on
///    web it inherits the locked-passcode rethrow (a locked vault must not
///    write contacts in cleartext any more than messages).
///  * On Android the store REFUSES anything but the SQLCipher backend
///    ([contactStoreAccepts]): the prefs fallback the message cache tolerates
///    for one session would put the contact graph in cleartext XML.
///  * Keys `e2e_<uid>_contact_v1_<peerUserId>` (+ `…_self`) sit INSIDE the
///    `e2e_<uid>_` namespace so account deletion's `clearAllKeys` sweeps them;
///    no other clear/erase path touches that prefix.
///  * An undecodable row (a `v` this build cannot read, a web row whose seal
///    key was lost, garbage) is UNDETERMINED: skipped, counted, never
///    deleted, and never turned into "no contacts". The first server list or
///    the PR2.4 restore rewrites it.
///  * Every write is read-modify-write under ONE cross-context lock per
///    account (web tabs) and one in-process queue (everywhere), re-reading
///    ground truth inside the lock so a concurrent tab's write is never
///    clobbered.
class ContactStore {
  ContactStore({
    required Future<ContentKv> Function() open,
    UserModel? Function()? selfProfile,
    SessionCrossContextLockRunner lock = runSessionCrossContextLocked,
    bool Function(ContentKv kv) accepts = contactStoreAccepts,
  }) : _open = open,
       _selfProfile = selfProfile,
       _lock = lock,
       _accepts = accepts;

  final Future<ContentKv> Function() _open;

  /// The signed-in account's own profile (the auth session's), consulted at
  /// [open] so [self] is known from the first session on — a brand-new
  /// account has pending requests to hydrate long before its first
  /// `conversationsList` (the only wire that otherwise names us).
  final UserModel? Function()? _selfProfile;
  final SessionCrossContextLockRunner _lock;
  final bool Function(ContentKv kv) _accepts;

  static String keyPrefix(int userId) => 'e2e_${userId}_contact_v1_';
  static String recordKey(int userId, int peerUserId) =>
      '${keyPrefix(userId)}$peerUserId';
  static String selfKey(int userId) => '${keyPrefix(userId)}self';
  static String lockName(int userId) => 'fireplace-contacts-$userId';

  /// This DEVICE's box request queue (metadata-privacy PR3.1, design §4.4).
  /// Deliberately OUTSIDE [keyPrefix]: every `contact_v1_` row is copied
  /// verbatim by the history file backup and read as a peer by the sweeps,
  /// and this row holds per-device private halves — a second install of the
  /// account importing it would take over this device's request queue.
  /// Inside `e2e_<uid>_`, so account deletion's `clearAllKeys` sweeps it; a
  /// sealed family on web (`SealedWebContentKv`).
  static String requestQueueKey(int userId) => 'e2e_${userId}_boxreq_v1';
  static const int requestQueueVersion = 1;

  int? _userId;
  ContentKv? _kv;
  final Map<int, ContactRecord> _records = <int, ContactRecord>{};
  UserModel? _self;
  ContactQueue? _requestQueue;
  bool _requestQueueUnsupported = false;
  int _undetermined = 0;
  Future<void> _queue = Future<void>.value();

  /// Bumped by [open] and [close]. A queued mutation captures it and refuses
  /// to run — or to touch the RAM view — under a later session: the
  /// [ContentKv] instance survives logout → login, so identity alone cannot
  /// tell the sessions apart.
  int _generation = 0;

  /// Fired once after any mutation that actually CHANGED a row on disk —
  /// never for a reconcile that found everything already equal, which is
  /// what most reconnects are.
  ///
  /// PR2.4's backup upload hangs off this: making the upload change-driven
  /// rather than timer-driven is what stops an empty or unopened store from
  /// ever overwriting a good server row, because a store nobody wrote to
  /// emits nothing.
  void Function()? onChanged;

  bool get isOpen => _kv != null;
  int? get userId => _userId;

  /// Completes when every mutation queued so far has settled (committed,
  /// refused, or skipped). Provider write-through is fire-and-forget; this is
  /// for the callers that need the disk to agree first — the PR2.4 backup
  /// upload, and tests.
  Future<void> get settled => _queue;

  /// This account's own profile as last written by [setSelf]; needed to build
  /// a `ConversationModel` (which names both parties) offline.
  UserModel? get self => _self;

  /// Rows present on disk that this build could not read at [open].
  int get undeterminedCount => _undetermined;

  List<ContactRecord> get all => List.unmodifiable(_records.values);

  ContactRecord? byUserId(int peerUserId) => _records[peerUserId];

  /// This device's request queue as last read or claimed; null when there is
  /// none, or the stored row is unreadable (replaceable) or a newer build's.
  ContactQueue? get requestQueue => _requestQueue;

  /// A NEWER build wrote the request-queue row: it is never overwritten.
  bool get requestQueueUnsupported => _requestQueueUnsupported;

  /// Opens the store for [userId] and loads every readable record. Throws
  /// [ContactStoreUnavailable]; a thrown open leaves the store closed. An
  /// open that a [close] (re-lock, logout) overtakes while it is awaiting
  /// finishes CLOSED rather than binding to a store the close revoked.
  Future<void> open(int userId) async {
    close();
    final generation = _generation;
    final ContentKv kv;
    try {
      kv = await _open();
    } on ContentStoreUnavailable catch (e) {
      throw ContactStoreUnavailable(e.locked ? 'locked' : e.stage);
    } on Object {
      throw const ContactStoreUnavailable('open');
    }
    if (!_accepts(kv)) throw const ContactStoreUnavailable('backend');

    final Map<String, Object?> rows;
    try {
      rows = await _readWhere(
        kv,
        (key) =>
            key.startsWith(keyPrefix(userId)) || key == requestQueueKey(userId),
      );
    } on Object {
      throw const ContactStoreUnavailable('read');
    }

    final prefix = keyPrefix(userId);
    final self = selfKey(userId);
    var undetermined = 0;
    final loaded = <int, ContactRecord>{};
    final request = _decodeRequest(rows.remove(requestQueueKey(userId)));
    UserModel? selfUser;
    for (final entry in rows.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is! String) {
        undetermined++;
        continue;
      }
      if (key == self) {
        selfUser = _decodeUser(value);
        if (selfUser == null) undetermined++;
        continue;
      }
      final peerId = int.tryParse(key.substring(prefix.length));
      final record = peerId == null ? null : _decode(value, peerId).record;
      if (record == null) {
        undetermined++;
        continue;
      }
      loaded[peerId!] = record;
    }
    if (undetermined > 0) {
      E2ePersistentDiag.record('CONTACT_STORE_UNDETERMINED', {
        'count': undetermined,
      });
    }

    if (_generation != generation) return;
    _generation++;
    _userId = userId;
    _kv = kv;
    _self = selfUser;
    _requestQueue = request.queue;
    _requestQueueUnsupported = request.unsupported;
    _undetermined = undetermined;
    _records
      ..clear()
      ..addAll(loaded);
    final profile = _selfProfile?.call();
    if (profile != null && profile.id == userId) {
      _self = profile;
      unawaited(setSelf(profile));
    }
  }

  /// Forgets the in-RAM view. Nothing on disk is touched.
  void close() {
    _generation++;
    _userId = null;
    _kv = null;
    _self = null;
    _requestQueue = null;
    _requestQueueUnsupported = false;
    _undetermined = 0;
    _records.clear();
  }

  /// Read-modify-write of one record. [mutate] sees the record as it is ON
  /// DISK right now (null when absent or unreadable) and returns the record
  /// to keep, or null to leave the row untouched. Returns whether every
  /// write committed; an unchanged record is reported committed without
  /// touching the store.
  Future<bool> update(
    int peerUserId,
    ContactRecord? Function(ContactRecord? current) mutate,
  ) => reconcile([peerUserId], (_, current) => mutate(current));

  /// [update] for a whole server list, plus the membership decision, in ONE
  /// lock over ONE ground-truth read: every listed peer goes through
  /// [mutate]; every OTHER readable record on disk goes through [sweep],
  /// which returns null to remove it, the record itself to keep it, or a
  /// rewritten one. Deciding membership here — on disk state, inside the
  /// lock — is what keeps two list events that land in one I/O window from
  /// pruning on a RAM view the first event has not yet updated.
  ///
  /// A `conversationsList` of fifty peers on a reconnect costs one
  /// enumeration and zero seals: only rows whose JSON changed are written.
  ///
  /// A row a NEWER build wrote (`v` above [ContactRecord.currentVersion]) is
  /// neither rewritten nor swept — it may hold material this build cannot
  /// see. Any other unreadable row (lost seal key, garbage) is replaced when
  /// a mutation names its peer: the server payload is strictly more than the
  /// nothing it held.
  Future<bool> reconcile(
    Iterable<int> peerUserIds,
    ContactRecord? Function(int peerUserId, ContactRecord? current) mutate, {
    ContactRecord? Function(ContactRecord unlisted)? sweep,
  }) {
    final kv = _kv;
    final userId = _userId;
    final generation = _generation;
    if (kv == null || userId == null) return Future.value(false);
    final ids = peerUserIds.toList(growable: false);
    if (ids.isEmpty && sweep == null) return Future.value(true);
    return _serial(
      () => _lock(lockName(userId), () async {
        if (_generation != generation) return false;
        final rows = await _readNamespace(kv, userId);
        final prefix = keyPrefix(userId);
        var ok = true;

        Future<void> write(int peerId, String key, ContactRecord next) async {
          final encoded = jsonEncode(next.toJson());
          if (encoded != rows[key]) {
            if (!await kv.setString(key, encoded)) {
              ok = false;
              return;
            }
            _mutated = true;
          }
          if (_generation == generation) _records[peerId] = next;
        }

        Future<void> erase(int peerId, String key) async {
          if (!await kv.remove(key)) {
            ok = false;
            return;
          }
          _mutated = true;
          if (_generation == generation) _records.remove(peerId);
        }

        final listed = ids.toSet();
        for (final peerId in ids) {
          final key = recordKey(userId, peerId);
          final current = _decode(rows[key], peerId);
          if (current.unsupported) continue;
          final next = mutate(peerId, current.record);
          if (next != null) await write(peerId, key, next);
        }

        if (sweep == null) return ok;
        for (final entry in rows.entries) {
          final peerId = int.tryParse(entry.key.substring(prefix.length));
          if (peerId == null || listed.contains(peerId)) continue;
          final current = _decode(entry.value, peerId).record;
          if (current == null) continue;
          final next = sweep(current);
          if (next == null) {
            await erase(peerId, entry.key);
          } else if (!identical(next, current)) {
            await write(peerId, entry.key, next);
          }
        }
        return ok;
      }),
    );
  }

  /// Deletes the record. Removing an absent record succeeds.
  Future<bool> remove(int peerUserId) {
    final kv = _kv;
    final userId = _userId;
    final generation = _generation;
    if (kv == null || userId == null) return Future.value(false);
    return _serial(
      () => _lock(lockName(userId), () async {
        if (_generation != generation) return false;
        final ok = await kv.remove(recordKey(userId, peerUserId));
        if (ok) _mutated = true;
        if (ok && _generation == generation) _records.remove(peerUserId);
        return ok;
      }),
    );
  }

  /// Records this account's own profile (see [self]).
  Future<bool> setSelf(UserModel user) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null || user.id != userId) {
      return Future.value(false);
    }
    final generation = _generation;
    return _serial(
      () => _lock(lockName(userId), () async {
        if (_generation != generation) return false;
        final key = selfKey(userId);
        final encoded = jsonEncode(_userToJson(user));
        if (kv.getString(key) != encoded) {
          if (!await kv.setString(key, encoded)) return false;
          _mutated = true;
        }
        if (_generation == generation) _self = user;
        return true;
      }),
    );
  }

  /// Stores [candidate] as this device's request queue UNLESS a readable one
  /// is already on disk — another tab of this device claimed first — in
  /// which case that one is kept and returned; the caller deletes its own
  /// from the box, so exactly one queue is ever published per device. Null
  /// when nothing could be decided: the store is closed, the write did not
  /// commit, or a newer build owns the row.
  ///
  /// Never fires [onChanged]: the contact backup does not carry this row.
  Future<ContactQueue?> claimRequestQueue(ContactQueue candidate) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value();
    final generation = _generation;
    ContactQueue? kept;
    return _serial(
      () => _lock(lockName(userId), () async {
        if (_generation != generation) return false;
        final key = requestQueueKey(userId);
        final current = _decodeRequest(
          (await _readWhere(kv, (k) => k == key))[key],
        );
        if (current.unsupported) return false;
        final onDisk = current.queue;
        if (onDisk == null) {
          final encoded = jsonEncode({
            'v': requestQueueVersion,
            'queue': candidate.toJson(),
          });
          if (!await kv.setString(key, encoded)) return false;
        }
        kept = onDisk ?? candidate;
        if (_generation == generation) _requestQueue = kept;
        return true;
      }),
    ).then((ok) => ok ? kept : null);
  }

  /// Forgets the request queue [rid] — the box refused it (deleted or
  /// reaped), so its sid must never be published again. A row holding a
  /// DIFFERENT queue (another tab already replaced it) is left alone.
  Future<bool> dropRequestQueue(String rid) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(lockName(userId), () async {
        if (_generation != generation) return false;
        final key = requestQueueKey(userId);
        final current = _decodeRequest(
          (await _readWhere(kv, (k) => k == key))[key],
        );
        if (current.unsupported) return false;
        if (current.queue?.rid == rid && !await kv.remove(key)) return false;
        if (_generation == generation && _requestQueue?.rid == rid) {
          _requestQueue = null;
        }
        return true;
      }),
    );
  }

  /// In-process serialization: the native lock runner is a pass-through, and
  /// two overlapping list events (friends + conversations at connect) must not
  /// interleave their read-then-write on the same rows. A mutation that
  /// THROWS (an enumeration failure under the lock, a refused Web Lock)
  /// answers `false` like a refused commit — every provider call site is
  /// fire-and-forget, so a rejection would otherwise surface as an unhandled
  /// async error and the store would go stale without a trace.
  Future<bool> _serial(Future<bool> Function() action) {
    final run = _queue
        .then((_) {
          _mutated = false;
          return action();
        })
        .then<bool>(
          (ok) => ok,
          onError: (Object e) {
            E2ePersistentDiag.record('CONTACT_STORE_WRITE_FAILED', {
              'error': e.runtimeType.toString(),
            });
            return false;
          },
        )
        .then<bool>((ok) {
          // AFTER the queue slot's work, so a listener that reads the store
          // (the backup upload does) sees the committed view, and a listener
          // that throws cannot poison the mutation's own result.
          if (_mutated) {
            _mutated = false;
            try {
              onChanged?.call();
            } on Object {
              // A backup scheduler must never be able to fail a write.
            }
          }
          return ok;
        });
    _queue = run.then<void>((_) {});
    return run;
  }

  /// Set by the mutators when a row actually changed on disk; read and reset
  /// by [_serial]. Safe as one field because [_serial] is the only runner and
  /// it is strictly serial.
  bool _mutated = false;

  /// Every row under this account's contact prefix, from GROUND TRUTH where the
  /// backend has a stale-able cache (web) and from the loaded view elsewhere.
  /// Never `reload()`: refilling the prefs cache across an await is the
  /// 2026-07-29 incident class for every other family's in-flight write.
  static Future<Map<String, Object?>> _readNamespace(
    ContentKv kv,
    int userId,
  ) => _readWhere(kv, (key) => key.startsWith(keyPrefix(userId)));

  static Future<Map<String, Object?>> _readWhere(
    ContentKv kv,
    bool Function(String key) wanted,
  ) async {
    final snapshot = await kv.authoritativeSnapshot();
    if (snapshot != null) {
      return <String, Object?>{
        for (final e in snapshot.entries)
          if (wanted(e.key)) e.key: e.value,
      };
    }
    return <String, Object?>{
      for (final key in kv.getKeys())
        if (wanted(key)) key: kv.getString(key),
    };
  }

  /// The request-queue row: `queue` null with `unsupported` false = absent
  /// or unreadable (garbage, a web row whose seal key was lost) — replaceable,
  /// because a fresh queue plus a re-publish loses at most the requests
  /// waiting in the old one. `unsupported` = a newer build's row, off limits.
  static ({ContactQueue? queue, bool unsupported}) _decodeRequest(Object? raw) {
    if (raw is! String) return (queue: null, unsupported: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return (queue: null, unsupported: false);
      }
      final v = decoded['v'];
      if (v is int && v > requestQueueVersion) {
        return (queue: null, unsupported: true);
      }
      final queue = ContactQueue.fromJson(
        decoded['queue'] as Map<String, dynamic>,
      );
      return (queue: queue, unsupported: false);
    } on Object {
      return (queue: null, unsupported: false);
    }
  }

  /// A row as this build sees it. `unsupported` = a newer build wrote it (or
  /// its body names another peer): present, opaque, and off limits to every
  /// mutation. `record` null with `unsupported` false = absent or unreadable.
  static _Decoded _decode(Object? raw, int peerUserId) {
    if (raw is! String) return const _Decoded(null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const _Decoded(null);
      final v = decoded['v'];
      if (v is int && v > ContactRecord.currentVersion) {
        return const _Decoded(null, unsupported: true);
      }
      final record = ContactRecord.fromJson(decoded);
      // The key names the peer; a body that disagrees is not this contact.
      return record.userId == peerUserId
          ? _Decoded(record)
          : const _Decoded(null, unsupported: true);
    } on Object {
      return const _Decoded(null);
    }
  }

  static UserModel? _decodeUser(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return UserModel.fromJson(decoded);
    } on Object {
      return null;
    }
  }

  static Map<String, dynamic> _userToJson(UserModel user) => {
    'id': user.id,
    'username': user.username,
    'tag': user.tag,
    if (user.profilePictureUrl != null)
      'profilePictureUrl': user.profilePictureUrl,
  };
}

class _Decoded {
  const _Decoded(this.record, {this.unsupported = false});

  final ContactRecord? record;
  final bool unsupported;
}
