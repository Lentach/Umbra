import 'dart:convert';

import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/services/box/box_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sentAt = DateTime.utc(2026, 9, 24);
  const senderListInfo = <String, dynamic>{
    'ownVersion': 12,
    'ownListHash': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'peerVersion': 7,
    'peerListHash': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  };

  ({String json, Map<String, String?>? linkPreview}) envelope(
    String text,
    Map<String, String?>? preview,
  ) => boxEnvelope(
    text,
    senderListInfo: senderListInfo,
    msgId: 'm' * 64,
    sentAt: sentAt,
    linkPreview: preview,
  );

  test('a preview that fits is kept', () {
    final preview = {'url': 'https://example.com/a', 'title': 'A page'};
    final built = envelope('see https://example.com/a', preview);
    expect(built.linkPreview, preview);
    expect(
      (jsonDecode(built.json) as Map<String, dynamic>)['linkPreview'],
      preview,
    );
  });

  test(
    'a preview that would overflow the frame is dropped — the text is kept '
    'whole, even at the longest length the composer accepts',
    () {
      final text = 'a' * (AppConstants.maxEnvelopeBytes - 14);
      final built = envelope(text, {
        'url': 'https://example.com/',
        'title': '標' * 40000,
      });

      expect(built.linkPreview, isNull);
      final decoded = jsonDecode(built.json) as Map<String, dynamic>;
      expect(decoded.containsKey('linkPreview'), isFalse);
      expect(decoded['content'], text);
      expect(
        utf8.encode(built.json).length,
        lessThanOrEqualTo(kBoxEnvelopeMaxBytes),
      );
    },
  );
}
