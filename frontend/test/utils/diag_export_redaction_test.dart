import 'package:fireplace/utils/diag_export_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const durable = [
    '11-25 10:00:01 DECRYPT_FAIL | {senderId: 8123, msgId: 12, error: Bad Mac!}',
  ];
  const live = [
    '10:00:00 SOCKET_CONNECT | {userId: 4711}',
    '10:00:02 BOX_FRIEND_NOT_LIVE | {peer: 8123, device: 31}',
    '10:00:03 BOX_FRIEND_NOT_LIVE | {peer: 9001, device: 31}',
    '10:00:04 SOCKET_READY | {activeConvId: 990077, windowMs: 1500}',
    '10:00:05 DECRYPT_FAIL | {senderId: 9001, msgId: 13, error: Bad Mac!}',
  ];

  test('one id is one placeholder across lines and across both logs', () {
    final out = redactDiagForExport(durable, live, ownUserId: 4711);
    for (final id in ['4711', '8123', '9001', '990077', '31']) {
      expect(out, isNot(contains(id)), reason: 'id $id leaked');
    }
    expect(out, contains('SOCKET_CONNECT | {userId: me}'));
    final first = RegExp(r'senderId: (peer#\w+),').firstMatch(out)!.group(1);
    expect(out, contains('peer: $first, device: dev#1}'));
    // The second peer is a different placeholder, also stable.
    expect(out, contains('peer: peer#B, device: dev#1}'));
    expect(out, contains('senderId: peer#B, msgId: 13'));
    expect(out, contains('activeConvId: conv#1, windowMs: 1500'));
  });

  test('a list of peer ids is redacted element by element', () {
    final out = redactDiagForExport(
      const [],
      const [
        '10:00:00 PEER_IDENTITY_ADOPTED | {peerIds: [8123, 9001, 8123], rebuiltAddresses: [1, 2]}',
      ],
      ownUserId: 4711,
    );
    expect(out, contains('peerIds: [peer#A, peer#B, peer#A]'));
    // Device ids too: a rebuilt address is a device of a peer.
    expect(out, contains('rebuiltAddresses: [dev#1, dev#2]'));
    expect(out, isNot(contains('8123')));
    expect(out, isNot(contains('9001')));
  });

  test('an unknown key named like a person, chat or device fails closed', () {
    final out = redactDiagForExport(
      const [],
      const [
        '10:00:00 X | {friendIds: [55555], blockedContact: 777, lastConversation: 4242, newDeviceId: 6}',
      ],
    );
    expect(out, isNot(contains('55555')));
    expect(out, isNot(contains('777')));
    expect(out, isNot(contains('4242')));
    expect(out, contains('newDeviceId: dev#1'));
  });

  test('time, steps, counts, errors, versions and platform stay readable', () {
    final out = redactDiagForExport(
      const [],
      const [
        '10:00:00 BOX_ACCOUNT_GOODBYE | {told: 3, missed: 1, ms: 842}',
        '10:00:01 BOX_NOTIFIERS | {platform: android, version: 0.2.106, devices: 2, friends: 5}',
        '10:00:02 E2E_INIT_FAIL | {error: Exception: lookup spent, msgId: 77, ids: [901, 902]}',
        '10:00:03 SOCKET_READY | {activeConvId: -1, userId: -1}',
      ],
      ownUserId: 4711,
    );
    expect(
      out,
      contains('10:00:00 BOX_ACCOUNT_GOODBYE | {told: 3, missed: 1, ms: 842}'),
    );
    expect(
      out,
      contains('platform: android, version: 0.2.106, devices: 2, friends: 5'),
    );
    expect(
      out,
      contains('error: Exception: lookup spent, msgId: 77, ids: [901, 902]'),
    );
    expect(out, contains('activeConvId: -1, userId: -1'));
  });

  test('an id inside error text, a temp id and a storage prefix is redacted', () {
    final out = redactDiagForExport(
      const [],
      const [
        '10:00:00 SEND_FAIL | {tempId: temp_1760000000000_3_4711, error: box peer 8123: lookup spent}',
        '10:00:01 IDENTITY_RESIDUE_UNKNOWN | {prefix: e2e_4711_}',
        '10:00:02 DEVICELIST_PIN_ENTRY_SKIPPED | {userId: 4711, key: 8123}',
      ],
      ownUserId: 4711,
    );
    expect(out, isNot(contains('4711')));
    expect(out, isNot(contains('8123')));
    expect(out, contains('tempId: temp_1760000000000_3_me'));
    expect(out, contains('error: box peer peer#A: lookup spent'));
    expect(out, contains('prefix: e2e_me_'));
  });

  // Production ids are 2-3 digits; the error text of a failed decrypt or a
  // failed init names them without a person word next to them.
  group('ids in error text with short production ids', () {
    const noSession =
        '10:00:00 DECRYPT_SKIP | {reason: NoSessionException - No session for: 48:3}';
    const pins =
        '10:00:01 E2E_INIT_FAIL | {error: device-list pins for 62 are malformed}';

    test('a missing session names the peer and the device', () {
      final out = redactDiagForExport(const [], const [noSession]);
      expect(out, contains('No session for: peer#A:dev#1'));
      expect(out, isNot(contains('48')));
      expect(out, isNot(contains(':3')));
    });

    test('the same peer named on another line is the same placeholder', () {
      final out = redactDiagForExport(const [], const [
        '10:00:00 BOX_FRIEND_NOT_LIVE | {peer: 48, device: 3}',
        noSession,
      ]);
      expect(out, contains('peer: peer#A, device: dev#1'));
      expect(out, contains('No session for: peer#A:dev#1'));
    });

    test('pins of a user name the person, own id is me', () {
      var out = redactDiagForExport(const [], const [pins]);
      expect(out, contains('pins for peer#A are malformed'));
      expect(out, isNot(contains('62')));

      out = redactDiagForExport(const [], const [pins], ownUserId: 62);
      expect(out, contains('pins for me are malformed'));

      out = redactDiagForExport(const [], const [
        '10:00:00 SOCKET_CONNECT | {userId: 62}',
        pins,
      ], ownUserId: 62);
      expect(out, contains('pins for me are malformed'));
    });

    test('a bare id already named elsewhere is redacted at any length, '
        'a version number is not touched', () {
      final out = redactDiagForExport(const [], const [
        '10:00:00 BOX_FRIEND_NOT_LIVE | {peer: 48, version: 0.48.1}',
        '10:00:01 X | {error: gave up on 48 after retry}',
      ]);
      expect(out, contains('error: gave up on peer#A after retry'));
      expect(out, contains('version: 0.48.1'));
    });
  });
}
