import 'package:fireplace/models/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Defends the CLAUDE.md invariant: "Message model copyWith must include every
/// field. Missing fields silently drop data." mediaKey/mediaIv loss is
/// unrecoverable (one-shot media keys), so a copyWith that forgets a field is
/// a silent-data-loss bug, not a style issue.
void main() {
  // Every field set to a distinct, non-default value.
  final full = MessageModel(
    id: 42,
    content: 'plaintext body',
    senderId: 7,
    senderUsername: 'alice',
    conversationId: 99,
    createdAt: DateTime.utc(2026, 3, 1, 10, 30),
    deliveryStatus: MessageDeliveryStatus.delivered,
    expiresAt: DateTime.utc(2026, 3, 2, 10, 30),
    disappearAfterSeconds: 3600,
    messageType: MessageType.image,
    mediaUrl: 'http://localhost:3000/media/msgs/blob.bin',
    mediaDuration: 12,
    mediaWidth: 1920,
    mediaHeight: 1080,
    mediaThumbHash: 'thumb-hash-b64',
    tempId: 'temp_123_7',
    reactions: const {
      '🔥': [7, 8],
    },
    replyToMessageId: 41,
    replyTo: const ReplyToPreview(
      id: 41,
      content: 'original',
      senderUsername: 'bob',
      messageType: MessageType.text,
    ),
    linkPreviewUrl: 'https://example.com',
    linkPreviewTitle: 'Example',
    linkPreviewImage: 'AAAA',
    encryptedContent: '3:AAAA',
    mediaKey: 'aes-key-b64',
    mediaIv: 'aes-iv-b64',
    editedAt: DateTime.utc(2026, 3, 1, 10, 45),
  );

  /// Field-by-field equality so a failure names the dropped field.
  void expectAllFieldsEqual(MessageModel actual, MessageModel expected) {
    expect(actual.id, expected.id, reason: 'id');
    expect(actual.content, expected.content, reason: 'content');
    expect(actual.senderId, expected.senderId, reason: 'senderId');
    expect(actual.senderUsername, expected.senderUsername,
        reason: 'senderUsername');
    expect(actual.conversationId, expected.conversationId,
        reason: 'conversationId');
    expect(actual.createdAt, expected.createdAt, reason: 'createdAt');
    expect(actual.deliveryStatus, expected.deliveryStatus,
        reason: 'deliveryStatus');
    expect(actual.expiresAt, expected.expiresAt, reason: 'expiresAt');
    expect(actual.disappearAfterSeconds, expected.disappearAfterSeconds,
        reason: 'disappearAfterSeconds');
    expect(actual.messageType, expected.messageType, reason: 'messageType');
    expect(actual.mediaUrl, expected.mediaUrl, reason: 'mediaUrl');
    expect(actual.mediaDuration, expected.mediaDuration,
        reason: 'mediaDuration');
    expect(actual.mediaWidth, expected.mediaWidth, reason: 'mediaWidth');
    expect(actual.mediaHeight, expected.mediaHeight, reason: 'mediaHeight');
    expect(actual.mediaThumbHash, expected.mediaThumbHash,
        reason: 'mediaThumbHash');
    expect(actual.tempId, expected.tempId, reason: 'tempId');
    expect(actual.reactions, expected.reactions, reason: 'reactions');
    expect(actual.replyToMessageId, expected.replyToMessageId,
        reason: 'replyToMessageId');
    expect(actual.replyTo?.id, expected.replyTo?.id, reason: 'replyTo.id');
    expect(actual.replyTo?.content, expected.replyTo?.content,
        reason: 'replyTo.content');
    expect(actual.linkPreviewUrl, expected.linkPreviewUrl,
        reason: 'linkPreviewUrl');
    expect(actual.linkPreviewTitle, expected.linkPreviewTitle,
        reason: 'linkPreviewTitle');
    expect(actual.linkPreviewImage, expected.linkPreviewImage,
        reason: 'linkPreviewImage');
    expect(actual.encryptedContent, expected.encryptedContent,
        reason: 'encryptedContent');
    expect(actual.mediaKey, expected.mediaKey, reason: 'mediaKey');
    expect(actual.mediaIv, expected.mediaIv, reason: 'mediaIv');
    expect(actual.editedAt, expected.editedAt, reason: 'editedAt');
  }

  group('MessageModel.copyWith preservation', () {
    test('copyWith() with no args preserves every field', () {
      expectAllFieldsEqual(full.copyWith(), full);
    });

    test('copyWith(content) changes only content', () {
      final copied = full.copyWith(content: 'changed');
      expect(copied.content, 'changed');
      expectAllFieldsEqual(copied.copyWith(content: full.content), full);
    });

    test(
        'unrelated copyWith preserves the unrecoverable media envelope fields',
        () {
      // The exact production shape: delivery-status patches must never drop
      // mediaKey/mediaIv — the one-shot keys have no other surviving copy.
      final patched =
          full.copyWith(deliveryStatus: MessageDeliveryStatus.read);
      expect(patched.mediaKey, 'aes-key-b64');
      expect(patched.mediaIv, 'aes-iv-b64');
      expect(patched.mediaUrl, full.mediaUrl);
      expect(patched.encryptedContent, full.encryptedContent);
      expect(patched.tempId, full.tempId);
      expect(patched.reactions, full.reactions);
    });

    test('fromJson(fully-populated row) -> copyWith() drops nothing', () {
      // Guards against a NEW field being added to fromJson but forgotten in
      // copyWith: parse a maximal server row, no-arg copy, compare all fields.
      final parsed = MessageModel.fromJson({
        'id': 42,
        'content': 'plaintext body',
        'senderId': 7,
        'senderUsername': 'alice',
        'conversationId': 99,
        'createdAt': '2026-03-01T10:30:00.000Z',
        'deliveryStatus': 'DELIVERED',
        'expiresAt': '2026-03-02T10:30:00.000Z',
        'disappearAfterSeconds': 3600,
        'messageType': 'IMAGE',
        'mediaUrl': 'http://localhost:3000/media/msgs/blob.bin',
        'mediaDuration': 12,
        'tempId': 'temp_123_7',
        'reactions': {
          '🔥': [7, 8],
        },
        'replyToMessageId': 41,
        'replyTo': {
          'id': 41,
          'content': 'original',
          'senderUsername': 'bob',
          'messageType': 'TEXT',
        },
        'linkPreviewUrl': 'https://example.com',
        'linkPreviewTitle': 'Example',
        'linkPreviewImage': 'AAAA',
        'encryptedContent': '3:AAAA',
        'editedAt': '2026-03-01T10:45:00.000Z',
      });
      expectAllFieldsEqual(parsed.copyWith(), parsed);
    });
  });

  group('MessageModel.editedAt', () {
    test('fromJson parses editedAt ISO string', () {
      final msg = MessageModel.fromJson({
        'id': 1,
        'content': '[encrypted]',
        'senderId': 1,
        'conversationId': 1,
        'createdAt': '2026-06-22T10:00:00.000Z',
        'editedAt': '2026-06-22T10:05:00.000Z',
      });
      expect(msg.editedAt, DateTime.parse('2026-06-22T10:05:00.000Z'));
    });

    test('fromJson leaves editedAt null when absent', () {
      final msg = MessageModel.fromJson({
        'id': 1,
        'content': 'hi',
        'senderId': 1,
        'conversationId': 1,
        'createdAt': '2026-06-22T10:00:00.000Z',
      });
      expect(msg.editedAt, isNull);
    });

    test('copyWith sets editedAt and preserves it', () {
      final base = MessageModel(
        id: 1,
        content: 'hi',
        senderId: 1,
        senderUsername: 'alice',
        conversationId: 1,
        createdAt: DateTime(2026, 6, 22, 10),
      );
      expect(base.editedAt, isNull);
      final edited = base.copyWith(
        content: 'hello',
        editedAt: DateTime(2026, 6, 22, 10, 5),
      );
      expect(edited.editedAt, DateTime(2026, 6, 22, 10, 5));
      // Preserved when not passed.
      expect(edited.copyWith(content: 'again').editedAt,
          DateTime(2026, 6, 22, 10, 5));
    });
  });

  group('MessageModel.hasCopyablePlaintext', () {
    MessageModel msg({
      MessageType messageType = MessageType.text,
      String content = 'hello',
    }) =>
        MessageModel(
          id: 1,
          content: content,
          senderId: 1,
          senderUsername: 'alice',
          conversationId: 1,
          createdAt: DateTime(2026, 6, 10),
          messageType: messageType,
        );

    test('true for TEXT message with real plaintext', () {
      expect(msg().hasCopyablePlaintext, isTrue);
    });

    test('false for empty content', () {
      expect(msg(content: '').hasCopyablePlaintext, isFalse);
    });

    test('false for E2E placeholder and terminal labels', () {
      expect(msg(content: '[encrypted]').hasCopyablePlaintext, isFalse);
      expect(
        msg(content: '[Decryption failed]').hasCopyablePlaintext,
        isFalse,
      );
      expect(
        msg(content: '[Encryption not initialized]').hasCopyablePlaintext,
        isFalse,
      );
    });

    test('false for every non-TEXT message type', () {
      for (final type in [
        MessageType.ping,
        MessageType.image,
        MessageType.voice,
        MessageType.gif,
        MessageType.file,
      ]) {
        expect(
          msg(messageType: type).hasCopyablePlaintext,
          isFalse,
          reason: 'type $type must not be copyable',
        );
      }
    });
  });
}
