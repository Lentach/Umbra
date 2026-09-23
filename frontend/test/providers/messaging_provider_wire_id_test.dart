import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata-privacy PR2.1: every message this device persists is findable by
/// its WIRE id, whichever way it arrived. The observable end state is the
/// real store's `wireIdIndex()` — what the box path (PR3.1) will dedup
/// against — so the persistence runs on a REAL [EncryptionService]; only the
/// Signal handshake is faked.
class _RealStoreEncryption extends EncryptionProvider {
  final EncryptionService service = EncryptionService();
  final List<String> encryptedPlaintexts = [];

  /// The envelope the next inbound decrypt hands back.
  String inboundEnvelope = jsonEncode(E2eEnvelope.build('hello'));

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async {
    encryptedPlaintexts.add(plaintext);
    return '2:wire-cipher-${encryptedPlaintexts.length}';
  }

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => inboundEnvelope;

  @override
  Future<void> savePendingSendRecord(
    String ciphertext,
    Map<String, dynamic> data,
  ) => service.savePendingSendRecord(ciphertext, data);

  @override
  Future<Map<String, dynamic>?> peekPendingSendRecord(String ciphertext) =>
      service.peekPendingSendRecord(ciphertext);

  @override
  Future<Map<String, dynamic>?> takePendingSendRecord(String ciphertext) =>
      service.takePendingSendRecord(ciphertext);

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    String? wireId,
  }) => service.saveDecryptedContent(
    messageId,
    data,
    conversationId: conversationId,
    createdAt: createdAt,
    expiresAt: expiresAt,
    disappearAfterSeconds: disappearAfterSeconds,
    wireId: wireId,
  );

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) =>
      service.getDecryptedContent(messageId);
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': null,
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _ownRow({
  required int id,
  required String encryptedContent,
  required String sendToken,
  String? tempId,
}) => {
  'id': id,
  'senderId': 1,
  'senderUsername': 'alice',
  'content': '[encrypted]',
  'encryptedContent': encryptedContent,
  // Echoed to the ORIGIN device only (spec §12 amendment (ix)).
  'sendToken': sendToken,
  'tempId': ?tempId,
  'conversationId': 10,
  'deliveryStatus': 'SENT',
  'messageType': 'TEXT',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late _RealStoreEncryption encryption;
  late List<Map<String, dynamic>> emitted;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});

    provider = MessagingProvider();
    final conversations = ConversationsProvider();
    encryption = _RealStoreEncryption();
    await encryption.service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    emitted = <Map<String, dynamic>>[];

    conversations
      ..setCurrentUserId(1)
      ..onConversationsList([_convJson()])
      ..openConversation(10);

    provider
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10)
      ..setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
      });
  });

  Future<void> pump([int turns = 30]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<Map<String, dynamic>> sendAndCapture(String text) async {
    provider.sendMessage(text);
    await pump();
    final send = emitted.firstWhere((e) => e['event'] == 'sendMessage');
    return send['data'] as Map<String, dynamic>;
  }

  test('a send puts its token inside the envelope as the wire id', () async {
    final send = await sendAndCapture('hi');

    final envelope = E2eEnvelope.parse(encryption.encryptedPlaintexts.single);
    expect(envelope.msgId, send['sendToken']);
  });

  test('an acked own send is indexed under the token it emitted', () async {
    final send = await sendAndCapture('hi');
    final token = send['sendToken'] as String;

    provider.onMessageSent(
      _ownRow(
        id: 501,
        encryptedContent: send['encryptedContent'] as String,
        sendToken: token,
        tempId: send['tempId'] as String,
      ),
    );
    await pump();

    expect(await encryption.service.wireIdIndex(), {token: 501});
  });

  test('a lost ack reconciled from history is indexed too', () async {
    final send = await sendAndCapture('hi');
    final token = send['sendToken'] as String;

    // No messageSent — only the later history snapshot.
    await provider.onMessageHistory({
      'conversationId': 10,
      'messages': [
        _ownRow(
          id: 502,
          encryptedContent: send['encryptedContent'] as String,
          sendToken: token,
        ),
      ],
    });
    await pump();

    expect(await encryption.service.wireIdIndex(), {token: 502});
  });

  test(
    'a received message is indexed under the msgId its sender sent',
    () async {
      const peerWireId = 'temp_1758700000000_2-peerwire';
      encryption.inboundEnvelope = jsonEncode(
        E2eEnvelope.build('hello from bob', msgId: peerWireId),
      );

      provider.onNewMessage({
        'id': 9001,
        'senderId': 2,
        'senderUsername': 'bob',
        'content': '[encrypted]',
        'encryptedContent': '2:peer-ciphertext',
        'originDeviceId': 1,
        'conversationId': 10,
        'deliveryStatus': 'DELIVERED',
        'messageType': 'TEXT',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      await pump();

      final row = provider.messages.firstWhere((m) => m.id == 9001);
      expect(row.content, 'hello from bob');
      expect(row.wireId, peerWireId);
      expect(await encryption.service.wireIdIndex(), {peerWireId: 9001});
    },
  );

  // Review finding (PR2.1): the server is not trusted with a PEER row's wire
  // id. A server that stamps a `sendToken` on bob's row must not outvote the
  // Signal-authenticated envelope, because `_wid` is first-write-wins.
  test('a server-supplied token on a peer row never becomes its wire id',
      () async {
    const peerWireId = 'temp_1758700000000_2-peerwire';
    encryption.inboundEnvelope = jsonEncode(
      E2eEnvelope.build('hello from bob', msgId: peerWireId),
    );

    provider.onNewMessage({
      'id': 9002,
      'senderId': 2,
      'senderUsername': 'bob',
      'content': '[encrypted]',
      'encryptedContent': '2:peer-ciphertext',
      'sendToken': 'planted-by-the-server',
      'originDeviceId': 1,
      'conversationId': 10,
      'deliveryStatus': 'DELIVERED',
      'messageType': 'TEXT',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    await pump();

    final row = provider.messages.firstWhere((m) => m.id == 9002);
    expect(row.wireId, peerWireId);
    expect(await encryption.service.wireIdIndex(), {peerWireId: 9002});
  });
}
