import 'dart:convert';

import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Receipts and typing over the box (metadata-privacy slice (g), E61b): a
/// receiver keeps a peer's `rcpt`/`typ` envelope only when every field is
/// sound, and drops it whole otherwise.
void main() {
  List<String> wires(int n) => [
    for (var i = 0; i < n; i++) 'wire-${i.toString().padLeft(6, '0')}',
  ];

  String json(Map<String, dynamic> envelope) => jsonEncode(envelope);

  group('receipt', () {
    test('both kinds round-trip their wire ids in order', () {
      for (final kind in E2eReceiptKind.values) {
        final built = E2eEnvelope.buildReceipt(kind, ['wire-bbbbbb', 'wire-a01']);
        expect(built, {
          't': 'rcpt',
          'k': kind == E2eReceiptKind.delivered ? 'd' : 'r',
          'w': ['wire-bbbbbb', 'wire-a01'],
        });
        final parsed = E2eEnvelope.parseReceipt(json(built));
        expect(parsed?.kind, kind);
        expect(parsed?.wireIds, ['wire-bbbbbb', 'wire-a01']);
      }
    });

    test('carries 1 to 100 wire ids; 0 and 101 are refused whole', () {
      Map<String, dynamic> raw(List<String> w) => {
        't': 'rcpt',
        'k': 'd',
        'w': w,
      };
      expect(E2eEnvelope.parseReceipt(json(raw(wires(1))))?.wireIds, hasLength(1));
      expect(
        E2eEnvelope.parseReceipt(json(raw(wires(100))))?.wireIds,
        hasLength(100),
      );
      expect(E2eEnvelope.parseReceipt(json(raw(const []))), isNull);
      expect(E2eEnvelope.parseReceipt(json(raw(wires(101)))), isNull);
    });

    test('the builder refuses 0 and 101 wire ids', () {
      expect(
        () => E2eEnvelope.buildReceipt(E2eReceiptKind.read, const []),
        throwsRangeError,
      );
      expect(
        () => E2eEnvelope.buildReceipt(E2eReceiptKind.read, wires(101)),
        throwsRangeError,
      );
    });

    test('one unsound wire id drops the whole receipt', () {
      for (final bad in <Object?>['short', 'has space-00', 7, null, 'x' * 65]) {
        expect(
          E2eEnvelope.parseReceipt(
            json({
              't': 'rcpt',
              'k': 'r',
              'w': ['wire-good01', bad],
            }),
          ),
          isNull,
          reason: '$bad',
        );
      }
    });

    test('an unknown kind, a non-list `w` or another type is no receipt', () {
      for (final raw in <Map<String, dynamic>>[
        {'t': 'rcpt', 'k': 'x', 'w': wires(1)},
        {'t': 'rcpt', 'w': wires(1)},
        {'t': 'rcpt', 'k': 'd', 'w': 'wire-000000'},
        {'t': 'typ', 'k': 'd', 'w': wires(1)},
      ]) {
        expect(E2eEnvelope.parseReceipt(json(raw)), isNull, reason: '$raw');
      }
      expect(E2eEnvelope.parseReceipt('not json'), isNull);
    });
  });

  group('typing', () {
    test('both kinds round-trip on and off', () {
      for (final kind in E2eTypingKind.values) {
        for (final on in [true, false]) {
          final built = E2eEnvelope.buildTyping(kind, on: on);
          expect(built, {
            't': 'typ',
            'k': kind == E2eTypingKind.text ? 't' : 'v',
            'on': on,
          });
          final parsed = E2eEnvelope.parseTyping(json(built));
          expect(parsed?.kind, kind);
          expect(parsed?.on, on);
        }
      }
    });

    test('an unknown kind, a non-bool `on` or another type is dropped', () {
      for (final raw in <Map<String, dynamic>>[
        {'t': 'typ', 'k': 'x', 'on': true},
        {'t': 'typ', 'k': 't', 'on': 'yes'},
        {'t': 'typ', 'k': 't'},
        {'t': 'rcpt', 'k': 't', 'on': true},
      ]) {
        expect(E2eEnvelope.parseTyping(json(raw)), isNull, reason: '$raw');
      }
    });
  });
}
