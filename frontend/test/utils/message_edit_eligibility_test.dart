import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/utils/message_edit_eligibility.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _msg({
  int id = 100,
  MessageType messageType = MessageType.text,
  String content = 'hello',
  MessageDeliveryStatus deliveryStatus = MessageDeliveryStatus.sent,
  DateTime? createdAt,
}) =>
    MessageModel(
      id: id,
      content: content,
      senderId: 1,
      senderUsername: 'me',
      conversationId: 1,
      createdAt: createdAt ?? DateTime.now(),
      messageType: messageType,
      deliveryStatus: deliveryStatus,
    );

void main() {
  group('messageEditEligible', () {
    final now = DateTime(2026, 6, 22, 12, 0);

    test('true for own, sent, TEXT, fresh, real-plaintext row', () {
      expect(
        messageEditEligible(_msg(createdAt: now), isMine: true, now: now),
        isTrue,
      );
    });

    test('false when not mine', () {
      expect(
        messageEditEligible(_msg(createdAt: now), isMine: false, now: now),
        isFalse,
      );
    });

    test('false for non-TEXT', () {
      for (final t in [
        MessageType.image,
        MessageType.voice,
        MessageType.gif,
        MessageType.file,
        MessageType.ping,
      ]) {
        expect(
          messageEditEligible(_msg(messageType: t, createdAt: now),
              isMine: true, now: now),
          isFalse,
          reason: '$t must not be editable',
        );
      }
    });

    test('false for optimistic/unsent row (negative id or sending/failed)', () {
      expect(
        messageEditEligible(_msg(id: -5, createdAt: now), isMine: true, now: now),
        isFalse,
      );
      expect(
        messageEditEligible(
            _msg(deliveryStatus: MessageDeliveryStatus.sending, createdAt: now),
            isMine: true,
            now: now),
        isFalse,
      );
      expect(
        messageEditEligible(
            _msg(deliveryStatus: MessageDeliveryStatus.failed, createdAt: now),
            isMine: true,
            now: now),
        isFalse,
      );
    });

    test('false for placeholder / terminal content', () {
      for (final c in [
        '[encrypted]',
        '[Decryption failed]',
        '[Encryption not initialized]',
      ]) {
        expect(
          messageEditEligible(_msg(content: c, createdAt: now),
              isMine: true, now: now),
          isFalse,
        );
      }
    });

    test('false once past the 15-minute window', () {
      final old = now.subtract(const Duration(minutes: 16));
      expect(
        messageEditEligible(_msg(createdAt: old), isMine: true, now: now),
        isFalse,
      );
      final exactCutoff = now.subtract(kMessageEditWindow);
      expect(
        messageEditEligible(_msg(createdAt: exactCutoff), isMine: true, now: now),
        isFalse,
      );
      final justInside = now.subtract(const Duration(minutes: 14, seconds: 59));
      expect(
        messageEditEligible(_msg(createdAt: justInside), isMine: true, now: now),
        isTrue,
      );
    });

    test('delivered and read states are editable within window', () {
      for (final s in [
        MessageDeliveryStatus.delivered,
        MessageDeliveryStatus.read,
      ]) {
        expect(
          messageEditEligible(_msg(deliveryStatus: s, createdAt: now),
              isMine: true, now: now),
          isTrue,
        );
      }
    });

    test(
      'a box message (local id) is editable by its wire id, never without '
      'one (item 4, E19j)',
      () {
        final box = MessageModel(
          id: kFirstLocalMessageId + 3,
          content: 'hello',
          senderId: 1,
          senderUsername: 'me',
          conversationId: 1,
          createdAt: now,
          wireId: 'wire-0000001',
        );
        expect(messageEditEligible(box, isMine: true, now: now), isTrue);
        expect(
          messageEditEligible(
            MessageModel(
              id: box.id,
              content: box.content,
              senderId: 1,
              senderUsername: 'me',
              conversationId: 1,
              createdAt: now,
            ),
            isMine: true,
            now: now,
          ),
          isFalse,
        );
      },
    );
  });
}
