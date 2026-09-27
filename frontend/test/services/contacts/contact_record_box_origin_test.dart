import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// A friendship made over the box (metadata-privacy slice (f), E15c/E15d):
/// the record carries how it began, and the requests this device holds
/// undecrypted are this device's alone.
void main() {
  final t = DateTime.utc(2026, 9, 27, 12);

  test(
    'the origin round-trips on this device, but the contact backup carries '
    'no kept request: its Signal bytes are readable by this device alone',
    () {
      final record = ContactRecord(
        userId: 342,
        username: 'ana',
        tag: '0342',
        state: ContactState.pendingIn,
        boxOrigin: ContactBoxOrigin(
          at: t,
          addresses: const [
            ContactOutbound(peerDeviceId: 2, sid: 'req-sid', sealPub: 'pub'),
          ],
          kept: [KeptRequest(deviceId: 2, signal: '3:AAAA', at: t)],
        ),
      );

      final back = ContactRecord.fromJson(record.toJson()).boxOrigin!;
      expect(back.at, t);
      expect(back.addresses.single.sid, 'req-sid');
      expect(back.kept.single.signal, '3:AAAA');
      expect(back.kept.single.deviceId, 2);

      final backup = record.toBackupJson();
      expect(backup['box'], {
        'at': t.millisecondsSinceEpoch,
        'addr': [
          {'peerDeviceId': 2, 'sid': 'req-sid', 'sealPub': 'pub'},
        ],
      });
      expect(record.toJson()['box'], containsPair('kept', hasLength(1)));
    },
  );

  test('a friendship the server knows of carries no origin at all', () {
    const record = ContactRecord(
      userId: 7,
      username: 'bob',
      tag: '0007',
      state: ContactState.friend,
    );
    expect(record.toJson(), isNot(contains('box')));
    expect(record.toBackupJson(), isNot(contains('box')));
    expect(ContactRecord.fromJson(record.toJson()).boxOrigin, isNull);
  });
}
