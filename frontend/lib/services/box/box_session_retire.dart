part of 'box_session.dart';

/// Deleting queues in a [BoxSession]: every queue this device holds, the
/// deletes an ended device life still owes, and expired first contacts.
extension BoxSessionRetire on BoxSession {
  /// Deletes every queue this device holds, read from the store ONCE up
  /// front; stops at the first [keepGoing] that answers false, and stops
  /// waiting on a delete still in flight at [deadline]. Returns how many it
  /// held and the queues whose delete was not confirmed ([_oweDeletes]).
  Future<({int held, List<BoxQueueAuth> owed})> _retireQueues(
    bool Function() keepGoing, {
    DateTime? deadline,
  }) async {
    final deletes = <(BoxQueueAuth?, Future<bool> Function())>[
      for (final record in _store.all)
        for (final queue in record.queues)
          (
            QueueKeys.authOf(queue),
            () => _keys.retireInbound(record.userId, queue),
          ),
      for (final queue in [..._store.retiringSelfQueues])
        (QueueKeys.authOf(queue.queue), () => _keys.retire(queue)),
      for (final queue in [_store.selfQueue, _store.requestQueue])
        if (queue != null)
          if (QueueKeys.authOf(queue) case final auth?)
            (auth, () async => await _box.deleteQueue(auth) is BoxOk),
    ];
    final owed = <BoxQueueAuth>[];
    var next = 0;
    try {
      for (; next < deletes.length; next++) {
        if (!keepGoing()) break;
        final pending = deletes[next].$2();
        final done = await (deadline == null
            ? pending
            : pending.timeout(deadline.difference(_now())));
        if (!done) {
          if (deletes[next].$1 case final auth?) owed.add(auth);
        }
      }
    } on TimeoutException {
      // The one in flight is owed with the rest.
    }
    for (; next < deletes.length; next++) {
      if (deletes[next].$1 case final auth?) owed.add(auth);
    }
    return (held: deletes.length, owed: owed);
  }

  /// Issue #208: queues whose delete the retire could not confirm go to the
  /// store's `boxgone_v1` row, which the fresh-start wipe keeps; the next
  /// life's box deletes them ([_deleteOwedQueues]).
  Future<void> _oweDeletes(List<BoxQueueAuth> owed) async {
    if (owed.isEmpty || !_store.isOpen) return;
    await _store.addOwedQueueDeletes([
      for (final auth in owed)
        (rid: boxB64(auth.rid), key: boxB64(auth.key.bytes)),
    ]);
  }

  /// Deletes the queues an ended device life of this install still owes
  /// ([_oweDeletes]); a delete the box does not confirm stays owed for the
  /// next ready box.
  Future<void> _deleteOwedQueues() async {
    if (_deletingOwed || _disposed || _revoked || !_store.isOpen) return;
    _deletingOwed = true;
    try {
      final owed = await _store.owedQueueDeletes();
      if (owed.isEmpty) return;
      final gone = <String>[];
      for (final queue in owed) {
        if (_disposed || _revoked || _box.state != BoxState.ready) break;
        final rid = boxB64Decode(queue.rid, kBoxRidBytes);
        final key = boxB64Decode(queue.key, 64);
        if (rid == null ||
            key == null ||
            await _box.deleteQueue(
                  BoxQueueAuth(rid: rid, key: BoxAuthKey.fromBytes(key)),
                )
                is BoxOk) {
          gone.add(queue.rid);
        }
      }
      if (gone.isNotEmpty) await _store.dropOwedQueueDeletes(gone);
      E2eDiagLog.add('BOX_OWED_QUEUES_DELETED', {
        'deleted': gone.length,
        'owed': owed.length - gone.length,
      });
    } finally {
      _deletingOwed = false;
    }
  }

  /// E15i, whenever the box and the store are ready and at most once a day
  /// (a long-lived tab outlives a request's lifetime): every pending box
  /// request older than [BoxFirstContact.lifetime] retires.
  Future<void> _expireFirstContacts() async {
    final last = _expiryRanAt;
    if (last != null && _now().difference(last) < const Duration(days: 1)) {
      return;
    }
    _expiryRanAt = _now();
    final expired = await firstContact.expired();
    for (final userId in expired) {
      if (_disposed) return;
      await retireFirstContact(userId);
    }
    if (expired.isNotEmpty && !_disposed) onFirstContactsChanged?.call();
  }
}
