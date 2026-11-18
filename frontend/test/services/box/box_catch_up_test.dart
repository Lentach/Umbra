import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/box/box_catch_up.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/services/plaintext_record_codec.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/box_fakes.dart';

void main() {
  final now = DateTime.utc(2026, 10, 16, 12);

  group('catchUpSince', () {
    test(
      'owes nothing without a stamp, after a short gap, or a future one',
      () {
        expect(catchUpSince(lastOnline: null, now: now), isNull);
        expect(
          catchUpSince(lastOnline: now.subtract(kCatchUpAbsence), now: now),
          isNull,
        );
        expect(
          catchUpSince(
            lastOnline: now.add(const Duration(hours: 1)),
            now: now,
          ),
          isNull,
        );
      },
    );

    test('asks from the stamp less the margin, at most 30 days back', () {
      final away = now.subtract(const Duration(hours: 5));
      expect(
        catchUpSince(lastOnline: away, now: now),
        away.subtract(kCatchUpMargin),
      );
      expect(
        catchUpSince(
          lastOnline: now.subtract(const Duration(days: 90)),
          now: now,
        ),
        now.subtract(kCatchUpReach),
      );
    });
  });

  test(
    'catchUpResponders: addressed only, most recently heard, then by id',
    () {
      final heard = {
        5: now.subtract(const Duration(days: 2)),
        7: now.subtract(const Duration(minutes: 5)),
      };
      expect(
        catchUpResponders(
          siblings: [9, 7, 5, 4, 2],
          addressed: {2, 4, 5, 7},
          lastHeard: (device) => heard[device],
        ),
        [7, 5, 2, 4],
      );
    },
  );

  test('catchUpRecords keeps the newest records within the byte cap', () {
    Map<String, dynamic> record(int minutesAgo, {String wire = 'wire-0000'}) =>
        {
          'content': 'x' * 100,
          'senderId': 2,
          PlaintextRecordCodec.conversationIdKey: 10,
          PlaintextRecordCodec.createdAtKey: now
              .subtract(Duration(minutes: minutesAgo))
              .millisecondsSinceEpoch,
          PlaintextRecordCodec.wireIdKey: '$wire$minutesAgo',
          PlaintextRecordCodec.wireSenderKey: 2,
        };
    const base = kFirstLocalMessageId;
    final records = {
      base + 1: record(30),
      base + 2: record(20),
      base + 3: record(10),
      // Before `since`.
      base + 4: record(120),
      // A server id: not a box message.
      5: record(5),
      // No wire id: the importer could not dedup it.
      base + 6: {...record(4)}..remove(PlaintextRecordCodec.wireIdKey),
    };
    final one = jsonEncode(jsonEncode(record(10))).length + 60;

    final picked = catchUpRecords(
      userId: 1,
      records: records,
      since: now.subtract(const Duration(hours: 1)),
      now: now,
      tombstoned: (_) => false,
      usable: (_, _) => true,
      maxBytes: 128 + 2 * one,
    );

    final prefix = HistoryBackupService.recordPrefix(1);
    expect(picked.keys, ['$prefix${base + 3}', '$prefix${base + 2}']);
  });

  test('catchUpRecords strips the link-preview thumbnail (C1)', () {
    final record = {
      'content': 'https://a.example',
      'linkPreviewTitle': 'T',
      'linkPreviewImage': 'A' * 10000,
      PlaintextRecordCodec.createdAtKey:
          now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
      PlaintextRecordCodec.wireIdKey: 'wire-1',
      PlaintextRecordCodec.wireSenderKey: 2,
    };
    final picked = catchUpRecords(
      userId: 1,
      records: {kFirstLocalMessageId + 1: record},
      since: now.subtract(const Duration(hours: 1)),
      now: now,
      tombstoned: (_) => false,
      usable: (_, _) => true,
    );
    final sent = jsonDecode(picked.values.single) as Map<String, dynamic>;
    expect(sent, isNot(contains('linkPreviewImage')));
    expect(sent['linkPreviewTitle'], 'T');
    expect(record, contains('linkPreviewImage'), reason: 'store untouched');
  });

  group('BoxCatchUpEnvelope', () {
    test('round-trips a request and a response', () {
      final since = DateTime.utc(2026, 10);
      expect(
        BoxCatchUpEnvelope.parseRequest(
          jsonEncode(BoxCatchUpEnvelope.request(since)),
        ),
        since,
      );
      final response = BoxCatchUpEnvelope.response(
        media: '${'A' * 42}E',
        key: base64Encode(List.filled(32, 1)),
        iv: base64Encode(List.filled(12, 2)),
        since: since,
        count: 3,
      );
      expect(
        BoxCatchUpEnvelope.parseResponse(jsonEncode(response)),
        isA<BoxCatchUpResponse>()
            .having((r) => r.count, 'count', 3)
            .having((r) => r.since, 'since', since),
      );
    });

    test('refuses a response with any unsound field', () {
      final sound = {
        't': E2eEnvelope.typeSyncResponse,
        'since': 1,
        'count': 1,
        'boxMedia': '${'A' * 42}E',
        'mediaKey': base64Encode(List.filled(32, 1)),
        'mediaIv': base64Encode(List.filled(12, 2)),
      };
      for (final broken in [
        {...sound, 't': E2eEnvelope.typeSyncRequest},
        {...sound, 'count': 0},
        {...sound, 'boxMedia': 'short'},
        {...sound, 'mediaKey': base64Encode(List.filled(16, 1))},
        {...sound, 'mediaIv': 'not base64!'},
        {...sound}..remove('since'),
      ]) {
        expect(
          BoxCatchUpEnvelope.parseResponse(jsonEncode(broken)),
          isNull,
          reason: '$broken',
        );
      }
    });
  });

  group('a catch-up blob sealed by this build (plan A1)', () {
    final cipher = PointyMediaCipher();
    final catchUp = BoxCatchUp(crypto: MediaCryptoService(cipher: cipher));

    Uint8List payloadOf(int records) => encodeCatchUpPayload(1, {
      for (var i = 1; i <= records; i++)
        '${HistoryBackupService.recordPrefix(1)}${kFirstLocalMessageId + i}':
            jsonEncode({
              'content': 'x' * 40,
              PlaintextRecordCodec.createdAtKey: 1000 + i,
              PlaintextRecordCodec.wireIdKey: 'wire-$i',
              PlaintextRecordCodec.wireSenderKey: 2,
            }),
    });

    test(
      'still reads on a 0.2.82 sibling, which parses the decrypted bytes as '
      'they are; this build reads it too',
      () async {
        final sealed = await catchUp.seal(payloadOf(3));
        final body = unframeMedia(frameMediaToRung(sealed.ciphertext))!;
        final key = base64Decode(sealed.keyBase64);
        final iv = base64Decode(sealed.ivBase64);

        // 0.2.82 opens the blob with the bare cipher: it knows no padding.
        final old = await cipher.open(key, iv, body);
        expect(decodeCatchUpPayload(1, old), hasLength(3));

        final current = await catchUp.crypto.decrypt(
          body,
          sealed.keyBase64,
          sealed.ivBase64,
        );
        expect(decodeCatchUpPayload(1, current), hasLength(3));
      },
    );

    test('the server sees its rung, never the history size', () async {
      for (final records in [1, 40]) {
        final framed = frameMediaToRung(
          (await catchUp.seal(payloadOf(records))).ciphertext,
        );
        expect(
          ByteData.sublistView(framed).getUint32(0),
          framed.length - 4,
          reason: '$records records',
        );
      }
    });
  });
}
