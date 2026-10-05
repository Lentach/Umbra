import 'dart:typed_data';

import '../contacts/contact_record.dart';
import 'box_wire.dart';

/// What one [BoxOutbox.deliver] came to (E93a).
enum BoxSendOutcome {
  /// The box answered ok: stored, or pushed for a `live` frame.
  taken,

  /// `queue_full`: that device has not read its queue for a while (128
  /// waiting, I3). Sending to it again before it drains is wasted, and
  /// every frame sealed to it moves its Signal chain further ahead.
  full,

  /// Anything else: another refusal, no answer, a seal that failed. A retry
  /// may still get through.
  failed,
}

/// The send side of the box (metadata-privacy PR3.1 slice (c)): what the
/// messaging send path needs, and nothing of how the box is reached.
/// `BoxSession` is the one implementation.
abstract interface class BoxOutbox {
  /// [peerUserId]'s box address per peer device id, from the contact record
  /// — whether or not the box is connected right now, so a covered peer's
  /// send fails at [deliver] instead of taking the old path. Empty when
  /// there is no record (the store is closed, or no such contact) or the
  /// peer is not a friend.
  Map<int, ContactOutbound> addressesFor(int peerUserId);

  /// This account's OWN other devices' self-queue addresses by device id
  /// (sibling queues part B, E5): where a sent copy goes. Only siblings
  /// whose handoff this device stored; whether a device is live is the own
  /// verified list's call, never this map's.
  Map<int, ContactOutbound> siblingAddresses();

  /// Every friend with at least one box address: the peers whose device
  /// lists the connect re-verifies (decision 21).
  Iterable<int> coveredPeers();

  /// Seals [body] (a `BoxFrame`) to [to] and sends it, kept as [mode] says
  /// (none = an ordinary send). [BoxSendOutcome.taken] only when the box
  /// answered ok; [BoxSendOutcome.full] when the queue is full.
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  });

  /// A fresh local message id (decision 14) for a message this device
  /// sends, from the counter box deliveries draw on; null when the store
  /// could not commit one.
  Future<int?> nextLocalId();

  /// Uploads [framed] (the file's ciphertext padded to a ladder rung,
  /// `frameMediaToRung`) ONCE, against [to]'s queue, whose daily budget pays
  /// (E17a). A bad address or a body off the ladder is refused with nothing
  /// sent.
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  );

  /// The framed body of media [id]; [BoxCode.notFound] once the box dropped
  /// it (14 days, D8) or never held it.
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id);
}
