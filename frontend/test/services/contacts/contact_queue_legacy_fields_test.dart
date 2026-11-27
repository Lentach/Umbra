import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// A record written by an earlier dev build may carry fields this build does
/// not know (the removed probe's `pd`/`ps`): reading must not throw and the
/// next write must drop them.
void main() {
  test('a queue JSON carrying the removed probe fields reads, and is written '
      'back without them', () {
    final json = <String, dynamic>{
      'rid': 'r',
      'sid': 's',
      'nid': 'n',
      'authPriv': 'ap',
      'sealPriv': 'sp',
      'sealPub': 'pub',
      'ackedBy': [3],
      'pd': 3,
      'ps': 'oldstale',
      'zzUnknown': {'x': 1},
    };
    final queue = ContactQueue.fromJson(json);
    expect(queue.sid, 's');
    expect(queue.ackedBy, [3]);
    final back = queue.toJson();
    expect(back.containsKey('pd'), isFalse);
    expect(back.containsKey('ps'), isFalse);
    expect(back.containsKey('zzUnknown'), isFalse);
  });

  test('a whole record with such a queue reads', () {
    final record = ContactRecord.fromJson({
      'v': ContactRecord.currentVersion,
      'userId': 5,
      'username': 'friend5',
      'tag': '0005',
      'state': 'friend',
      'queues': [
        {
          'rid': 'r',
          'sid': 's',
          'nid': 'n',
          'authPriv': 'ap',
          'sealPriv': 'sp',
          'sealPub': 'pub',
          'pd': 3,
          'ps': 'oldstale',
        },
      ],
    });
    expect(record.queues.single.sid, 's');
  });
}
