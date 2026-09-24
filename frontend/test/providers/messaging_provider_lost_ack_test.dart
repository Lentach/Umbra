import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end provider regression for the lost-`messageSent`-ack reconcile.
///
/// The reconcile-critical store (savePendingSendRecord / peek / take /
/// saveDecryptedContent / getDecryptedContent) runs against a REAL
/// [EncryptionService] over mocked storage — so these tests exercise the actual
/// durable round-trip, not a stub. Only the Signal handshake (ensureSession /
/// encrypt) is faked: it is irrelevant to the reconcile, which matches by EXACT
/// ciphertext string equality — the ciphertext just has to round-trip verbatim
/// from the SEND_EMIT capture back onto the history row.
class _RealStoreEncryption extends EncryptionProvider {
  /// The real store backing every reconcile-critical passthrough below.
  final EncryptionService service = EncryptionService();
  int _cipherSeq = 0;

  /// When set, the NEXT saveDecryptedContent silently drops the write once —
  /// simulating a persist that does not survive the read-back verify.
  bool dropNextSaveDecryptedContent = false;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<void> deleteSessionWithPeer(int peerUserId) async {}

  /// Deterministic, unique-per-send ciphertext. Reused verbatim as the
  /// pending-send store key and echoed back on the history row.
  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => '2:lostack-cipher-${++_cipherSeq}';

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
    WireKey? wire,
  }) async {
    if (dropNextSaveDecryptedContent) {
      dropNextSaveDecryptedContent = false;
      return; // persist "fails" — the read-back verify will find nothing
    }
    return service.saveDecryptedContent(messageId, data);
  }

  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) =>
      service.getDecryptedContent(messageId);
}

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': 60,
  'unreadCount': 0,
  'lastMessage': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessagingProvider — lost-ack reconcile', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _RealStoreEncryption encryption;
    late List<Map<String, dynamic>> emitted;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _RealStoreEncryption();
      await encryption.service.initialize(
        1,
        checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
      ); // "me" = user 1
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
    });

    // Drain the fire-and-forget send path and the async history decrypt pass.
    // Every await in those chains is microtask/zero-timer based (no wall clock),
    // so a bounded number of event-loop turns fully settles them.
    Future<void> pump([int turns = 30]) async {
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// Sends [text] through the provider and returns the captured
    /// `sendMessage` emit payload (holds the exact `encryptedContent` + tempId).
    Future<Map<String, dynamic>> sendAndCapture(String text) async {
      provider.sendMessage(text);
      await pump();
      final send = emitted.firstWhere((e) => e['event'] == 'sendMessage');
      return (send['data'] as Map<String, dynamic>);
    }

    Map<String, dynamic> ownHistoryRow({
      required int id,
      required String encryptedContent,
      String? sendToken,
    }) => {
      'id': id,
      'senderId': 1,
      'senderUsername': 'alice',
      'content': '[encrypted]',
      'encryptedContent': encryptedContent,
      // The server persists the client's token for its own idempotency and
      // echoes it back to the ORIGIN device (spec §12 amendment (ix)) — so
      // a real legacy row carries BOTH. Omitting it here is what let a
      // reconcile-key precedence bug ship: the record is saved under the
      // ciphertext, and preferring the token stranded the only plaintext.
      'sendToken': ?sendToken,
      'conversationId': 10,
      'deliveryStatus': 'DELIVERED',
      'messageType': 'TEXT',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    // Contract 9: happy path. The ack died with the socket, so the own row
    // arrives from history as '[encrypted]' with nothing persisted under its
    // real id. Reconcile matches the durable pending-send record by exact
    // ciphertext and restores plaintext into RAM + the persisted cache.
    test(
      'lost ack: history [encrypted] own row reconciles to plaintext',
      () async {
        const plaintext = 'the eagle lands at noon';
        final send = await sendAndCapture(plaintext);
        final ciphertext = send['encryptedContent'] as String;

        // The SEND_EMIT wiring durably recorded the plaintext under the ciphertext.
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNotNull,
          reason: 'SEND_EMIT must record the pending-send insurance',
        );

        const realId = 5001;
        // No messageSent ack is delivered — only the later history snapshot.
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [ownHistoryRow(id: realId, encryptedContent: ciphertext)],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == realId);
        // (a) in-memory row shows the ORIGINAL plaintext.
        expect(row.content, plaintext);
        // (b) it was persisted under the real id.
        final persisted = await encryption.getDecryptedContent(realId);
        expect(persisted?['content'], plaintext);
        // (c) the pending record was consumed.
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNull,
          reason: 'reconcile must take the record after a verified persist',
        );
      },
    );

    // Contract 9b (T4 regression, GATE-FAIL finding). A LEGACY row carries the
    // echoed `sendToken` AS WELL AS its ciphertext, and its durable record is
    // keyed by the CIPHERTEXT. Preferring the token here looked up a key the
    // record was never saved under and stranded the only plaintext copy — on
    // every lost ack, for every send, since no account is enrolled yet.
    test(
      'lost ack: a legacy row that also echoes sendToken still reconciles',
      () async {
        const plaintext = 'echoed token must not win';
        final send = await sendAndCapture(plaintext);
        final ciphertext = send['encryptedContent'] as String;
        final token = send['sendToken'] as String;
        expect(token, isNotEmpty, reason: 'the client mints a token per send');

        const realId = 5002;
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            ownHistoryRow(
              id: realId,
              encryptedContent: ciphertext,
              sendToken: token,
            ),
          ],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == realId);
        expect(
          row.content,
          plaintext,
          reason: 'the only plaintext copy survives',
        );
        expect(
          (await encryption.getDecryptedContent(realId))?['content'],
          plaintext,
        );
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNull,
          reason: 'consumed by the SAME key it was saved under',
        );
      },
    );

    // Contract 10: negative. A DIFFERENT ciphertext on the history row must NOT
    // resolve — no heuristic match. The row stays '[encrypted]' and the record
    // is preserved for the pass that carries the correct ciphertext.
    test(
      'lost ack: mismatched ciphertext leaves row encrypted, record intact',
      () async {
        const plaintext = 'do not guess me';
        final send = await sendAndCapture(plaintext);
        final ciphertext = send['encryptedContent'] as String;
        final wrongCiphertext = '$ciphertext-DIFFERENT';

        const realId = 6001;
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            ownHistoryRow(id: realId, encryptedContent: wrongCiphertext),
          ],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == realId);
        expect(
          row.content,
          '[encrypted]',
          reason: 'a non-exact ciphertext must never resolve plaintext',
        );
        expect(await encryption.getDecryptedContent(realId), isNull);
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNotNull,
          reason: 'the record survives for the correct-ciphertext pass',
        );
      },
    );

    // Contract 9c (the token-keyed half of amendment (ix), previously untested).
    // A NEW-MODEL row has a NULL ciphertext for its ORIGIN device — the server
    // marks it `own_origin` and echoes the send token instead — so the record,
    // saved under the TOKEN by a fan-out send, can only be found by falling
    // through to it. Without this case a precedence inversion on the fan-out
    // branch would ship green (the legacy cases above would still pass).
    test('lost ack: an own_origin row reconciles by sendToken', () async {
      const plaintext = 'no ciphertext exists for my own device';
      const token = 'tok-fanout-9c';
      // What a fan-out send durably records: keyed by the token, because this
      // device's own copy of the row will carry no ciphertext at all.
      await encryption.savePendingSendRecord(token, {
        'content': plaintext,
        'messageType': 'TEXT',
      });

      const realId = 5003;
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            'id': realId,
            'senderId': 1,
            'senderUsername': 'alice',
            'content': '[encrypted]',
            // No `encryptedContent`: the origin device has no envelope.
            'envelopeStatus': 'own_origin',
            'originDeviceId': 1,
            'sendToken': token,
            'conversationId': 10,
            'deliveryStatus': 'SENT',
            'messageType': 'TEXT',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      });
      await pump();

      final row = provider.messages.firstWhere((m) => m.id == realId);
      expect(
        row.content,
        plaintext,
        reason: 'the token is the ONLY key such a row can be matched by',
      );
      expect(
        (await encryption.getDecryptedContent(realId))?['content'],
        plaintext,
      );
      expect(
        await encryption.peekPendingSendRecord(token),
        isNull,
        reason: 'consumed after a verified persist',
      );
    });

    // Contract 11: the normal ack path is self-cleaning. A delivered
    // `messageSent` echo (tempId + encryptedContent) consumes the pending
    // record so the store never accumulates for successfully-acked sends.
    test('normal messageSent ack consumes the pending-send record', () async {
      const plaintext = 'acked and done';
      final send = await sendAndCapture(plaintext);
      final ciphertext = send['encryptedContent'] as String;
      final tempId = send['tempId'] as String;

      expect(await encryption.peekPendingSendRecord(ciphertext), isNotNull);

      provider.onMessageSent({
        'id': 7001,
        'senderId': 1,
        'senderUsername': 'alice',
        'content': '[encrypted]',
        'encryptedContent': ciphertext,
        'conversationId': 10,
        'tempId': tempId,
        'deliveryStatus': 'SENT',
        'messageType': 'TEXT',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      await pump();

      expect(
        await encryption.peekPendingSendRecord(ciphertext),
        isNull,
        reason: 'the ack must take the record so the store self-cleans',
      );
      // The acked row shows the original plaintext (from the optimistic snapshot).
      final row = provider.messages.firstWhere((m) => m.id == 7001);
      expect(row.content, plaintext);
    });

    // Contract 12 (anti-data-loss guard): the reconcile persists, VERIFIES by
    // read-back, and takes the record ONLY when verified. A failed persist must
    // leave the record for a later pass — a refactor to unconditional take()
    // would drop the sender's only surviving plaintext copy and fail this test.
    test(
      'failed persist keeps the record; a later pass reconciles fully',
      () async {
        const plaintext = 'survive a failed persist';
        final send = await sendAndCapture(plaintext);
        final ciphertext = send['encryptedContent'] as String;
        const realId = 8001;

        // Pass 1: the persist read-back fails, so verify is false.
        encryption.dropNextSaveDecryptedContent = true;
        E2eDiagLog.clear();
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [ownHistoryRow(id: realId, encryptedContent: ciphertext)],
        });
        await pump();

        // (a) the record SURVIVES — take was NOT called on the unverified persist.
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNotNull,
          reason: 'a failed persist must never consume the only plaintext copy',
        );
        // Nothing landed under the real id (the persist was dropped).
        expect(await encryption.getDecryptedContent(realId), isNull);
        // (b) the guard reported the unverified persist.
        final reconciledDiag = E2eDiagLog.entries
            .where(
              (e) =>
                  e.contains('SEND_ACK_RECONCILED') &&
                  e.contains('msgId: $realId'),
            )
            .toList();
        expect(
          reconciledDiag,
          isNotEmpty,
          reason: 'the reconcile branch must have run',
        );
        expect(
          reconciledDiag.every((e) => e.contains('persistVerified: false')),
          isTrue,
          reason:
              'an unverified persist must be reported as persistVerified:false',
        );

        // (c) a later pass with persist working reconciles fully. Clearing the
        // transient in-memory plaintext models an app reopen / re-fetch: the
        // durable pending-send record is what carries the recovery.
        provider.clearMessages();
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [ownHistoryRow(id: realId, encryptedContent: ciphertext)],
        });
        await pump();

        final row = provider.messages.firstWhere((m) => m.id == realId);
        expect(row.content, plaintext);
        expect(
          (await encryption.getDecryptedContent(realId))?['content'],
          plaintext,
        );
        expect(
          await encryption.peekPendingSendRecord(ciphertext),
          isNull,
          reason: 'a verified persist finally consumes the record',
        );
      },
    );
  });
}
