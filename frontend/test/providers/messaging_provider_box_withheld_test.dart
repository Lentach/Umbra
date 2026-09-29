import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real plaintext store; Signal and the peer's device list are faked.
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  final List<int?> decryptedIds = [];

  /// The friend's verified list this device HOLDS; null = none held, and a
  /// fetch fails.
  VerifiedDeviceList? held;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == 2 ? held : null;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => throw StateError('no list in this test');

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decryptedIds.add(messageId);
    return jsonEncode(E2eEnvelope.build('hello'));
  }
}

VerifiedDeviceList _list(List<int> live, {List<int> revoked = const []}) =>
    VerifiedDeviceList.enrolled(
      version: 3,
      listHash: 'H' * 44,
      devices: [
        for (final id in [...live, ...revoked]..sort())
          DeviceListEntry(
            deviceId: id,
            platform: 'test',
            addedAtMs: 0,
            revokedAtMs: revoked.contains(id) ? 1 : null,
          ),
      ],
    );

const _bob = ContactRecord(
  userId: 2,
  username: 'bob',
  tag: '0002',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: 10),
);

/// BOX-WITHHELD-FOREVER (G5): a friend's box frame from a device the held
/// list does not name live is never held for good — the revoked, possibly
/// stolen, device still holds our old queue's sid and can claim any device
/// id. As `_readSiblingBox` (E8): a REVOKED verdict is finished at once; an
/// absent origin is held until the box could no longer redeliver it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late _Encryption encryption;
  var nextLocal = kFirstLocalMessageId;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _Encryption(service);
    final conversations = ConversationsProvider()
      ..setCurrentUserId(1)
      ..onConversationsList([
        {
          'id': 10,
          'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
          'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
      ])
      ..openConversation(10);
    provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10);
  });

  /// Whether the reader is FINISHED with a frame from bob's [device],
  /// received [age] ago.
  Future<bool> read(int device, {Duration age = Duration.zero}) =>
      provider.consumeBoxEntry(
        BoxInboxEntry(
          rid: 'rid',
          id: 'm${nextLocal - kFirstLocalMessageId}',
          localId: nextLocal++,
          peerUserId: 2,
          senderDeviceId: device,
          signal: '2:AQID',
          receivedAt: DateTime.now().toUtc().subtract(age),
          acked: true,
        ),
        _bob,
      );

  const window = kBoxRedeliveryWindow;
  const margin = Duration(hours: 1);

  test('a device the held list names REVOKED is finished at once, unread', () async {
    encryption.held = _list([1], revoked: [3]);

    expect(await read(3), isTrue);
    expect(encryption.decryptedIds, isEmpty);
    expect(provider.messages, isEmpty);
  });

  test(
    'a device the held list does not name is held while the box could '
    'still redeliver it, then finished unread',
    () async {
      encryption.held = _list([1]);

      expect(await read(7), isFalse, reason: 'fresh');
      expect(await read(7, age: window - margin), isFalse, reason: 'inside');
      expect(await read(7, age: window + margin), isTrue, reason: 'past');
      expect(encryption.decryptedIds, isEmpty);
      expect(provider.messages, isEmpty);
    },
  );

  test(
    'with no list held and none reachable, a device >= 2 is held the same '
    'way, then finished unread',
    () async {
      expect(await read(2, age: window - margin), isFalse);
      expect(await read(2, age: window + margin), isTrue);
      expect(encryption.decryptedIds, isEmpty);
    },
  );

  test('a live device is still read', () async {
    encryption.held = _list([1, 3]);

    expect(await read(3, age: window + margin), isTrue);
    expect(encryption.decryptedIds, hasLength(1));
  });
}
