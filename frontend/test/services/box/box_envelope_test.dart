import 'dart:convert';

import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/services/box/box_envelope.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sentAt = DateTime.utc(2026, 9, 24);
  const senderListInfo = <String, dynamic>{
    'ownVersion': 12,
    'ownListHash': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'peerVersion': 7,
    'peerListHash': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  };

  ({String json, String copyJson, Map<String, String?>? linkPreview})
  envelope(String text, Map<String, String?>? preview) => boxEnvelope(
    text,
    senderListInfo: senderListInfo,
    msgId: 'm' * 64,
    sentAt: sentAt,
    sentTo: 0x7fffffff,
    linkPreview: preview,
  );

  Map<String, dynamic> decode(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  test('a preview that fits is kept', () {
    final preview = {'url': 'https://example.com/a', 'title': 'A page'};
    final built = envelope('see https://example.com/a', preview);
    expect(built.linkPreview, preview);
    expect(decode(built.json), containsPair('linkPreview', preview));
    expect(decode(built.copyJson), containsPair('linkPreview', preview));
    expect(decode(built.copyJson), containsPair('to', 0x7fffffff));
    expect(decode(built.json), isNot(contains('to')));
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
      for (final json in [built.json, built.copyJson]) {
        final decoded = decode(json);
        expect(decoded, isNot(contains('linkPreview')));
        expect(decoded, containsPair('content', text));
        expect(utf8.encode(json), hasLength(lessThanOrEqualTo(kBoxEnvelopeMaxBytes)));
      }
    },
  );

  test(
    'a preview that fits the peer envelope but not the longer sent copy is '
    'dropped from both, so every device shows the same message',
    () {
      const url = 'https://example.com/';
      int peerBytes(String title) => utf8
          .encode(
            jsonEncode(
              E2eEnvelope.build(
                'x',
                linkPreview: {'url': url, 'title': title},
                senderListInfo: senderListInfo,
                msgId: 'm' * 64,
                sentAt: sentAt,
              ),
            ),
          )
          .length;
      final title = 't' * (kBoxEnvelopeMaxBytes - peerBytes('') - 5);
      expect(peerBytes(title), kBoxEnvelopeMaxBytes - 5);

      final built = envelope('x', {'url': url, 'title': title});

      expect(built.linkPreview, isNull);
      expect(decode(built.json), isNot(contains('linkPreview')));
      expect(decode(built.copyJson), isNot(contains('linkPreview')));
    },
  );

  const quote = (
    wireId: 'temp_1758700000000_2-m3x9k2a1',
    senderId: 2,
    type: 'TEXT',
    snippet: 'the quoted words',
  );

  test(
    'the message type, timer and quote ride BOTH envelopes (item 3, '
    'E18a/E18b)',
    () {
      final built = boxEnvelope(
        '',
        messageType: 'PING',
        ttl: 60,
        replyQuote: quote,
        senderListInfo: senderListInfo,
        msgId: 'm' * 64,
        sentAt: sentAt,
        sentTo: 0x7fffffff,
      );
      for (final json in [built.json, built.copyJson]) {
        final parsed = E2eEnvelope.parse(json);
        expect(parsed.messageType, 'PING');
        expect(parsed.ttl, 60);
        expect(parsed.replyQuote, quote);
      }
    },
  );

  test(
    'at the longest text the composer accepts, a preview that would '
    'overflow is dropped — never the quote or the timer (E18c)',
    () {
      final text = 'a' * (AppConstants.maxEnvelopeBytes - 14);
      final built = boxEnvelope(
        text,
        ttl: 2592000,
        replyQuote: (
          wireId: 'w' * 64,
          senderId: 0x7fffffff,
          type: 'TEXT',
          snippet: '\u0001' * 256,
        ),
        senderListInfo: senderListInfo,
        msgId: 'm' * 64,
        sentAt: sentAt,
        sentTo: 0x7fffffff,
        linkPreview: {'url': 'https://example.com/', 'title': 't' * 3000},
      );

      expect(built.linkPreview, isNull);
      for (final json in [built.json, built.copyJson]) {
        final parsed = E2eEnvelope.parse(json);
        expect(parsed.linkPreviewUrl, isNull);
        expect(parsed.content, text);
        expect(parsed.ttl, 2592000);
        expect(parsed.replyQuote?.snippet, '\u0001' * 256);
        expect(parsed.replyQuote?.wireId, 'w' * 64);
        expect(utf8.encode(json), hasLength(lessThanOrEqualTo(kBoxEnvelopeMaxBytes)));
      }
    },
  );
}
