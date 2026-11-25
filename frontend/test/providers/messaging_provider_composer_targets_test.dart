import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/box_send_harness.dart';
import '../support/chat_seed.dart';

/// The composer's reply and edit targets belong to the chat they were
/// picked in: chat 10 is with Bob (2), chat 11 with Carol (3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BoxSendHarness h;
  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late SendOutbox outbox;

  setUp(() async {
    h = await BoxSendHarness.create();
    provider = h.provider;
    conversations = h.conversations;
    outbox = h.outbox;
    seedConversations(conversations, [
      boxSendConversation(),
      {
        'id': 11,
        'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
        'userTwo': {'id': 3, 'username': 'carol', 'tag': '0003'},
        'createdAt': '2026-01-01T00:00:00.000Z',
        'unreadCount': 0,
        'lastMessage': null,
      },
    ]);
    for (final peer in [2, 3]) {
      h.encryption.lists[peer] = enrolledList([1]);
      outbox.addresses[peer] = {1: boxAddress(1)};
    }
    provider
      ..refreshBoxDeviceLists()
      ..getMessages(10);
    await h.pump();
  });

  tearDown(() => h.dispose());

  /// What the chat screen does when [id] becomes the chat on screen.
  Future<void> open(int id) async {
    conversations.openConversation(id);
    provider
      ..setActiveConversationIdForTest(id)
      ..getMessages(id);
    await h.pump();
  }

  /// The active id alone has moved to [id]: the chat's rows are not
  /// installed yet (the frame between the sidebar tap and the chat screen's
  /// post-frame open).
  void activeOnly(int id) {
    conversations.openConversation(id);
    provider.setActiveConversationIdForTest(id);
  }

  Future<MessageModel> send(String text) async {
    provider.sendMessage(text);
    await h.pump();
    return provider.messages.last;
  }

  Map<String, dynamic> envelopeOf(BoxFrame frame) =>
      jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

  /// The message envelopes handed to the box since the last clear.
  List<Map<String, dynamic>> sentEnvelopes() => [
    for (final (_, frame) in outbox.delivered) envelopeOf(frame),
  ];

  MessageModel fromBob() => MessageModel(
    id: 5,
    content: 'what Bob said in private',
    senderId: 2,
    senderUsername: 'bob',
    conversationId: 10,
    createdAt: DateTime.utc(2026, 9, 20),
    wireId: 'wire-00000005',
  );

  group('reply target', () {
    test('a reply picked and sent in one chat quotes the message, then the '
        'target is gone', () async {
      provider.setReplyingTo(fromBob());
      expect(provider.replyingToMessage?.id, 5);

      final reply = await send('re: that');

      expect(reply.conversationId, 10);
      expect(reply.replyTo?.id, 5);
      expect(reply.replyTo?.content, 'what Bob said in private');
      expect(sentEnvelopes().single['re'], {
        'w': 'wire-00000005',
        's': 2,
        'k': 'TEXT',
        'x': 'what Bob said in private',
      });
      expect(provider.replyingToMessage, isNull);
    });

    test('opening the same chat again keeps its reply target', () async {
      provider.setReplyingTo(fromBob());

      await open(10);

      expect(provider.replyingToMessage?.id, 5);
    });

    test('opening another chat drops the reply target: its composer shows no '
        'reply bar and a send there quotes nothing', () async {
      provider.setReplyingTo(fromBob());

      await open(11);
      expect(provider.replyingToMessage, isNull);

      final sent = await send('hello Carol');
      expect(sent.conversationId, 11);
      expect(sent.replyToMessageId, isNull);
      expect(sent.replyTo, isNull);
      expect(sentEnvelopes().single.containsKey('re'), isFalse);

      await open(10);
      expect(
        provider.replyingToMessage,
        isNull,
        reason: 'coming back starts with no reply bar',
      );
    });

    test('a send never quotes a message of another chat, even while that '
        'target is still held', () async {
      provider.setReplyingTo(fromBob());
      activeOnly(11);

      provider.sendMessage('hello Carol');
      final optimistic = provider.messages.last;
      expect(optimistic.conversationId, 11);
      expect(optimistic.replyToMessageId, isNull);
      expect(optimistic.replyTo, isNull);

      await h.pump();
      final envelopes = sentEnvelopes();
      expect(envelopes, isNotEmpty);
      for (final envelope in envelopes) {
        expect(envelope.containsKey('re'), isFalse);
        expect(jsonEncode(envelope), isNot(contains('what Bob said')));
      }
    });

    test('a voice note never quotes a message of another chat', () async {
      provider.setReplyingTo(fromBob());
      activeOnly(11);

      final sending = provider.sendVoiceMessage(
        recipientId: 3,
        duration: 2,
        localAudioBytes: List<int>.filled(64, 7),
      );
      final optimistic = provider.messages.last;
      expect(optimistic.messageType, MessageType.voice);
      expect(optimistic.conversationId, 11);
      expect(optimistic.replyToMessageId, isNull);
      expect(optimistic.replyTo, isNull);
      await sending;
      await h.pump();
    });
  });
}
