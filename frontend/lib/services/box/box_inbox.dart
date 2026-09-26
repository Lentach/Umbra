import 'dart:async';
import 'dart:typed_data';

import '../../utils/e2e_persistent_diag.dart';
import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_client.dart';
import 'box_frame.dart';
import 'box_wire.dart';
import 'queue_keys.dart';
import 'queue_seal.dart';

/// Hands one journaled delivery to the app: decrypt, store, show. True when
/// the app is finished with it (stored, or refused for good); false to be
/// offered again by the next [BoxInbox.drain].
typedef BoxInboxConsumer = Future<bool> Function(BoxInboxEntry entry);

/// Takes every [BoxDelivery] off the box (metadata-privacy PR3.1 slice (b),
/// design §4.3): finds the queue, opens the seal, reads the [BoxFrame],
/// journals it, acks it, and offers it to [consumer].
///
/// Order, each step load-bearing — the box pushes at most 16 unacked blobs
/// per socket across EVERY queue, and re-pushes an unacked one only after a
/// resubscribe, so anything left unacked on a live socket stalls all of them:
///  * JOURNAL before ack. Once acked the box deletes the blob, so a delivery
///    the journal could not take (the store closed by a passcode re-lock, a
///    refused write) is HELD in RAM and retried by the next [drain].
///  * ACK before the app reads it, on its OWN chain: intake (journal + ack)
///    never waits for a read (E2E coming up, a device-list round trip), and
///    reads run one at a time on a second chain, in arrival order.
///  * An ack the box refused or never answered is sent again: a journal row
///    stays `acked: false` until the box confirms, and every [drain] re-acks
///    those; a refusal arms a timer for the next drain ([BoxRefused.retryAfter],
///    else [ackRetry]).
///  * A blob pushed again — its ack answer was lost — finds its journal row
///    and is only acked again: Signal never sees a ciphertext twice.
///  * Anything that is not a sealed, readable frame is acked and dropped:
///    nothing will ever read it.
///
/// This account's OWN other devices (siblings, PR3.1 sibling queues) reach it
/// on two queues, both journaled under the OWN account id — the store's:
/// this device's SELF-queue — and any it is retiring after a rotation —
/// (normal frames, like a friend's queue) and its
/// REQUEST queue, where only an account-bearing frame naming this very
/// account is read (the sibling address swap). Everything else on the
/// request queue is a stranger's and stays acked-and-dropped until first
/// contact (slice (f)).
class BoxInbox {
  BoxInbox({
    required BoxClient box,
    required ContactStore store,
    QueueSeal? seal,
    DateTime Function()? now,
    this.ackRetry = const Duration(seconds: 30),
  }) : _box = box,
       _store = store,
       _seal = seal ?? QueueSeal(),
       _now = now ?? DateTime.now;

  final BoxClient _box;
  final ContactStore _store;
  final QueueSeal _seal;
  final DateTime Function() _now;

  /// When a refused ack is tried again if the box named no time.
  final Duration ackRetry;

  /// The app's reader; null until it is wired, and meanwhile deliveries
  /// wait in the journal.
  BoxInboxConsumer? consumer;

  StreamSubscription<BoxDelivery>? _deliveries;
  bool _disposed = false;

  /// Journal + ack, one delivery at a time.
  Future<void> _intakes = Future<void>.value();

  /// Reads, one at a time, in the order they were queued.
  Future<void> _reads = Future<void>.value();
  final Set<String> _readQueued = <String>{};

  Timer? _ackTimer;

  /// Deliveries the journal could not take yet, keyed `rid.id`, in arrival
  /// order. Bounded by the socket window: the box pushes at most 16 unacked.
  final Map<String, BoxDelivery> _held = <String, BoxDelivery>{};

  /// Completes once everything queued so far — acks and reads — has run.
  Future<void> get idle async {
    await _intakes;
    await _reads;
  }

  void start() {
    _deliveries ??= _box.deliveries.listen(
      (d) => _chain(() => _intake(d)),
    );
  }

  /// Retries every held delivery, re-acks every journal row the box never
  /// confirmed, forgets read rows the box can no longer push, and queues a
  /// read of every journaled delivery the app has not finished with. Run
  /// whenever a reader may have become able to read — the box is ready, the
  /// store opened, E2E became ready — or a refused ack may be retried.
  Future<void> drain() => _chain(() async {
    for (final delivery in _held.values.toList()) {
      if (_disposed) return;
      await _intake(delivery);
    }
    if (!_store.isOpen) return;
    await _store.pruneInbox(_now());
    for (final entry in _store.unackedInbox) {
      if (_disposed) return;
      final auth = _authFor(entry.rid);
      final id = boxB64Decode(entry.id, kBoxMsgIdBytes);
      if (auth != null && id != null) await _ack(entry, auth, id);
    }
    _store.pendingInbox.forEach(_queueRead);
  });

  void dispose() {
    _disposed = true;
    _ackTimer?.cancel();
    unawaited(_deliveries?.cancel());
    _deliveries = null;
  }

  Future<void> _chain(Future<void> Function() step) {
    final run = _intakes.then((_) => _disposed ? null : step()).catchError((
      Object e,
    ) {
      E2ePersistentDiag.record('BOX_INBOX_FAILED', {
        'error': e.runtimeType.toString(),
      });
    });
    _intakes = run;
    return run;
  }

  Future<void> _intake(BoxDelivery delivery) async {
    final rid = boxB64(delivery.rid);
    final slot = '$rid.${boxB64(delivery.id)}';
    _held.remove(slot);
    if (!_store.isOpen) {
      _held[slot] = delivery;
      return;
    }
    final request = _store.requestQueue;
    if (request != null && request.rid == rid) {
      await _intakeRequest(delivery, slot, request);
      return;
    }
    final owner = _ownerOf(rid);
    if (owner == null) {
      // No record holds the queue any more (the contact is gone): nothing
      // will read it. The box client still holds its key from the
      // subscribe, so ack it and stop following.
      if (await _ackAndDrop(delivery, slot, _box.authFor(delivery.rid))) {
        _box.forget(delivery.rid);
      }
      return;
    }
    final (:peerUserId, :queue, :self) = owner;
    final auth = QueueKeys.authOf(queue);
    if (auth == null) return;

    final frame = await _open(queue, delivery);
    // A normal queue names its sender by itself: a frame claiming an
    // account is not one it carries.
    if (frame == null || frame.senderUserId != null) {
      E2ePersistentDiag.record('BOX_UNREADABLE', {'peer': peerUserId});
      await _ackAndDrop(delivery, slot, auth);
      return;
    }
    await _journal(delivery, slot, peerUserId, frame, auth, viaSelf: self);
  }

  /// A delivery on this device's request queue: journaled only when it is an
  /// account-bearing frame from THIS account (a sibling's handoff); any other
  /// — a stranger's first contact, a frame naming no account, one that does
  /// not open — is acked and dropped, as before sibling queues.
  Future<void> _intakeRequest(
    BoxDelivery delivery,
    String slot,
    ContactQueue request,
  ) async {
    final auth = QueueKeys.authOf(request);
    final own = _store.userId;
    final frame = await _open(request, delivery);
    if (auth == null ||
        own == null ||
        frame == null ||
        frame.senderUserId != own) {
      await _ackAndDrop(delivery, slot, auth);
      return;
    }
    await _journal(delivery, slot, own, frame, auth);
  }

  /// JOURNAL, then ack, then queue the read. [viaSelf]: it came in on one of
  /// this device's self-queues.
  Future<void> _journal(
    BoxDelivery delivery,
    String slot,
    int peerUserId,
    BoxFrame frame,
    BoxQueueAuth auth, {
    bool viaSelf = false,
  }) async {
    final entry = await _store.journalDelivery(
      rid: boxB64(delivery.rid),
      id: boxB64(delivery.id),
      peerUserId: peerUserId,
      senderDeviceId: frame.senderDeviceId,
      signal: frame.signalCiphertext,
      receivedAt: _now().toUtc(),
      viaSelfQueue: viaSelf,
    );
    if (entry == null) {
      _held[slot] = delivery;
      return;
    }
    await _ack(entry, auth, delivery.id);
    // A read row (a redelivery) is skipped by `_read`, which reads only what
    // the journal still lists as pending.
    _queueRead(entry);
  }

  /// Acks a journaled [entry]; the row records it only once the box
  /// confirms, and anything else arms the retry.
  Future<void> _ack(
    BoxInboxEntry entry,
    BoxQueueAuth auth,
    Uint8List id,
  ) async {
    final answer = await _box.ack(auth, id);
    if (answer is BoxOk<void>) {
      await _store.markInboxAcked(entry);
    } else {
      _retryAcksLater(answer);
    }
  }

  /// Acks a delivery nothing will read. One the box did not confirm is held
  /// (no journal row remembers it) and taken again by the retry's drain.
  Future<bool> _ackAndDrop(
    BoxDelivery delivery,
    String slot,
    BoxQueueAuth? auth,
  ) async {
    if (auth == null) return false;
    final answer = await _box.ack(auth, delivery.id);
    if (answer is BoxOk<void>) return true;
    _held[slot] = delivery;
    _retryAcksLater(answer);
    return false;
  }

  void _retryAcksLater(BoxResult<void> answer) {
    if (_disposed || _ackTimer != null) return;
    final wait = answer is BoxRefused<void> && answer.retryAfter != null
        ? answer.retryAfter!
        : ackRetry;
    _ackTimer = Timer(wait, () {
      _ackTimer = null;
      unawaited(drain());
    });
  }

  void _queueRead(BoxInboxEntry entry) {
    final slot = '${entry.rid}.${entry.id}';
    if (_disposed || consumer == null || !_readQueued.add(slot)) return;
    _reads = _reads
        .then((_) async {
          _readQueued.remove(slot);
          await _read(entry);
        })
        .catchError((Object e) {
          E2ePersistentDiag.record('BOX_CONSUME_FAILED', {
            'error': e.runtimeType.toString(),
          });
        });
  }

  Future<void> _read(BoxInboxEntry entry) async {
    final read = consumer;
    if (read == null || _disposed) return;
    // Read, stored and consumed while this read waited in the queue.
    if (!_store.pendingInbox.any((e) => e.rid == entry.rid && e.id == entry.id)) {
      return;
    }
    bool finished;
    try {
      finished = await read(entry);
    } on Object catch (e) {
      E2ePersistentDiag.record('BOX_CONSUME_FAILED', {
        'error': e.runtimeType.toString(),
      });
      finished = false;
    }
    if (finished) await _store.markInboxConsumed(entry);
  }

  Future<BoxFrame?> _open(ContactQueue queue, BoxDelivery delivery) async {
    final keys = QueueKeys.sealOf(queue);
    if (keys == null) return null;
    final body = await _seal.open(keys.privateKey, keys.publicKey, delivery.blob);
    return body == null ? null : BoxFrame.decode(body);
  }

  /// How to prove queue [rid]: its owner record's key, else the one the box
  /// client holds from the subscribe.
  BoxQueueAuth? _authFor(String rid) {
    final owner = _ownerOf(rid);
    if (owner != null) return QueueKeys.authOf(owner.queue);
    final bytes = boxB64Decode(rid, kBoxRidBytes);
    return bytes == null ? null : _box.authFor(bytes);
  }

  /// Which account queue [rid] reads for: a contact record's, or — this
  /// device's own self-queue (current or retiring, `self` true) and request
  /// queue — the own account.
  ({int peerUserId, ContactQueue queue, bool self})? _ownerOf(String rid) {
    for (final record in _store.all) {
      for (final queue in record.queues) {
        if (queue.rid == rid) {
          return (peerUserId: record.userId, queue: queue, self: false);
        }
      }
    }
    final own = _store.userId;
    if (own == null) return null;
    final request = _store.requestQueue;
    if (request?.rid == rid) {
      return (peerUserId: own, queue: request!, self: false);
    }
    for (final queue in [
      _store.selfQueue,
      for (final r in _store.retiringSelfQueues) r.queue,
    ]) {
      if (queue?.rid == rid) return (peerUserId: own, queue: queue!, self: true);
    }
    return null;
  }
}
