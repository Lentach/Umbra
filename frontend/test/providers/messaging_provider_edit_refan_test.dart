import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Edit re-fan contracts (multi-device spec §5.7 + §12 amendments (xxx)-(xxxiv)).
///
/// The Signal handshake is faked — a per-address deterministic ciphertext is all
/// these contracts need — but the re-fan decision, the envelope shape, the
/// version stamps and the receive-side device attribution are the real provider
/// code.
class _EditEncryption extends EncryptionProvider {
  final Map<int, VerifiedDeviceList> _cache = {};
  final List<(int, int)> encryptCalls = [];

  /// Every (senderId, deviceId) a decrypt was ATTEMPTED against. The whole
  /// ticket turns on this being the EDITING device, not the original sender's.
  final List<(int, int)> decryptAddresses = [];
  final List<String> encryptedPlaintexts = [];
  int _ownDeviceId = 1;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => _ownDeviceId;

  /// The server confirms this on `socketReady`; without it every device-scoped
  /// own-row decision falls back to "treat it as our own send" (amendment
  /// (xii)), which would hide the sibling-device edit case entirely.
  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  void setOwnDeviceId(int deviceId) => _ownDeviceId = deviceId;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => _cache[userId];

  void cache(int userId, VerifiedDeviceList list) => _cache[userId] = list;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => _cache[userId] ?? const VerifiedDeviceList.notEnrolled();

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async {
    encryptCalls.add((recipientId, deviceId));
    encryptedPlaintexts.add(plaintext);
    return '2:ct-for-$recipientId-$deviceId';
  }

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decryptAddresses.add((senderId, deviceId));
    return jsonEncode({'v': 1, 'content': 'decrypted-by-$senderId-$deviceId'});
  }

  @override
  void invalidateDecryptionCache(int messageId) {}
}

VerifiedDeviceList _enrolled(int version, List<int> deviceIds) =>
    VerifiedDeviceList.enrolled(
      version: version,
      devices: [
        for (final id in deviceIds)
          DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
      ],
    );

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

  group('MessagingProvider — edit re-fan', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _EditEncryption encryption;
    late List<Map<String, dynamic>> emitted;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _EditEncryption();
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

    Future<void> pump([int turns = 30]) async {
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// Seed one server-confirmed TEXT row through the real history path.
    Future<void> seed({
      required int id,
      required int senderId,
      int originDeviceId = 1,
    }) async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {
            'id': id,
            'content': '[encrypted]',
            'encryptedContent': 'seed-$id',
            'senderId': senderId,
            'senderUsername': senderId == 1 ? 'alice' : 'bob',
            'conversationId': 10,
            'deliveryStatus': 'READ',
            'messageType': 'TEXT',
            'originDeviceId': originDeviceId,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      });
      await pump();
      encryption.decryptAddresses.clear();
    }

    Map<String, dynamic> lastEdit() => (emitted.lastWhere(
      (e) => e['event'] == 'editMessage',
    )['data'] as Map<String, dynamic>);

    test('no cached list: the edit keeps the LEGACY single-ciphertext shape', () async {
      await seed(id: 500, senderId: 1);

      provider.editMessage(500, 'after');
      await pump();

      final edit = lastEdit();
      expect(edit.containsKey('envelopes'), isFalse);
      expect(edit['encryptedContent'], '2:ct-for-2-1');
      expect(edit.containsKey('recipientListVersion'), isFalse);
      expect(encryption.encryptCalls, [(2, 1)]);
    });

    test('cached lists: one DISTINCT edited ciphertext per device, origin excluded', () async {
      encryption.cache(2, _enrolled(4, [1, 2]));
      encryption.cache(1, _enrolled(7, [1, 3]));
      encryption.setOwnDeviceId(1);
      await seed(id: 500, senderId: 1);

      provider.editMessage(500, 'after');
      await pump();

      final edit = lastEdit();
      final envelopes = (edit['envelopes'] as List).cast<Map<String, dynamic>>();
      final addresses = envelopes.map((e) => (e['userId'], e['deviceId']));
      // Both of the peer's devices AND the sender's other device — an edit that
      // reached device 1 alone is the defect this ticket exists to fix.
      expect(addresses, containsAll([(2, 1), (2, 2), (1, 3)]));
      // Never this device: it holds the plaintext and the server refuses that
      // envelope as self_envelope_for_origin_device.
      expect(addresses, isNot(contains((1, 1))));
      // Reusing one ciphertext across devices would consume the same message
      // key twice and brick every device but the first.
      expect(
        envelopes.map((e) => e['ciphertext']).toSet(),
        hasLength(envelopes.length),
      );
      expect(edit['recipientListVersion'], 4);
      expect(edit['senderListVersion'], 7);
      expect(edit.containsKey('encryptedContent'), isFalse);
    });

    test('an edited envelope carries senderListInfo (amendment (xxxiv))', () async {
      encryption.cache(2, _enrolled(4, [1]));
      encryption.cache(1, _enrolled(7, [1]));
      await seed(id: 500, senderId: 1);

      provider.editMessage(500, 'after');
      await pump();

      final plaintext =
          jsonDecode(encryption.encryptedPlaintexts.last) as Map<String, dynamic>;
      // Omitting it would leave the edit as the one ciphertext-bearing message
      // with no E2E cross-check of the lists the server served.
      final info = plaintext['senderListInfo'] as Map<String, dynamic>;
      expect(info['ownVersion'], 7);
      expect(info['peerVersion'], 4);
    });

    test('an inbound peer edit is decrypted against the EDITING device', () async {
      // The accept-side gate ((e)/(xxvii)) only lets an `originDeviceId >= 2`
      // row decrypt when that device is live in a VERIFIED list, so the edit
      // arriving from the peer's device 3 needs that list held.
      encryption.cache(2, _enrolled(9, [1, 3]));
      await seed(id: 501, senderId: 2);

      // The peer edited from their device 3, so the ciphertext is bound to
      // THAT ratchet — decrypting against the row's original device 1 would
      // fail with a Bad-MAC on a row that decrypted fine before the edit.
      provider.onMessageEdited({
        'messageId': 501,
        'conversationId': 10,
        'content': '[encrypted]',
        'encryptedContent': '2:edited-by-3',
        'editedAt': '2026-08-22T10:00:00.000Z',
        'originDeviceId': 3,
      });
      await pump();

      expect(encryption.decryptAddresses, contains((2, 3)));
      expect(encryption.decryptAddresses, isNot(contains((2, 1))));
    });

    test('an edit from ANOTHER of my devices is decrypted, not just reconciled', () async {
      encryption.cache(1, _enrolled(9, [1, 2]));
      encryption.setOwnDeviceId(1);
      await seed(id: 500, senderId: 1);

      // My device 2 edited a row this device sent: this device now holds a real
      // self-sync envelope for its OWN row and must decrypt it, or my own edit
      // never lands here.
      provider.onMessageEdited({
        'messageId': 500,
        'conversationId': 10,
        'content': '[encrypted]',
        'encryptedContent': '2:edited-by-my-device-2',
        'editedAt': '2026-08-22T10:00:00.000Z',
        'originDeviceId': 2,
      });
      await pump();

      expect(encryption.decryptAddresses, contains((1, 2)));
    });

    test('the echo of MY OWN edit reconciles editedAt and decrypts nothing', () async {
      encryption.setOwnDeviceId(1);
      await seed(id: 500, senderId: 1);

      final contentBeforeEcho = provider.messages
          .firstWhere((m) => m.id == 500)
          .content;
      // This device produced the ciphertext, so it gets no envelope and the
      // echo carries none: there is nothing to decrypt.
      provider.onMessageEdited({
        'messageId': 500,
        'conversationId': 10,
        'content': '[encrypted]',
        'encryptedContent': null,
        'editedAt': '2026-08-22T10:00:00.000Z',
        'originDeviceId': 1,
      });
      await pump();

      expect(encryption.decryptAddresses, isEmpty);
      final row = provider.messages.firstWhere((m) => m.id == 500);
      expect(row.editedAt, isNotNull);
      // The locally held text must survive its own echo: the echo carries no
      // ciphertext, so overwriting with '[encrypted]' here would blank the
      // author's own message.
      expect(row.content, contentBeforeEcho);
    });
    test('a stale-list edit refusal is REPAIRED and re-fanned, not left diverging', () async {
      await seed(id: 500, senderId: 1);
      provider.editMessage(500, 'after');
      await pump();
      final firstEdit = lastEdit();
      expect(firstEdit.containsKey('envelopes'), isFalse, reason: 'no list held yet');

      // The server refuses and hands back the signed lists. Without a handler
      // for this the optimistic edit would stick on this device FOREVER while
      // the server and the peer keep the old ciphertext.
      encryption.cache(2, _enrolled(4, [1, 2]));
      encryption.cache(1, _enrolled(7, [1]));
      await provider.onDeviceListStale({
        'success': false,
        'error': 'device_list_stale',
        'messageId': 500,
        'lists': const [],
      });
      await pump();

      final repaired = lastEdit();
      final addresses = (repaired['envelopes'] as List)
          .cast<Map<String, dynamic>>()
          .map((e) => (e['userId'], e['deviceId']));
      expect(addresses, containsAll([(2, 1), (2, 2)]));
      expect(repaired['recipientListVersion'], 4);
      // The user's text survives the repair.
      expect(provider.messages.firstWhere((m) => m.id == 500).content, 'after');
    });

    test('a stale-list edit that never settles REVERTS instead of diverging', () async {
      await seed(id: 500, senderId: 1);
      final original = provider.messages.firstWhere((m) => m.id == 500).content;
      provider.editMessage(500, 'after');
      await pump();

      // Four refusals: three retries then a surfaced revert (§5.2 bounded
      // bounce). Retrying forever would strand the row in a state only this
      // device believes in.
      for (var i = 0; i < 4; i++) {
        await provider.onDeviceListStale({
          'success': false,
          'error': 'device_list_stale',
          'messageId': 500,
          'lists': const [],
        });
        await pump();
      }

      expect(provider.messages.firstWhere((m) => m.id == 500).content, original);
    });
    test('each new edit gets a FULL staleness budget', () async {
      await seed(id: 500, senderId: 1);

      Future<void> bounce() async {
        await provider.onDeviceListStale({
          'success': false,
          'error': 'device_list_stale',
          'messageId': 500,
          'lists': const [],
        });
        await pump();
      }

      // Spend the budget on a first edit, up to but NOT PAST the cap. Three
      // bounces leave the counter at 3 without tripping the exhaustion path —
      // which clears the key itself, and would therefore hand the next edit a
      // fresh budget even with the production reset removed, making this test
      // unable to fail.
      provider.editMessage(500, 'first');
      await pump();
      for (var i = 0; i < 3; i++) {
        await bounce();
      }

      // A SECOND, independent edit of the same row. The retry counter is keyed
      // by messageId (an edit has no tempId), so without a per-edit reset this
      // edit would inherit the spent budget and be reverted immediately.
      provider.editMessage(500, 'second');
      await pump();
      final beforeBounce = provider.messages
          .firstWhere((m) => m.id == 500)
          .content;
      expect(beforeBounce, 'second');
      await bounce();

      expect(
        provider.messages.firstWhere((m) => m.id == 500).content,
        'second',
        reason: 'the first bounce of a fresh edit must not revert it',
      );
    });
    test('a RATE-LIMITED edit reverts, because the refusal rides editMessageFailed', () async {
      await seed(id: 500, senderId: 1);
      final original = provider.messages.firstWhere((m) => m.id == 500).content;

      provider.editMessage(500, 'after');
      await pump();
      expect(provider.messages.firstWhere((m) => m.id == 500).content, 'after');

      // The server's throttle guard answers on the request's OWN response event
      // rather than a new global one, precisely so this needs no new client
      // code: silence here would strand the optimistic edit forever.
      provider.onEditMessageFailed({
        'messageId': 500,
        'reason': 'rate_limited',
        'retryAfterMs': 42000,
      });
      await pump();

      expect(provider.messages.firstWhere((m) => m.id == 500).content, original);
    });
  });
}
