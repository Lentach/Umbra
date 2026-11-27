import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// `takenBy` (review 3, P1/P2-2): every device that ever acknowledged or was
/// handed a queue. The anchor move and the re-announce clear the handoff
/// state; this set is never cleared by them.
void main() {
  final at = DateTime.utc(2026, 9, 26);
  const queue = ContactQueue(
    rid: 'r',
    sid: 's',
    nid: 'n',
    authPriv: 'ap',
    sealPriv: 'sp',
    sealPub: 'pub',
  );

  test('an ack and a handoff both add the device; clearing the handoff '
      'state leaves the set', () {
    final q = queue.withAck(3).withHanded(4, at);
    expect(q.takenBy, unorderedEquals([3, 4]));
    final cleared = q.withoutHandoffState();
    expect(cleared.ackedBy, isEmpty);
    expect(cleared.handedAt, isEmpty);
    expect(cleared.takenBy, unorderedEquals([3, 4]));
    expect(cleared.retired(at).takenBy, unorderedEquals([3, 4]));
  });

  test('it survives a write and a read', () {
    final q = ContactQueue.fromJson(
      queue.withAck(3).withoutHandoffState().toJson(),
    );
    expect(q.ackedBy, isEmpty);
    expect(q.takenBy, [3]);
  });

  test('a queue written before the field reads it as acked plus handed', () {
    final q = ContactQueue.fromJson({
      'rid': 'r',
      'sid': 's',
      'nid': 'n',
      'authPriv': 'ap',
      'sealPriv': 'sp',
      'sealPub': 'pub',
      'ackedBy': [3],
      'handedAt': {'4': at.millisecondsSinceEpoch},
    });
    expect(q.takenBy, unorderedEquals([3, 4]));
  });

  // Review 4, P2-1: the devices the upgrade one-shot cleared (`qs`) are
  // handed by any later pass only on a usable session.
  test('qs survives a write and a read, a retire and an old record reads it '
      'empty', () {
    final q = queue.withAck(3).withoutHandoffState(quiet: true);
    expect(q.quietCleared, [3]);
    expect(ContactQueue.fromJson(q.toJson()).quietCleared, [3]);
    expect(q.retired(at).quietCleared, [3]);
    expect(queue.toJson().containsKey('qs'), isFalse);
    expect(
      ContactQueue.fromJson({
        'rid': 'r',
        'sid': 's',
        'nid': 'n',
        'authPriv': 'ap',
        'sealPriv': 'sp',
        'sealPub': 'pub',
      }).quietCleared,
      isEmpty,
    );
  });

  test('a handoff or an ack of the device removes it from qs; an anchor '
      'move or a re-mint (a plain clear) removes them all', () {
    final q = queue
        .withAck(3)
        .withHanded(4, at)
        .withoutHandoffState(quiet: true);
    expect(q.quietCleared, unorderedEquals([3, 4]));
    expect(q.withHanded(3, at).quietCleared, [4]);
    expect(q.withAck(4).quietCleared, [3]);
    expect(q.withoutHandoffState().quietCleared, isEmpty);
  });
}
