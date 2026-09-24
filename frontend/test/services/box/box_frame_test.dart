import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_length.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 11 + 5) & 0xff));

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
    'every chat, so no message the user may send is refused by the box',
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

  group('decode answers null for anything else', () {
    Uint8List body(List<int> header, [int signal = 8]) =>
        Uint8List.fromList([...header, ..._bytes(signal)]);

    test('an unknown version', () {
      expect(BoxFrame.decode(body([0x02, 0x02, 0x00, 0x01])), isNull);
      expect(BoxFrame.decode(body([0x00, 0x02, 0x00, 0x01])), isNull);
    });

    test('a kind that is not a Signal message — the request-queue range '
        'included, until first contact reads it', () {
      for (final kind in [0x00, 0x01, 0x04, 0x10, 0x11, 0xff]) {
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
