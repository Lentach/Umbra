import 'dart:async';
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

/// [SendEncryption] with the server's side scripted: what a forced list fetch
/// finds, lookups and bundle fetches held in flight, and the real
/// [ensureSession] rebuild contract.
class ScriptedSendEncryption extends SendEncryption {
  ScriptedSendEncryption(super.store);

  /// What a forced fetch finds on the server, when it differs from [lists].
  final Map<int, VerifiedDeviceList> served = {};

  /// Every lookup that reaches the server — forced, or a list not held —
  /// by user id.
  final List<int> forcedFetches = [];

  /// Every `getVerifiedDeviceList` call, forced or not — a cache miss would
  /// fetch in the real provider.
  final List<int> fetches = [];

  /// Users whose list cannot be verified (the fetch fails closed).
  final Set<int> unverifiable = {};

  /// When set, every forced fetch waits for it: a lookup still in flight.
  Completer<void>? fetchHold;

  /// Per-user holds, taking precedence over [fetchHold].
  final Map<int, Completer<void>> holdFor = {};

  /// Peer devices whose Signal message comes out longer than one frame.
  final Set<int> oversize = {};

  final List<(int, int)> encryptCalls = [];

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    fetches.add(userId);
    // The real provider asks the server when forced AND when it holds
    // nothing (decision 51: a held peer list is kept across connects).
    final lookup = forceRefresh || !lists.containsKey(userId);
    if (lookup) {
      forcedFetches.add(userId);
      await (holdFor[userId] ?? fetchHold)?.future;
    }
    if (unverifiable.contains(userId)) throw StateError('chain refused');
    if (lookup) {
      // Like the real cache: a verified answer is held, a non-enrolled one
      // included.
      lists[userId] =
          served[userId] ??
          lists[userId] ??
          const VerifiedDeviceList.notEnrolled();
    }
    return lists[userId] ?? const VerifiedDeviceList.notEnrolled();
  }

  /// Every pre-key bundle fetch the real [ensureSession] would emit on the
  /// account socket, as (user, device).
  final List<(int, int)> bundleFetches = [];

  /// Addresses whose bundle fetch fails (no bundle, a timeout).
  final Set<(int, int)> unbuildable = {};

  /// Per-address holds on a bundle fetch still in flight.
  final Map<(int, int), Completer<void>> buildHold = {};

  /// The real one's contract: a session with no rebuild pending returns at
  /// once; anything else fetches the bundle and builds, and a failed build
  /// leaves the rebuild pending.
  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {
    final address = (recipientId, deviceId);
    final rebuild = needsSessionRebuild(recipientId, deviceId: deviceId);
    clearSessionRebuild(recipientId, deviceId: deviceId);
    if (sessions.contains(address) && !rebuild) return;
    bundleFetches.add(address);
    await buildHold[address]?.future;
    if (unbuildable.contains(address)) {
      if (rebuild) markSessionRebuild(recipientId, deviceId: deviceId);
      throw StateError('Recipient has no key bundle');
    }
    sessions.add(address);
  }

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async {
    encryptCalls.add((recipientId, deviceId));
    final error = encryptError;
    if (error != null) throw error;
    final bytes = oversize.contains(deviceId)
        ? Uint8List(BoxFrame.maxSignalBytes + 1)
        : utf8.encode(plaintext);
    return '3:${base64Encode(bytes)}';
  }

  /// When set, a stored record cannot be proven (a write the store
  /// swallowed).
  bool recordsUnproven = false;

  /// While set, `recordExists` waits for it: a store write in flight.
  Completer<void>? recordHold;

  @override
  Future<bool?> recordExists(int messageId) async {
    await recordHold?.future;
    return recordsUnproven ? false : super.recordExists(messageId);
  }

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
    if (recordsUnproven) return;
    await super.saveDecryptedContent(
      messageId,
      data,
      conversationId: conversationId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      disappearAfterSeconds: disappearAfterSeconds,
      wire: wire,
    );
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
  Future<BoxResult<void>> deleteMedia(Uint8List id, Uint8List secret) async =>
      const BoxOk(null);

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

/// [SendOutbox] with the box's answers scripted: a full queue, a box or an
/// upload that has not answered yet, no local id, and deletes. Its uploads
/// carry a delete secret.
class ScriptedSendOutbox extends SendOutbox {
  /// Devices whose queue is full (`queue_full`).
  final Set<int> full = {};

  /// How each frame was kept, by sid, in send order (decision 61).
  final List<(String, BoxSendMode?)> modes = [];

  bool noLocalId = false;

  /// When set, every `send` waits for it: a box that has not answered yet.
  Completer<void>? hold;

  /// When set, the media route answers this instead of storing the body.
  BoxResult<BoxMediaRef>? uploadAnswer;

  /// When set, every `POST /box/media` waits for it: an upload in flight.
  Completer<void>? uploadHold;

  /// Every `DELETE /box/media`, with the secret it presented.
  final List<(Uint8List, Uint8List)> deletes = [];

  /// When set, a delete never completes until it does.
  Completer<void>? deleteHold;

  @override
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    delivered.add((to, BoxFrame.decode(body)!));
    modes.add((to.sid, mode));
    await hold?.future;
    if (full.contains(to.peerDeviceId)) return BoxSendOutcome.full;
    return refuse.contains(to.peerDeviceId)
        ? BoxSendOutcome.failed
        : BoxSendOutcome.taken;
  }

  @override
  Future<int?> nextLocalId() async => noLocalId ? null : _next++;

  @override
  Future<BoxResult<void>> deleteMedia(Uint8List id, Uint8List secret) async {
    deletes.add((id, secret));
    await deleteHold?.future;
    return const BoxOk(null);
  }

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    uploads.add((to, framed));
    await uploadHold?.future;
    final answer = uploadAnswer;
    if (answer != null) return answer;
    final id = Uint8List(kBoxMediaIdBytes)..[0] = media.length + 1;
    media[boxB64(id)] = framed;
    return BoxOk(
      BoxMediaRef(
        id: id,
        bucket: 'd14',
        expiresAt: DateTime.utc(2026, 10, 10),
        deleteSecret: Uint8List(kBoxMediaDeleteSecretBytes)
          ..fillRange(0, kBoxMediaDeleteSecretBytes, 0x5a + id[0]),
      ),
    );
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

VerifiedDeviceList enrolledList(
  List<int> live, {
  List<int> revoked = const [],
}) => VerifiedDeviceList.enrolled(
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

/// The harness chat: id 10, between user 1 and Bob (2), with a disappearing
/// [timer] in seconds when given.
Map<String, dynamic> boxSendConversation({int? timer}) => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': timer,
  'unreadCount': 0,
  'lastMessage': null,
};

/// One chat (id 10) between user 1 (this device's account) and Bob (2), a
/// [MessagingProvider] over a fake box, and every socket emit it makes.
class BoxSendHarness {
  BoxSendHarness._(
    this.conversations,
    this.encryption,
    this.outbox,
    this.crypto,
    this.emitted,
  ) {
    provider = newProvider();
  }

  /// The provider under test; a restart test replaces it with
  /// [newProvider].
  late MessagingProvider provider;
  final ConversationsProvider conversations;
  final SendEncryption encryption;
  final SendOutbox outbox;
  final ReversingMediaCrypto crypto;

  /// Every event the provider emitted on the account socket.
  final List<String> emitted;

  /// [timer]: the chat's disappearing timer, in seconds. [encryption] and
  /// [outbox] swap in a scripted fake ([ScriptedSendEncryption],
  /// [ScriptedSendOutbox]); the caller keeps its own typed reference.
  static Future<BoxSendHarness> create({
    int? timer,
    SendEncryption Function(EncryptionService store)? encryption,
    SendOutbox? outbox,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    // Box-ready a moment ago: a held peer list is kept (decision 51).
    await service.markBoxListsReady(DateTime.now().millisecondsSinceEpoch);
    final conversations = ConversationsProvider()..setCurrentUserId(1);
    seedConversations(conversations, [boxSendConversation(timer: timer)]);
    conversations.openConversation(10);
    return BoxSendHarness._(
      conversations,
      encryption?.call(service) ?? SendEncryption(service),
      outbox ?? SendOutbox(),
      ReversingMediaCrypto(),
      [],
    );
  }

  /// A provider over this harness's fakes: the first one, or the app
  /// started again on the same device.
  MessagingProvider newProvider() => MessagingProvider()
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
