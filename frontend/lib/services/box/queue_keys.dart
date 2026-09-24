import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_signer.dart';
import 'box_wire.dart';
import 'queue_seal.dart';

sealed class InboundQueueResult {
  const InboundQueueResult();
}

/// The queue exists, is stored on the peer's record and is subscribed.
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

  /// Mints an auth key and a seal key pair, creates a normal queue under the
  /// auth key, stores it on [peerUserId]'s record, then subscribes it (a
  /// queue nobody subscribes within 24 h is reaped).
  ///
  /// Order matters: the queue is created BEFORE it is stored because the
  /// record needs the address the box assigns. A process death in between
  /// leaves only an unsubscribed queue whose sid nobody was ever given — the
  /// reaper's case, not a lost message.
  Future<InboundQueueResult> createInbound(int peerUserId) async {
    final auth = _signer.mint();
    final seal = QueueSeal.mintKeyPair();
    final created = await _box.createQueue(QueueKind.normal, auth);
    if (created is! BoxOk<QueueAddress>) {
      return InboundQueueNotCreated(created);
    }
    final address = created.value;
    final queue = _material(address, auth, seal);
    var attached = false;
    final committed = await _store.update(peerUserId, (current) {
      if (current == null) return null;
      attached = true;
      return current.copyWith(queues: [...current.queues, queue]);
    });
    final owned = BoxQueueAuth(rid: address.rid, key: auth);
    if (!committed || !attached) {
      await _box.deleteQueue(owned);
      return const InboundQueueNotStored();
    }
    await _box.subscribe([owned]);
    return InboundQueueCreated(queue);
  }

  /// This DEVICE's request queue (design §4.4; wire.md "First contact"): the
  /// one a stranger who searched this account seals a friend request into.
  /// Loaded from the store, or created, stored and only then subscribed, the
  /// [createInbound] order. A stored queue the box refuses on subscribe
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
  Future<ContactQueue?> ensureRequest() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_store.isOpen || _store.requestQueueUnsupported) return null;
      final queue = _store.requestQueue ?? await _createRequest();
      if (queue == null) return null;
      final owned = authOf(queue);
      if (owned != null) {
        final answer = await _box.subscribe([owned]);
        final gone =
            answer is BoxOk<List<BoxRefusal>> &&
            answer.value.any((r) => boxB64(r.rid) == queue.rid);
        if (!gone) return queue;
      }
      if (!await _store.dropRequestQueue(queue.rid)) return null;
    }
    return null;
  }

  Future<ContactQueue?> _createRequest() async {
    final auth = _signer.mint();
    final seal = QueueSeal.mintKeyPair();
    final created = await _box.createQueue(QueueKind.request, auth);
    if (created is! BoxOk<QueueAddress>) return null;
    final mine = _material(created.value, auth, seal);
    final kept = await _store.claimRequestQueue(mine);
    if (kept?.rid != mine.rid) {
      // Another tab of this device claimed first, or nothing was stored:
      // this queue's sid is never published, so nobody may keep it alive.
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
  /// after 90 days. What a connection subscribes.
  List<BoxQueueAuth> inbound() => [
    for (final record in _store.all)
      for (final queue in record.queues) ?authOf(queue),
  ];
}
