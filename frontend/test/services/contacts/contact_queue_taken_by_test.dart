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
}
