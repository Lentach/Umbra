import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_seed.dart';

/// The real plaintext store; Signal and the device-list round trip are
/// faked. A "ciphertext" is `3:` + base64(the plaintext), so a frame the
/// box was handed can be read back.
class SendEncryption extends EncryptionProvider {
  SendEncryption(this.store) : super(service: store);

  final EncryptionService store;

  /// Verified lists this client holds, by user id; absent = not enrolled
  /// (single device 1).
  final Map<int, VerifiedDeviceList> lists = {};

  /// Signal sessions this device holds, as (user, device).
  final Set<(int, int)> sessions = {};

  /// When false the E2E layer is not ready: no send can encrypt.
  bool ready = true;

  /// What every encrypt throws, when set.
  Object? encryptError;

  @override
  bool get isE2EReady => ready;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => lists[userId];

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      lists.putIfAbsent(userId, () => const VerifiedDeviceList.notEnrolled());

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async =>
      sessions.contains((peerUserId, deviceId));

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {
    sessions.add((recipientId, deviceId));
  }

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async {
    final error = encryptError;
    if (error != null) throw error;
    return '3:${base64Encode(utf8.encode(plaintext))}';
  }
}

/// The box, as far as a send reads it: addresses, frames taken, uploads.
class SendOutbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};

  /// Our own other devices' self-queue addresses, by device id.
  final Map<int, ContactOutbound> siblings = {};

  /// Every frame handed over, with its address.
  final List<(ContactOutbound, BoxFrame)> delivered = [];

  /// Peer devices whose `send` the box refuses.
  final Set<int> refuse = {};

  /// Every `POST /box/media`, with the queue it was charged to.
  final List<(ContactOutbound, Uint8List)> uploads = [];

  /// What the box's media route holds, by base64url id.
  final Map<String, Uint8List> media = {};

  int _next = kFirstLocalMessageId + 40;

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      addresses[peerUserId] ?? const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => siblings;

  @override
  Iterable<int> coveredPeers() => [
    for (final MapEntry(:key, :value) in addresses.entries)
      if (value.isNotEmpty) key,
  ];

  @override
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    delivered.add((to, BoxFrame.decode(body)!));
    return refuse.contains(to.peerDeviceId)
        ? BoxSendOutcome.failed
        : BoxSendOutcome.taken;
  }

  @override
  Future<int?> nextLocalId() async => _next++;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    uploads.add((to, framed));
    final id = Uint8List(kBoxMediaIdBytes)..[0] = media.length + 1;
    media[boxB64(id)] = framed;
    return BoxOk(
      BoxMediaRef(id: id, bucket: 'd14', expiresAt: DateTime.utc(2026, 10, 10)),
    );
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    final body = media[boxB64(id)];
    return body == null ? const BoxRefused(BoxCode.notFound) : BoxOk(body);
  }
}

/// A "ciphertext" is the plaintext reversed plus a 16-byte tag; every encrypt
/// is kept, and a plaintext in here means a file was encrypted for the box.
class ReversingMediaCrypto extends MediaCryptoService {
  final List<Uint8List> encrypted = [];

  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async {
    encrypted.add(bytes);
    final n = encrypted.length;
    return EncryptedMedia(
      ciphertext: Uint8List.fromList([
        ...bytes.reversed,
        ...List.filled(16, n),
      ]),
      keyBase64: base64Encode(List.filled(32, n)),
      ivBase64: base64Encode(List.filled(12, n)),
    );
  }
}

ContactOutbound boxAddress(int device) => ContactOutbound(
  peerDeviceId: device,
  sid: 'sid-$device',
  sealPub: 'seal-$device',
);

VerifiedDeviceList enrolledList(List<int> live) => VerifiedDeviceList.enrolled(
  version: 3,
  listHash: 'H' * 44,
  devices: [
    for (final id in live..sort())
      DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
  ],
);

/// One chat (id 10) between user 1 (this device's account) and Bob (2), a
/// [MessagingProvider] over a fake box, and every socket emit it makes.
class BoxSendHarness {
  BoxSendHarness._(
    this.provider,
    this.conversations,
    this.encryption,
    this.outbox,
    this.crypto,
    this.emitted,
  );

  final MessagingProvider provider;
  final ConversationsProvider conversations;
  final SendEncryption encryption;
  final SendOutbox outbox;
  final ReversingMediaCrypto crypto;

  /// Every event the provider emitted on the account socket.
  final List<String> emitted;

  static Future<BoxSendHarness> create() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    // Box-ready a moment ago: a held peer list is kept (decision 51).
    await service.markBoxListsReady(DateTime.now().millisecondsSinceEpoch);
    final encryption = SendEncryption(service);
    final conversations = ConversationsProvider()..setCurrentUserId(1);
    seedConversations(conversations, [
      {
        'id': 10,
        'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
        'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
        'createdAt': '2026-01-01T00:00:00.000Z',
        'unreadCount': 0,
        'lastMessage': null,
      },
    ]);
    conversations.openConversation(10);
    final outbox = SendOutbox();
    final crypto = ReversingMediaCrypto();
    final emitted = <String>[];
    final provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10)
      ..setEmitCallback((event, data) => emitted.add(event))
      ..boxOutbox = outbox
      ..setMediaCryptoForTest(crypto);
    return BoxSendHarness._(
      provider,
      conversations,
      encryption,
      outbox,
      crypto,
      emitted,
    );
  }

  /// Bob (2) on devices [live]; every one of [addressed] (default: all of
  /// them) handed us a queue.
  void bob(List<int> live, {List<int>? addressed}) {
    encryption.lists[2] = enrolledList([...live]);
    outbox.addresses[2] = {for (final d in addressed ?? live) d: boxAddress(d)};
    provider.refreshBoxDeviceLists();
  }

  Future<void> pump([int turns = 40]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void dispose() => provider.dispose();
}
