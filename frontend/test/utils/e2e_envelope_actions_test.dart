import 'dart:convert';

import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Box message actions (metadata-privacy item 4, E19a/E19e): what a
/// receiver keeps from a peer's action envelope.
void main() {
  final at = DateTime.utc(2026, 9, 26, 12);

  String json(Map<String, dynamic> envelope) => jsonEncode(envelope);

  test('every type round-trips its target and its own fields', () {
    final react = E2eEnvelope.parseAction(
      json(
        E2eEnvelope.buildAction(
          E2eEnvelope.typeReact,
          targetSender: 7,
          targetWire: 'wire-0000001',
          sentAt: at,
          emoji: '👍🏽',
          on: true,
          sentTo: 9,
        ),
      ),
    );
    expect(react?.type, 'react');
    expect(react?.targetSender, 7);
    expect(react?.targetWire, 'wire-0000001');
    expect(react?.emoji, '👍🏽');
    expect(react?.on, isTrue);

    final pin = E2eEnvelope.parseAction(
      json(
        E2eEnvelope.buildAction(
          E2eEnvelope.typePin,
          targetSender: 7,
          targetWire: 'wire-0000001',
          sentAt: at,
          on: false,
        ),
      ),
    );
    expect(pin?.on, isFalse);

    final edit = E2eEnvelope.buildAction(
      E2eEnvelope.typeEdit,
      targetSender: 7,
      targetWire: 'wire-0000001',
      sentAt: at,
      content: 'new words',
    );
    expect(E2eEnvelope.parseAction(json(edit))?.type, 'edit');
    final fields = E2eEnvelope.parse(json(edit));
    expect(fields.content, 'new words');
    expect(fields.sentAt, at);
    expect(fields.msgId, isNull, reason: 'an action is not a message');

    expect(
      E2eEnvelope.parseAction(
        json(
          E2eEnvelope.buildAction(
            E2eEnvelope.typeDelete,
            targetSender: 7,
            targetWire: 'wire-0000001',
            sentAt: at,
          ),
        ),
      )?.type,
      'del',
    );
  });

  test('a malformed action is dropped whole', () {
    Map<String, dynamic> base(String t) => {
      't': t,
      'ts': at.millisecondsSinceEpoch,
      'tg': {'s': 7, 'w': 'wire-0000001'},
      if (t == 'react') 'e': '👍',
      if (t == 'react' || t == 'pin') 'on': true,
    };
    for (final t in ['react', 'pin', 'edit', 'del']) {
      expect(E2eEnvelope.parseAction(json(base(t))), isNotNull, reason: t);
      for (final bad in <Object?>[
        null,
        'x',
        {'s': 7},
        {'w': 'wire-0000001'},
        {'s': '7', 'w': 'wire-0000001'},
        {'s': 0, 'w': 'wire-0000001'},
        {'s': 7, 'w': 'short'},
        {'s': 7, 'w': 'has space in it'},
      ]) {
        expect(
          E2eEnvelope.parseAction(json({...base(t), 'tg': bad})),
          isNull,
          reason: '$t tg=$bad',
        );
      }
    }
    for (final t in ['react', 'pin']) {
      expect(E2eEnvelope.parseAction(json(base(t)..remove('on'))), isNull);
      expect(E2eEnvelope.parseAction(json({...base(t), 'on': 1})), isNull);
    }
    for (final e in <Object?>[null, '', 7, 'x' * 65]) {
      expect(
        E2eEnvelope.parseAction(json({...base('react'), 'e': e})),
        isNull,
        reason: 'emoji $e',
      );
    }
    expect(E2eEnvelope.parseAction(json({...base('del'), 't': 'msg'})), isNull);
    expect(E2eEnvelope.parseAction(json({...base('del'), 't': 'boom'})), isNull);
    expect(E2eEnvelope.parseAction('not json'), isNull);
  });
}
