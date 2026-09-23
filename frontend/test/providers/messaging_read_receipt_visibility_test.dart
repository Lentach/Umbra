import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression for the backgrounded-PWA false read receipt (field bug, users
/// 48/90, Aug 2026): a hidden client with a mounted chat route emitted
/// `markConversationRead` for every arriving message, so the sender saw READ
/// while the recipient was away. The gate lives in
/// `MessagingActions.markConversationRead` and consults
/// `ConversationsProvider.isClientVisible` — the same signal MainShell already
/// maintains for push suppression. `messageDelivered` must keep flowing from a
/// hidden client: delivery is a transport fact, not a "user saw it" claim.
class _PlainEncryption extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  // `deviceId` arrived with the multi-device work (spec §5.2): a send addresses
  // every live device of the account, not a fixed device 1. This fake predates
  // that and must track the signature or it stops overriding anything.
  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      null;

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    String? wireId,
  }) async {}

  @override
  Future<void> loadRetiredIds() async {}
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _plainIncomingJson(int id) => {
  'id': id,
  'content': 'hello there',
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late List<Map<String, dynamic>> emitted;

  List<Map<String, dynamic>> emitsOf(String event) =>
      emitted.where((e) => e['event'] == event).toList();

  setUp(() {
    provider = MessagingProvider();
    conversations = ConversationsProvider();
    emitted = <Map<String, dynamic>>[];

    conversations.setCurrentUserId(1);
    conversations.onConversationsList([_convJson()]);
    conversations.openConversation(10);

    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(_PlainEncryption());
    provider.setCurrentUserId(1);
    provider.setToken('tok');
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
    });
    provider.setActiveConversationIdForTest(10);
  });

  test(
    'hidden client: incoming peer message for the active conversation emits '
    'messageDelivered but never markConversationRead',
    () async {
      conversations.setClientVisible(false);
      emitted.clear();

      provider.onNewMessage(_plainIncomingJson(50));
      // Let any queued decrypt/microtask work settle before asserting.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        emitsOf('messageDelivered'),
        hasLength(1),
        reason: 'delivery acknowledgment must not depend on visibility',
      );
      expect(
        emitsOf('markConversationRead'),
        isEmpty,
        reason:
            'a backgrounded client must never claim the user read the message',
      );
    },
  );

  test(
    'visible client: incoming peer message for the active conversation still '
    'emits markConversationRead',
    () async {
      // Default visibility is true; this is the unchanged desktop behavior.
      emitted.clear();

      provider.onNewMessage(_plainIncomingJson(51));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(emitsOf('messageDelivered'), hasLength(1));
      expect(
        emitsOf('markConversationRead').map((e) => e['data']),
        [
          {'conversationId': 10},
        ],
      );
    },
  );

  test(
    'hidden client suppresses the history-driven read mark; becoming visible '
    'again lets the next history refetch mark READ',
    () async {
      conversations.setClientVisible(false);
      emitted.clear();

      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(60)],
      });

      expect(
        emitsOf('markConversationRead'),
        isEmpty,
        reason: 'history refetch while hidden must not mark READ',
      );

      // Foreground return: every recovery path refetches history, and THAT
      // refetch is what marks the conversation read once the gate passes.
      conversations.setClientVisible(true);
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_plainIncomingJson(61)],
      });

      expect(
        emitsOf('markConversationRead').map((e) => e['data']),
        [
          {'conversationId': 10},
        ],
      );
    },
  );
}
