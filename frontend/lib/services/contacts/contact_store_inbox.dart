part of 'contact_store.dart';

String _inboxPrefix(int userId) => 'e2e_${userId}_boxin_v1_';

String _inboxKey(int userId, String rid, String id) =>
    '${_inboxPrefix(userId)}$rid.$id';

/// The next local message id (decision 14). Plain: it names no one. Bumped
/// under the account's cross-context lock and never lowered, so an id is
/// never handed out twice — not after its record is deleted, expired or
/// retired, and not by two web tabs.
String _localIdCounterKey(int userId) => 'e2e_${userId}_boxlid_v1';

const int _inboxVersion = 1;

/// How long the box can still push a delivery again: its message TTL
/// (wire.md "Bounds (I3)"). A read row older than this maps nothing.
const Duration kBoxRedeliveryWindow = Duration(days: 30);

/// One box delivery this device holds (metadata-privacy PR3.1 slice (b)).
///
/// Written BEFORE the delivery is acked, keyed on the delivery itself
/// (`rid`, box message `id`), so everything after the write is replayable:
///  * the ack can be lost — the box pushes the blob again, and the push
///    finds this row and its [localId] instead of minting a new one and
///    re-running Signal on a key it already spent;
///  * the decrypt can be refused for now (a withheld sender device, E2E not
///    ready) — the ciphertext waits here, not in one of the box socket's 16
///    unacked window slots.
/// [signal] is dropped once the app consumed it; the row itself goes once it
/// is both consumed and acked.
class BoxInboxEntry {
  const BoxInboxEntry({
    required this.rid,
    required this.id,
    required this.localId,
    required this.peerUserId,
    required this.senderDeviceId,
    required this.signal,
    required this.receivedAt,
    required this.acked,
    this.viaSelfQueue = false,
  });

  /// The queue (base64url) and the box's message id on it.
  final String rid;
  final String id;
  final int localId;
  final int peerUserId;
  final int senderDeviceId;

  /// `"{type}:{base64}"` for `EncryptionService.decrypt`; null once consumed.
  final String? signal;
  final DateTime receivedAt;
  final bool acked;

  /// Journaled from one of this device's SELF-queues — the current one or
  /// one retiring (sibling queues part B) — whose sid only siblings were
  /// handed. Decided when the delivery is taken in, never when it is read:
  /// by then that queue may have retired and left the sibling row.
  final bool viaSelfQueue;

  bool get consumed => signal == null;

  String get _slot => '$rid.$id';

  Map<String, dynamic> _toJson() => {
    'v': _inboxVersion,
    'rid': rid,
    'id': id,
    'lid': localId,
    'peer': peerUserId,
    'dev': senderDeviceId,
    'sig': ?signal,
    'at': receivedAt.millisecondsSinceEpoch,
    'acked': acked,
    if (viaSelfQueue) 'self': true,
  };

  BoxInboxEntry _with({bool? acked, bool consume = false}) => BoxInboxEntry(
    rid: rid,
    id: id,
    localId: localId,
    peerUserId: peerUserId,
    senderDeviceId: senderDeviceId,
    signal: consume ? null : signal,
    receivedAt: receivedAt,
    acked: acked ?? this.acked,
    viaSelfQueue: viaSelfQueue,
  );

  /// Null for anything this build cannot read — a newer `v`, a web row whose
  /// seal key is gone, garbage: such a row is left on disk and treated as
  /// absent, so at worst a redelivery mints a fresh id for it.
  static BoxInboxEntry? _decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final json = jsonDecode(raw);
      if (json case {
        'v': _inboxVersion,
        'rid': final String rid,
        'id': final String id,
        'lid': final int localId,
        'peer': final int peer,
        'dev': final int dev,
        'at': final int at,
        'acked': final bool acked,
      } when localId >= kFirstLocalMessageId) {
        final sig = json['sig'];
        return BoxInboxEntry(
          rid: rid,
          id: id,
          localId: localId,
          peerUserId: peer,
          senderDeviceId: dev,
          signal: sig is String ? sig : null,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
          acked: acked,
          viaSelfQueue: json['self'] == true,
        );
      }
    } on FormatException {
      // Unreadable: absent.
    }
    return null;
  }
}

/// Removes this account's journal rows from [rows] and returns the readable
/// ones, keyed like [ContactStore._inbox].
Map<String, BoxInboxEntry> _takeInbox(Map<String, Object?> rows, int userId) {
  final prefix = _inboxPrefix(userId);
  final taken = <String, BoxInboxEntry>{};
  for (final key in rows.keys.where((k) => k.startsWith(prefix)).toList()) {
    final entry = BoxInboxEntry._decode(rows.remove(key));
    if (entry != null) taken[entry._slot] = entry;
  }
  return taken;
}

/// The box delivery journal. Same lock, queue and generation rules as every
/// other write in [ContactStore]; never fires [ContactStore.onChanged] — the
/// contact backup does not carry these rows.
extension ContactStoreInbox on ContactStore {
  /// Journaled deliveries not yet consumed, in arrival (local id) order —
  /// Signal's per-session order.
  List<BoxInboxEntry> get pendingInbox =>
      _inbox.values.where((e) => !e.consumed).toList()
        ..sort((a, b) => a.localId.compareTo(b.localId));

  /// Journal rows whose ack the box has not confirmed — read or not.
  List<BoxInboxEntry> get unackedInbox =>
      _inbox.values.where((e) => !e.acked).toList(growable: false);

  /// The journal row for delivery [id] on queue [rid], written now unless
  /// one is already on disk — then that one, local id and all, is returned
  /// unchanged. Null when nothing committed (store closed, write refused).
  Future<BoxInboxEntry?> journalDelivery({
    required String rid,
    required String id,
    required int peerUserId,
    required int senderDeviceId,
    required String signal,
    required DateTime receivedAt,
    bool viaSelfQueue = false,
  }) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value();
    final generation = _generation;
    BoxInboxEntry? journaled;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = _inboxKey(userId, rid, id);
        final counterKey = _localIdCounterKey(userId);
        final rows = await ContactStore._readWhere(
          kv,
          (k) => k == key || k == counterKey,
        );
        var entry = BoxInboxEntry._decode(rows[key]);
        if (entry == null) {
          final localId = _nextLocalId(kv, userId, rows[counterKey]);
          // Counter FIRST: a crash between the writes wastes an id, never
          // hands the same one out twice.
          if (!await kv.setString(counterKey, '${localId + 1}')) return false;
          entry = BoxInboxEntry(
            rid: rid,
            id: id,
            localId: localId,
            peerUserId: peerUserId,
            senderDeviceId: senderDeviceId,
            signal: signal,
            receivedAt: receivedAt,
            acked: false,
            viaSelfQueue: viaSelfQueue,
          );
          if (!await kv.setString(key, jsonEncode(entry._toJson()))) {
            return false;
          }
        }
        journaled = entry;
        if (_generation == generation) _inbox[entry._slot] = entry;
        return true;
      }),
    ).then((ok) => ok ? journaled : null);
  }

  /// A fresh local id for a message THIS device sends over the box (slice
  /// (c)), from the same counter and under the same lock as
  /// [journalDelivery], so a sent and a received message never share one.
  /// Null when nothing committed (store closed, write refused).
  Future<int?> allocateLocalId() {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value();
    final generation = _generation;
    int? allocated;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final counterKey = _localIdCounterKey(userId);
        final rows = await ContactStore._readWhere(kv, (k) => k == counterKey);
        final localId = _nextLocalId(kv, userId, rows[counterKey]);
        if (!await kv.setString(counterKey, '${localId + 1}')) return false;
        allocated = localId;
        return true;
      }),
    ).then((ok) => ok ? allocated : null);
  }

  /// The box confirmed the ack of [entry].
  Future<bool> markInboxAcked(BoxInboxEntry entry) =>
      _rewriteInbox(entry, (e) => e._with(acked: true));

  /// The app is finished with [entry] — shown, or refused for good.
  Future<bool> markInboxConsumed(BoxInboxEntry entry) =>
      _rewriteInbox(entry, (e) => e._with(consume: true));

  /// Drops consumed rows whose ack was never confirmed once the box can no
  /// longer push them ([kBoxRedeliveryWindow]); nothing unconsumed ever goes.
  Future<void> pruneInbox(DateTime now) async {
    final stale = _inbox.values.where(
      (e) =>
          e.consumed &&
          !e.acked &&
          now.difference(e.receivedAt) > kBoxRedeliveryWindow,
    );
    for (final entry in stale.toList()) {
      await _rewriteInbox(entry, (e) => null);
    }
  }

  /// Read-modify-write of [entry]'s row under the lock: [change] maps the row
  /// as it is on disk to its next state; a row both consumed and acked, or a
  /// null result, is deleted. An absent row is already gone: success.
  Future<bool> _rewriteInbox(
    BoxInboxEntry entry,
    BoxInboxEntry? Function(BoxInboxEntry onDisk) change,
  ) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = _inboxKey(userId, entry.rid, entry.id);
        final onDisk = BoxInboxEntry._decode(
          (await ContactStore._readWhere(kv, (k) => k == key))[key],
        );
        if (onDisk == null) {
          if (_generation == generation) _inbox.remove(entry._slot);
          return true;
        }
        final next = change(onDisk);
        final done = next == null || (next.consumed && next.acked);
        final ok = done
            ? await kv.remove(key)
            : await kv.setString(key, jsonEncode(next._toJson()));
        if (!ok) return false;
        if (_generation == generation) {
          if (done) {
            _inbox.remove(entry._slot);
          } else {
            _inbox[entry._slot] = next;
          }
        }
        return true;
      }),
    );
  }

  /// Above the stored counter AND above every local id the account still
  /// names anywhere — a plaintext record, the retired set, the decrypt ledger
  /// — so a lost counter row (a restored history file, a wiped row) never
  /// hands out an id a stored or retired message holds.
  static int _nextLocalId(ContentKv kv, int userId, Object? counterRaw) {
    var next = kFirstLocalMessageId;
    final counter = counterRaw is String ? int.tryParse(counterRaw) : null;
    if (counter != null && counter > next) next = counter;
    void atLeastPast(int? id) {
      if (id != null && id >= next) next = id + 1;
    }

    final prefix = 'e2e_${userId}_decrypted_';
    for (final key in kv.getKeys()) {
      if (key.startsWith(prefix)) {
        atLeastPast(int.tryParse(key.substring(prefix.length)));
      }
    }
    for (final listKey in ['e2e_${userId}_retired_v1', 'e2e_${userId}_ledger_v1']) {
      final raw = kv.getString(listKey);
      if (raw == null) continue;
      try {
        final ids = jsonDecode(raw);
        if (ids is List) {
          for (final id in ids) {
            atLeastPast(id is int ? id : null);
          }
        }
      } on FormatException {
        // Unreadable: it names nothing.
      }
    }
    return next;
  }
}
