import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../support/box_send_harness.dart';

Map<String, dynamic> _envelopeOf(BoxFrame frame) =>
    jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

/// What the media senders promise their callers (the composer sequences a
/// caption on them): a `true` only once the box took the frames, a visible
/// failure otherwise, geometry inside the envelope, and nothing on the
/// account socket.
void main() {
  late BoxSendHarness h;
  final photo = List<int>.generate(2000, (i) => i % 251);

  setUp(() async => h = await BoxSendHarness.create());
  tearDown(() => h.dispose());

  XFile image() => XFile.fromData(Uint8List.fromList(photo), name: 'a.jpg');

  MessageModel rowOf(MessageType type) =>
      h.provider.messages.lastWhere((m) => m.messageType == type);

  group('sendImageMessage ordering contract', () {
    test(
      'completes only after the box took the frames, and returns true',
      () async {
        h.bob([1]);
        final ok = await h.provider.sendImageMessage(image(), 2);

        expect(ok, isTrue);
        expect(h.outbox.delivered, hasLength(1));
        expect(
          _envelopeOf(h.outbox.delivered.single.$2),
          containsPair('messageType', 'IMAGE'),
        );
        expect(
          rowOf(MessageType.image).deliveryStatus,
          MessageDeliveryStatus.sent,
        );
        expect(h.emitted, isEmpty);
      },
    );

    test('two images started in the same millisecond both go out', () async {
      h.bob([1]);
      final both = await Future.wait([
        h.provider.sendImageMessage(image(), 2),
        h.provider.sendImageMessage(image(), 2),
      ]);

      expect(both, [true, true]);
      expect(h.outbox.uploads, hasLength(2));
      expect(h.outbox.delivered, hasLength(2));
    });

    test('returns false when E2E is not ready', () async {
      h.bob([1]);
      h.encryption.ready = false;

      expect(await h.provider.sendImageMessage(image(), 2), isFalse);
      expect(
        rowOf(MessageType.image).deliveryStatus,
        MessageDeliveryStatus.failed,
      );
      expect(h.outbox.delivered, isEmpty);
    });
  });

  group('sendVideoMessage', () {
    final clip = List<int>.generate(3000, (i) => i % 251);

    test(
      'carries geometry and ThumbHash inside the envelope, never outside',
      () async {
        h.bob([1]);
        final ok = await h.provider.sendVideoMessage(
          clip,
          2,
          duration: 4,
          width: 720,
          height: 1280,
          thumbHash: 'THASH',
        );

        expect(ok, isTrue);
        final envelope = _envelopeOf(h.outbox.delivered.single.$2);
        expect(envelope, containsPair('mediaWidth', 720));
        expect(envelope, containsPair('mediaHeight', 1280));
        expect(envelope, containsPair('mediaThumbHash', 'THASH'));
        expect(envelope, containsPair('mediaDuration', 4));
        expect(h.emitted, isEmpty);
      },
    );

    test('a RETRY after the upload succeeded still carries geometry and '
        'ThumbHash', () async {
      h.bob([1]);
      h.outbox.refuse.add(1);
      await h.provider.sendVideoMessage(
        clip,
        2,
        duration: 4,
        width: 720,
        height: 1280,
        thumbHash: 'THASH',
      );
      final failed = rowOf(MessageType.video);
      expect(failed.deliveryStatus, MessageDeliveryStatus.failed);
      expect(failed.mediaUrl, startsWith('box:'));

      h.outbox
        ..refuse.clear()
        ..delivered.clear();
      await h.provider.retryFailedMessage(failed.tempId!);
      await h.pump();

      final envelope = _envelopeOf(h.outbox.delivered.single.$2);
      expect(envelope, containsPair('mediaWidth', 720));
      expect(envelope, containsPair('mediaHeight', 1280));
      expect(envelope, containsPair('mediaThumbHash', 'THASH'));
      expect(h.outbox.uploads, hasLength(1), reason: 'never a second upload');
    });

    test(
      'rejects a clip longer than the duration cap without uploading',
      () async {
        h.bob([1]);
        final ok = await h.provider.sendVideoMessage(
          clip,
          2,
          duration: MediaCryptoService.maxVideoDurationSeconds + 1,
        );

        expect(ok, isFalse);
        expect(
          rowOf(MessageType.video).deliveryStatus,
          MessageDeliveryStatus.failed,
        );
        expect(h.outbox.uploads, isEmpty);
        expect(h.crypto.encrypted, isEmpty);
      },
    );

    test('accepts a clip exactly at the duration cap', () async {
      h.bob([1]);
      final ok = await h.provider.sendVideoMessage(
        clip,
        2,
        duration: MediaCryptoService.maxVideoDurationSeconds,
      );

      expect(ok, isTrue);
    });
  });

  group('voice and file', () {
    test('a voice note carries its duration, a file its name', () async {
      h.bob([1]);
      await h.provider.sendVoiceMessage(
        recipientId: 2,
        duration: 7,
        conversationId: 10,
        localAudioBytes: [1, 2, 3, 4],
      );
      await h.provider.sendFileMessage(
        [5, 6, 7],
        'plan.pdf',
        'application/pdf',
        2,
      );

      final [voice, file] = [
        for (final (_, frame) in h.outbox.delivered) _envelopeOf(frame),
      ];
      expect(voice, containsPair('messageType', 'VOICE'));
      expect(voice, containsPair('mediaDuration', 7));
      expect(file, containsPair('messageType', 'FILE'));
      expect(file, containsPair('content', 'plan.pdf'));
      expect(h.emitted, isEmpty);
    });
  });
}
