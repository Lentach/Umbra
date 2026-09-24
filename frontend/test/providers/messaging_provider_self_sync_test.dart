import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Self-sync receive (multi-device spec §5.4 + §12 amendment (xi)/(xii)/(xiii)).
///
/// A message sent from device 1 is fanned out to the account's OTHER devices as
/// an ordinary per-device envelope. On device 2 it arrives with
/// `senderId == me` and `originDeviceId == 1`, and it must decrypt like any
/// inbound message — a pairwise session between two devices of one account,
/// which libsignal supports as a normal address pair.
///
/// The three rules these tests defend:
///  * a foreign-origin own row DECRYPTS, against the ORIGIN device's session;
///  * this device's own send is NEVER decrypted (a Signal sender cannot decrypt
///    its own output, and a failed attempt would render `[Decryption failed]`
///    over the only plaintext copy that will ever exist) and never loses its
///    pending-send record to a self-sync row;
///  * no delivery/read receipt is ever produced for the account's own message,
///    whichever device reads it (spec §4, falsification 19).
class _SelfSyncEncryption extends EncryptionProvider {
  _SelfSyncEncryption({
    required this.plaintextByCiphertext,
    this.envelopeByCiphertext = const {},
  });

  final Map<String, String> plaintextByCiphertext;

  /// Ciphertexts whose plaintext is a FULL envelope (media rows), returned
  /// verbatim instead of being wrapped as `{"content": …}`.
  final Map<String, String> envelopeByCiphertext;

  /// Every decrypt attempt, as `(senderId, deviceId, ciphertext)`.
  final List<(int, int, String)> decryptCalls = [];

  final EncryptionService service = EncryptionService();

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
    decryptCalls.add((senderId, deviceId, ciphertext));
    final raw = envelopeByCiphertext[ciphertext];
    if (raw != null) return raw;
    final plaintext = plaintextByCiphertext[ciphertext];
    if (plaintext == null) {
      throw StateError('no session for ciphertext $ciphertext');
    }
    return '{"content":"$plaintext"}';
  }

  @override
  Future<void> savePendingSendRecord(String key, Map<String, dynamic> data) =>
      service.savePendingSendRecord(key, data);

  @override
  Future<Map<String, dynamic>?> peekPendingSendRecord(String key) =>
      service.peekPendingSendRecord(key);

  @override
  Future<Map<String, dynamic>?> takePendingSendRecord(String key) =>
      service.takePendingSendRecord(key);

  @override
  Future<void> saveDecryptedContent(
    int messageId,
    Map<String, dynamic> data, {
    int? conversationId,
    DateTime? createdAt,
    DateTime? expiresAt,
    int? disappearAfterSeconds,
    WireKey? wire,
  }) => service.saveDecryptedContent(messageId, data);

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

/// A row for one of OUR sends, as some device of our account sees it.
Map<String, dynamic> _ownRow({
  required int id,
  String? encryptedContent,
  int? originDeviceId,
  String? envelopeStatus,
  String? sendToken,
}) => {
  'id': id,
  'senderId': 1,
  'senderUsername': 'alice',
  'content': '[encrypted]',
  'encryptedContent': ?encryptedContent,
  'originDeviceId': ?originDeviceId,
  'envelopeStatus': ?envelopeStatus,
  'sendToken': ?sendToken,
  'conversationId': 10,
  'deliveryStatus': 'SENT',
  'messageType': 'TEXT',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessageModel — the own-row decision law (amendment (xi))', () {
    MessageModel model({
      String? encryptedContent = '3:selfsync',
      int? originDeviceId,
      String? envelopeStatus,
    }) => MessageModel.fromJson(
      _ownRow(
        id: 1,
        encryptedContent: encryptedContent,
        originDeviceId: originDeviceId,
        envelopeStatus: envelopeStatus,
      ),
    );

    test('branch 3: our row from ANOTHER device is self-sync and decrypts', () {
      final row = model(originDeviceId: 1);
      expect(row.isSelfSyncRow(1, 2), isTrue);
      expect(row.needsDecryption(1, ownDeviceId: 2), isTrue);
    });

    test('branch 1: an own_origin row is never self-sync, never decrypts', () {
      final row = model(
        encryptedContent: null,
        originDeviceId: 1,
        envelopeStatus: 'own_origin',
      );
      expect(row.isSelfSyncRow(1, 2), isFalse);
      expect(row.needsDecryption(1, ownDeviceId: 2), isFalse);
    });

    test('branch 2: our row from THIS device (legacy shape) never decrypts', () {
      // A legacy own row is served its own ciphertext with no marker; only the
      // origin comparison keeps the ratchet away from it.
      final row = model(originDeviceId: 1);
      expect(row.isSelfSyncRow(1, 1), isFalse);
      expect(row.needsDecryption(1, ownDeviceId: 1), isFalse);
      // NULL originDeviceId means device 1 (pre-migration / legacy client).
      final legacy = model();
      expect(legacy.isSelfSyncRow(1, 1), isFalse);
      expect(legacy.isSelfSyncRow(1, 2), isTrue);
    });

    test(
      'amendment (xii): an UNCONFIRMED device id decrypts nothing of ours',
      () {
        final row = model(originDeviceId: 1);
        // Before socketReady the caller passes null rather than the default 1,
        // so a real device 2 does not act on a value it cannot trust.
        expect(row.isSelfSyncRow(1, null), isFalse);
        expect(row.needsDecryption(1, ownDeviceId: null), isFalse);
      },
    );

    test("a peer's row is unaffected by any of this", () {
      final peer = MessageModel.fromJson({
        ..._ownRow(id: 2, encryptedContent: '3:peer', originDeviceId: 2),
        'senderId': 2,
        'senderUsername': 'bob',
      });
      expect(peer.needsDecryption(1, ownDeviceId: 1), isTrue);
      expect(peer.isSelfSyncRow(1, 1), isFalse);
    });
  });

  group('MessagingProvider — self-sync receive', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _SelfSyncEncryption encryption;
    late List<Map<String, dynamic>> emitted;

    const selfSyncCipher = '3:selfsync-from-device-1';
    const selfSyncPlaintext = 'sent from my other device';

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _SelfSyncEncryption(
        plaintextByCiphertext: {selfSyncCipher: selfSyncPlaintext},
      );
      await encryption.service.initialize(
        1,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
      );
      emitted = <Map<String, dynamic>>[];

      conversations.setCurrentUserId(1);
      conversations.onConversationsList([_convJson()]);
      conversations.openConversation(10);

      provider.setConversationsProvider(conversations);
      provider.setEncryptionProvider(encryption);
      provider.setCurrentUserId(1);
      provider.setIncomingMessageSoundEnabledForTest(false);
      provider.onConnect(false);
      provider.setActiveConversationIdForTest(10);
      provider.setEmitCallback((event, data) {
        emitted.add({'event': event, 'data': data});
      });
    });

    Future<void> pump([int turns = 30]) async {
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'this device is 2: a device-1 self-sync row decrypts and renders',
      () async {
        encryption.setOwnDeviceId(2);

        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            _ownRow(
              id: 7001,
              encryptedContent: selfSyncCipher,
              originDeviceId: 1,
            ),
          ],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == 7001);
        expect(
          row.content,
          selfSyncPlaintext,
          reason: 'a self-sync copy must render as the same message',
        );
        expect(
          encryption.decryptCalls.single,
          (1, 1, selfSyncCipher),
          reason:
              'decrypted against the ORIGIN device session (userId 1, dev 1)',
        );
      },
    );

    test(
      'a device-1 VIDEO self-sync row arrives on device 2 with everything '
      'needed to play it, and keeps it across a reopen',
      () async {
        // The envelope the origin device built in `sendVideoMessage`
        // (`E2eEnvelope.build` with the media fields). Self-sync shares that
        // path with the peer fan-out; this pins that the RECEIVING end of our
        // own account applies the media fields, not just `content`.
        const videoCipher = '3:selfsync-video';
        final envelope = jsonEncode(
          E2eEnvelope.build(
            '',
            messageType: 'VIDEO',
            mediaUrl: 'https://media.example/msgs/v1.bin',
            mediaDuration: 7,
            mediaKey: 'k'.padRight(43, 'A'),
            mediaIv: 'i'.padRight(15, 'B'),
            mediaWidth: 720,
            mediaHeight: 1280,
          ),
        );
        encryption = _SelfSyncEncryption(
          plaintextByCiphertext: const {},
          envelopeByCiphertext: {videoCipher: envelope},
        );
        await encryption.service.initialize(
          1,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: false),
        );
        provider.setEncryptionProvider(encryption);
        encryption.setOwnDeviceId(2);

        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            {
              ..._ownRow(
                id: 7010,
                encryptedContent: videoCipher,
                originDeviceId: 1,
              ),
              'messageType': 'VIDEO',
            },
          ],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == 7010);
        expect(row.messageType, MessageType.video);
        expect(row.mediaUrl, 'https://media.example/msgs/v1.bin');
        expect(row.mediaKey, 'k'.padRight(43, 'A'));
        expect(row.mediaIv, 'i'.padRight(15, 'B'));
        expect(row.mediaDuration, 7);
        expect(row.mediaWidth, 720);
        expect(row.mediaHeight, 1280);
        expect(encryption.decryptCalls.single, (1, 1, videoCipher));

        // Replay after reopening the chat reads the persisted copy, not the
        // ratchet (which cannot decrypt the same ciphertext twice).
        final stored = await encryption.getDecryptedContent(7010);
        expect(stored?['messageType'], 'VIDEO');
        expect(stored?['mediaKey'], 'k'.padRight(43, 'A'));
        expect(stored?['mediaIv'], 'i'.padRight(15, 'B'));
        expect(stored?['mediaUrl'], 'https://media.example/msgs/v1.bin');
      },
    );

    test('falsification 19: reading our own copy emits NO receipt', () async {
      encryption.setOwnDeviceId(2);

      provider.onNewMessage(
        _ownRow(id: 7002, encryptedContent: selfSyncCipher, originDeviceId: 1),
      );
      await pump();

      expect(
        emitted.where((e) => e['event'] == 'messageDelivered'),
        isEmpty,
        reason: 'the account authored this message — never receipt our own',
      );
      expect(
        emitted.where((e) => e['event'] == 'markConversationRead'),
        isEmpty,
      );
    });

    test('an own_origin row is never handed to the ratchet', () async {
      encryption.setOwnDeviceId(1);

      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _ownRow(
            id: 7003,
            originDeviceId: 1,
            envelopeStatus: 'own_origin',
            sendToken: 'tok-7003',
          ),
        ],
      });
      await pump();

      expect(
        encryption.decryptCalls,
        isEmpty,
        reason:
            'the sender cannot decrypt its own output — attempting it would '
            'burn the only plaintext copy on [Decryption failed]',
      );
    });

    test(
      'before socketReady the row waits, and decrypts once the id is confirmed',
      () async {
        // ownDeviceId is still the §8 default and UNCONFIRMED: a real device 2
        // must not act on it (amendment (xii)).
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            _ownRow(
              id: 7004,
              encryptedContent: selfSyncCipher,
              originDeviceId: 1,
            ),
          ],
        });
        await pump();
        expect(encryption.decryptCalls, isEmpty);
        expect(
          provider.messages.firstWhere((m) => m.id == 7004).content,
          '[encrypted]',
        );

        // socketReady lands: the retry pass now sees a foreign origin.
        encryption.setOwnDeviceId(2);
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            _ownRow(
              id: 7004,
              encryptedContent: selfSyncCipher,
              originDeviceId: 1,
            ),
          ],
        });
        await pump();

        expect(
          provider.messages.firstWhere((m) => m.id == 7004).content,
          selfSyncPlaintext,
        );
      },
    );
    test(
      'review fold: before socketReady, a row CLAIMING an origin device is not '
      'reconcilable either — but a legacy row still is',
      () async {
        // Device id unconfirmed: we cannot yet tell our own send from a
        // sibling's, so a row that names an origin device must not be able to
        // reach the pending-send store at all (amendment (xii) + (xiv)).
        await encryption.savePendingSendRecord(selfSyncCipher, {
          'content': 'my own in-flight send',
        });

        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            _ownRow(
              id: 7006,
              encryptedContent: selfSyncCipher,
              originDeviceId: 1,
            ),
          ],
        });
        await pump();
        expect(
          await encryption.peekPendingSendRecord(selfSyncCipher),
          isNotNull,
          reason: 'an unevaluable origin claim gets no record key',
        );

        // A legacy row carries NO originDeviceId — device 1 by definition — and
        // must keep reconciling exactly as it does in production today, where
        // no account is enrolled and no server echo is required.
        const legacyCipher = '2:legacy-lost-ack';
        await encryption.savePendingSendRecord(legacyCipher, {
          'content': 'legacy plaintext survives',
          'messageType': 'TEXT',
        });
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [_ownRow(id: 7007, encryptedContent: legacyCipher)],
        });
        await pump();

        expect(
          provider.messages.firstWhere((m) => m.id == 7007).content,
          'legacy plaintext survives',
        );
        expect(
          await encryption.peekPendingSendRecord(legacyCipher),
          isNull,
          reason: 'the legacy reconcile must not regress',
        );
      },
    );

    test(
      'a self-sync row NEVER consumes a pending-send record (amendment (xiv))',
      () async {
        encryption.setOwnDeviceId(2);
        // A genuinely in-flight local send, insured under its own ciphertext.
        await encryption.savePendingSendRecord(selfSyncCipher, {
          'content': 'my own in-flight send',
        });

        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            _ownRow(
              id: 7005,
              encryptedContent: selfSyncCipher,
              originDeviceId: 1,
            ),
          ],
        });
        await pump();

        expect(
          await encryption.peekPendingSendRecord(selfSyncCipher),
          isNotNull,
          reason: 'a foreign-origin row must never touch the local insurance',
        );
        expect(
          provider.messages.firstWhere((m) => m.id == 7005).content,
          selfSyncPlaintext,
          reason: 'and it still decrypts on its own merits',
        );
      },
    );
  });
}
