import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chat's E2E pin (metadata-privacy item 4, decision 45, E19f): one
/// last-writer-wins register every device must settle the same way.
void main() {
  final t = DateTime.utc(2026, 9, 26, 12);
  BoxPin pin(DateTime at, [int s = 2, String w = 'wire-0000001']) =>
      BoxPin(at: at, senderId: s, wireId: w);

  test('a newer write wins, an older one loses, whatever it says', () {
    final later = t.add(const Duration(milliseconds: 1));
    expect(pin(later).supersedes(BoxPin(at: t)), isTrue);
    expect(BoxPin(at: later).supersedes(pin(t)), isTrue);
    expect(pin(t).supersedes(BoxPin(at: later)), isFalse);
    expect(BoxPin(at: t).supersedes(pin(later)), isFalse);
    expect(pin(t).supersedes(null), isTrue);
  });

  test(
    'a tie settles the same on every device: an unpin beats a pin, then the '
    'greater s:w — and nothing re-applies itself',
    () {
      expect(BoxPin(at: t).supersedes(pin(t)), isTrue);
      expect(pin(t).supersedes(BoxPin(at: t)), isFalse);
      expect(pin(t, 3).supersedes(pin(t)), isTrue);
      expect(pin(t).supersedes(pin(t, 3)), isFalse);
      expect(pin(t).supersedes(pin(t)), isFalse);
      expect(BoxPin(at: t).supersedes(BoxPin(at: t)), isFalse);
    },
  );

  test(
    'the register rides the contact record but never the contact backup: a '
    'pin must not move the server row',
    () {
      final record = ContactRecord(
        userId: 2,
        username: 'bob',
        tag: '0002',
        state: ContactState.friend,
        settings: ContactSettings(muted: true, boxPin: pin(t)),
      );
      final back = ContactRecord.fromJson(record.toJson());
      expect(back.settings.boxPin?.wire, (senderId: 2, wireId: 'wire-0000001'));
      expect(back.settings.boxPin?.at, t);
      final unpinned = ContactSettings.fromJson(
        ContactSettings(boxPin: BoxPin(at: t)).toJson(),
      );
      expect(unpinned.boxPin?.pinned, isFalse);
      expect(unpinned.boxPin?.at, t);

      final backup = record.toBackupJson();
      expect(backup['settings'], {'muted': true});
      expect(record.toJson()['settings'], containsPair('muted', true));
    },
  );

  // A friendship made over the box (metadata-privacy slice (f), E15c/E15d):
  // the record carries how it began, and the requests this device holds
  // undecrypted are this device's alone.
  group('box origin', () {
    final originAt = DateTime.utc(2026, 9, 27, 12);

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
            at: originAt,
            addresses: const [
              ContactOutbound(peerDeviceId: 2, sid: 'req-sid', sealPub: 'pub'),
            ],
            kept: [KeptRequest(deviceId: 2, signal: '3:AAAA', at: originAt)],
          ),
        );

        final back = ContactRecord.fromJson(record.toJson()).boxOrigin!;
        expect(back.at, originAt);
        expect(back.addresses.single.sid, 'req-sid');
        expect(back.kept.single.signal, '3:AAAA');
        expect(back.kept.single.deviceId, 2);

        final backup = record.toBackupJson();
        expect(backup['box'], {
          'at': originAt.millisecondsSinceEpoch,
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
  });
}
