import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../support/box_send_harness.dart';
import '../support/chat_seed.dart';
import '../support/media_metadata_fixtures.dart';

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

  group('camera metadata never reaches the cipher (plan A2)', () {
    test('a photo goes out without GPS, Exif or XMP, still turned', () async {
      h.bob([1]);
      final photo = XFile.fromData(jpegWithCameraMetadata(), name: 'p.jpg');

      expect(await h.provider.sendImageMessage(photo, 2), isTrue);

      final sealed = h.crypto.encrypted.single;
      for (final secret in ['SECRET-GPS', 'SECRET-EXIF-MODEL', 'SECRET-XMP']) {
        expect(containsAscii(sealed, secret), isFalse, reason: secret);
      }
      expect(img.decodeJpgExif(sealed)!.imageIfd.orientation, 6);
    });

    test('a video goes out without its location, at its exact size', () async {
      h.bob([1]);
      final clip = mp4WithLocation();

      expect(await h.provider.sendVideoMessage(clip, 2), isTrue);

      final sealed = h.crypto.encrypted.single;
      expect(sealed.length, clip.length);
      expect(containsAscii(sealed, 'SECRET+52.2297'), isFalse);
      expect(containsAscii(clip, 'SECRET+52.2297'), isTrue);
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
      final fileOk = await h.provider.sendFileMessage(
        [5, 6, 7],
        'plan.pdf',
        'application/pdf',
        2,
      );
      expect(fileOk, isTrue);

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

  // Opening a chat reads this device's records and nothing else (decision
  // 99): a record stored under a pre-box (server) id is neither fetched nor
  // shown, whatever plaintext of it is still on disk.
  group('opening a chat (history)', () {
    Future<void> store(int id, String text, {required String wire}) =>
        h.encryption.store.saveDecryptedContent(
          id,
          {'content': text, 'senderId': 2},
          conversationId: 10,
          createdAt: DateTime.now().toUtc(),
          wire: (senderId: 2, wireId: wire),
        );

    test('a chat shows its box messages and never a record stored under a '
        'pre-box id, and emits nothing on the account socket', () async {
      await store(77, 'pre-box record', wire: 'wire-old');
      await store(kFirstLocalMessageId + 1, 'over the box', wire: 'wire-box');

      h.provider.getMessages(10);
      await h.pump(80);

      expect(h.provider.messages.map((m) => m.content), ['over the box']);
      expect(h.emitted, isEmpty);
    });
  });

  group('MessagingProvider media reply', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;

    setUp(() {
      provider = MessagingProvider();
      conversations = ConversationsProvider();
      seedConversations(conversations, [
        {
          'id': 10,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
      ]);
      provider.setConversationsProvider(conversations);
      provider.setCurrentUserId(1);
      provider.setToken('tok');
      provider.onConnect(false);
      conversations.openConversation(10);
      provider.setReplyingTo(
        MessageModel(
          id: 42,
          content: 'quoted text',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
    });

    test('sendImageMessage includes replyToMessageId in optimistic message', () async {
      await provider.sendImageMessage(
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'test.jpg'),
        2,
      );

      final optimistic = provider.messages.last;
      expect(optimistic.replyToMessageId, 42);
      expect(optimistic.replyTo?.id, 42);
      expect(optimistic.replyTo?.content, 'quoted text');
      expect(provider.replyingToMessage, isNull);
    });
  });
}
