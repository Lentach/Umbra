import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Encryption fake: decrypt() maps ciphertext -> plaintext via [decryptMap]
/// (default 'decrypted'); persists saveDecryptedContent in-memory so the
/// edit-staleness cache path can be exercised.
class _FakeEnc extends EncryptionProvider {
  bool ready = true;
  final Map<String, String> decryptMap;
  final Map<int, Map<String, dynamic>> persisted = {};

  _FakeEnc({this.decryptMap = const {}});

  @override
  bool get isE2EReady => ready;
  @override
  bool get hadIdentityReset => false;
  @override
  Future<void> deleteSessionWithPeer(int peerUserId) async {}
  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}
  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => 'cipher';
  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async =>
      jsonEncode(E2eEnvelope.build(decryptMap[ciphertext] ?? 'decrypted'));
  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int id) async =>
      persisted[id];
  @override
  Future<void> saveDecryptedContent(
    int id,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    WireKey? wire,
  }) async {
    persisted[id] = data;
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

Map<String, dynamic> _peerMsg({
  required int id,
  required String cipher,
  required String createdAt,
  String? editedAt,
}) => {
  'id': id,
  'content': '[encrypted]',
  'encryptedContent': cipher,
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': createdAt,
  'editedAt': ?editedAt,
};

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _FakeEnc encryption;
  late List<Map<String, dynamic>> emitted;

  void wire(_FakeEnc enc) {
    encryption = enc;
    provider = MessagingProvider();
    conversations = ConversationsProvider();
    emitted = <Map<String, dynamic>>[];
    conversations.setCurrentUserId(1);
    conversations.onConversationsList([_convJson()]);
    conversations.openConversation(10);
    provider.setConversationsProvider(conversations);
    provider.setEncryptionProvider(encryption);
    provider.setCurrentUserId(1);
    provider.setToken('tok');
    provider.setIncomingMessageSoundEnabledForTest(false);
    provider.onConnect(false);
    provider.setActiveConversationIdForTest(10);
    provider.setEmitCallback((event, data) {
      emitted.add({'event': event, 'data': data});
    });
  }

  /// Seed an own, server-confirmed TEXT message (id>0) with plaintext content.
  Future<void> seedOwn(int id, String content) async {
    encryption.persisted[id] = {'content': content};
    provider.onMessageHistory({
      'conversationId': 10,
      'messages': [
        {
          'id': id,
          'content': '[encrypted]',
          'encryptedContent': 'own-$id',
          'senderId': 1,
          'senderUsername': 'alice',
          'conversationId': 10,
          'deliveryStatus': 'READ',
          'messageType': 'TEXT',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      ],
    });
    await _settle();
  }

  group('editMessage (own, optimistic)', () {
    test('applies new content + editedAt and emits editMessage', () async {
      wire(_FakeEnc());
      await seedOwn(100, 'original');

      provider.editMessage(100, 'edited');
      // Optimistic update is synchronous.
      final row = provider.messages.firstWhere((m) => m.id == 100);
      expect(row.content, 'edited');
      expect(row.editedAt, isNotNull);

      await _settle();
      final edits = emitted.where((e) => e['event'] == 'editMessage').toList();
      expect(edits, hasLength(1));
      expect(edits.first['data']['messageId'], 100);
      expect(edits.first['data']['encryptedContent'], 'cipher');
      expect(edits.first['data']['content'], '[encrypted]');
    });

    test('no-op when content unchanged', () async {
      wire(_FakeEnc());
      await seedOwn(100, 'original');
      provider.editMessage(100, 'original');
      await _settle();
      expect(emitted.where((e) => e['event'] == 'editMessage'), isEmpty);
    });

    test('refuses to edit a non-own / unsent / non-text row', () async {
      wire(_FakeEnc());
      // (1) non-own: a peer message may never be edited.
      provider.onNewMessage(
        _peerMsg(
          id: 7,
          cipher: 'c7',
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await _settle();
      provider.editMessage(7, 'hack');
      await _settle();
      expect(emitted.where((e) => e['event'] == 'editMessage'), isEmpty);

      // (2) unsent optimistic own row (negative/temp id) is not server-confirmed:
      //     sendMessage creates a SENDING row with a monotonic negative id.
      provider.sendMessage('optimistic');
      await _settle();
      final optimistic = provider.messages.firstWhere(
        (m) => m.id < 0 && m.senderId == 1,
      );
      emitted.clear(); // drop the sendMessage emit from the optimistic send
      provider.editMessage(optimistic.id, 'edited');
      await _settle();
      expect(emitted.where((e) => e['event'] == 'editMessage'), isEmpty);

      // (3) non-TEXT own row (IMAGE) is not editable.
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            'id': 200,
            'content': '',
            'senderId': 1,
            'senderUsername': 'alice',
            'conversationId': 10,
            'deliveryStatus': 'READ',
            'messageType': 'IMAGE',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      });
      await _settle();
      expect(
        provider.messages.any((m) => m.id == 200),
        isTrue,
        reason: 'image row must be present so the non-TEXT guard is exercised',
      );
      provider.editMessage(200, 'caption hack');
      await _settle();
      expect(emitted.where((e) => e['event'] == 'editMessage'), isEmpty);
    });
  });

  group('editMessage revert', () {
    test('reverts optimistic edit when encryption not ready', () async {
      wire(_FakeEnc());
      await seedOwn(100, 'original');
      encryption.ready = false; // E2E drops after the message was sent
      provider.editMessage(100, 'edited');
      await _settle();
      final row = provider.messages.firstWhere((m) => m.id == 100);
      expect(row.content, 'original');
      expect(row.editedAt, isNull);
    });

    test('onEditMessageFailed restores the original row', () async {
      wire(_FakeEnc());
      await seedOwn(100, 'original');
      provider.editMessage(100, 'edited');
      await _settle();
      expect(
        provider.messages.firstWhere((m) => m.id == 100).content,
        'edited',
      );

      provider.onEditMessageFailed({
        'messageId': 100,
        'reason': 'window_expired',
      });
      final row = provider.messages.firstWhere((m) => m.id == 100);
      expect(row.content, 'original');
      expect(row.editedAt, isNull);
    });

    test('rolls back the persisted plaintext cache so a rejected edit does not '
        'resurrect on reopen (H1)', () async {
      wire(_FakeEnc());
      await seedOwn(100, 'original');
      provider.editMessage(100, 'edited');
      await _settle();
      // Optimistic success path persisted the new content.
      expect(encryption.persisted[100]?['content'], 'edited');

      provider.onEditMessageFailed({
        'messageId': 100,
        'reason': 'window_expired',
      });
      await _settle();
      // Revert must roll the persisted cache back to the original, else the
      // own-message restore path would re-show 'edited' after reopening.
      expect(encryption.persisted[100]?['content'], 'original');
      expect(
        provider.messages.firstWhere((m) => m.id == 100).content,
        'original',
      );
    });
  });

  group('messageEdited (peer)', () {
    test('decrypts the new ciphertext in the active conversation', () async {
      wire(_FakeEnc(decryptMap: {'cP': 'hello', 'cP2': 'hello edited'}));
      provider.onNewMessage(
        _peerMsg(
          id: 5,
          cipher: 'cP',
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await _settle();
      expect(provider.messages.firstWhere((m) => m.id == 5).content, 'hello');

      provider.onMessageEdited({
        'messageId': 5,
        'conversationId': 10,
        'encryptedContent': 'cP2',
        'editedAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      });
      await _settle();
      final row = provider.messages.firstWhere((m) => m.id == 5);
      expect(row.content, 'hello edited');
      expect(row.editedAt, isNotNull);
    });

    test('ignores edit for a deleted message (delete wins)', () async {
      wire(_FakeEnc(decryptMap: {'cP': 'hello', 'cP2': 'edited'}));
      provider.onNewMessage(
        _peerMsg(
          id: 6,
          cipher: 'cP',
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await _settle();
      provider.onMessageDeleted({
        'messageId': 6,
        'conversationId': 10,
        'forEveryone': true,
      });
      provider.onMessageEdited({
        'messageId': 6,
        'conversationId': 10,
        'encryptedContent': 'cP2',
        'editedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _settle();
      expect(provider.messages.any((m) => m.id == 6), isFalse);
    });
  });

  group('offline reconnect interleave', () {
    test('send A, send B, edit A offline, reconnect -> all decrypt', () async {
      wire(_FakeEnc(decryptMap: {'cA': 'A', 'cB': 'B', 'cA2': 'A-edited'}));
      final t1 = DateTime.now().toUtc().subtract(const Duration(seconds: 20));
      final t2 = DateTime.now().toUtc().subtract(const Duration(seconds: 10));
      provider.onNewMessage(
        _peerMsg(id: 1, cipher: 'cA', createdAt: t1.toIso8601String()),
      );
      provider.onNewMessage(
        _peerMsg(id: 2, cipher: 'cB', createdAt: t2.toIso8601String()),
      );
      await _settle();
      expect(provider.messages.firstWhere((m) => m.id == 1).content, 'A');
      expect(provider.messages.firstWhere((m) => m.id == 2).content, 'B');

      // Reconnect: A was edited remotely (new ciphertext + newer editedAt), B unchanged.
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _peerMsg(
            id: 1,
            cipher: 'cA2',
            createdAt: t1.toIso8601String(),
            editedAt: DateTime.now().toUtc().toIso8601String(),
          ),
          _peerMsg(id: 2, cipher: 'cB', createdAt: t2.toIso8601String()),
        ],
      });
      await _settle();
      expect(
        provider.messages.firstWhere((m) => m.id == 1).content,
        'A-edited',
      );
      expect(provider.messages.firstWhere((m) => m.id == 2).content, 'B');
    });
  });
}
