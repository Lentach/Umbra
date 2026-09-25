import 'dart:typed_data';

import '../contacts/contact_record.dart';

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

  /// Seals [body] (a `BoxFrame`) to [to] and sends it. True only when the
  /// box answered ok; a refusal, no answer and a seal that failed are all
  /// false.
  Future<bool> deliver(ContactOutbound to, Uint8List body);

  /// A fresh local message id (decision 14) for a message this device
  /// sends, from the counter box deliveries draw on; null when the store
  /// could not commit one.
  Future<int?> nextLocalId();
}
