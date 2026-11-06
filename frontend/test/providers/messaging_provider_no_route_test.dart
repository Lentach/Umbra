import 'dart:async';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart'
    show AccountIdentityMismatch;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

import '../support/box_send_harness.dart';

/// The box is the only path (metadata-privacy step 5): a send to a friend
/// this device holds no route for FAILS where the user sees it — red row,
/// 'Ponów' — and nothing is emitted, uploaded or fetched.
void main() {
  late BoxSendHarness h;

  setUp(() async => h = await BoxSendHarness.create());
  tearDown(() => h.dispose());

  /// Bob has handed this device no queue at all.
  void expectNothingLeft() {
    expect(h.emitted, isEmpty, reason: 'no account-socket emit');
    expect(h.outbox.uploads, isEmpty, reason: 'no upload');
    expect(h.outbox.delivered, isEmpty, reason: 'no frame');
  }

  MessageModel lastRow() => h.provider.messages.last;

  test('a text fails, is kept on the device, and its retry goes out once a '
      'route exists', () async {
    h.provider.sendMessage('no route yet');
    await h.pump();

    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
    expect(await h.encryption.boxUnsent(1, 10), hasLength(1));

    h.bob([1]);
    await h.pump();
    await h.provider.retryFailedMessage(lastRow().tempId!);
    await h.pump();

    expect(h.outbox.delivered, hasLength(1));
    expect(
      h.provider.messages
          .singleWhere((m) => m.content == 'no route yet')
          .deliveryStatus,
      MessageDeliveryStatus.sent,
    );
    expect(h.emitted, isEmpty);
  });

  test('a ping fails the same way', () async {
    h.provider.sendPing(2);
    await h.pump();

    expect(lastRow().messageType, MessageType.ping);
    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
  });

  test(
    'an image fails before any upload, and its retry uploads once',
    () async {
      final ok = await h.provider.sendImageMessage(
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'a.jpg'),
        2,
      );

      expect(ok, isFalse);
      expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
      expectNothingLeft();

      h.bob([1]);
      await h.pump();
      await h.provider.retryFailedMessage(lastRow().tempId!);
      await h.pump();

      expect(h.outbox.uploads, hasLength(1));
      expect(h.crypto.encrypted, hasLength(1), reason: 'never re-encrypted');
      expect(lastRow().deliveryStatus, MessageDeliveryStatus.sent);
    },
  );

  test('a voice note fails before any upload', () async {
    await h.provider.sendVoiceMessage(
      recipientId: 2,
      duration: 3,
      conversationId: 10,
      localAudioBytes: [1, 2, 3],
    );

    expect(lastRow().messageType, MessageType.voice);
    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
  });

  test('a video fails before any upload', () async {
    final ok = await h.provider.sendVideoMessage([1, 2, 3], 2, duration: 2);

    expect(ok, isFalse);
    expect(lastRow().messageType, MessageType.video);
    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
  });

  test('a GIF fails before any upload', () async {
    await http.runWithClient(
      () => h.provider.sendGif('https://giphy.test/a.gif', 2),
      () => MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
    );

    expect(lastRow().messageType, MessageType.gif);
    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
  });

  test('a file fails before any upload', () async {
    await h.provider.sendFileMessage([1, 2, 3], 'a.pdf', 'application/pdf', 2);

    expect(lastRow().messageType, MessageType.file);
    expect(lastRow().deliveryStatus, MessageDeliveryStatus.failed);
    expectNothingLeft();
  });

  group('send guards', () {
    test('an anchor refusal marks THAT row, a timeout does not', () async {
      h.bob([1]);
      h.encryption.encryptError = const AccountIdentityMismatch(
        userId: 2,
        deviceId: 1,
      );
      await h.provider.encryptAndSendForTest(
        recipientId: 2,
        content: 'blocked',
        tempId: 'temp_refused',
      );
      await h.pump();

      expect(h.provider.sendRefusedForIdentity('temp_refused'), isTrue);

      h.encryption.encryptError = TimeoutException('timed out');
      await h.provider.encryptAndSendForTest(
        recipientId: 2,
        content: 'timed out',
        tempId: 'temp_timeout',
      );
      await h.pump();

      expect(
        h.provider.sendRefusedForIdentity('temp_timeout'),
        isFalse,
        reason: "a timeout is worth retrying; it must not read as a key change",
      );
    });

    test(
      'a tempId goes out exactly once; a retry after a failure is allowed',
      () async {
        h.bob([1]);
        h.outbox.refuse.add(1);
        await h.provider.encryptAndSendForTest(
          recipientId: 2,
          content: 'once',
          tempId: 'temp_once',
        );
        await h.pump();
        expect(h.outbox.delivered, hasLength(1));

        h.outbox.refuse.clear();
        await h.provider.encryptAndSendForTest(
          recipientId: 2,
          content: 'once',
          tempId: 'temp_once',
        );
        await h.pump();
        expect(h.outbox.delivered, hasLength(2), reason: 'retry after failure');

        await h.provider.encryptAndSendForTest(
          recipientId: 2,
          content: 'once',
          tempId: 'temp_once',
        );
        await h.pump();
        expect(
          h.outbox.delivered,
          hasLength(2),
          reason: 'a sent one never again',
        );
      },
    );
  });
}
