import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_length.dart';

void main() {
  int envelopeBytes(String s) =>
      utf8.encode(jsonEncode(E2eEnvelope.build(s))).length;

  const limit = AppConstants.maxEnvelopeBytes;

  group('isMessageWithinByteLimit', () {
    test('short ASCII is within limit', () {
      expect(isMessageWithinByteLimit('Hello, world!'), isTrue);
    });

    test('the boundary is the ENVELOPE size: `{"content":""}` is 14 bytes', () {
      expect(isMessageWithinByteLimit('a' * (limit - 14)), isTrue);
      expect(isMessageWithinByteLimit('a' * (limit - 13)), isFalse);
    });

    test('gates multi-byte emoji by bytes, not character count', () {
      // 4-byte emoji: the UTF-8 size is over the limit while the UTF-16
      // length is about half of it, so a naive char/length check would pass.
      final s = '\u{1F600}' * (limit ~/ 4 + 1);
      expect(s.length < limit, isTrue);
      expect(
        isMessageWithinByteLimit(s),
        isFalse,
        reason: 'byte size, not char count, must gate emoji',
      );
    });

    test('measures escape-heavy content after JSON encoding', () {
      // Quotes double under JSON escaping; a raw-length check would pass.
      final s = '"' * (limit ~/ 2);
      expect(s.length <= limit, isTrue);
      expect(envelopeBytes(s) > limit, isTrue);
      expect(isMessageWithinByteLimit(s), isFalse);
    });
  });
}
