import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `envelopeStatus` handling (multi-device spec §5.3 + §12 amendment (viii)).
///
/// A row the server marked has NO ciphertext for this device. The contracts that
/// matter are all about what must NOT happen to it: it must not be decrypted
/// (which would land in the decryption-failure policy), it must not overwrite a
/// plaintext copy this device already holds, and it must never be a destruction
/// trigger (I8, falsification 13).
class _NoopEncryption extends EncryptionProvider {
  int decryptCalls = 0;

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
    return '{"content":"should never be reached"}';
  }
}

/// Opens every row except the ids in [failures], which throw the given text:
/// the provider classifies a failure by the exception's text, so this drives
/// the REAL decryption-failure policy per row.
class _BoundaryEncryption extends EncryptionProvider {
  _BoundaryEncryption({this.since});

  final DateTime? since;
  final Map<int, String> failures = {};
  bool identityReset = false;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => identityReset;

  @override
  DateTime? get ownIdentitySince => since;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  /// Nothing was ever persisted: a failed row has no stored plaintext, so the
  /// chat list's lazy lookup answers "none held" instead of never answering.
  @override
  Future<Map<String, dynamic>?> getDecryptedContent(int messageId) async =>
      null;

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    final failure = failures[messageId];
    if (failure != null) throw Exception(failure);
    return '{"content":"readable $messageId"}';
  }
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

Map<String, dynamic> _row({
  required int id,
  String? envelopeStatus,
  String? encryptedContent,
  int senderId = 2,
  DateTime? createdAt,
  String messageType = 'TEXT',
}) => {
  'id': id,
  'senderId': senderId,
  'senderUsername': senderId == 1 ? 'alice' : 'bob',
  'content': '[encrypted]',
  'encryptedContent': ?encryptedContent,
  'envelopeStatus': ?envelopeStatus,
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': messageType,
  'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('envelopeStatus', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _NoopEncryption encryption;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _NoopEncryption();

      conversations.setCurrentUserId(1);
      conversations.onConversationsList([_convJson()]);
      conversations.openConversation(10);

      provider.setConversationsProvider(conversations);
      provider.setEncryptionProvider(encryption);
      provider.setCurrentUserId(1);
      provider.setIncomingMessageSoundEnabledForTest(false);
      provider.onConnect(false);
      provider.setActiveConversationIdForTest(10);
      provider.setEmitCallback((event, data) {});
    });

    Future<void> pump([int turns = 30]) async {
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('the model carries both marker values off the wire', () {
      expect(
        MessageModel.fromJson(
          _row(id: 1, envelopeStatus: 'none_for_device'),
        ).envelopeStatus,
        'none_for_device',
      );
      expect(
        MessageModel.fromJson(
          _row(id: 2, envelopeStatus: 'own_origin', senderId: 1),
        ).envelopeStatus,
        'own_origin',
      );
      // Absent on an older server, and on any row that DID get a ciphertext.
      expect(
        MessageModel.fromJson(
          _row(id: 3, encryptedContent: '2:ct'),
        ).envelopeStatus,
        isNull,
      );
    });

    test('a none_for_device row is never decrypted, is hidden from the thread '
        'and counted for the divider (amendment (lxxxi))', () async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _row(id: 100, encryptedContent: '2:ct'),
          _row(id: 101, envelopeStatus: 'none_for_device'),
        ],
      });
      await pump();

      expect(encryption.decryptCalls, 1, reason: 'only the real ciphertext');
      expect(provider.messages.map((m) => m.id), [100]);
      expect(provider.hiddenPreLinkCount, 1);
    });

    test('the filtered view is rebuilt after an IN-PLACE mutation of the '
        'loaded list (the cache invalidates on notify, not on reassignment)',
        () async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _row(id: 100, encryptedContent: '2:ct'),
          _row(id: 101, envelopeStatus: 'none_for_device'),
        ],
      });
      await pump();
      // The hidden row forces a FILTERED copy, so the view is a different
      // list than the store; an append to the store must still show.
      expect(provider.messages.map((m) => m.id), [100]);

      provider.onNewMessage(_row(id: 102, encryptedContent: '2:ct2'));
      await pump();

      expect(provider.loadedMessagesForTest.map((m) => m.id), [100, 101, 102]);
      expect(provider.messages.map((m) => m.id), [100, 102],
          reason: 'a stale filtered view would still read [100]');
      expect(provider.hiddenPreLinkCount, 1);
    });

    test('a row that never predated this device is not hidden', () async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_row(id: 100, encryptedContent: '2:ct')],
      });
      await pump();

      expect(provider.messages.map((m) => m.id), [100]);
      expect(provider.hiddenPreLinkCount, 0);
    });

    test('a marker row is not a destruction trigger', () async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_row(id: 102, envelopeStatus: 'none_for_device')],
      });
      await pump();

      // The row survives locally — I8: an honest marker never purges, retires,
      // or removes anything (falsification 13). Hidden from the thread is not
      // gone.
      final row = provider.loadedMessagesForTest.firstWhere((m) => m.id == 102);
      expect(row.content, isNot(kRetiredMessageLabel));
      expect(provider.messages.any((m) => m.id == 102), isFalse);
    });

    test('the marker can never overwrite plaintext already held', () {
      // saveDecryptedContent refuses a placeholder over real content, and the
      // marker must be part of that set or a later marked payload would erase a
      // message this device legitimately decrypted.
      expect(
        EncryptionService.placeholderContents,
        contains(kNotLinkedYetMessageLabel),
      );
    });

    test('copyWith preserves the per-device fields', () {
      final row = MessageModel.fromJson(
        _row(id: 104, envelopeStatus: 'own_origin', senderId: 1),
      ).copyWith(deliveryStatus: MessageDeliveryStatus.read);

      // Losing these on a merge would resurrect a decrypt attempt on a row with
      // no ciphertext for this device, or drop the origin device's reconcile key.
      expect(row.envelopeStatus, 'own_origin');
    });
  });

  group('(lxvi) clause 2 — local plaintext outranks the none_for_device marker',
      () {
    // A re-linked install is a NEW device id (amendment (a): ids are never
    // reused), so the history read answers `none_for_device` for every row
    // that predates it — including rows THIS install already decrypted and
    // sealed under its previous id. Live QA 2026-09-02: those rows rendered
    // "sent before this device was linked" while the plaintext sat on disk.
    //
    // Falsification contract: removing `kNotLinkedYetMessageLabel` from
    // `_hasUsableDecryptedContent`'s placeholder set turns the first test RED
    // (the hydration pass counts the sentinel as usable and never consults
    // storage); the second is the control that a genuinely pre-link row is
    // unchanged.
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late EncryptionProvider encryption;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      encryption = EncryptionProvider();
      encryption.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          encryption.onOwnKeyBundleStatus({'exists': false});
        }
      });
      encryption.setOwnDeviceId(3);
      await encryption.initializeE2E(1);
      await pumpEventQueue(times: 200);

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      conversations.setCurrentUserId(1);
      conversations.onConversationsList([_convJson()]);
      conversations.openConversation(10);
      provider.setConversationsProvider(conversations);
      provider.setEncryptionProvider(encryption);
      provider.setCurrentUserId(1);
      provider.setIncomingMessageSoundEnabledForTest(false);
      provider.onConnect(false);
      provider.setActiveConversationIdForTest(10);
      provider.setEmitCallback((event, data) {});
    });

    test('a marked row this install already decrypted renders its sealed '
        'plaintext, not the placeholder', () async {
      // Sealed under the previous device id, exactly as the decrypt pass
      // persists a successful decrypt.
      await encryption.saveDecryptedContent(201, {
        'content': 'msg1 decrypted as device 2',
        'messageType': 'TEXT',
      }, conversationId: 10);
      expect(
        (await encryption.getDecryptedContent(201))?['content'],
        'msg1 decrypted as device 2',
      );

      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_row(id: 201, envelopeStatus: 'none_for_device')],
      });
      await pumpEventQueue(times: 200);

      final row = provider.messages.firstWhere((m) => m.id == 201);
      expect(row.content, 'msg1 decrypted as device 2');
      expect(row.envelopeStatus, 'none_for_device');
    });

    test('a marked row with nothing local stays hidden', () async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_row(id: 202, envelopeStatus: 'none_for_device')],
      });
      await pumpEventQueue(times: 200);

      expect(provider.messages, isEmpty);
      expect(provider.hiddenPreLinkCount, 1);
    });
  });

  // Amendment (lxxxvi). A storage loss on an account with linking OFF re-mints
  // the identity (`IDENTITY_MINTED {reason: server-bundle-unlocked-remint}`),
  // and every row the server still holds from before was sealed to keys this
  // install never had: the thread opened on a wall of "can't be read" bubbles.
  // Those rows now join the (lxxxi) divider. The boundary is the SERVER's audit
  // instant for the change that ended at this device's key — never a device
  // clock ((li)).
  //
  // Falsification: drop the pre-identity term from the filter → the count
  // stays 0 and the failed bubbles render; drop the provider callback → the
  // open thread is never told to re-filter when the audit row lands late.
  group('(lxxxvi) rows sealed before this identity existed', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late EncryptionService service;
    late EncryptionProvider encryption;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      service = EncryptionService();
      encryption = EncryptionProvider(service: service)
        ..setEmitCallback((event, data) {
          if (event == 'checkOwnKeyBundle') {
            encryption.onOwnKeyBundleStatus({'exists': false});
          }
        });
      await encryption.initializeE2E(1);
      await pumpEventQueue(times: 200);

      conversations = ConversationsProvider()
        ..setCurrentUserId(1)
        ..onConversationsList([_convJson()])
        ..openConversation(10);
      provider = MessagingProvider();
      // Wired the way `ConversationsScreen` wires production, so the F56
      // assertion below defends the real callback owner.
      ConnectionProvider(socketService: SocketService()).setProviders(
        encryption: encryption,
        friends: FriendsProvider(),
        conversations: conversations,
        messaging: provider,
      );
      provider
        ..setConversationsProvider(conversations)
        ..setEncryptionProvider(encryption)
        ..setCurrentUserId(1)
        ..setIncomingMessageSoundEnabledForTest(false)
        ..onConnect(false)
        ..setActiveConversationIdForTest(10)
        ..setEmitCallback((event, data) {});
    });

    test('unreadable rows older than the audit instant join the divider; '
        'readable rows and newer failures stay', () async {
      final minted = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );
      // Pre-loss rows whose plaintext came back from a history FILE are
      // readable, so their age must never hide them — including a keyed image,
      // which keeps `[encrypted]` as its content by design.
      await encryption.saveDecryptedContent(304, {
        'content': 'imported from the backup file',
        'messageType': 'TEXT',
      }, conversationId: 10);
      await encryption.saveDecryptedContent(305, {
        'content': '[encrypted]',
        'messageType': 'IMAGE',
        'mediaUrl': 'http://localhost:3000/media/msgs/a.bin',
        'mediaKey': 'a2V5',
        'mediaIv': 'aXY=',
      }, conversationId: 10);

      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _row(
            id: 304,
            encryptedContent: '2:ct',
            createdAt: minted.subtract(const Duration(hours: 2)),
          ),
          _row(
            id: 305,
            encryptedContent: '2:ct',
            messageType: 'IMAGE',
            createdAt: minted.subtract(const Duration(minutes: 90)),
          ),
          _row(
            id: 300,
            encryptedContent: '2:ct',
            createdAt: minted.subtract(const Duration(hours: 1)),
          ),
          _row(
            id: 301,
            senderId: 1,
            envelopeStatus: 'own_origin',
            createdAt: minted.subtract(const Duration(minutes: 59)),
          ),
          _row(
            id: 302,
            encryptedContent: '2:ct',
            createdAt: minted.add(const Duration(minutes: 1)),
          ),
        ],
      });
      await pumpEventQueue(times: 200);

      // Before the server names the boundary nothing is hidden.
      expect(
        provider.messages.map((m) => m.id),
        unorderedEquals([300, 301, 302, 304, 305]),
      );
      expect(provider.hiddenPreLinkCount, 0);

      var notified = 0;
      provider.addListener(() => notified++);
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      encryption.onOwnKeyBundleStatus({
        'exists': true,
        'linkingEnabled': false,
        'identityReplacedAt': minted.toIso8601String(),
        'identityReplacedTo': own,
      });
      await pumpEventQueue(times: 50);

      expect(
        notified,
        greaterThan(0),
        reason: 'an open thread must re-filter when the audit row lands after '
            'its history',
      );
      expect(
        provider.messages.map((m) => m.id),
        unorderedEquals([302, 304, 305]),
        reason: '300 (a peer row this install never opened, still '
            '[encrypted]) and 301 (own row whose only copy died with the old '
            'install) predate this identity',
      );
      expect(provider.hiddenPreLinkCount, 2);
    });

    test('after a restart a pre-boundary peer row still reading [encrypted] '
        'joins the divider; the same shape after the instant stays', () async {
      // The session that re-minted fails these rows as `[Decryption failed]`
      // (identity-reset rule), but that verdict is never persisted. After a
      // relaunch `hadIdentityReset` is false, a row with no session keeps
      // `[encrypted]` and waits for a retry — so the SAME row comes back
      // wearing the other placeholder. Seeded directly: no decrypt runs.
      final minted = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      await service.recordOwnIdentityReplacedFromServer(
        minted.toIso8601String(),
        replacedTo: own,
      );
      provider
        ..seedCacheForTest(10, [
          MessageModel.fromJson(
            _row(
              id: 320,
              encryptedContent: '2:ct',
              createdAt: minted.subtract(const Duration(hours: 1)),
            ),
          ),
          MessageModel.fromJson(
            _row(
              id: 321,
              encryptedContent: '2:ct',
              createdAt: minted.add(const Duration(minutes: 1)),
            ),
          ),
        ])
        ..loadCachedMessages(10);

      expect(
        provider.loadedMessagesForTest.map((m) => m.content),
        everyElement(kEncryptedPlaceholderLabel),
      );
      expect(provider.messages.map((m) => m.id), [321]);
      expect(provider.hiddenPreLinkCount, 1);
    });

    test('in the re-minting session a pre-boundary peer row failed as '
        '[Decryption failed] joins the divider; the same verdict after the '
        'instant stays', () async {
      // The identity-reset rule marks a row the minting session cannot open
      // `[Decryption failed]`, in memory only. Seeded directly: no decrypt runs.
      final minted = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );
      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      await service.recordOwnIdentityReplacedFromServer(
        minted.toIso8601String(),
        replacedTo: own,
      );
      provider
        ..seedCacheForTest(10, [
          MessageModel.fromJson(
            _row(
              id: 330,
              encryptedContent: '2:ct',
              createdAt: minted.subtract(const Duration(hours: 1)),
            ),
          ).copyWith(content: kDecryptionFailedLabel),
          MessageModel.fromJson(
            _row(
              id: 331,
              encryptedContent: '2:ct',
              createdAt: minted.add(const Duration(minutes: 1)),
            ),
          ).copyWith(content: kDecryptionFailedLabel),
        ])
        ..loadCachedMessages(10);

      expect(
        provider.loadedMessagesForTest.map((m) => m.content),
        everyElement(kDecryptionFailedLabel),
      );
      expect(provider.messages.map((m) => m.id), [331]);
      expect(provider.hiddenPreLinkCount, 1);
    });

    test('a boundary that moved without a notification still applies on the '
        'next read', () async {
      // The launch-time load from storage moves the boundary with no callback;
      // a view cached before it must not keep showing the failed rows.
      final minted = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          _row(
            id: 310,
            encryptedContent: '2:ct',
            createdAt: minted.subtract(const Duration(hours: 1)),
          ),
        ],
      });
      await pumpEventQueue(times: 200);
      expect(provider.messages.map((m) => m.id), [310]);

      final own =
          (await service.getKeyBundleForReupload())!['identityPublicKey']
              as String;
      await service.recordOwnIdentityReplacedFromServer(
        minted.toIso8601String(),
        replacedTo: own,
      );

      expect(provider.messages, isEmpty);
      expect(provider.hiddenPreLinkCount, 1);
    });
  });

  // Amendment (lxxxviii), owner decision 2026-09-23 (after dropping the
  // re-delivery, storage-loss Part C): a PEER row stamped AFTER the boundary
  // `T` that failed because it was sealed to a session this install never
  // held is SHOWN as a failure. Nothing will ever re-deliver it, so hiding it
  // would drop the message silently while its sender sees it delivered.
  // Falsification: hide the post-`T` dead-session failure again → the row
  // vanishes from [messages].
  group('(lxxxviii) post-boundary rows sealed to a session never held', () {
    late MessagingProvider provider;
    final since = DateTime.now().toUtc().subtract(const Duration(minutes: 10));

    Future<_BoundaryEncryption> wire({DateTime? boundary}) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final encryption = _BoundaryEncryption(since: boundary);
      final conversations = ConversationsProvider()
        ..setCurrentUserId(1)
        ..onConversationsList([_convJson()])
        ..openConversation(10);
      provider = MessagingProvider()
        ..setConversationsProvider(conversations)
        ..setEncryptionProvider(encryption)
        ..setCurrentUserId(1)
        ..setIncomingMessageSoundEnabledForTest(false)
        ..onConnect(false)
        ..setActiveConversationIdForTest(10)
        ..setEmitCallback((event, data) {});
      return encryption;
    }

    Future<void> loadHistory(List<Map<String, dynamic>> rows) async {
      await provider.onMessageHistory({'conversationId': 10, 'messages': rows});
      await pumpEventQueue(times: 200);
    }

    test('a post-boundary no-session failure is shown, not hidden; only the '
        'pre-boundary row joins the divider', () async {
      final encryption = await wire(boundary: since);
      encryption.failures
        ..[500] = 'NoSessionException: no session for 2'
        ..[502] = 'NoSessionException: no session for 2';
      await loadHistory([
        _row(
          id: 502,
          encryptedContent: '2:ct',
          createdAt: since.subtract(const Duration(hours: 1)),
        ),
        _row(
          id: 500,
          encryptedContent: '2:ct',
          createdAt: since.add(const Duration(minutes: 1)),
        ),
        _row(
          id: 501,
          encryptedContent: '2:ct',
          createdAt: since.add(const Duration(minutes: 2)),
        ),
      ]);

      expect(
        provider.messages.map((m) => (m.id, m.content)),
        [(500, kDecryptionFailedLabel), (501, 'readable 501')],
      );
      expect(provider.hiddenPreLinkCount, 1);
    });

    test('the identity-reset rule after the boundary is shown too', () async {
      final encryption = await wire(boundary: since)..identityReset = true;
      encryption.failures[510] = 'InvalidMessageException: no valid sessions';
      await loadHistory([
        _row(
          id: 510,
          encryptedContent: '2:ct',
          createdAt: since.add(const Duration(minutes: 1)),
        ),
      ]);

      expect(provider.messages.map((m) => m.content), [kDecryptionFailedLabel]);
      expect(provider.hiddenPreLinkCount, 0);
    });

    // A1 follows the same choice: the chat list must not blank a message the
    // thread shows. A live post-boundary row still in the restart shape
    // (`[encrypted]`, its no-session attempt already failed) that is unread
    // previews as "New message"; a pre-boundary row of the same shape is
    // history and previews nothing.
    test('an unread post-boundary row whose attempt failed is still new in '
        'the list; the same row before the boundary is not', () async {
      final encryption = await wire(boundary: since);
      encryption.failures
        ..[520] = 'NoSessionException: no session for 2'
        ..[521] = 'NoSessionException: no session for 2';
      for (final (id, at) in [
        (520, since.add(const Duration(minutes: 1))),
        (521, since.subtract(const Duration(hours: 1))),
      ]) {
        provider.onNewMessage(
          _row(id: id, encryptedContent: '2:ct', createdAt: at),
        );
      }
      await pumpEventQueue(times: 200);
      provider.onDisconnect(); // stop the debounced live retry

      MessageModel row(int id) =>
          provider.loadedMessagesForTest.firstWhere((m) => m.id == id);
      expect(row(520).content, kEncryptedPlaceholderLabel,
          reason: 'precondition: the restart shape, attempt already failed');
      expect(provider.messages.map((m) => m.id), [520]);
      // The first ask starts the lazy stored-plaintext lookup; the answer
      // (none held) lands on the next turn.
      provider
        ..listPreviewFor(row(520), unreadCount: 1)
        ..listPreviewFor(row(521), unreadCount: 1);
      await pumpEventQueue();
      expect(provider.listPreviewFor(row(520), unreadCount: 1)?.id, 520);
      expect(provider.listPreviewFor(row(521), unreadCount: 1), isNull);
    });
  });
}
