import 'package:fake_async/fake_async.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_seed.dart';

/// Records the purges the provider asks for.
class _PurgingEncryption extends EncryptionProvider {
  final List<Set<int>> localPurges = <Set<int>>[];
  final List<Set<int>> conversationPurges = <Set<int>>[];

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<PlaintextPurgeResult> purgeLocalPlaintext(
    Iterable<int> messageIds,
  ) async {
    localPurges.add(messageIds.toSet());
    return const PlaintextPurgeResult.empty();
  }

  @override
  Future<PlaintextPurgeResult> purgeConversations(
    Iterable<int> conversationIds,
  ) async {
    conversationPurges.add(conversationIds.toSet());
    return const PlaintextPurgeResult.empty();
  }
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

MessageModel _boxRow(int n) => MessageModel(
  id: kFirstLocalMessageId + n,
  content: 'hello',
  senderId: 2,
  senderUsername: 'bob',
  conversationId: 10,
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _PurgingEncryption encryption;

  setUp(() {
    provider = MessagingProvider();
    conversations = ConversationsProvider();
    encryption = _PurgingEncryption();

    conversations.setCurrentUserId(1);
    seedConversations(conversations, [_convJson()]);
    conversations.openConversation(10);

    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(encryption);
    provider.setCurrentUserId(1);
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setActiveConversationIdForTest(10);
  });

  group('plaintext purge events', () {
    test(
      'deleting a message here drops the row and requests a per-id purge',
      () {
        provider.seedMessagesForTest(10, [_boxRow(90)]);

        provider.deleteMessage(kFirstLocalMessageId + 90, forEveryone: false);

        expect(provider.messages, isEmpty);
        expect(encryption.localPurges, [
          {kFirstLocalMessageId + 90},
        ]);
      },
    );

    test('a row with no local id is not deleted and purges nothing', () {
      provider.seedMessagesForTest(10, [
        MessageModel(
          id: 90,
          content: 'hello',
          senderId: 2,
          senderUsername: 'bob',
          conversationId: 10,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]);

      provider.deleteMessage(90, forEveryone: false);

      expect(provider.messages.map((m) => m.id), [90]);
      expect(encryption.localPurges, isEmpty);
    });

    test('unfriend removes rows and requests a conversation purge', () {
      provider.seedMessagesForTest(10, [_boxRow(91)]);

      provider.onConversationsRemovedForUser([10]);

      expect(provider.messages, isEmpty);
      expect(encryption.conversationPurges, [
        {10},
      ]);
    });

    test('clearing a chat removes rows and requests a conversation purge', () {
      provider.seedMessagesForTest(10, [_boxRow(92)]);

      provider.clearChatHistory(10);

      expect(provider.messages, isEmpty);
      expect(encryption.conversationPurges, [
        {10},
      ]);
    });
  });

  group('typing indicators', () {
    test(
      'onPartnerTyping sets the flag and expires after the timer window',
      () {
        fakeAsync((async) {
          provider.onPartnerTyping({'conversationId': 10});
          expect(provider.isPartnerTyping(10), isTrue);

          async.elapse(const Duration(seconds: 2, milliseconds: 900));
          expect(
            provider.isPartnerTyping(10),
            isTrue,
            reason: 'flag must survive until the 3s window elapses',
          );

          async.elapse(const Duration(milliseconds: 200));
          expect(provider.isPartnerTyping(10), isFalse);
        });
      },
    );

    test(
      'typing in another conversation does not leak into the active one',
      () {
        fakeAsync((async) {
          provider.onPartnerTyping({'conversationId': 99});
          expect(provider.isPartnerTyping(10), isFalse);
          expect(provider.isPartnerTyping(99), isTrue);
          async.elapse(const Duration(seconds: 4));
          expect(provider.isPartnerTyping(99), isFalse);
        });
      },
    );
  });

  group('no account-socket indicators', () {
    test(
      'typing and recording go over the box or nowhere, never the socket',
      () {
        final emitted = <String>[];
        provider
          ..receiptsAndTyping = (() => true)
          ..setEmitCallback((event, data) => emitted.add(event));

        provider.sendTypingIndicator(2, 10);
        provider.sendRecordingVoiceIndicator(2, 10, isRecording: true);
        provider.sendRecordingVoiceIndicator(2, 10, isRecording: false);

        expect(emitted, isEmpty);
      },
    );
  });
}
