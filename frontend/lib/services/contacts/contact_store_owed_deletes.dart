part of 'contact_store.dart';

/// One queue this install still owes the box a delete for: its rid and the
/// private auth key that proves it (`BoxQueueAuth`), both base64url.
typedef OwedQueueDelete = ({String rid, String key});

/// Issue #208: the `boxgone_v1` row — queues of a device life that ended
/// (revoked, or about to become a new device) whose delete the box has not
/// confirmed within the retire's wait. Kept by the fresh-start wipe
/// (`EncryptionService._wipeAccountNamespace`), so the next life's box
/// deletes them (`BoxSession`) instead of leaving them to the box's reaper:
/// while they exist a friend's old list keeps filling them and waking this
/// device for nothing. Sealed on web (it holds queue auth keys); no backup
/// carries it. Same kv, lock and `_generation` close semantics as every other
/// row here; never fires [ContactStore.onChanged].
extension ContactStoreOwedQueueDeletes on ContactStore {
  /// The queues still owed a delete, from ground truth; empty when none, the
  /// store is closed, or the row is unreadable.
  Future<List<OwedQueueDelete>> owedQueueDeletes() async {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return const [];
    final key = ContactStore.owedQueueDeletesKey(userId);
    final raw = (await ContactStore._readWhere(kv, (k) => k == key))[key];
    return _decodeOwed(raw) ?? const [];
  }

  /// Adds [queues] to the row (a rid already owed is kept once).
  Future<bool> addOwedQueueDeletes(Iterable<OwedQueueDelete> queues) =>
      _updateOwed((held) => {...held, for (final q in queues) q.rid: q.key});

  /// Drops the queues named by [rids]: their delete was confirmed.
  Future<bool> dropOwedQueueDeletes(Iterable<String> rids) {
    final gone = rids.toSet();
    return _updateOwed(
      (held) => {
        for (final e in held.entries)
          if (!gone.contains(e.key)) e.key: e.value,
      },
    );
  }

  Future<bool> _updateOwed(
    Map<String, String> Function(Map<String, String> held) mutate,
  ) {
    final kv = _kv;
    final userId = _userId;
    if (kv == null || userId == null) return Future.value(false);
    final generation = _generation;
    return _serial(
      () => _lock(ContactStore.lockName(userId), () async {
        if (_generation != generation) return false;
        final key = ContactStore.owedQueueDeletesKey(userId);
        final raw = (await ContactStore._readWhere(kv, (k) => k == key))[key];
        final current = _decodeOwed(raw);
        if (current == null && raw != null) return false;
        final next = mutate({
          for (final OwedQueueDelete q in current ?? const <OwedQueueDelete>[])
            q.rid: q.key,
        });
        if (next.isEmpty) return raw == null || await kv.remove(key);
        final encoded = jsonEncode({
          'v': 1,
          'q': [
            for (final e in next.entries) {'rid': e.key, 'key': e.value},
          ],
        });
        return encoded == raw || await kv.setString(key, encoded);
      }),
    );
  }
}

/// Null = a newer build's row (off limits) or one that does not parse.
List<OwedQueueDelete>? _decodeOwed(Object? raw) {
  if (raw == null) return const [];
  try {
    final json = jsonDecode(raw as String) as Map<String, Object?>;
    if (json['v'] != 1) return null;
    return [
      for (final q in json['q']! as List<Object?>)
        if (q case {'rid': final String rid, 'key': final String key})
          (rid: rid, key: key)
        else
          throw const FormatException('owed queue delete'),
    ];
  } on Object {
    return null;
  }
}
