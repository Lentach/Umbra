import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/device_list/sender_list_info.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RECEIVE-side wiring of the §5.2 layer-2 cross-check (spec §12 amendments
/// (xv)/(xvi)/(xvii)).
///
/// `sender_list_info_test.dart` covers the pure decision logic. What is defended
/// here is that the provider actually CALLS it on an inbound message and that
/// the bounded consequences are the only ones that happen: at most one
/// device-list re-fetch per account per cooldown, a calm syncing flag for our
/// own skew, and — whatever the claim says — no alarm, no trust change, and no
/// unbounded work. A claim rides on every message, so a hostile peer gets to
/// run this path as often as it likes.
class _ClaimEncryption extends EncryptionProvider {
  _ClaimEncryption();

  final Map<int, VerifiedDeviceList> _cache = {};

  /// Every `getVerifiedDeviceList` call, in order — the re-fetch budget.
  final List<int> refreshes = [];

  /// The claim the next decrypt will hand back inside the envelope.
  SenderListInfo? claim;

  /// Optional latch: when set, `getVerifiedDeviceList` parks until it is
  /// completed, so a test can observe the calm flag WHILE the fetch is in
  /// flight. Every existing test leaves it null and is unaffected.
  Completer<void>? gate;

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
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    refreshes.add(userId);
    if (gate != null) await gate!.future;
    // Whatever we re-fetch, our OWN verified truth does not change — that is
    // the point: the peer's claim never rewrites it.
    final resolved = _cache[userId] ?? const VerifiedDeviceList.notEnrolled();
    _cache[userId] = resolved;
    return resolved;
  }

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => jsonEncode(
    E2eEnvelope.build('hello from the peer', senderListInfo: claim?.toJson()),
  );
}

VerifiedDeviceList _enrolled(int version, String hash) =>
    VerifiedDeviceList.enrolled(
      version: version,
      listHash: hash,
      devices: const [
        DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
      ],
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

Map<String, dynamic> _peerRow(int id) => {
  'id': id,
  'senderId': 2,
  'senderUsername': 'bob',
  'content': '[encrypted]',
  'encryptedContent': '2:peer-ciphertext-$id',
  'originDeviceId': 1,
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('senderListInfo — receive wiring', () {
    late MessagingProvider provider;
    late ConversationsProvider conversations;
    late _ClaimEncryption encryption;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      provider = MessagingProvider();
      conversations = ConversationsProvider();
      encryption = _ClaimEncryption();

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

    Future<void> receive(int id) async {
      provider.onNewMessage(_peerRow(id));
      await pump();
    }

    test('a matching claim changes nothing at all', () async {
      encryption.seed(2, _enrolled(3, 'peer'));
      encryption.seed(1, _enrolled(5, 'mine'));
      encryption.claim = const SenderListInfo(
        ownVersion: 3,
        ownListHash: 'peer',
        peerVersion: 5,
        peerListHash: 'mine',
      );

      await receive(9001);

      expect(encryption.refreshes, isEmpty, reason: 'nothing to re-check');
      expect(provider.devicesSyncing, isFalse);
      // The message itself still arrives — the cross-check is never allowed to
      // interfere with delivery.
      expect(
        provider.messages.firstWhere((m) => m.id == 9001).content,
        'hello from the peer',
      );
    });

    test(
      'a NEWER peer claim buys exactly ONE re-fetch, then is dropped',
      () async {
        encryption.seed(2, _enrolled(3, 'peer'));
        encryption.claim = const SenderListInfo(ownVersion: 99);

        await receive(9002);
        expect(encryption.refreshes, [2], reason: 'one re-check of the PEER');

        // A storm of further claims inside the cooldown must not fetch again —
        // otherwise a hostile peer turns every message into a round trip.
        for (var i = 0; i < 10; i++) {
          await receive(9100 + i);
        }
        expect(
          encryption.refreshes,
          [2],
          reason: 'rate-limited to one in flight per account plus a cooldown',
        );
        expect(
          provider.devicesSyncing,
          isFalse,
          reason: 'a peer-side claim is not our own devices syncing',
        );
      },
    );

    test(
      'own-device skew raises the calm flag and re-fetches OUR list',
      () async {
        // The accept-side gate (amendment (e)) needs a verified list for the
        // SENDER before it decrypts anything; seeding it keeps this test about
        // the escalation's own re-fetch budget.
        encryption.seed(2, _enrolled(7, 'peer'));
        encryption.seed(1, _enrolled(5, 'mine'));
        encryption.claim = const SenderListInfo(peerVersion: 6);

        await receive(9003);

        expect(encryption.refreshes, [1], reason: 'we re-check OUR OWN list');
        // The flag is bounded by the same limiter, so it cannot be pinned on
        // permanently by a peer that keeps claiming a version we do not have.
        for (var i = 0; i < 10; i++) {
          await receive(9200 + i);
        }
        expect(encryption.refreshes, [1]);
        expect(
          provider.devicesSyncing,
          isFalse,
          reason: 'cleared after the fetch',
        );
      },
    );

    test(
      'the calm flag is actually RAISED while our own list is re-fetched',
      () async {
        // The sibling test above only ever observes the flag after the fetch
        // has settled, so deleting `_setDevicesSyncing(true)` from the
        // escalation would leave it green while DevicesSyncingNote silently
        // never appeared (spec §12 (xvii)). Hold the fetch open and look.
        encryption.seed(2, _enrolled(7, 'peer'));
        encryption.seed(1, _enrolled(5, 'mine'));
        encryption.claim = const SenderListInfo(peerVersion: 6);
        final gate = Completer<void>();
        encryption.gate = gate;

        final inFlight = receive(9004);
        await pump();

        expect(
          provider.devicesSyncing,
          isTrue,
          reason: 'raised for the duration of the re-fetch',
        );

        gate.complete();
        await inFlight;
        await pump();

        expect(
          provider.devicesSyncing,
          isFalse,
          reason: 'and cleared once it settles',
        );
      },
    );

    test(
      'a frozen-list claim never alarms and never blocks the message',
      () async {
        encryption.seed(2, _enrolled(7, 'peer'));
        encryption.claim = const SenderListInfo(
          ownVersion: 2,
          ownListHash: 'stale',
        );

        await receive(9004);

        // The split-view signal is recorded for the operator, not surfaced as a
        // security state and never as a delivery failure (I7).
        expect(provider.devicesSyncing, isFalse);
        expect(
          provider.messages.firstWhere((m) => m.id == 9004).content,
          'hello from the peer',
        );
        expect(
          encryption.cachedDeviceList(2)!.version,
          7,
          reason: 'our verified truth is untouched by a claim',
        );
      },
    );

    test(
      'a malformed claim is ignored and the message still arrives',
      () async {
        encryption.seed(2, _enrolled(3, 'peer'));
        encryption.claim = null; // envelope carries no senderListInfo at all

        await receive(9005);

        expect(encryption.refreshes, isEmpty);
        expect(provider.devicesSyncing, isFalse);
        expect(
          provider.messages.firstWhere((m) => m.id == 9005).content,
          'hello from the peer',
        );
      },
    );
  });

  group('senderListInfo on a BOX frame (slice (e), E50f)', () {
    late MessagingProvider provider;
    late _ClaimEncryption encryption;
    late _Link link;
    var nextLocal = kFirstLocalMessageId;

    const peer = ContactRecord(
      userId: 2,
      username: 'bob',
      tag: '0002',
      state: ContactState.friend,
      legacy: ContactLegacy(conversationId: 10),
    );

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final conversations = ConversationsProvider()
        ..setCurrentUserId(1)
        ..onConversationsList([_convJson()]);
      encryption = _ClaimEncryption();
      link = _Link();
      provider = MessagingProvider()
        ..setConversationsProvider(conversations)
        ..setEncryptionProvider(encryption)
        ..setCurrentUserId(1)
        ..setIncomingMessageSoundEnabledForTest(false)
        ..onConnect(false)
        ..setEmitCallback((event, data) {})
        ..boxFriends = link;
    });

    Future<void> receiveBox({int device = 1}) async {
      final localId = nextLocal++;
      await provider.consumeBoxEntry(
        BoxInboxEntry(
          rid: 'peer-rid',
          id: 'm$localId',
          localId: localId,
          peerUserId: 2,
          senderDeviceId: device,
          signal: '2:box-ciphertext-$localId',
          receivedAt: DateTime.now().toUtc(),
          acked: true,
        ),
        peer,
      );
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a NEWER claim of the sender is never looked up: its own '
        'announcements carry it (decision 51)', () async {
      encryption
        ..seed(2, _enrolled(3, 'peer'))
        ..claim = const SenderListInfo(ownVersion: 99);

      await receiveBox();

      expect(encryption.refreshes, isEmpty);
    });

    test('a view of OUR list older than ours is answered with our list into '
        "that device's queue — once per device and version", () async {
      encryption
        ..seed(2, _enrolled(3, 'peer'))
        ..seed(
          1,
          const VerifiedDeviceList.enrolled(
            version: 5,
            listHash: 'mine',
            devices: [
              DeviceListEntry(deviceId: 1, platform: 'test', addedAtMs: 0),
            ],
            authorization: {'listVersion': 5},
          ),
        )
        ..claim = const SenderListInfo(ownVersion: 3, peerVersion: 5);

      await receiveBox();
      expect(link.listUpdates, isEmpty, reason: 'a current view: nothing');

      encryption.claim = const SenderListInfo(ownVersion: 3, peerVersion: 4);
      await receiveBox();
      await receiveBox();

      expect(link.listUpdates, hasLength(1));
      final (to, device, auth) = link.listUpdates.single;
      expect((to, device), (2, 1));
      expect(auth, {'listVersion': 5});
      expect(encryption.refreshes, isEmpty, reason: 'no server lookup');
    });
  });
}

/// The box's friend side, as far as a list answer goes.
class _Link implements BoxFriendLink {
  final List<(int, int, Map<String, dynamic>)> listUpdates = [];

  @override
  Future<bool> sendListUpdate(
    int userId,
    int deviceId,
    Map<String, dynamic> auth,
  ) async {
    listUpdates.add((userId, deviceId, auth));
    return true;
  }

  @override
  Future<bool> announceOwnList(Map<String, dynamic> auth) async => true;

  @override
  void friendDevicesChanged(int userId) {}

  @override
  bool get onBox => true;

  @override
  ContactRecord? contactOf(int userId) => null;

  @override
  Future<FriendWrite> takeFriendHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async => FriendWrite.refused;

  @override
  Future<FriendWrite> friendAcked(int userId, int deviceId, String sid) async =>
      FriendWrite.refused;

  @override
  Future<void> rekeyFriend(int userId, int deviceId) async {}

  @override
  void friendSessionStarted(int userId, int deviceId) {}

  @override
  bool awaitingFriendRekeyFrom(int userId, int deviceId) => false;

  @override
  void friendRekeyAnswered(int userId, int deviceId) {}

  @override
  void friendHeard(int userId, int deviceId) {}

  @override
  void rekeyFriendNextConnect(int userId, int deviceId) {}
}
