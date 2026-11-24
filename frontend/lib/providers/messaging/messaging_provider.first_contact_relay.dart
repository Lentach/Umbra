part of '../messaging_provider.dart';

/// First contact's copies to our own devices, out of
/// [MessagingFirstContact] (E15e, E15j, E15k): one JSON copy to each live
/// sibling through its self-queue, and the `friend_accepted` copy every
/// device that becomes a friend sends.
extension MessagingFirstContactRelay on MessagingProvider {
  /// Sends [json] to each of our [devices] through its self-queue in
  /// [addresses] (E15e/E15j/E15k). True only when the box took every copy;
  /// a copy it did not take is also in the durable log.
  Future<bool> _relayToSiblings(
    Iterable<int> devices,
    Map<int, ContactOutbound> addresses,
    String json, {
    required int peer,
  }) async {
    final outbox = boxOutbox;
    if (outbox == null) return devices.isEmpty;
    var all = true;
    for (final device in devices) {
      final to = addresses[device];
      var taken = false;
      if (to != null) {
        try {
          final frame = await encryptForOwnDevice(device, json);
          // A relay carries no message: stored quiet, it never wakes our
          // closed device with an empty card (decision 91).
          taken =
              frame != null &&
              await outbox.deliver(
                    to,
                    frame.encode(),
                    mode: BoxSendMode.quiet,
                  ) ==
                  BoxSendOutcome.taken;
          // `avoid_catching_errors` is waived here: a copy too big for one
          // frame or seal is refused with an ArgumentError, and a refused
          // copy is a failed one, recorded below.
          // ignore: avoid_catching_errors
        } on ArgumentError {
          taken = false;
        }
      }
      if (!taken) {
        all = false;
        E2ePersistentDiag.record('BOX_SIBLING_COPY_FAILED', {
          'peer': peer,
          'device': device,
        });
      }
    }
    return all;
  }

  /// Our live siblings and their self-queue addresses; null when the own
  /// list cannot be verified now.
  Future<({List<int> devices, Map<int, ContactOutbound> addresses})?>
  _siblingTargets() async {
    final outbox = boxOutbox;
    final mine = await ownLiveDevices();
    if (outbox == null || mine == null) return null;
    return (
      devices: [
        for (final d in mine.live)
          if (d != mine.self) d,
      ],
      addresses: outbox.siblingAddresses(),
    );
  }

  Future<bool> _relayToAllSiblings(String json, {required int peer}) async {
    final siblings = await _siblingTargets();
    if (siblings == null) return false;
    return _relayToSiblings(
      siblings.devices,
      siblings.addresses,
      json,
      peer: peer,
    );
  }

  /// Tells our siblings [userId] is a friend over the box now (E15e): the
  /// `friend_accepted` copy, sent by EVERY device that becomes the friend
  /// (the accepter, the requester on the accept, a sibling on the
  /// account's handoff), so one that missed an earlier copy still befriends
  /// and hands the account its queue — decision 16 keeps the account from
  /// writing to us until every one of our devices has. A sibling already a
  /// friend ignores it. Built from what this device holds: the record's
  /// addresses, bundles and profile, and the account's kept list.
  Future<void> _relayFriendship(int userId, {FirstContactPeer? served}) async {
    final record = boxFirstContact?.firstContact.contactOf(userId);
    final origin = record?.boxOrigin;
    final peer =
        served ??
        (record == null || origin == null
            ? null
            : FirstContactPeer.fromSearchEntry({
                'id': userId,
                'username': record.username,
                'tag': record.tag,
                'authorization': _encryptionProvider
                    ?.cachedDeviceList(userId)
                    ?.authorization,
                'devices': [
                  for (final MapEntry(key: device, value: bundle)
                      in origin.bundles.entries)
                    {
                      'deviceId': device,
                      'bundle': bundle,
                      'requestSid': origin.addresses
                          .where((a) => a.peerDeviceId == device)
                          .firstOrNull
                          ?.sid,
                      'sealPub': origin.addresses
                          .where((a) => a.peerDeviceId == device)
                          .firstOrNull
                          ?.sealPub,
                    },
                ],
              }));
    if (peer == null) return;
    await _relayToAllSiblings(
      jsonEncode(
        E2eEnvelope.buildFriendRelay(
          E2eEnvelope.typeFriendAccepted,
          peer.toSiblingJson(),
        ),
      ),
      peer: userId,
    );
  }
}
