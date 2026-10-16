part of 'contact_store.dart';

/// What this install knows of one sibling's presence (owner decisions 101 B
/// and 103): when it was last heard from on our self-queue — or first known
/// here, so neither a fresh link nor the upgrade to this build ever counts as
/// a month of silence — when this device last sent it `alive`, and until
/// when the primary's unlink question is kept away ("Keep").
typedef SiblingPresence = ({
  DateTime? heardAt,
  DateTime? aliveSentAt,
  DateTime? keptUntil,
});

const SiblingPresence _noPresence = (
  heardAt: null,
  aliveSentAt: null,
  keptUntil: null,
);

/// The `boxalive_v1` row: [SiblingPresence] per sibling device id.
class _AliveBook {
  const _AliveBook(this.devices);

  static const _AliveBook empty = _AliveBook({});

  final Map<int, SiblingPresence> devices;

  String encode() => jsonEncode({
    'v': ContactStore.siblingAliveVersion,
    'd': {
      for (final MapEntry(key: id, value: p) in devices.entries)
        '$id': {
          if (p.heardAt case final at?) 'h': at.millisecondsSinceEpoch,
          if (p.aliveSentAt case final at?) 's': at.millisecondsSinceEpoch,
          if (p.keptUntil case final at?) 'k': at.millisecondsSinceEpoch,
        },
    },
  });

  /// Null = a newer build's row (off limits). Absent or unreadable reads
  /// [empty]: every live sibling is then first known again, which only
  /// delays a question, never asks one early.
  static _AliveBook? decode(Object? raw) {
    if (raw is! String) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return empty;
      final v = decoded['v'];
      if (v is int && v > ContactStore.siblingAliveVersion) return null;
      final devices = decoded['d'];
      if (devices is! Map<String, dynamic>) return empty;
      DateTime? at(Object? ms) => ms is int && ms > 0
          ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
          : null;
      return _AliveBook({
        for (final MapEntry(:key, :value) in devices.entries)
          if ((int.tryParse(key), value) case (
            final int id,
            final Map<String, dynamic> p,
          ))
            id: (
              heardAt: at(p['h']),
              aliveSentAt: at(p['s']),
              keptUntil: at(p['k']),
            ),
      });
    } on Object {
      return empty;
    }
  }

  /// [deviceId]'s entry rewritten by [change] (from an empty one if absent).
  _AliveBook withDevice(
    int deviceId,
    SiblingPresence Function(SiblingPresence current) change,
  ) => _AliveBook({
    ...devices,
    deviceId: change(devices[deviceId] ?? _noPresence),
  });
}

/// When this device heard each sibling, when it last sent each one `alive`,
/// and which the user chose to keep (decisions 101 B, 103). One row,
/// `e2e_<uid>_boxalive_v1`, outside `contact_v1_` with the other box rows:
/// it is THIS install's view, so no backup and no history file carries it.
/// Sealed on web: it names every linked device and when each was last used.
///
/// Same kv, lock, `_generation` close semantics and newer-build refusal as
/// every other row here; never fires [ContactStore.onChanged].
extension ContactStoreSiblingAlive on ContactStore {
  /// A NEWER build wrote the row: it is never overwritten.
  bool get siblingAliveUnsupported => _aliveUnsupported;

  /// What this install knows of sibling [deviceId]; null when nothing.
  SiblingPresence? siblingPresence(int deviceId) =>
      _aliveBook.devices[deviceId];

  /// When sibling [deviceId] was last heard from (or first known here).
  DateTime? siblingHeardAt(int deviceId) =>
      _aliveBook.devices[deviceId]?.heardAt;

  /// Every sibling in [live] with no heard mark ([SiblingPresence]) is first
  /// known [now]; every entry outside [live] (revoked, or never ours) goes.
  Future<bool> noteSiblingsKnown(Set<int> live, DateTime now) =>
      _updateAlive((book) {
        final next = <int, SiblingPresence>{
          for (final id in live)
            id: switch (book.devices[id] ?? _noPresence) {
              (heardAt: null, :final aliveSentAt, :final keptUntil) => (
                heardAt: now,
                aliveSentAt: aliveSentAt,
                keptUntil: keptUntil,
              ),
              final held => held,
            },
        };
        return _AliveBook(next);
      });

  /// Sibling [deviceId] was heard [at]; a mark only moves forward.
  Future<bool> markSiblingHeard(int deviceId, DateTime at) =>
      _updateAlive((book) {
        final held = book.devices[deviceId]?.heardAt;
        if (held != null && !at.isAfter(held)) return book;
        return book.withDevice(
          deviceId,
          (p) => (
            heardAt: at,
            aliveSentAt: p.aliveSentAt,
            keptUntil: p.keptUntil,
          ),
        );
      });

  /// The box took this device's `alive` for sibling [deviceId] [at].
  Future<bool> markSiblingAliveSent(int deviceId, DateTime at) => _updateAlive(
    (book) => book.withDevice(
      deviceId,
      (p) => (heardAt: p.heardAt, aliveSentAt: at, keptUntil: p.keptUntil),
    ),
  );

  /// The user kept sibling [deviceId]: no unlink question before [until].
  Future<bool> keepSibling(int deviceId, DateTime until) => _updateAlive(
    (book) => book.withDevice(
      deviceId,
      (p) => (heardAt: p.heardAt, aliveSentAt: p.aliveSentAt, keptUntil: until),
    ),
  );

  /// Read-modify-write of the row under the account lock, from GROUND TRUTH.
  /// [mutate] returns the book to keep; an unchanged encoding writes nothing.
  /// False when nothing could be written (closed, uncommitted, a newer
  /// build's row).
  Future<bool> _updateAlive(_AliveBook Function(_AliveBook current) mutate) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = ContactStore.siblingAliveKey(userId);
        final raw = (await ContactStore._readWhere(kv, (k) => k == key))[key];
        final current = _AliveBook.decode(raw);
        if (current == null) return false;
        final next = mutate(current);
        final encoded = next.encode();
        if (encoded != raw && !await kv.setString(key, encoded)) return false;
        if (_generation == generation) _aliveBook = next;
        return true;
      }),
    );
  }
}
