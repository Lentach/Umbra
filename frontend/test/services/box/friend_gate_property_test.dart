import 'dart:math';

import 'package:fireplace/services/box/box_friend_gate.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in box that records every write that passed the gate with the
/// identity of the permit it passed under.
class _FakeBox {
  _FakeBox(this.gate);

  final FriendGate gate;
  final List<({String sid, String? permitIdentity, int step})> written = [];

  void write(FriendPermit? permit, String sid, int step) {
    if (gate.refusalOf(permit, sid) != null) return;
    written.add((sid: sid, permitIdentity: permit?.identity, step: step));
  }
}

void main() {
  test('no write ever reaches an address that is not current for the pinned '
      'identity, under random interleavings', () {
    for (var seed = 0; seed < 300; seed++) {
      final rng = Random(seed);
      var anchor = 'A0';
      var n = 0;
      var address = ContactOutbound(
        peerDeviceId: 1,
        sid: 'Q0',
        sealPub: 'p',
        idk: anchor,
      );
      var judged = rng.nextBool();
      var calm = false;
      final gate = FriendGate(
        addressesOf: (_) => [address],
        anchorOf: (_) => anchor,
        journalJudged: () => judged,
      )..calmHeld = (_) => calm;
      final box = _FakeBox(gate);
      // Sends sealed under a permit that are still in flight.
      final inFlight = <(FriendPermit, String)>[];
      var steps = 0;

      void check() {
        for (final w in box.written.where((w) => w.step == steps)) {
          // The invariant is read at the moment of the write: the step that
          // wrote it is the current one, so the state is the state now.
          expect(w.sid, address.sid, reason: 'seed $seed: stored address');
          expect(address.idk, anchor, reason: 'seed $seed: address tag');
          expect(w.permitIdentity, anchor, reason: 'seed $seed: permit');
        }
      }

      for (; steps < 40; steps++) {
        switch (rng.nextInt(8)) {
          case 0: // accept: the anchor moves, the address is now stale
            anchor = 'A${++n}';
          case 1: // the handoff is read: a new queue under the pinned key
            address = ContactOutbound(
              peerDeviceId: 1,
              sid: 'Q$n.$steps',
              sealPub: 'p',
              idk: anchor,
            );
          case 2: // a send takes a permit and seals; it is written later
            final p = gate.permitFor(1, to: [address]);
            if (p != null) inFlight.add((p, address.sid));
          case 3: // an in-flight send is written (maybe long after sealing)
            if (inFlight.isNotEmpty) {
              final (p, sid) = inFlight.removeAt(rng.nextInt(inFlight.length));
              box.write(p, sid, steps);
            }
          case 4: // retry: a fresh permit and an immediate write
            final p = gate.permitFor(1, to: [address]);
            box.write(p, address.sid, steps);
          case 5: // reconnect / drain failure: nothing in the state moves
            break;
          case 6: // the journal is judged
            judged = true;
          case 7: // a calm hold comes and goes
            calm = !calm;
        }
        check();
      }
      // Whatever is still in flight is written now.
      for (final (p, sid) in inFlight) {
        box.write(p, sid, steps);
      }
      check();
    }
  });
}
