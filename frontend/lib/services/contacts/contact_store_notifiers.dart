part of 'contact_store.dart';

/// The `boxntf_v1` row: the push target this device last registered, and
/// the queues (by nid) whose box notifier is ACTIVE under it.
class _NotifierBook {
  const _NotifierBook({required this.target, required this.nids});

  static const _NotifierBook empty = _NotifierBook(target: null, nids: {});

  final String? target;
  final Set<String> nids;

  String encode() => jsonEncode({
    'v': ContactStore.notifiersVersion,
    'target': target,
    'nids': nids.toList()..sort(),
  });

  /// Null = a newer build's row (off limits). Absent or unreadable reads
  /// [empty]: the only cost is one more challenge and activation pass.
  static _NotifierBook? decode(Object? raw) {
    if (raw is! String) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return empty;
      final v = decoded['v'];
      if (v is int && v > ContactStore.notifiersVersion) return null;
      final target = decoded['target'];
      final nids = decoded['nids'];
      if (target is! String || nids is! List) return empty;
      return _NotifierBook(target: target, nids: {...nids.whereType<String>()});
    } on Object {
      return empty;
    }
  }
}

/// Which of this device's normal inbound queues has an ACTIVE box push
/// notifier, and for which push target (metadata-privacy E9). One row,
/// `e2e_<uid>_boxntf_v1`, outside `contact_v1_` with the other box rows: the
/// target is THIS device's push token, so no backup and no history file may
/// carry it to another install. Without it every launch would challenge
/// every queue again — a push each pass, against a 30 / 15 min budget.
///
/// Same kv, lock, `_generation` close semantics and newer-build refusal as
/// every other row here; never fires [ContactStore.onChanged].
extension ContactStoreNotifiers on ContactStore {
  /// A NEWER build wrote the row: it is never overwritten.
  bool get notifiersUnsupported => _notifiersUnsupported;

  /// Whether queue [nid]'s notifier was activated under push [target].
  bool notifierActive(String nid, String target) =>
      _notifierBook.target == target && _notifierBook.nids.contains(nid);

  /// Records the notifiers of queues [nids] as active under [target], in one
  /// write. A different target on disk means the token changed: every other
  /// nid is stale and dropped. So is any nid no contact record holds any
  /// more (the queue is gone). False when nothing was written (closed,
  /// uncommitted, a newer build's row).
  Future<bool> markNotifiers(Iterable<String> nids, String target) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = ContactStore.notifiersKey(userId);
        final current = _NotifierBook.decode(
          (await ContactStore._readWhere(kv, (k) => k == key))[key],
        );
        if (current == null) return false;
        final held = {
          for (final record in _records.values)
            for (final queue in record.queues) queue.nid,
        };
        final next = _NotifierBook(
          target: target,
          nids: {
            if (current.target == target)
              ...current.nids.where(held.contains),
            ...nids,
          },
        );
        if (!await kv.setString(key, next.encode())) return false;
        if (_generation == generation) _notifierBook = next;
        return true;
      }),
    );
  }
}
