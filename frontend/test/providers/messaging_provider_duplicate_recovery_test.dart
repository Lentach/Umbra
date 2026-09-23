import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression for the "message breaks mid-conversation" bug (2026-07-11, the
/// `kind:duplicate` `[Decryption failed]` entries, e.g. bob210 / msg 15284).
///
/// Mechanism: on a history re-decrypt the client re-runs `decrypt` on a message
/// whose ratchet key was already consumed → `DuplicateMessageException`. The OLD
/// policy PERSISTED `[Decryption failed]`, poisoning the durable decrypted-content
/// cache so the message could never come back — a permanent break. The fix marks
/// `duplicate` failed IN MEMORY only (no durable write), so a later launch can
/// still restore the plaintext if its row survives.
///
/// This drives the REAL MessagingProvider decrypt path (not the policy in
/// isolation) and asserts the durable-write behavior, with a `badMac` contrast so
/// the test fails if the duplicate/badMac distinction ever regresses.
class _ThrowingEncryption extends EncryptionProvider {
  _ThrowingEncryption(
    this._error, {
    Map<int, Map<String, dynamic>>? persisted,
    this.forcedReadMisses = 0,
  }) : persisted = persisted ?? {};

  final Object _error;
  final Map<int, Map<String, dynamic>> persisted;
  int forcedReadMisses;
  int decryptCalls = 0;

  /// Every (messageId, payload) written to the DURABLE cache.
  final List<MapEntry<int, Map<String, dynamic>>> durableWrites = [];

  @override
  bool get isE2EReady => true;
  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decryptCalls++;
    throw _error;
  }

  @override
  MessageModel? getCachedDecryption(int messageId) => null;
  @override
  void cacheDecryption(int messageId, MessageModel msg) {}

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async {
    if (forcedReadMisses > 0) {
      forcedReadMisses--;
      return null;
    }
    return persisted[messageId];
  }

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    String? wireId,
  }) async {
    final copy = Map<String, dynamic>.from(data);
    durableWrites.add(MapEntry(messageId, copy));
    persisted[messageId] = copy;
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

Map<String, dynamic> _encryptedInboundJson(int id) => {
  'id': id,
  'content': '[encrypted]',
  'encryptedContent': '2:ciphertext-$id',
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const failedLabel = '[Decryption failed]';

  Future<({MessagingProvider provider, _ThrowingEncryption encryption})>
  runHistoryDecrypt(
    Object error, {
    Map<int, Map<String, dynamic>>? persisted,
    int forcedReadMisses = 0,
  }) async {
    final encryption = _ThrowingEncryption(
      error,
      persisted: persisted,
      forcedReadMisses: forcedReadMisses,
    );
    final conversations = ConversationsProvider();
    conversations.setCurrentUserId(1);
    conversations.onConversationsList([_convJson()]);
    conversations.openConversation(10);

    final provider = MessagingProvider();
    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(encryption);
    provider.setCurrentUserId(1);
    provider.setToken('tok');
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setEmitCallback((_, _) {});
    provider.setActiveConversationIdForTest(10);

    provider.onMessageHistory({
      'conversationId': 10,
      'messages': [_encryptedInboundJson(5001)],
    });

    // History decrypt runs async (whenComplete). Poll until the row settles.
    for (var i = 0; i < 200; i++) {
      final m = provider.messages.where((m) => m.id == 5001).firstOrNull;
      if (m != null && !m.displayAsEncryptedPlaceholder) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return (provider: provider, encryption: encryption);
  }

  group('mid-conversation duplicate does not permanently break the message', () {
    test(
      'DuplicateMessage on re-decrypt marks failed IN MEMORY but does NOT '
      'persist [Decryption failed] (durable cache stays un-poisoned → recoverable)',
      () async {
        final run = await runHistoryDecrypt(
          Exception('DuplicateMessageException 42'),
        );
        final enc = run.encryption;

        // The message shows failed in memory this session (no [encrypted] loop)...
        // (we don't assert the in-memory label strictly — the load-bearing claim
        // is the durable cache is not poisoned).
        // ...but nothing was written to the durable cache as [Decryption failed].
        final poisoned = enc.durableWrites
            .where((w) => w.value['content'] == failedLabel)
            .toList();
        expect(
          poisoned,
          isEmpty,
          reason:
              'duplicate must NOT persist [Decryption failed] — that is '
              'what permanently broke bob210\'s message',
        );
      },
    );

    test(
      'a transient durable-cache miss can show duplicate failure, then a fresh '
      'provider restores the preserved plaintext without decrypting again',
      () async {
        final persisted = <int, Map<String, dynamic>>{
          5001: {'content': 'restored plaintext', 'messageType': 'TEXT'},
        };

        final failedRun = await runHistoryDecrypt(
          Exception('DuplicateMessageException 42'),
          persisted: persisted,
          // History checks storage before decrypt and once more in the catch.
          forcedReadMisses: 2,
        );
        expect(failedRun.provider.messages.single.content, failedLabel);
        expect(
          persisted[5001]!['content'],
          'restored plaintext',
          reason: 'duplicate handling must not poison the durable cache',
        );

        final recoveredRun = await runHistoryDecrypt(
          StateError('decrypt must not run when durable plaintext is readable'),
          persisted: persisted,
        );
        expect(
          recoveredRun.provider.messages.single.content,
          'restored plaintext',
        );
        expect(
          recoveredRun.encryption.decryptCalls,
          0,
          reason: 'the apparent repair is cache restoration, not re-decryption',
        );
      },
    );

    test(
      'CONTRAST: badMac still persists [Decryption failed] (proves the test '
      'distinguishes duplicate from badMac; guards against a policy regression)',
      () async {
        final run = await runHistoryDecrypt(Exception('Bad Mac!'));
        final enc = run.encryption;
        final poisoned = enc.durableWrites
            .where((w) => w.value['content'] == failedLabel)
            .toList();
        expect(
          poisoned,
          isNotEmpty,
          reason:
              'badMac is terminal + persisted by policy; if this is empty '
              'the decrypt path never ran or the policy changed',
        );
      },
    );
  });
}
