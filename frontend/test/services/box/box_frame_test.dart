import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/services/box/box_envelope.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_length.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 11 + 5) & 0xff));

/// [plaintext] as the FIRST Signal message of a fresh session: the PreKey
/// header is the worst case a box frame carries.
Future<CiphertextMessage> _firstMessage(String plaintext) async {
  final bobIdentity = generateIdentityKeyPair();
  final bobPreKey = generatePreKeys(1, 1).single;
  final bobSigned = generateSignedPreKey(bobIdentity, 1);
  final alice = InMemorySignalProtocolStore(
    generateIdentityKeyPair(),
    generateRegistrationId(false),
  );
  const bob = SignalProtocolAddress('bob', 1);
  await SessionBuilder.fromSignalStore(alice, bob).processPreKeyBundle(
    PreKeyBundle(
      generateRegistrationId(false),
      1,
      bobPreKey.id,
      bobPreKey.getKeyPair().publicKey,
      bobSigned.id,
      bobSigned.getKeyPair().publicKey,
      bobSigned.signature,
      bobIdentity.getPublicKey(),
    ),
  );
  return SessionCipher.fromStore(
    alice,
    bob,
  ).encrypt(Uint8List.fromList(utf8.encode(plaintext)));
}

void main() {
  test('the body is v ‖ kind ‖ u16be device ‖ the raw Signal bytes', () {
    final signal = _bytes(3);
    final body = BoxFrame(
      kind: BoxFrameKind.preKey,
      senderDeviceId: 100,
      signal: signal,
    ).encode();
    expect(body, [0x01, 0x03, 0x00, 0x64, ...signal]);
  });

  test('decode reverses encode for both Signal kinds and the device bounds', () {
    for (final kind in BoxFrameKind.values) {
      for (final device in [1, 2, 100]) {
        final frame = BoxFrame(
          kind: kind,
          senderDeviceId: device,
          signal: _bytes(40),
        );
        final back = BoxFrame.decode(frame.encode())!;
        expect(back.kind, kind);
        expect(back.senderDeviceId, device);
        expect(back.signal, frame.signal);
      }
    }
  });

  test('the Signal string is what EncryptionService.decrypt reads', () {
    final signal = _bytes(9);
    expect(
      BoxFrame(
        kind: BoxFrameKind.whisper,
        senderDeviceId: 1,
        signal: signal,
      ).signalCiphertext,
      '2:${base64Encode(signal)}',
    );
    expect(
      BoxFrame(
        kind: BoxFrameKind.preKey,
        senderDeviceId: 1,
        signal: signal,
      ).signalCiphertext,
      '3:${base64Encode(signal)}',
    );
  });

  test(
    'what EncryptionService.encrypt answers becomes a frame of that kind, '
    'from our device; anything else is no frame',
    () {
      final signal = _bytes(9);
      for (final kind in BoxFrameKind.values) {
        final frame = BoxFrame.fromSignalCiphertext(
          '${kind.byte}:${base64Encode(signal)}',
          senderDeviceId: 7,
        )!;
        expect(frame.kind, kind);
        expect(frame.senderDeviceId, 7);
        expect(frame.signal, signal);
      }
      for (final bad in ['1:AQID', '4:AQID', ':AQID', '3:', '3:!!', 'AQID']) {
        expect(
          BoxFrame.fromSignalCiphertext(bad, senderDeviceId: 1),
          isNull,
          reason: bad,
        );
      }
    },
  );

  test('a body carrying the most Signal bytes still fits one sealed blob', () {
    const most = BoxFrame.maxSignalBytes;
    final frame = BoxFrame(
      kind: BoxFrameKind.whisper,
      senderDeviceId: 1,
      signal: _bytes(most),
    );
    expect(frame.encode(), hasLength(QueueSeal.maxBodyBytes));
    expect(
      () => BoxFrame(
        kind: BoxFrameKind.whisper,
        senderDeviceId: 1,
        signal: _bytes(most + 1),
      ).encode(),
      throwsArgumentError,
    );
  });

  test(
    'the longest message the composer accepts (isMessageWithinByteLimit), '
    'with a link preview, as a first (PreKey) message, fits one frame — in '
    'every chat, so no message the user may send is refused by the box; '
    "measured on a sibling's SENT COPY, the longest envelope (it adds `to`)",
    () async {
      // The composer's boundary in 3-byte characters: `{"content":"…"}` is
      // 14 bytes around the text, so this is the last length it takes.
      final text = '界' * ((AppConstants.maxEnvelopeBytes - 14) ~/ 3);
      expect(isMessageWithinByteLimit(text), isTrue);
      expect(isMessageWithinByteLimit('$text界'), isFalse);
      // A REAL Signal first message: the PreKey header is the worst case.
      final bobIdentity = generateIdentityKeyPair();
      final bobPreKey = generatePreKeys(1, 1).single;
      final bobSigned = generateSignedPreKey(bobIdentity, 1);
      final alice = InMemorySignalProtocolStore(
        generateIdentityKeyPair(),
        generateRegistrationId(false),
      );
      const bob = SignalProtocolAddress('bob', 1);
      await SessionBuilder.fromSignalStore(alice, bob).processPreKeyBundle(
        PreKeyBundle(
          generateRegistrationId(false),
          1,
          bobPreKey.id,
          bobPreKey.getKeyPair().publicKey,
          bobSigned.id,
          bobSigned.getKeyPair().publicKey,
          bobSigned.signature,
          bobIdentity.getPublicKey(),
        ),
      );
      final envelope = jsonEncode(
        E2eEnvelope.build(
          text,
          linkPreview: {
            'url': 'https://example.com/${'a' * 200}',
            'title': '標題' * 50,
            'imageUrl': 'https://example.com/${'i' * 200}.png',
          },
          senderListInfo: {
            'ownVersion': 12,
            'ownListHash': 'A' * 44,
            'peerVersion': 7,
            'peerListHash': 'B' * 44,
          },
          msgId: 'm' * 64,
          type: E2eEnvelope.typeMessage,
          sentAt: DateTime.utc(2026, 9, 24),
          sentTo: 0x7fffffff,
        ),
      );
      final message = await SessionCipher.fromStore(
        alice,
        bob,
      ).encrypt(Uint8List.fromList(utf8.encode(envelope)));
      expect(message.getType(), CiphertextMessage.prekeyType);
      expect(
        message.serialize().length,
        lessThanOrEqualTo(BoxFrame.maxSignalBytes),
      );
    },
  );

  test(
    'the longest text the composer accepts WITH a maximal quote (a '
    '256-byte snippet at its worst JSON escaping, a 64-char wire id, the '
    'largest sender id) and the longest timer, as a first (PreKey) message, '
    "fits one frame — the peer's envelope and the sibling's sent copy; a "
    'preview that would overflow is what goes, never the quote (E18c)',
    () async {
      final text = '界' * ((AppConstants.maxEnvelopeBytes - 14) ~/ 3);
      expect(isMessageWithinByteLimit(text), isTrue);
      // A control char is escaped `\u0001`: six JSON bytes per UTF-8 byte.
      final snippet = '\u0001' * E2eEnvelope.maxQuoteSnippetBytes;
      final built = boxEnvelope(
        text,
        ttl: 2592000,
        replyQuote: (
          wireId: 'w' * 64,
          senderId: 0x7fffffff,
          type: 'TEXT',
          snippet: snippet,
        ),
        senderListInfo: {
          'ownVersion': 12,
          'ownListHash': 'A' * 44,
          'peerVersion': 7,
          'peerListHash': 'B' * 44,
        },
        msgId: 'm' * 64,
        sentAt: DateTime.utc(2026, 9, 24),
        sentTo: 0x7fffffff,
        linkPreview: {
          'url': 'https://example.com/${'a' * 200}',
          'title': '標題' * 50,
          'imageUrl': 'https://example.com/${'i' * 200}.png',
        },
      );
      expect(built.linkPreview, isNull, reason: 'the preview went');
      for (final json in [built.json, built.copyJson]) {
        final parsed = E2eEnvelope.parse(json);
        expect(parsed.content, text);
        expect(parsed.replyQuote?.snippet, snippet);
        expect(parsed.ttl, 2592000);
        final message = await _firstMessage(json);
        expect(message.getType(), CiphertextMessage.prekeyType);
        expect(
          message.serialize().length,
          lessThanOrEqualTo(BoxFrame.maxSignalBytes),
        );
      }
      expect(E2eEnvelope.parse(built.copyJson).sentTo, 0x7fffffff);
    },
  );

  test('a device id outside 1..100 is a caller bug on encode', () {
    for (final device in [0, 101, 65535]) {
      expect(
        () => BoxFrame(
          kind: BoxFrameKind.whisper,
          senderDeviceId: device,
          signal: _bytes(4),
        ).encode(),
        throwsArgumentError,
      );
    }
  });

  group('account-bearing frames (request queue, sibling handoff)', () {
    test(
      'the body is v ‖ kind|0x10 ‖ u16be device ‖ u32be account ‖ Signal',
      () {
        final signal = _bytes(3);
        final body = BoxFrame(
          kind: BoxFrameKind.whisper,
          senderDeviceId: 2,
          senderUserId: 0x01020304,
          signal: signal,
        ).encode();
        expect(body, [0x01, 0x12, 0x00, 0x02, 1, 2, 3, 4, ...signal]);
      },
    );

    test('decode reads the sender account back; a normal frame has none', () {
      for (final kind in BoxFrameKind.values) {
        for (final account in [1, 42, 0xffffffff]) {
          final back = BoxFrame.decode(
            BoxFrame(
              kind: kind,
              senderDeviceId: 7,
              senderUserId: account,
              signal: _bytes(20),
            ).encode(),
          )!;
          expect(back.kind, kind);
          expect(back.senderDeviceId, 7);
          expect(back.senderUserId, account);
          expect(back.signal, _bytes(20));
        }
      }
      final normal = BoxFrame.decode(
        BoxFrame(
          kind: BoxFrameKind.preKey,
          senderDeviceId: 7,
          signal: _bytes(20),
        ).encode(),
      )!;
      expect(normal.senderUserId, isNull);
    });

    test('fromSignalCiphertext carries the account it is given', () {
      final frame = BoxFrame.fromSignalCiphertext(
        '3:${base64Encode(_bytes(5))}',
        senderDeviceId: 4,
        senderUserId: 9,
      )!;
      expect(BoxFrame.decode(frame.encode())!.senderUserId, 9);
    });

    test('the account header costs four Signal bytes: one more is a caller '
        'bug', () {
      expect(
        BoxFrame(
          kind: BoxFrameKind.whisper,
          senderDeviceId: 1,
          senderUserId: 1,
          signal: _bytes(BoxFrame.maxSignalBytes - 4),
        ).encode().length,
        QueueSeal.maxBodyBytes,
      );
      expect(
        () => BoxFrame(
          kind: BoxFrameKind.whisper,
          senderDeviceId: 1,
          senderUserId: 1,
          signal: _bytes(BoxFrame.maxSignalBytes - 3),
        ).encode(),
        throwsArgumentError,
      );
    });

    test('an account outside 1..2^32-1 is a caller bug on encode', () {
      for (final account in [0, -1, 0x100000000]) {
        expect(
          () => BoxFrame(
            kind: BoxFrameKind.whisper,
            senderDeviceId: 1,
            senderUserId: account,
            signal: _bytes(4),
          ).encode(),
          throwsArgumentError,
        );
      }
    });

    test('decode refuses account 0, a short header, and no Signal bytes', () {
      Uint8List body(List<int> header, [int signal = 8]) =>
          Uint8List.fromList([...header, ..._bytes(signal)]);
      expect(
        BoxFrame.decode(body([0x01, 0x12, 0x00, 0x01, 0, 0, 0, 0])),
        isNull,
      );
      expect(
        BoxFrame.decode(body([0x01, 0x13, 0x00, 0x01, 0, 0, 0, 1], 0)),
        isNull,
      );
      expect(
        BoxFrame.decode(Uint8List.fromList([0x01, 0x12, 0x00, 0x01, 0, 0])),
        isNull,
      );
      expect(
        BoxFrame.decode(body([0x01, 0x12, 0x00, 0x00, 0, 0, 0, 1])),
        isNull,
        reason: 'device 0',
      );
    });
  });

  group('decode answers null for anything else', () {
    Uint8List body(List<int> header, [int signal = 8]) =>
        Uint8List.fromList([...header, ..._bytes(signal)]);

    test('an unknown version', () {
      expect(BoxFrame.decode(body([0x02, 0x02, 0x00, 0x01])), isNull);
      expect(BoxFrame.decode(body([0x00, 0x02, 0x00, 0x01])), isNull);
    });

    test('a kind that is not a Signal message — the reserved range beside '
        'the account-bearing kinds included', () {
      for (final kind in [0x00, 0x01, 0x04, 0x10, 0x11, 0x14, 0x22, 0xff]) {
        expect(BoxFrame.decode(body([0x01, kind, 0x00, 0x01])), isNull);
      }
    });

    test('a device id outside 1..100', () {
      expect(BoxFrame.decode(body([0x01, 0x02, 0x00, 0x00])), isNull);
      expect(BoxFrame.decode(body([0x01, 0x02, 0x00, 0x65])), isNull);
      expect(BoxFrame.decode(body([0x01, 0x02, 0x01, 0x01])), isNull);
    });

    test('no Signal bytes, or not even a header', () {
      expect(BoxFrame.decode(body([0x01, 0x02, 0x00, 0x01], 0)), isNull);
      expect(BoxFrame.decode(Uint8List.fromList([0x01, 0x02, 0x00])), isNull);
      expect(BoxFrame.decode(Uint8List(0)), isNull);
    });
  });
}
