part of 'contact_store.dart';

/// The `boxlook_v1` row: when each friend was last looked up by handle for the
/// request queues of its devices, per friend.
class _LookupBook {
  const _LookupBook(this.at);

  static const _LookupBook empty = _LookupBook({});

  final Map<int, DateTime> at;

  String encode() => jsonEncode({
    'v': ContactStore.friendLookupVersion,
    'f': {
      for (final MapEntry(key: id, value: stamp) in at.entries)
        '$id': stamp.millisecondsSinceEpoch,
    },
  });

  /// Null = a newer build's row (off limits). Absent or unreadable reads
  /// [empty]: every friend is then asked once more, which costs one lookup and
  /// never withholds one.
  static _LookupBook? decode(Object? raw) {
    if (raw is! String) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return empty;
      final v = decoded['v'];
      if (v is int && v > ContactStore.friendLookupVersion) return null;
      final friends = decoded['f'];
      if (friends is! Map<String, dynamic>) return empty;
      return _LookupBook({
        for (final MapEntry(:key, :value) in friends.entries)
          if ((int.tryParse(key), value) case (final int id, final int ms)
              when ms > 0)
            id: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      });
    } on Object {
      return empty;
    }
  }
}

/// When this device last looked each friend up by handle (decision 120, E114n):
/// "at most once per process and once per 24 h per still-unrouted friend" has a
/// per-process half the box session keeps in RAM and this per-24 h half, which
/// must outlive the process — a PWA is opened many times a day, and a friend
/// whose live device never gets a handoff stays owed one every time. One row,
/// `e2e_<uid>_boxlook_v1`, outside `contact_v1_` with the other box rows: it is
/// THIS install's view, so no backup and no history file carries it, and it
/// never leaves the device. Sealed on web: it names the friends this device
/// looked up and when.
///
/// Same kv, lock, `_generation` close semantics and newer-build refusal as
/// every other row here; never fires [ContactStore.onChanged].
extension ContactStoreFriendLookups on ContactStore {
  /// A NEWER build wrote the row: it is never overwritten, and nothing is
  /// remembered (the per-process bound still holds).
  bool get friendLookupsUnsupported => _lookupsUnsupported;

  /// When friend [userId] was last looked up here; null when never, or not
  /// remembered.
  DateTime? friendLookedUpAt(int userId) => _lookupBook.at[userId];

  /// Friend [userId] was looked up [at]; the last write wins. A stamp later
  /// than [at] is one a clock that has since gone back wrote, and keeping it
  /// would make the friend due at every start until the clock passed it
  /// (`BoxFriendHandoff._lookupDue` counts a stamp from the future as due).
  Future<bool> noteFriendLookup(int userId, DateTime at) => _updateLookups((
    book,
  ) {
    final held = book.at[userId];
    if (held != null && held.isAtSameMomentAs(at)) return book;
    return _LookupBook({...book.at, userId: at});
  });

  /// Every stamp of an account outside [friends] goes (a friendship that
  /// ended, a record that was never a friend). Writes nothing when none does.
  Future<bool> pruneFriendLookups(Set<int> friends) => _updateLookups(
    (book) => book.at.keys.every(friends.contains)
        ? book
        : _LookupBook({
            for (final MapEntry(:key, :value) in book.at.entries)
              if (friends.contains(key)) key: value,
          }),
  );

  /// Read-modify-write of the row under the account lock, from GROUND TRUTH.
  /// [mutate] returns the book to keep; an unchanged encoding writes nothing.
  /// False when nothing could be written (closed, uncommitted, a newer
  /// build's row).
  Future<bool> _updateLookups(
    _LookupBook Function(_LookupBook current) mutate,
  ) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = ContactStore.friendLookupKey(userId);
        final raw = (await ContactStore._readWhere(kv, (k) => k == key))[key];
        final current = _LookupBook.decode(raw);
        if (current == null) return false;
        final next = mutate(current);
        if (!identical(next, current)) {
          final encoded = next.encode();
          if (encoded != raw && !await kv.setString(key, encoded)) return false;
        }
        if (_generation == generation) _lookupBook = next;
        return true;
      }),
    );
  }
}
