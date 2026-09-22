import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ACCEPT-side revocation (multi-device spec §12 amendments (e)/(xxvii)).
///
/// Revocation is bidirectional. Not routing envelopes to a revoked device is
/// only half of it: a message SENT by a device that the sender's own signed
/// list shows as revoked must be refused at RECEIVE time too, or a stolen
/// device keeps talking to every peer that still holds its session.
///
/// The refusal must also be the RIGHT KIND of refusal: silent (a decrypt
/// refusal is not an alarm surface, I7) and retryable (the verified-list cache
/// is memory-only, so "no list yet" is the normal state after every reload and
/// must never become a permanent verdict on a message).
class _AcceptEncryption extends EncryptionProvider {
  _AcceptEncryption();

  final Map<int, VerifiedDeviceList> _cache = {};

  /// Every `getVerifiedDeviceList` call, in order.
  final List<int> refreshes = [];

  /// Answers a fetch when the cache is cold; null makes the fetch fail closed.
  VerifiedDeviceList? fetchAnswer;

  /// Every decrypt attempt as `(senderId, deviceId)` — empty means refused.
  final List<(int, int)> decryptCalls = [];

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => _cache[userId];

  void seed(int userId, VerifiedDeviceList list) => _cache[userId] = list;

  @override
  void invalidateDeviceList(int userId) => _cache.remove(userId);

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    refreshes.add(userId);
    final answer = fetchAnswer;
    if (answer == null) {
      // Same fail-closed contract as production: a timeout or a bad chain
      // THROWS rather than degrading to "single device".
      throw StateError('device list unavailable');
    }
    _cache[userId] = answer;
    return answer;
  }

  @override
  Future<bool> hasSessionWith(int peerId, {int deviceId = 1}) async => true;

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decryptCalls.add((senderId, deviceId));
    return jsonEncode(E2eEnvelope.build('hello from the peer'));
  }
}

VerifiedDeviceList _list({
  required int version,
  required List<DeviceListEntry> devices,
}) => VerifiedDeviceList.enrolled(version: version, devices: devices);

const _live1 = DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0);
const _live2 = DeviceListEntry(deviceId: 2, platform: 'web', addedAtMs: 10);
const _revoked2 = DeviceListEntry(
  deviceId: 2,
  platform: 'web',
  addedAtMs: 10,
  revokedAtMs: 20,
);
const _live3 = DeviceListEntry(deviceId: 3, platform: 'web', addedAtMs: 30);
const _revoked1 = DeviceListEntry(
  deviceId: 1,
  platform: 'test',
  addedAtMs: 0,
  revokedAtMs: 40,
);

Map<String, dynamic> _convJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': null,
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _peerRow({required int id, required int originDeviceId}) =>
    {
      'id': id,
      'senderId': 2,
      'senderUsername': 'bob',
      'content': '[encrypted]',
      'encryptedContent': '2:peer-ciphertext-$id',
      'originDeviceId': originDeviceId,
      'conversationId': 10,
      'deliveryStatus': 'DELIVERED',
      'messageType': 'TEXT',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('accept-side revocation', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _AcceptEncryption encryption;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _AcceptEncryption();

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

    Future<void> receive({required int id, required int originDeviceId}) async {
      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [_peerRow(id: id, originDeviceId: originDeviceId)],
      });
      await pump();
    }

    test('a live origin device decrypts normally', () async {
      encryption.seed(2, _list(version: 3, devices: const [_live1, _live2]));

      await receive(id: 8001, originDeviceId: 2);

      expect(encryption.decryptCalls, [(2, 2)]);
      expect(
        provider.messages.firstWhere((m) => m.id == 8001).content,
        'hello from the peer',
      );
    });

    test(
      'a REVOKED origin device is refused, and never reaches the ratchet',
      () async {
        encryption.seed(
          2,
          _list(version: 4, devices: const [_live1, _revoked2]),
        );

        await receive(id: 8002, originDeviceId: 2);

        expect(
          encryption.decryptCalls,
          isEmpty,
          reason: 'the ciphertext of a revoked device must not be accepted',
        );
        final row = provider.messages.firstWhere((m) => m.id == 8002);
        // Retryable, not a terminal failure: the row keeps its placeholder and
        // no `[Decryption failed]` is written over it.
        expect(row.content, '[encrypted]');
      },
    );

    test('an origin device ABSENT from the list is refused', () async {
      // Never linked, or linked after this list version — either way we hold no
      // signed evidence that it belongs to the account.
      encryption.seed(2, _list(version: 2, devices: const [_live1]));

      await receive(id: 8003, originDeviceId: 3);

      expect(encryption.decryptCalls, isEmpty);
    });

    test('a NON-ENROLLED sender may only speak as device 1', () async {
      encryption.seed(2, const VerifiedDeviceList.notEnrolled());

      await receive(id: 8004, originDeviceId: 1);
      expect(encryption.decryptCalls, [(2, 1)]);

      await receive(id: 8005, originDeviceId: 2);
      expect(
        encryption.decryptCalls,
        [(2, 1)],
        reason: 'a non-enrolled account has exactly one device by construction',
      );
    });

    test('a legacy row with NO originDeviceId is read as device 1', () async {
      encryption.seed(2, _list(version: 3, devices: const [_live1, _live2]));

      provider.onMessageHistory({
        'conversationId': 10,
        'messages': [
          {..._peerRow(id: 8006, originDeviceId: 1)}..remove('originDeviceId'),
        ],
      });
      await pump();

      expect(encryption.decryptCalls, [(2, 1)]);
    });

    group('a cache miss is not a verdict (amendment (xxvii))', () {
      test('fetches a verified list and decrypts on it', () async {
        encryption.fetchAnswer = _list(
          version: 3,
          devices: const [_live1, _live2],
        );

        await receive(id: 8007, originDeviceId: 2);

        expect(encryption.refreshes, [2]);
        expect(encryption.decryptCalls, [(2, 2)]);
      });

      test(
        'refuses on the FETCHED list when it shows the origin revoked',
        () async {
          encryption.fetchAnswer = _list(
            version: 5,
            devices: const [_live1, _revoked2],
          );

          await receive(id: 8008, originDeviceId: 2);

          expect(encryption.refreshes, [2]);
          expect(encryption.decryptCalls, isEmpty);
        },
      );

      test(
        'a failed fetch leaves the row RETRYABLE, never terminally failed',
        () async {
          // fetchAnswer stays null, so the fetch throws — the production
          // fail-closed contract.
          await receive(id: 8009, originDeviceId: 2);

          expect(encryption.decryptCalls, isEmpty);
          final row = provider.messages.firstWhere((m) => m.id == 8009);
          expect(
            row.content,
            '[encrypted]',
            reason:
                'a missing list must never be written over the message as a '
                'permanent failure — the next pass asks again',
          );
        },
      );
    });

    group('a stale cache HIT is not a verdict either', () {
      // Peer wedged after a phrase restore, 2026-09-22: the sender restored
      // its identity, the server moved its bundle to a NEW device id and
      // revoked the old one, and this client sat on the pre-restore list. The
      // in-band `senderListInfo` that would refresh it rides INSIDE the E2E
      // plaintext of the very row being withheld, so the cache could never
      // heal itself — every inbound row stayed `[encrypted]` until a reload.
      test(
        'refetches once and accepts when the fresh list shows it live',
        () async {
          encryption
            ..seed(2, _list(version: 1, devices: const [_live1]))
            ..fetchAnswer = _list(
              version: 2,
              devices: const [_revoked1, _live3],
            );

          await receive(id: 8011, originDeviceId: 3);

          expect(encryption.refreshes, [2]);
          expect(encryption.decryptCalls, [(2, 3)]);
        },
      );

      test('a fresh list still lacking the device withholds, once', () async {
        encryption
          ..seed(2, _list(version: 1, devices: const [_live1]))
          ..fetchAnswer = _list(version: 2, devices: const [_live1]);

        await receive(id: 8012, originDeviceId: 3);
        expect(encryption.refreshes, [2]);
        expect(encryption.decryptCalls, isEmpty);

        await receive(id: 8013, originDeviceId: 3);
        expect(
          encryption.refreshes,
          [2],
          reason:
              'one re-fetch per cooldown — a sender stuck on a device we do '
              'not hold must not become a fetch storm',
        );
        expect(encryption.decryptCalls, isEmpty);
      });
    });

    test(
      'own rows never reach this gate (the (xi) branches run first)',
      () async {
        // An own_origin row of ours: no ciphertext to decrypt and no list lookup,
        // whatever the roster says.
        encryption.seed(1, _list(version: 9, devices: const [_live1]));
        provider.onMessageHistory({
          'conversationId': 10,
          'messages': [
            {
              'id': 8010,
              'senderId': 1,
              'senderUsername': 'alice',
              'content': '[encrypted]',
              'envelopeStatus': 'own_origin',
              'originDeviceId': 1,
              'conversationId': 10,
              'deliveryStatus': 'SENT',
              'messageType': 'TEXT',
              'createdAt': DateTime.now().toUtc().toIso8601String(),
            },
          ],
        });
        await pump();

        expect(encryption.decryptCalls, isEmpty);
        expect(encryption.refreshes, isEmpty);
      },
    );
  });
}
