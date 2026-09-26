import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_signer.dart';
import 'box_wire.dart';
import 'queue_seal.dart';

sealed class InboundQueueResult {
  const InboundQueueResult();
}

/// The queue exists and is stored on the peer's record; subscribed unless
/// the caller asked to batch that itself ([QueueKeys.ensureInbound]).
final class InboundQueueCreated extends InboundQueueResult {
  const InboundQueueCreated(this.queue);

  final ContactQueue queue;
}

/// The box did not create it: [answer] is its refusal or the missing answer.
/// A [BoxUnknown] may still have created a queue under the discarded key;
/// nobody ever subscribes it, so the box reaps it within 24 h (`claimBy`).
final class InboundQueueNotCreated extends InboundQueueResult {
  const InboundQueueNotCreated(this.answer);

  final BoxResult<QueueAddress> answer;
}

/// The box created it but the contact store did not keep it (no record for
/// the peer, a record a newer build owns, a failed write). The queue was
/// deleted again: an address no record holds can never be handed out.
final class InboundQueueNotStored extends InboundQueueResult {
  const InboundQueueNotStored();
}

/// This device's inbound queues (design §4.2: one normal queue per (this
/// device, peer account)) and their keys, kept in the peer's
/// [ContactRecord.queues] — the only copy of the private halves, so the
/// store's rules about never destroying a record are the rules about never
/// losing a queue.
class QueueKeys {
  QueueKeys({
    required BoxClient box,
    required ContactStore store,
    BoxSigner signer = const Ed25519BoxSigner(),
  }) : _box = box,
       _store = store,
       _signer = signer;

  final BoxClient _box;
  final ContactStore _store;
  final BoxSigner _signer;

  /// [peerUserId]'s inbound queue on this device (item 5, E20b): the one
  /// its record holds, or a new one when it holds none — an auth key and a
  /// seal key pair minted, a normal queue created under the auth key, stored
  /// on the record, then subscribed (a queue nobody subscribes within 24 h
  /// is reaped). A queue another tab stored meanwhile wins and ours is
  /// deleted again, so a friend is never handed two queues of this device.
  ///
  /// [subscribe] false leaves the subscribe to the caller, which batches a
  /// whole pass's new queues into one frame: the box counts subscribe
  /// FRAMES against its per-IP limit (60 per 15 min).
  ///
  /// Order matters: the queue is created BEFORE it is stored because the
  /// record needs the address the box assigns. A process death in between
  /// leaves only an unsubscribed queue whose sid nobody was ever given — the
  /// reaper's case, not a lost message.
  Future<InboundQueueResult> ensureInbound(
    int peerUserId, {
    bool subscribe = true,
  }) async {
    final held = _store.byUserId(peerUserId)?.queues.firstOrNull;
    if (held != null) return InboundQueueCreated(held);
    final auth = _signer.mint();
    final seal = QueueSeal.mintKeyPair();
    final created = await _box.createQueue(QueueKind.normal, auth);
    if (created is! BoxOk<QueueAddress>) {
      return InboundQueueNotCreated(created);
    }
    final address = created.value;
    final queue = _material(address, auth, seal);
    ContactQueue? kept;
    final committed = await _store.update(peerUserId, (current) {
      if (current == null) return null;
      final existing = current.queues.firstOrNull;
      if (existing != null) {
        kept = existing;
        return null;
      }
      kept = queue;
      return current.copyWith(queues: [queue]);
    });
    final owned = BoxQueueAuth(rid: address.rid, key: auth);
    final stored = kept;
    if (!committed || stored == null || stored.rid != queue.rid) {
      await _box.deleteQueue(owned);
      return committed && stored != null
          ? InboundQueueCreated(stored)
          : const InboundQueueNotStored();
    }
    if (subscribe) await _box.subscribe([owned]);
    return InboundQueueCreated(queue);
  }

  /// This DEVICE's request queue (design §4.4; wire.md "First contact"): the
  /// one a stranger who searched this account seals a friend request into.
  /// Loaded from the store, or created, stored and only then subscribed, the
  /// [ensureInbound] order. A stored queue the box refuses on subscribe
  /// (deleted, or reaped after 90 unsubscribed days) is dropped and replaced
  /// once: its sid is public, and publishing a queue nobody reads loses every
  /// request sent to it.
  ///
  /// No push notifier is ever registered on it (owner, 2026-09-24): the
  /// device's one push token would link this public queue to the device's
  /// normal queues in a dump, so a friend request waits for the next open.
  ///
  /// Null when it cannot be known now: the store is closed, a newer build
  /// owns the row, the box did not answer, or the write did not commit. A
  /// row the store could not rule on is never minted over.
  Future<ContactQueue?> ensureRequest() => _ensureOwn(
    QueueKind.request,
    stored: () => _store.requestQueue,
    unsupported: () => _store.requestQueueUnsupported,
    claim: _store.claimRequestQueue,
    drop: _store.dropRequestQueue,
  );

  /// This DEVICE's SELF-queue (PR3.1 sibling queues, owner decision 27): a
  /// NORMAL queue every other device of the account sends into, the
  /// per-friend model applied to the own account. Kept in the sibling row
  /// (`ContactStore.siblingsKey`), created, claimed and subscribed exactly
  /// like [ensureRequest] — including the drop-and-replace of a queue the
  /// box refuses. Null for the same reasons.
  Future<ContactQueue?> ensureSelf() => _ensureOwn(
    QueueKind.normal,
    stored: () => _store.selfQueue,
    unsupported: () => _store.siblingsUnsupported,
    claim: _store.claimSelfQueue,
    drop: _store.dropSelfQueue,
  );

  /// Replaces this device's self-queue [current] (E6): a new normal queue,
  /// stored in ONE write that starts [current] retiring at [now] and drops
  /// every sibling entry outside [live], then subscribed. [current] stays
  /// subscribed until [retire] deletes it. Null when nothing was rotated —
  /// the box did not create one, or the store kept a different self-queue
  /// (the new one is then deleted again).
  Future<ContactQueue?> rotateSelf(
    ContactQueue current, {
    required Set<int> live,
    required DateTime now,
  }) async {
    final next = await _createOwn(
      QueueKind.normal,
      (candidate) => _store.rotateSelfQueue(
        candidate,
        replaces: current.rid,
        live: live,
        now: now,
      ),
    );
    final owned = next == null ? null : authOf(next);
    if (owned != null) await _box.subscribe([owned]);
    return next;
  }

  /// Deletes retiring self-queue [queue] from the box and then forgets it;
  /// false when the box did not confirm (tried again on the next check). A
  /// queue the box no longer knows counts as deleted.
  Future<bool> retire(RetiringSelfQueue queue) async {
    final owned = authOf(queue.queue);
    if (owned != null && await _box.deleteQueue(owned) is! BoxOk) return false;
    return await _store.dropRetiringSelfQueue(queue.queue.rid) ==
        SiblingWrite.stored;
  }

  /// One of this device's own queues: loaded from its row, or created, stored
  /// and only then subscribed. A stored queue the box refuses on subscribe
  /// (deleted, or reaped after 90 unsubscribed days) is dropped and replaced
  /// once.
  Future<ContactQueue?> _ensureOwn(
    QueueKind kind, {
    required ContactQueue? Function() stored,
    required bool Function() unsupported,
    required Future<ContactQueue?> Function(ContactQueue candidate) claim,
    required Future<bool> Function(String rid) drop,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_store.isOpen || unsupported()) return null;
      final queue = stored() ?? await _createOwn(kind, claim);
      if (queue == null) return null;
      final owned = authOf(queue);
      if (owned != null) {
        final answer = await _box.subscribe([owned]);
        final gone =
            answer is BoxOk<List<BoxRefusal>> &&
            answer.value.any((r) => boxB64(r.rid) == queue.rid);
        if (!gone) return queue;
      }
      if (!await drop(queue.rid)) return null;
    }
    return null;
  }

  Future<ContactQueue?> _createOwn(
    QueueKind kind,
    Future<ContactQueue?> Function(ContactQueue candidate) claim,
  ) async {
    final auth = _signer.mint();
    final seal = QueueSeal.mintKeyPair();
    final created = await _box.createQueue(kind, auth);
    if (created is! BoxOk<QueueAddress>) return null;
    final mine = _material(created.value, auth, seal);
    final kept = await claim(mine);
    if (kept?.rid != mine.rid) {
      // Another tab of this device claimed first, or nothing was stored:
      // this queue's sid is never handed out, so nobody may keep it alive.
      await _box.deleteQueue(BoxQueueAuth(rid: created.value.rid, key: auth));
    }
    return kept;
  }

  static ContactQueue _material(
    QueueAddress address,
    BoxAuthKey auth,
    QueueSealKeyPair seal,
  ) => ContactQueue(
    rid: boxB64(address.rid),
    sid: boxB64(address.sid),
    nid: boxB64(address.nid),
    authPriv: boxB64(auth.bytes),
    sealPriv: boxB64(seal.privateKey),
    sealPub: boxB64(seal.publicKey),
  );

  /// How to prove [queue] to the box; null for a stored shape this build
  /// cannot read (never guessed around: a wrong key only earns auth_failed).
  static BoxQueueAuth? authOf(ContactQueue queue) {
    final rid = boxB64Decode(queue.rid, kBoxRidBytes);
    final key = boxB64Decode(queue.authPriv, 64);
    if (rid == null || key == null) return null;
    return BoxQueueAuth(rid: rid, key: BoxAuthKey.fromBytes(key));
  }

  /// The seal key pair blobs to [queue] are opened with; null if unreadable.
  static QueueSealKeyPair? sealOf(ContactQueue queue) {
    final privateKey = boxB64Decode(queue.sealPriv, 32);
    final publicKey = boxB64Decode(queue.sealPub, 32);
    if (privateKey == null || publicKey == null) return null;
    return QueueSealKeyPair(privateKey: privateKey, publicKey: publicKey);
  }

  /// Every readable inbound queue on every record — `former` ones too: the
  /// peer may still be sending there, and an unsubscribed queue is reaped
  /// after 90 days — and every self-queue this device is retiring (E6): a
  /// sibling may still be sending there. What a connection subscribes.
  List<BoxQueueAuth> inbound() => [
    for (final record in _store.all)
      for (final queue in record.queues) ?authOf(queue),
    for (final retiring in _store.retiringSelfQueues) ?authOf(retiring.queue),
  ];
}
