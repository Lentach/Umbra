import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/utils/e2e_envelope.dart';

void main() {
  group('E2eEnvelope', () {
    test('build includes mediaKey and mediaIv when provided', () {
      final map = E2eEnvelope.build(
        'hello',
        mediaKey: 'key123',
        mediaIv: 'iv456',
      );
      expect(map['mediaKey'], 'key123');
      expect(map['mediaIv'], 'iv456');
    });

    test('build omits mediaKey/mediaIv when null', () {
      final map = E2eEnvelope.build('hello');
      expect(map.containsKey('mediaKey'), isFalse);
      expect(map.containsKey('mediaIv'), isFalse);
    });

    test('parse returns mediaKey and mediaIv from JSON', () {
      final json = jsonEncode({
        'content': 'hi',
        'mediaKey': 'k',
        'mediaIv': 'iv',
      });
      final result = E2eEnvelope.parse(json);
      expect(result.mediaKey, 'k');
      expect(result.mediaIv, 'iv');
    });

    test('parse returns null mediaKey for legacy envelope', () {
      final json = jsonEncode({
        'content': 'legacy',
        'mediaUrl': 'https://res.cloudinary.com/demo/image/upload/x.jpg',
      });
      final result = E2eEnvelope.parse(json);
      expect(result.mediaKey, isNull);
      expect(result.mediaIv, isNull);
    });

    test(
      'media dimensions and ThumbHash survive a build -> parse round trip',
      () {
        final built = E2eEnvelope.build(
          '',
          messageType: 'IMAGE',
          mediaUrl: 'http://localhost:3000/media/msgs/image.bin',
          mediaKey: 'key',
          mediaIv: 'iv',
          mediaWidth: 3024,
          mediaHeight: 4032,
          mediaThumbHash: 'thumbhash-base64',
        );

        final result = E2eEnvelope.parse(jsonEncode(built));

        expect(result.mediaWidth, 3024);
        expect(result.mediaHeight, 4032);
        expect(result.mediaThumbHash, 'thumbhash-base64');
      },
    );

    test(
      'parse drops media geometry and ThumbHash when dimensions are unsafe',
      () {
        final cases = <({String name, Map<String, Object?> fields})>[
          (name: 'missing', fields: {}),
          (
            name: 'half-present',
            fields: {'mediaWidth': 640, 'mediaThumbHash': 'hash'},
          ),
          (
            name: 'wrong-type',
            fields: {
              'mediaWidth': '640',
              'mediaHeight': 480,
              'mediaThumbHash': 'hash',
            },
          ),
          (
            name: 'out-of-range',
            fields: {
              'mediaWidth': 32769,
              'mediaHeight': 480,
              'mediaThumbHash': 'hash',
            },
          ),
          (
            name: 'invalid',
            fields: {
              'mediaWidth': 0,
              'mediaHeight': -1,
              'mediaThumbHash': 'hash',
            },
          ),
        ];

        for (final c in cases) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': '', 'messageType': 'IMAGE', ...c.fields}),
          );

          expect(result.mediaWidth, isNull, reason: c.name);
          expect(result.mediaHeight, isNull, reason: c.name);
          expect(result.mediaThumbHash, isNull, reason: c.name);
        }
      },
    );

    test('parse drops invalid ThumbHash while keeping valid dimensions', () {
      final emptyHash = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'IMAGE',
          'mediaWidth': 640,
          'mediaHeight': 480,
          'mediaThumbHash': '',
        }),
      );
      expect(emptyHash.mediaWidth, 640);
      expect(emptyHash.mediaHeight, 480);
      expect(emptyHash.mediaThumbHash, isNull);

      final wrongTypeHash = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'IMAGE',
          'mediaWidth': 640,
          'mediaHeight': 480,
          'mediaThumbHash': 42,
        }),
      );
      expect(wrongTypeHash.mediaWidth, 640);
      expect(wrongTypeHash.mediaHeight, 480);
      expect(wrongTypeHash.mediaThumbHash, isNull);
    });

    test('build omits messageType for TEXT and includes it otherwise', () {
      final text = E2eEnvelope.build('hi');
      expect(
        text.containsKey('messageType'),
        isFalse,
        reason: 'TEXT is the wire default and must be elided',
      );

      final voice = E2eEnvelope.build('', messageType: 'VOICE');
      expect(voice['messageType'], 'VOICE');
    });

    test('parse defaults messageType to TEXT when absent', () {
      final result = E2eEnvelope.parse(jsonEncode({'content': 'hi'}));
      expect(result.messageType, 'TEXT');
    });

    test('parse rounds a fractional num mediaDuration', () {
      final result = E2eEnvelope.parse(
        jsonEncode({
          'content': '',
          'messageType': 'VOICE',
          'mediaDuration': 7.6,
        }),
      );
      expect(result.mediaDuration, 8);
    });

    test('linkPreview fields survive a build -> parse round trip', () {
      final built = E2eEnvelope.build(
        'check this out https://example.com',
        linkPreview: {
          'url': 'https://example.com',
          'title': 'Example',
          'imageUrl': 'https://example.com/og.png',
        },
      );
      final result = E2eEnvelope.parse(jsonEncode(built));
      expect(result.linkPreviewUrl, 'https://example.com');
      expect(result.linkPreviewTitle, 'Example');
      expect(result.linkPreviewImageUrl, 'https://example.com/og.png');
    });

    test('parse leaves linkPreview fields null when envelope has none', () {
      final result = E2eEnvelope.parse(jsonEncode({'content': 'hi'}));
      expect(result.linkPreviewUrl, isNull);
      expect(result.linkPreviewTitle, isNull);
      expect(result.linkPreviewImageUrl, isNull);
    });

    group('msgId (metadata-privacy PR2.1 wire id)', () {
      test('survives a build -> parse round trip', () {
        final built = E2eEnvelope.build(
          'hi',
          msgId: 'temp_1758700000000_7-m3x9k2a1',
        );
        final result = E2eEnvelope.parse(jsonEncode(built));
        expect(result.msgId, 'temp_1758700000000_7-m3x9k2a1');
      });

      test('is absent from an envelope built without one', () {
        expect(E2eEnvelope.build('hi'), isNot(contains('msgId')));
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).msgId, isNull);
      });

      // The value comes from a PEER and lands on this device's disk as a
      // record stamp; anything outside the sender's own minting shape (the
      // server's sendToken bound, 8..64 of [A-Za-z0-9_-]) is refused.
      test('parses to null when the peer sent a malformed one', () {
        final malformed = <Object?>[
          42,
          'short',
          'x' * 65,
          'has space in it',
          'semi;colon-token',
          <String, Object?>{'nested': true},
        ];
        for (final value in malformed) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'msgId': value}),
          );
          expect(result.msgId, isNull, reason: 'msgId $value');
          expect(result.content, 'hi', reason: 'the message still arrives');
        }
      });

      test('accepts both ends of the length bound', () {
        for (final value in ['a' * 8, 'Z' * 64]) {
          final result = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'msgId': value}),
          );
          expect(result.msgId, value);
        }
      });
    });

    group('t / ts (metadata-privacy PR3.1 box envelope, decision 13)', () {
      test('an envelope without t is a chat message — every old-path one', () {
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).type, 'msg');
        expect(E2eEnvelope.build('hi'), isNot(contains('t')));
      });

      test('t and ts survive a build -> parse round trip', () {
        final sentAt = DateTime.utc(2026, 9, 24, 12, 30, 5, 123);
        final built = E2eEnvelope.build('hi', type: 'goodbye', sentAt: sentAt);
        expect(built['t'], 'goodbye');
        expect(built['ts'], sentAt.millisecondsSinceEpoch);
        final parsed = E2eEnvelope.parse(jsonEncode(built));
        expect(parsed.type, 'goodbye');
        expect(parsed.sentAt, sentAt);
        expect(parsed.sentAt!.isUtc, isTrue);
      });

      test('a t that is not a string matches no type, never a message', () {
        for (final value in <Object>[1, true, <String>[], <String, Object>{}]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 't': value}),
          );
          expect(parsed.type, isNot('msg'), reason: '$value');
        }
      });

      test('a ts that is not a positive whole ms is absent, never a date', () {
        for (final value in <Object>[0, -1, 1.5, '1758700000000', 1 << 53]) {
          final parsed = E2eEnvelope.parse(
            jsonEncode({'content': 'hi', 'ts': value}),
          );
          expect(parsed.sentAt, isNull, reason: '$value');
        }
        expect(E2eEnvelope.parse(jsonEncode({'content': 'hi'})).sentAt, isNull);
      });
    });

    group('queue_handoff / queue_handoff_ack (sibling self-queues)', () {
      // Canonical unpadded base64url of 32 bytes: 42 free chars, then one of
      // the 16 whose low two bits are zero.
      final sid = '${'A' * 42}E';
      final sealPub = '${'b' * 42}w';

      test('a handoff round-trips its address under its own type', () {
        final json = jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
        );
        expect(E2eEnvelope.parse(json).type, E2eEnvelope.typeQueueHandoff);
        expect(E2eEnvelope.parseQueueHandoff(json), (sid: sid, sealPub: sealPub));
      });

      test('an ack round-trips the sid it acknowledges', () {
        final json = jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid));
        expect(E2eEnvelope.parse(json).type, E2eEnvelope.typeQueueHandoffAck);
        expect(E2eEnvelope.parseQueueHandoffAck(json), sid);
      });

      test('neither is ever read as a chat message', () {
        for (final built in [
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
          E2eEnvelope.buildQueueHandoffAck(sid: sid),
        ]) {
          expect(
            E2eEnvelope.parse(jsonEncode(built)).type,
            isNot(E2eEnvelope.typeMessage),
          );
        }
      });

      test('an address that is not a canonical 32-byte id is null — never '
          'stored, never sent to', () {
        for (final bad in [
          'short',
          '${'A' * 42}B', // spare bits set: not the canonical spelling
          '${'A' * 43}=',
          'A' * 44,
          42,
          null,
        ]) {
          expect(
            E2eEnvelope.parseQueueHandoff(
              jsonEncode({'t': 'queue_handoff', 'sid': bad, 'sealPub': sealPub}),
            ),
            isNull,
          );
          expect(
            E2eEnvelope.parseQueueHandoff(
              jsonEncode({'t': 'queue_handoff', 'sid': sid, 'sealPub': bad}),
            ),
            isNull,
          );
          expect(
            E2eEnvelope.parseQueueHandoffAck(
              jsonEncode({'t': 'queue_handoff_ack', 'sid': bad}),
            ),
            isNull,
          );
        }
      });

      test('the other type, or no JSON object at all, is null', () {
        final handoff = jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: sealPub),
        );
        final ack = jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid));
        expect(E2eEnvelope.parseQueueHandoff(ack), isNull);
        expect(E2eEnvelope.parseQueueHandoffAck(handoff), isNull);
        expect(E2eEnvelope.parseQueueHandoff('[1]'), isNull);
        expect(E2eEnvelope.parseQueueHandoffAck('not json'), isNull);
      });
    });
  });
}
