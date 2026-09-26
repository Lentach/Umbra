import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encrypted_media_upload_service.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real plaintext store; Signal and the device-list round trip are
/// faked. A "ciphertext" is `3:` + base64(the plaintext), so a frame the
/// box was handed can be read back.
class _SendEncryption extends EncryptionProvider {
  _SendEncryption(this.store) : super(service: store);

  final EncryptionService store;

  /// Verified lists this client holds, by user id; absent = not enrolled
  /// (single device 1).
  final Map<int, VerifiedDeviceList> lists = {};

  /// What a forced fetch finds on the server, when it differs from [lists].
  final Map<int, VerifiedDeviceList> served = {};

  /// Every `forceRefresh` fetch, by user id.
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
  bool get isE2EReady => true;

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
  }) async {
    fetches.add(userId);
    if (forceRefresh) {
      forcedFetches.add(userId);
      await (holdFor[userId] ?? fetchHold)?.future;
    }
    if (unverifiable.contains(userId)) throw StateError('chain refused');
    if (forceRefresh) {
      // Like the real cache: a verified answer is held, a non-enrolled one
      // included.
      lists[userId] =
          served[userId] ?? lists[userId] ?? const VerifiedDeviceList.notEnrolled();
    }
    return lists[userId] ?? const VerifiedDeviceList.notEnrolled();
  }

  /// Signal sessions this device holds, as (user, device).
  final Set<(int, int)> sessions = {};

  /// Every pre-key bundle fetch the real [ensureSession] would emit on the
  /// account socket, as (user, device).
  final List<(int, int)> bundleFetches = [];

  /// Addresses whose bundle fetch fails (no bundle, a timeout).
  final Set<(int, int)> unbuildable = {};

  /// Per-address holds on a bundle fetch still in flight.
  final Map<(int, int), Completer<void>> buildHold = {};

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async =>
      sessions.contains((peerUserId, deviceId));

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
    final bytes = oversize.contains(deviceId)
        ? Uint8List(BoxFrame.maxSignalBytes + 1)
        : utf8.encode(plaintext);
    return '3:${base64Encode(bytes)}';
  }

  @override
  Future<void> savePendingSendRecord(
    String key,
    Map<String, dynamic> data,
  ) async {}
}

class _Outbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};

  /// Our own other devices' self-queue addresses, by device id.
  final Map<int, ContactOutbound> siblings = {};

  /// Peer devices whose `send` the box refuses.
  final Set<int> refuse = {};

  /// Every frame handed over, with its address.
  final List<(ContactOutbound, BoxFrame)> delivered = [];

  bool noLocalId = false;

  /// When set, every `send` waits for it: a box that has not answered yet.
  Completer<void>? hold;
  int _next = kFirstLocalMessageId + 40;

  /// What the box's media route holds, by base64url id.
  final Map<String, Uint8List> media = {};

  /// Every `POST /box/media`, with the queue it was charged to.
  final List<(ContactOutbound, Uint8List)> uploads = [];

  /// When set, the media route answers this instead of storing the body.
  BoxResult<BoxMediaRef>? uploadAnswer;

  /// When set, every `POST /box/media` waits for it: an upload in flight.
  Completer<void>? uploadHold;

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
  Future<bool> deliver(ContactOutbound to, Uint8List body) async {
    delivered.add((to, BoxFrame.decode(body)!));
    await hold?.future;
    return !refuse.contains(to.peerDeviceId);
  }

  @override
  Future<int?> nextLocalId() async => noLocalId ? null : _next++;

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
      BoxMediaRef(id: id, bucket: 'd14', expiresAt: DateTime.utc(2026, 10, 10)),
    );
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    final body = media[boxB64(id)];
    return body == null ? const BoxRefused(BoxCode.notFound) : BoxOk(body);
  }
}

ContactOutbound _address(int device) => ContactOutbound(
  peerDeviceId: device,
  sid: 'sid-$device',
  sealPub: 'seal-$device',
);

/// Media crypto and the old path's `/media/upload`, faked: a "ciphertext"
/// is the plaintext reversed plus a 16-byte tag, under a fresh key and IV
/// per encrypt, so a re-encryption shows; every old-path upload is kept.
class _MediaUpload extends EncryptedMediaUploadService {
  _MediaUpload() : super(api: ApiService(baseUrl: 'http://test'));

  /// Every plaintext encrypted for the box path.
  final List<Uint8List> encrypted = [];

  /// Every `POST /media/upload`, by media type.
  final List<String> oldPathUploads = [];

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

  @override
  Future<EncryptedMediaUpload> encryptAndUpload({
    required Uint8List bytes,
    required String token,
    required String mediaType,
    int? duration,
    int? expiresIn,
    String? fileName,
    void Function(String keyBase64, String ivBase64)? onEncrypted,
  }) async {
    oldPathUploads.add(mediaType);
    onEncrypted?.call('OLDK', 'OLDIV');
    return EncryptedMediaUpload(
      mediaUrl: 'http://test/media/msgs/x.bin',
      keyBase64: 'OLDK',
      ivBase64: 'OLDIV',
      mediaDuration: duration,
    );
  }
}

VerifiedDeviceList _enrolled(List<int> live, {List<int> revoked = const []}) =>
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

Map<String, dynamic> _conv({int? timer}) => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': timer,
  'unreadCount': 0,
  'lastMessage': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _SendEncryption encryption;
  late _Outbox outbox;
  late List<String> emitted;
  late _MediaUpload mediaUpload;

  /// Every old-path `sendMessage` payload.
  late List<Map<String, dynamic>> oldPathSends;

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setActiveConversationIdForTest(10)
    ..setEmitCallback((event, data) {
      emitted.add(event);
      if (event == 'sendMessage') {
        oldPathSends.add(data as Map<String, dynamic>);
      }
    })
    ..boxOutbox = outbox
    ..setMediaUploadServiceForTest(mediaUpload);

  Future<void> setUpWith({int? timer}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _SendEncryption(service);
    conversations = ConversationsProvider()
      ..setCurrentUserId(1)
      ..onConversationsList([_conv(timer: timer)])
      ..openConversation(10);
    outbox = _Outbox();
    mediaUpload = _MediaUpload();
    emitted = [];
    oldPathSends = [];
    provider = newProvider();
  }

  setUp(setUpWith);

  Future<void> pump([int turns = 40]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Bob (2) on devices [live]; every one of [addressed] handed us a queue.
  /// [connected]: the connect's list refresh has run since (E2E ready).
  void bob(
    List<int> live, {
    List<int>? addressed,
    List<int> revoked = const [],
    bool connected = true,
  }) {
    encryption.lists[2] = _enrolled(live, revoked: revoked);
    outbox.addresses[2] = {
      for (final d in addressed ?? live) d: _address(d),
    };
    if (connected) provider.refreshBoxDeviceLists();
  }

  Future<MessageModel> send(String text) async {
    provider.sendMessage(text);
    await pump();
    return provider.messages.last;
  }

  /// The envelope a delivered frame carries.
  Map<String, dynamic> envelopeOf(BoxFrame frame) =>
      jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

  test(
    'a text to a peer whose every live device has an address goes ONLY over '
    'the box: one frame per device, never a sendMessage (decisions 15-16)',
    () async {
      bob([1, 2]);
      final row = await send('hi over the box');

      expect(emitted, isNot(contains('sendMessage')));
      expect(
        outbox.delivered.map((d) => d.$1.sid),
        unorderedEquals(['sid-1', 'sid-2']),
      );
      for (final (_, frame) in outbox.delivered) {
        expect(frame.senderDeviceId, 1, reason: 'the sending device');
        expect(frame.kind, BoxFrameKind.preKey);
        final envelope = envelopeOf(frame);
        expect(envelope['content'], 'hi over the box');
        expect(envelope['msgId'], row.wireId, reason: 'one wire id per message');
        expect(envelope['ts'], row.createdAt.millisecondsSinceEpoch);
      }
      expect(isLocalMessageId(row.id), isTrue);
      expect(row.deliveryStatus, MessageDeliveryStatus.sent);
      expect(row.content, 'hi over the box');
      expect(conversations.lastMessages[10]?.id, row.id);
    },
  );

  test(
    'the sent box message is stored under its local id with our wire stamp, '
    'and comes back after a restart as SENT, not delivered',
    () async {
      bob([1]);
      final row = await send('kept');

      final record = await encryption.store.getDecryptedContent(row.id);
      expect(record?['content'], 'kept');
      expect(record?['senderId'], 1);

      provider.dispose();
      provider = newProvider();
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': <Object>[],
      });
      await pump(80);

      final back = provider.messages.singleWhere((m) => m.id == row.id);
      expect(back.content, 'kept');
      expect(back.senderId, 1);
      expect(back.wireId, row.wireId);
      expect(back.deliveryStatus, MessageDeliveryStatus.sent);
    },
  );

  test(
    'a live peer device WITHOUT an address sends the whole message over the '
    'old path — never split across the two',
    () async {
      bob([1, 2], addressed: [1]);
      final row = await send('mixed');

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
      expect(isLocalMessageId(row.id), isFalse);
    },
  );

  ContactOutbound selfQueueOf(int device) => ContactOutbound(
    peerDeviceId: device,
    sid: 'self-$device',
    sealPub: 'self-seal-$device',
  );

  test(
    'a live device of OUR account with no self-queue address keeps the '
    'whole message on the old path (decision 16)',
    () async {
      bob([1]);
      encryption.lists[1] = _enrolled([1, 3, 4]);
      outbox.siblings[3] = selfQueueOf(3);
      await send('siblings');

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
    },
  );

  test(
    'every live sibling gets a sent copy in its SELF-queue, encrypted for '
    'that own device, under the same wire id and time, naming the peer '
    'inside E2E; the peer copy names no one; a revoked sibling gets nothing '
    '(E5)',
    () async {
      bob([1, 2]);
      encryption.lists[1] = _enrolled([1, 3, 4], revoked: [5]);
      outbox.siblings.addAll({
        for (final d in [3, 4, 5]) d: selfQueueOf(d),
      });
      final row = await send('to bob, seen on my phone');

      expect(emitted, isNot(contains('sendMessage')));
      expect(row.deliveryStatus, MessageDeliveryStatus.sent);
      expect(
        outbox.delivered.map((d) => d.$1.sid),
        unorderedEquals(['sid-1', 'sid-2', 'self-3', 'self-4']),
      );
      expect(encryption.encryptCalls, containsAll([(1, 3), (1, 4)]));
      for (final (to, frame) in outbox.delivered) {
        final envelope = envelopeOf(frame);
        expect(frame.senderDeviceId, 1);
        expect(envelope, containsPair('content', 'to bob, seen on my phone'));
        expect(envelope, containsPair('msgId', row.wireId));
        expect(
          envelope,
          containsPair('ts', row.createdAt.millisecondsSinceEpoch),
        );
        if (to.sid.startsWith('self-')) {
          expect(envelope, containsPair('to', 2), reason: to.sid);
        } else {
          expect(envelope, isNot(contains('to')), reason: to.sid);
        }
      }
    },
  );

  test(
    'a sibling frame the box refuses fails the whole row (decision 20)',
    () async {
      bob([1]);
      encryption.lists[1] = _enrolled([1, 3]);
      outbox
        ..siblings[3] = selfQueueOf(3)
        ..refuse.add(3);
      final row = await send('half sent');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test(
    'a revoked peer device gets nothing, even though it still holds an '
    'address',
    () async {
      bob([1], addressed: [1, 2], revoked: [2]);
      await send('live only');

      expect(outbox.delivered.map((d) => d.$1.peerDeviceId), [1]);
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test(
    'a peer list with no live device is never "sent" to nobody',
    () async {
      bob(const [], addressed: [2], revoked: [2]);
      await send('to whom');

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
    },
  );

  test(
    'a covered peer whose list the connect could not verify FAILS the row '
    'with no lookup of its own — never the old path, whose emit a web socket '
    'buffers offline and replays as a server row (decision 21)',
    () async {
      encryption.unverifiable.add(2);
      bob([1]);
      final row = await send('unverified');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(outbox.delivered, isEmpty);
      expect(emitted, isNot(contains('sendMessage')));
      expect(encryption.forcedFetches, [1, 2], reason: 'the connect only');

      encryption.unverifiable.clear();
      await provider.retryFailedMessage(row.tempId!);
      await pump();
      expect(outbox.delivered, isEmpty, reason: 'a retry fetches nothing');
      expect(encryption.forcedFetches, [1, 2]);

      provider.refreshBoxDeviceLists();
      await provider.retryFailedMessage(row.tempId!);
      await pump();
      expect(outbox.delivered, hasLength(1));
      expect(encryption.forcedFetches, [1, 2, 2]);
    },
  );

  test(
    'a box refusal on ANY device fails the row (retry), stores nothing, and '
    'the retry carries the SAME wire id',
    () async {
      bob([1, 2]);
      outbox.refuse.add(2);
      final failed = await send('try again');

      expect(failed.deliveryStatus, MessageDeliveryStatus.failed);
      expect(emitted, isNot(contains('sendMessage')));
      final firstWire = envelopeOf(outbox.delivered.first.$2)['msgId'];

      outbox
        ..refuse.clear()
        ..delivered.clear();
      await provider.retryFailedMessage(failed.tempId!);
      await pump();

      final sent = provider.messages.singleWhere(
        (m) => m.content == 'try again',
      );
      expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
      expect(outbox.delivered, hasLength(2));
      for (final (_, frame) in outbox.delivered) {
        expect(envelopeOf(frame)['msgId'], firstWire);
      }
      expect(
        await encryption.store.localMessageRecords(10),
        hasLength(1),
        reason: 'only the attempt that went through is stored',
      );
    },
  );

  test(
    'the retry keeps the wire id across a same-user reconnect — the box is '
    'most often down exactly when the account socket reconnects',
    () async {
      bob([1, 2]);
      outbox.refuse.add(2);
      final failed = await send('after a reconnect');
      final firstWire = envelopeOf(outbox.delivered.first.$2)['msgId'];

      provider
        ..onConnect(true)
        ..refreshBoxDeviceLists();
      outbox
        ..refuse.clear()
        ..delivered.clear();
      await provider.retryFailedMessage(failed.tempId!);
      await pump();

      expect(outbox.delivered, hasLength(2));
      for (final (_, frame) in outbox.delivered) {
        expect(envelopeOf(frame)['msgId'], firstWire);
      }
    },
  );

  test(
    'a retry whose box route is gone stays failed and never reaches the '
    'server: device 1 may already hold it, and the old path cannot dedup',
    () async {
      bob([1, 2]);
      outbox.refuse.add(2);
      final failed = await send('pinned to the box');

      outbox.addresses[2]!.remove(2);
      await provider.retryFailedMessage(failed.tempId!);
      await pump();

      expect(emitted, isNot(contains('sendMessage')));
      expect(
        provider.messages.singleWhere((m) => m.tempId == failed.tempId)
            .deliveryStatus,
        MessageDeliveryStatus.failed,
      );
    },
  );

  test(
    'a Signal message longer than one frame is refused before ANY device is '
    'sent to — never truncated, never split',
    () async {
      bob([1, 2]);
      encryption.oversize.add(2);
      final row = await send('too long for the box');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(outbox.delivered, isEmpty);
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test('no local id (the store refused) fails before anything goes out', () async {
    bob([1]);
    outbox.noLocalId = true;
    final row = await send('nowhere to keep it');

    expect(row.deliveryStatus, MessageDeliveryStatus.failed);
    expect(outbox.delivered, isEmpty);
  });

  /// A fresh provider whose chat opens with an empty server page: box rows
  /// come back only from their records (decision 14).
  Future<void> restart() async {
    provider.dispose();
    provider = newProvider();
    await provider.onMessageHistory({
      'conversationId': 10,
      'messages': <Object>[],
    });
    await pump(80);
  }

  /// Our other device 3, with a self-queue: every box send makes a copy.
  void withSibling() {
    encryption.lists[1] = _enrolled([1, 3]);
    outbox.siblings[3] = selfQueueOf(3);
  }

  test(
    'a text in a chat with a timer goes over the box, its timer in the peer '
    'frame AND the sent copy; our row counts from the send, its record '
    'carries that deadline, and a restart brings both back (E18b, decision '
    '41)',
    () async {
      await setUpWith(timer: 60);
      bob([1]);
      withSibling();
      final row = await send('vanishing');

      expect(emitted, isNot(contains('sendMessage')));
      expect(
        outbox.delivered.map((d) => d.$1.sid),
        unorderedEquals(['sid-1', 'self-3']),
      );
      for (final (to, frame) in outbox.delivered) {
        expect(envelopeOf(frame), containsPair('ttl', 60), reason: to.sid);
      }
      expect(isLocalMessageId(row.id), isTrue);
      expect(row.disappearAfterSeconds, 60);
      expect(row.expiresAt, row.createdAt.add(const Duration(seconds: 60)));
      final record = await encryption.store.getDecryptedContent(row.id);
      expect(
        record?['_expiresAt'],
        row.expiresAt!.millisecondsSinceEpoch,
        reason: 'the stamp the destruction gate honours',
      );

      await restart();
      final back = provider.messages.singleWhere((m) => m.id == row.id);
      expect(back.disappearAfterSeconds, 60);
      expect(back.expiresAt, row.expiresAt);
    },
  );

  MessageModel quotable(int id, {String? wireId, int senderId = 2}) =>
      MessageModel(
        id: id,
        content: 'the original words',
        senderId: senderId,
        senderUsername: senderId == 2 ? 'bob' : 'alice',
        conversationId: 10,
        createdAt: DateTime.utc(2026, 9, 20),
        wireId: wireId,
      );

  test(
    'a reply goes over the box quoting the original by wire id and sender, '
    'with its type and snippet, in the peer frame AND the sent copy — never '
    'a server id; a restart brings the quote back (E18a)',
    () async {
      bob([1]);
      withSibling();
      final original = await send('the original words');
      outbox.delivered.clear();
      provider.setReplyingTo(original);
      final reply = await send('re: that');

      expect(emitted, isNot(contains('sendMessage')));
      expect(outbox.delivered, hasLength(2));
      for (final (to, frame) in outbox.delivered) {
        expect(envelopeOf(frame)['re'], {
          'w': original.wireId,
          's': 1,
          'k': 'TEXT',
          'x': 'the original words',
        }, reason: to.sid);
      }
      expect(isLocalMessageId(reply.id), isTrue);
      expect(reply.deliveryStatus, MessageDeliveryStatus.sent);
      expect(reply.replyTo?.id, original.id);
      expect(reply.replyTo?.wireId, original.wireId);
      expect(reply.replyTo?.senderId, 1);

      await restart();
      final back = provider.messages.singleWhere((m) => m.id == reply.id);
      expect(back.replyTo?.id, original.id);
      expect(back.replyTo?.content, 'the original words');
      expect(back.replyTo?.wireId, original.wireId);
      expect(back.replyTo?.senderId, 1);
      expect(back.replyTo?.messageType, MessageType.text);
    },
  );

  test(
    'a reply to a message with no wire id (older than PR2.1) sends the '
    'snippet alone, a non-text original its type and no snippet',
    () async {
      bob([1]);
      provider.setReplyingTo(quotable(5));
      await send('re: old');
      expect(envelopeOf(outbox.delivered.single.$2)['re'], {
        's': 2,
        'k': 'TEXT',
        'x': 'the original words',
      });

      outbox.delivered.clear();
      provider.setReplyingTo(
        quotable(6, wireId: 'wire-00000006').copyWith(
          messageType: MessageType.ping,
          content: '',
        ),
      );
      await send('re: ping');
      expect(envelopeOf(outbox.delivered.single.$2)['re'], {
        'w': 'wire-00000006',
        's': 2,
        'k': 'PING',
        'x': '',
      });
    },
  );

  test(
    'a reply to a message that itself disappears sends NO snippet of it — '
    'only its wire id, sender and type — and keeps none on OUR side either: '
    'the sent row and its record carry the quote the wire carried, and a '
    'restart brings back no words (E18a)',
    () async {
      bob([1]);
      final timed = quotable(5, wireId: 'wire-00000005');
      final replies = <MessageModel>[];
      for (final quoted in [
        timed.copyWith(disappearAfterSeconds: 60),
        timed.copyWith(expiresAt: DateTime.now().add(const Duration(hours: 1))),
      ]) {
        outbox.delivered.clear();
        provider.setReplyingTo(quoted);
        final reply = await send('re: fleeting');
        replies.add(reply);
        expect(envelopeOf(outbox.delivered.single.$2)['re'], {
          'w': 'wire-00000005',
          's': 2,
          'k': 'TEXT',
          'x': '',
        });
        expect(reply.replyTo?.content, isEmpty);
        final record = await encryption.store.getDecryptedContent(reply.id);
        expect(record?['replyTo'], containsPair('content', ''));
      }

      await restart();
      for (final reply in replies) {
        final back = provider.messages.singleWhere((m) => m.id == reply.id);
        expect(back.replyTo?.content, isEmpty);
        expect(back.replyTo?.wireId, 'wire-00000005');
        expect(back.replyTo?.senderId, 2);
        expect(back.replyTo?.quotedDisappears, isTrue);
      }
    },
  );

  test(
    'a failed box reply is retried with the quote rebuilt from its row',
    () async {
      bob([1]);
      outbox.refuse.add(1);
      provider.setReplyingTo(quotable(5, wireId: 'wire-00000005'));
      final failed = await send('re: again');
      expect(failed.deliveryStatus, MessageDeliveryStatus.failed);

      outbox
        ..refuse.clear()
        ..delivered.clear();
      await provider.retryFailedMessage(failed.tempId!);
      await pump();

      expect(outbox.delivered, hasLength(1));
      expect(
        envelopeOf(outbox.delivered.single.$2)['re'],
        containsPair('w', 'wire-00000005'),
      );
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test(
    'a reply to a peer the box does not cover keeps the old path: the '
    'server row it quotes is named by replyToMessageId, as ever',
    () async {
      bob([1, 2], addressed: [1]);
      provider.setReplyingTo(quotable(5, wireId: 'wire-00000005'));
      await send('re: over the server');

      expect(outbox.delivered, isEmpty);
      expect(oldPathSends.single, containsPair('replyToMessageId', 5));
    },
  );

  test(
    'a reply naming a message this device holds no preview of stays on the '
    'old path: the box would have nothing to quote',
    () async {
      bob([1]);
      provider.sendMessage('re: that', replyToMessageId: 5);
      await pump();

      expect(outbox.delivered, isEmpty);
      expect(oldPathSends.single, containsPair('replyToMessageId', 5));
    },
  );

  test(
    'a send while the connect is still verifying the peer waits for that '
    'lookup and makes none of its own (decision 21)',
    () async {
      final hold = encryption.fetchHold = Completer<void>();
      bob([1]);
      provider.sendMessage('early');
      await pump();
      expect(outbox.delivered, isEmpty);
      expect(provider.messages.last.deliveryStatus,
          MessageDeliveryStatus.sending);

      hold.complete();
      await pump();
      expect(outbox.delivered, hasLength(1));
      expect(encryption.forcedFetches, [1, 2]);
    },
  );

  test(
    'a covered peer no connect has verified yet fails the row: no lookup, no '
    'sendMessage',
    () async {
      bob([1], connected: false);
      final row = await send('too soon');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(encryption.forcedFetches, isEmpty);
      expect(outbox.delivered, isEmpty);
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test(
    "the peer's list is re-verified once per connect, never per message — a "
    'lookup per send would hand the server the pair and every send time; a '
    'device linked mid-session is seen at the next connect',
    () async {
      bob([1]);
      await pump();
      encryption.served[2] = _enrolled([1, 2]);
      await send('one');
      await send('two');
      expect(encryption.forcedFetches, [1, 2]);
      expect(outbox.delivered, hasLength(2));

      provider
        ..onConnect(true)
        ..refreshBoxDeviceLists();
      await send('three');
      expect(encryption.forcedFetches, [1, 2, 1, 2]);
      expect(outbox.delivered, hasLength(2), reason: 'device 2 has no address');
      expect(emitted, contains('sendMessage'));
    },
  );

  test(
    'a peer device revoked since the last connect gets nothing once that '
    "connect's lookup has verified the list",
    () async {
      bob([1, 2]);
      await send('both');
      expect(outbox.delivered, hasLength(2));

      encryption.served[2] = _enrolled([1], revoked: [2]);
      provider
        ..onConnect(true)
        ..refreshBoxDeviceLists();
      outbox.delivered.clear();
      await send('only one');
      expect([for (final (to, _) in outbox.delivered) to.peerDeviceId], [1]);
    },
  );

  test(
    'a peer list the E2E layer dropped is looked up again by the refresh, '
    'not by the send',
    () async {
      bob([1]);
      await pump();
      encryption.lists.remove(2);
      encryption.served[2] = _enrolled([1]);
      provider.onDeviceListInvalidated(2);
      await send('after a rebuild request');

      expect(outbox.delivered, hasLength(1));
      expect(encryption.forcedFetches, [1, 2, 2]);
    },
  );

  test(
    'a peer list gone from the cache fails the send rather than fetch it',
    () async {
      bob([1]);
      await pump();
      encryption.lists.remove(2);
      final row = await send('no list');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(encryption.fetches, [1, 2]);
      expect(emitted, isNot(contains('sendMessage')));
    },
  );

  test(
    'our OWN list is looked up by the connect too and never by a send — a '
    'lookup timed by the send names the sender at the moment of the box '
    'frame',
    () async {
      bob([1]);
      await pump();
      encryption.fetches.clear();
      await send('one');
      await send('two');

      expect(outbox.delivered, hasLength(2));
      expect(encryption.fetches, isEmpty);
    },
  );

  test(
    'an account the box covers no peer of looks nothing up at connect — '
    'not even its own list',
    () async {
      bob([1], addressed: []);
      await pump();
      expect(encryption.forcedFetches, isEmpty);
    },
  );

  test(
    "a send waits for our own list's lookup as well as the peer's",
    () async {
      final own = encryption.holdFor[1] = Completer<void>();
      bob([1]);
      provider.sendMessage('mine first');
      await pump();
      expect(outbox.delivered, isEmpty);
      expect(provider.messages.last.deliveryStatus,
          MessageDeliveryStatus.sending);

      own.complete();
      await pump();
      expect(outbox.delivered, hasLength(1));
    },
  );

  test(
    'our own list dropped since the connect (deviceListChanged) is looked '
    'up again by the refresh; with none held the send fails, never fetches',
    () async {
      bob([1]);
      await pump();
      encryption.lists.remove(1);
      final row = await send('own list gone');
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(encryption.fetches, [1, 2]);

      provider.onDeviceListInvalidated(1);
      await send('own list back');
      expect(outbox.delivered, hasLength(1));
      expect(encryption.forcedFetches, [1, 2, 1]);
    },
  );

  test(
    'an account-socket error while the box has not answered neither fails '
    'the row nor lets a retry store a second copy',
    () async {
      bob([1]);
      final hold = outbox.hold = Completer<void>();
      provider.sendMessage('slow box');
      await pump();
      final tempId = provider.messages.last.tempId!;

      provider.markSendingMessagesFailed('socket error');
      expect(
        provider.messages.last.deliveryStatus,
        MessageDeliveryStatus.sending,
      );
      await provider.retryFailedMessage(tempId);
      await pump();
      expect(outbox.delivered, hasLength(1));

      hold.complete();
      await pump();
      expect(
        provider.messages.singleWhere((m) => m.tempId == tempId).deliveryStatus,
        MessageDeliveryStatus.sent,
      );
      expect(await encryption.store.localMessageRecords(10), hasLength(1));
    },
  );

  test(
    'a send refused before any frame went out is not pinned to the box: '
    'its retry may take the old path once the route is gone',
    () async {
      bob([1, 2]);
      encryption.oversize.add(2);
      final failed = await send('nothing left the device');

      encryption.oversize.clear();
      outbox.addresses[2]!.remove(2);
      await provider.retryFailedMessage(failed.tempId!);
      await pump();

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
    },
  );

  test(
    'a TEXT that carries a mediaUrl stays on the old path — the box '
    'envelope would drop the media silently',
    () async {
      bob([1]);
      await provider.encryptAndSendForTest(
        recipientId: 2,
        content: 'with media',
        tempId: 'temp_text_media',
        mediaUrl: '/media/x.bin',
      );
      await pump();

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
    },
  );

  test('media stays on the old path', () async {
    bob([1]);
    await provider.encryptAndSendForTest(
      recipientId: 2,
      content: '',
      tempId: 'temp_img',
      messageType: 'IMAGE',
      mediaUrl: '/media/x.bin',
    );
    await pump();

    expect(outbox.delivered, isEmpty);
    expect(emitted, contains('sendMessage'));
  });

  test(
    'a ping goes over the box like a text, typed PING in the peer frame AND '
    'the sent copy, and comes back after a restart as a ping that fires '
    'nothing (decision 43)',
    () async {
      await setUpWith(timer: 30);
      bob([1]);
      withSibling();
      provider.sendPing(2);
      await pump();

      expect(emitted, isNot(contains('sendMessage')));
      expect(outbox.delivered, hasLength(2));
      for (final (to, frame) in outbox.delivered) {
        final envelope = envelopeOf(frame);
        expect(envelope, containsPair('messageType', 'PING'), reason: to.sid);
        expect(envelope, containsPair('ttl', 30), reason: to.sid);
      }
      final row = provider.messages.single;
      expect(isLocalMessageId(row.id), isTrue);
      expect(row.messageType, MessageType.ping);
      expect(row.deliveryStatus, MessageDeliveryStatus.sent);

      await restart();
      final back = provider.messages.singleWhere((m) => m.id == row.id);
      expect(back.messageType, MessageType.ping);
      expect(back.content, isEmpty);
      expect(provider.showPingEffect, isFalse);
    },
  );

  test(
    'a failed box text, ping or reply is retried under its OWN timer, not '
    "the chat's timer changed since: the retry reuses the wire id, so a "
    'device already holding the message keeps what it has (E18b)',
    () async {
      await setUpWith(timer: 30);
      bob([1, 2]);
      outbox.refuse.add(2);
      final text = await send('first try');
      provider.sendPing(2);
      await pump();
      final ping = provider.messages.last;
      provider.setReplyingTo(quotable(5, wireId: 'wire-00000005'));
      final reply = await send('re: first try');
      for (final row in [text, ping, reply]) {
        expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      }

      conversations.onDisappearingTimerUpdated({
        'conversationId': 10,
        'seconds': 3600,
      });
      outbox.refuse.clear();
      for (final row in [text, ping, reply]) {
        outbox.delivered.clear();
        await provider.retryFailedMessage(row.tempId!);
        await pump();
        expect(outbox.delivered, hasLength(2), reason: row.tempId);
        for (final (_, frame) in outbox.delivered) {
          expect(envelopeOf(frame), containsPair('ttl', 30), reason: row.tempId);
        }
      }
    },
  );

  test(
    'the connect pre-builds a session for exactly the box-covered live '
    'devices with no usable one — never a device that has one, an '
    'unaddressed or revoked device, or this device (decision 38)',
    () async {
      encryption
        ..sessions.addAll({(2, 1), (2, 4), (1, 3)})
        ..markSessionRebuild(2, deviceId: 4)
        ..lists[1] = _enrolled([1, 3, 4, 6], revoked: [7]);
      outbox.siblings.addAll({
        for (final d in [3, 4, 7]) d: selfQueueOf(d),
      });
      bob([1, 2, 3, 4], addressed: [1, 2, 4, 5], revoked: [5]);
      await pump();

      expect(
        encryption.bundleFetches,
        unorderedEquals([(2, 2), (2, 4), (1, 4)]),
      );
    },
  );

  test(
    "a send waits for the connect's pre-build and then fetches nothing: "
    'every bundle fetch lines up with the connect, none with the send',
    () async {
      final build = encryption.buildHold[(2, 2)] = Completer<void>();
      bob([1, 2]);
      await pump();
      expect(encryption.bundleFetches, [(2, 1), (2, 2)]);

      provider.sendMessage('after the pre-build');
      await pump();
      expect(outbox.delivered, isEmpty);
      expect(provider.messages.last.deliveryStatus,
          MessageDeliveryStatus.sending);

      build.complete();
      await pump();
      expect(outbox.delivered, hasLength(2));
      expect(provider.messages.last.deliveryStatus,
          MessageDeliveryStatus.sent);
      expect(encryption.bundleFetches, [(2, 1), (2, 2)]);
    },
  );

  test(
    'a box send to a device whose session is gone FAILS the row and fetches '
    'no bundle; the next connect pre-builds it and the retry goes through '
    '(E38b)',
    () async {
      bob([1, 2]);
      await pump();
      encryption.sessions.remove((2, 2));
      final row = await send('no session');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(outbox.delivered, isEmpty);
      expect(emitted, isNot(contains('sendMessage')));
      expect(encryption.bundleFetches, [(2, 1), (2, 2)], reason: 'connect only');

      provider
        ..onConnect(true)
        ..refreshBoxDeviceLists();
      await pump();
      expect(encryption.bundleFetches, [(2, 1), (2, 2), (2, 2)]);

      await provider.retryFailedMessage(row.tempId!);
      await pump();
      expect(outbox.delivered, hasLength(2));
      expect(
        provider.messages.singleWhere((m) => m.tempId == row.tempId)
            .deliveryStatus,
        MessageDeliveryStatus.sent,
      );
      expect(encryption.bundleFetches, [(2, 1), (2, 2), (2, 2)]);
    },
  );

  test(
    'a session with a rebuild pending is not usable: the send fails and '
    'fetches nothing',
    () async {
      bob([1]);
      await pump();
      encryption.markSessionRebuild(2);
      final row = await send('stale session');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(outbox.delivered, isEmpty);
      expect(emitted, isNot(contains('sendMessage')));
      expect(encryption.bundleFetches, [(2, 1)]);
    },
  );

  test(
    "a peer's rebuild request re-runs the pre-build on receipt, so the next "
    'send rides the rebuilt session and fetches nothing',
    () async {
      encryption.onDeviceListInvalidated = provider.onDeviceListInvalidated;
      bob([1]);
      await pump();

      encryption.onSessionRebuildNeeded({'fromUserId': 2});
      await pump();
      expect(encryption.bundleFetches, [(2, 1), (2, 1)]);

      final row = await send('after the rebuild');
      expect(row.deliveryStatus, MessageDeliveryStatus.sent);
      expect(encryption.bundleFetches, [(2, 1), (2, 1)]);
    },
  );

  test(
    'a pre-build that failed fails the send (never the old path, never a '
    'fetch of its own), and so does a retry before the next pass; the pass '
    'builds it and the retry goes through',
    () async {
      encryption.unbuildable.add((2, 1));
      bob([1]);
      final row = await send('no bundle yet');

      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(emitted, isNot(contains('sendMessage')));
      expect(encryption.bundleFetches, [(2, 1)]);

      encryption.unbuildable.clear();
      await provider.retryFailedMessage(row.tempId!);
      await pump();
      expect(outbox.delivered, isEmpty);
      expect(encryption.bundleFetches, [(2, 1)], reason: 'a retry is a send');

      provider.refreshBoxDeviceLists();
      await provider.retryFailedMessage(row.tempId!);
      await pump();
      expect(outbox.delivered, hasLength(1));
      expect(encryption.bundleFetches, [(2, 1), (2, 1)]);
    },
  );

  group('item 3 / media wiring: attachments over the box', () {
    final photo = List<int>.generate(5000, (i) => i % 251);
    final key1 = base64Encode(List.filled(32, 1));
    final iv1 = base64Encode(List.filled(12, 1));

    MessageModel rowOf(MessageType type) =>
        provider.messages.lastWhere((m) => m.messageType == type);

    Future<bool> sendImage() async {
      // Distinct tempIds (`temp_<ms>_<user>`) between sends.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final ok = await provider.sendImageMessage(
        'tok',
        XFile.fromData(Uint8List.fromList(photo), name: 'a.jpg'),
        2,
      );
      await pump();
      return ok;
    }

    test(
      'an image to a covered peer is uploaded ONCE — framed to a ladder '
      'rung, charged to the first live peer device — and the same id and key '
      'ride in every peer frame and sent copy; nothing reaches /media/upload '
      'or the socket, and a restart brings the row back (E17a, decision 44)',
      () async {
        bob([1, 2]);
        withSibling();
        expect(await sendImage(), isTrue);

        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
        expect(mediaUpload.encrypted, hasLength(1));
        final (to, framed) = outbox.uploads.single;
        expect(to.sid, 'sid-1', reason: 'the first live peer target pays');
        expect(framed.length, 16 * 1024, reason: 'the smallest rung that fits');
        expect(unframeMedia(framed), [...photo.reversed, ...List.filled(16, 1)]);
        final id = outbox.media.keys.single;
        expect(
          outbox.delivered.map((d) => d.$1.sid),
          unorderedEquals(['sid-1', 'sid-2', 'self-3']),
        );
        for (final (to, frame) in outbox.delivered) {
          final envelope = envelopeOf(frame);
          expect(envelope, containsPair('boxMedia', id), reason: to.sid);
          expect(envelope, containsPair('messageType', 'IMAGE'));
          expect(envelope, containsPair('mediaKey', key1));
          expect(envelope, containsPair('mediaIv', iv1));
          expect(envelope, isNot(contains('mediaUrl')));
        }
        final row = rowOf(MessageType.image);
        expect(isLocalMessageId(row.id), isTrue);
        expect(row.deliveryStatus, MessageDeliveryStatus.sent);
        expect(row.mediaUrl, 'box:$id');
        expect(row.mediaKey, key1);
        expect(row.mediaIv, iv1);

        await restart();
        final back = provider.messages.singleWhere((m) => m.id == row.id);
        expect(back.messageType, MessageType.image);
        expect(back.mediaUrl, 'box:$id');
        expect(back.mediaKey, key1);
        expect(back.mediaIv, iv1);
      },
    );

    test(
      'a voice note and a file go the same way: one upload each, their '
      'duration and name in the frames',
      () async {
        bob([1]);
        await provider.sendVoiceMessage(
          recipientId: 2,
          duration: 7,
          conversationId: 10,
          localAudioBytes: [1, 2, 3, 4],
        );
        await pump();
        await provider.sendFileMessage(
          'tok',
          [5, 6, 7],
          'plan.pdf',
          'application/pdf',
          2,
        );
        await pump();

        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
        expect(outbox.uploads.map((u) => u.$1.sid), ['sid-1', 'sid-1']);
        final [voice, file] = [
          for (final (_, frame) in outbox.delivered) envelopeOf(frame),
        ];
        expect(voice, containsPair('messageType', 'VOICE'));
        expect(voice, containsPair('mediaDuration', 7));
        expect(file, containsPair('messageType', 'FILE'));
        expect(file, containsPair('content', 'plan.pdf'));
        expect(voice['boxMedia'], isNot(file['boxMedia']));
        final voiceRow = rowOf(MessageType.voice);
        expect(voiceRow.mediaUrl, 'box:${voice['boxMedia']}');
        expect(voiceRow.mediaDuration, 7);
        final fileRow = rowOf(MessageType.file);
        expect(fileRow.mediaUrl, 'box:${file['boxMedia']}');
        expect(fileRow.content, 'plan.pdf');
        expect(fileRow.deliveryStatus, MessageDeliveryStatus.sent);
      },
    );

    test(
      'a refused upload (quota_exceeded, rate_limited) or no answer fails the '
      'row for a retry: no frame, nothing on the old path (decisions 19, 31)',
      () async {
        bob([1]);
        for (final answer in <BoxResult<BoxMediaRef>>[
          const BoxRefused(BoxCode.quotaExceeded),
          const BoxRefused(
            BoxCode.rateLimited,
            retryAfter: Duration(minutes: 1),
          ),
          const BoxUnknown(BoxUnknownReason.timeout),
        ]) {
          outbox.uploadAnswer = answer;
          expect(await sendImage(), isFalse);
          expect(
            rowOf(MessageType.image).deliveryStatus,
            MessageDeliveryStatus.failed,
          );
        }
        expect(outbox.uploads, hasLength(3));
        expect(outbox.delivered, isEmpty);
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'a peer the box does not cover — no address, or a live device without '
      'one — still gets the image over /media/upload and the socket, as '
      'before',
      () async {
        expect(await sendImage(), isTrue);
        bob([1, 2], addressed: [1]);
        expect(await sendImage(), isTrue);

        expect(mediaUpload.oldPathUploads, ['image', 'image']);
        expect(mediaUpload.encrypted, isEmpty);
        expect(outbox.uploads, isEmpty);
        expect(outbox.delivered, isEmpty);
        expect(oldPathSends, hasLength(2));
        for (final payload in oldPathSends) {
          expect(payload['messageType'], 'IMAGE');
          expect(payload['mediaUrl'], 'http://test/media/msgs/x.bin');
        }
      },
    );

    test(
      'a retry after a successful upload re-sends the frames only — the same '
      "id, key, IV and wire id, under the row's OWN timer, not the chat's "
      'changed since (E17b, E18d)',
      () async {
        await setUpWith(timer: 30);
        bob([1, 2]);
        outbox.refuse.add(2);
        expect(await sendImage(), isFalse);
        final failed = rowOf(MessageType.image);
        expect(failed.deliveryStatus, MessageDeliveryStatus.failed);
        expect(failed.mediaUrl, startsWith('box:'));
        final first = envelopeOf(outbox.delivered.first.$2);

        conversations.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': 3600,
        });
        outbox
          ..refuse.clear()
          ..delivered.clear();
        await provider.retryFailedMessage(failed.tempId!);
        await pump();

        expect(outbox.uploads, hasLength(1), reason: 'never uploaded again');
        expect(mediaUpload.encrypted, hasLength(1));
        expect(outbox.delivered, hasLength(2));
        for (final (to, frame) in outbox.delivered) {
          final envelope = envelopeOf(frame);
          for (final field in ['boxMedia', 'mediaKey', 'mediaIv', 'msgId']) {
            expect(envelope[field], first[field], reason: '${to.sid} $field');
          }
          expect(envelope, containsPair('ttl', 30), reason: to.sid);
        }
        final sent = rowOf(MessageType.image);
        expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
        expect(sent.mediaUrl, failed.mediaUrl);
        expect(sent.disappearAfterSeconds, 30);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'a retry of an upload that never succeeded uploads the SAME ciphertext '
      'under the SAME key and IV — never re-encrypted (E17b)',
      () async {
        bob([1]);
        outbox.uploadAnswer = const BoxRefused(BoxCode.quotaExceeded);
        expect(await sendImage(), isFalse);
        final failed = rowOf(MessageType.image);
        expect(failed.mediaUrl, isNull);

        outbox.uploadAnswer = null;
        await provider.retryFailedMessage(failed.tempId!);
        await pump();

        expect(mediaUpload.encrypted, hasLength(1), reason: 'not re-encrypted');
        expect(outbox.uploads, hasLength(2));
        expect(outbox.uploads[1].$2, outbox.uploads[0].$2);
        final envelope = envelopeOf(outbox.delivered.single.$2);
        expect(envelope, containsPair('mediaKey', key1));
        expect(envelope, containsPair('mediaIv', iv1));
        final sent = rowOf(MessageType.image);
        expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
        expect(sent.mediaUrl, 'box:${outbox.media.keys.single}');
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'a retried upload whose row leaves the open chat meanwhile still goes '
      "under the row's OWN timer, not the chat's changed since (E17b, E18b)",
      () async {
        await setUpWith(timer: 30);
        bob([1]);
        outbox.uploadAnswer = const BoxRefused(BoxCode.quotaExceeded);
        expect(await sendImage(), isFalse);
        final failed = rowOf(MessageType.image);
        expect(failed.disappearAfterSeconds, 30);

        conversations.onDisappearingTimerUpdated({
          'conversationId': 10,
          'seconds': 3600,
        });
        outbox.uploadAnswer = null;
        final hold = outbox.uploadHold = Completer<void>();
        final retry = provider.retryFailedMessage(failed.tempId!);
        await pump();
        expect(outbox.uploads, hasLength(2), reason: 'the upload is in flight');
        // The user leaves the chat: its rows leave the provider.
        provider.clearMessages();
        hold.complete();
        await retry;
        await pump();

        final envelope = envelopeOf(outbox.delivered.single.$2);
        expect(envelope, containsPair('ttl', 30));
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'an uploaded attachment whose route is gone at the retry stays failed '
      'and never reaches the server, even when no frame went out before: the '
      'old path cannot name a box id (decision 25)',
      () async {
        bob([1, 2]);
        outbox.noLocalId = true;
        expect(await sendImage(), isFalse);
        final failed = rowOf(MessageType.image);
        expect(failed.mediaUrl, startsWith('box:'));
        expect(outbox.delivered, isEmpty);

        outbox
          ..noLocalId = false
          ..addresses[2]!.remove(2);
        await provider.retryFailedMessage(failed.tempId!);
        await pump();

        expect(
          rowOf(MessageType.image).deliveryStatus,
          MessageDeliveryStatus.failed,
        );
        expect(outbox.uploads, hasLength(1));
        expect(outbox.delivered, isEmpty);
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'a box reply whose row leaves the chat during the upload still quotes '
      'and times it: the frames carry the row as it was when the send '
      'started (E18a, E18b)',
      () async {
        await setUpWith(timer: 30);
        bob([1]);
        provider.setReplyingTo(quotable(5, wireId: 'wire-00000005'));
        outbox.uploadHold = Completer<void>();
        final sending = provider.sendImageMessage(
          'tok',
          XFile.fromData(Uint8List.fromList(photo), name: 'a.jpg'),
          2,
        );
        await pump();
        expect(outbox.uploads, hasLength(1));
        provider.clearMessages();
        outbox.uploadHold!.complete();
        expect(await sending, isTrue);

        final envelope = envelopeOf(outbox.delivered.single.$2);
        expect(envelope['re'], {
          'w': 'wire-00000005',
          's': 2,
          'k': 'TEXT',
          'x': 'the original words',
        });
        expect(envelope, containsPair('ttl', 30));
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'a box reply whose row left the chat before its quote could be read '
      'fails rather than go out without it',
      () async {
        bob([1]);
        await pump();
        provider.setReplyingTo(quotable(5, wireId: 'wire-00000005'));
        final sending = provider.sendImageMessage(
          'tok',
          XFile.fromData(Uint8List.fromList(photo), name: 'a.jpg'),
          2,
        );
        provider.clearMessages();

        final ok = await sending;
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'never without its quote');
        expect(ok, isFalse);
        expect(outbox.uploads, isEmpty);
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    test(
      'an attachment failed because this connect has not verified the lists '
      'is held for its retry: once they are, the retry uploads it once, '
      'never re-encrypted, and sends it over the box — a voice note with no '
      'second bubble (E17b)',
      () async {
        final dir = Directory.systemTemp.createTempSync('box_voice_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final recording = File('${dir.path}/rec.m4a')
          ..writeAsBytesSync([1, 2, 3, 4]);
        bob([1], connected: false);
        expect(await sendImage(), isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        await provider.sendVoiceMessage(
          recipientId: 2,
          duration: 7,
          conversationId: 10,
          localAudioPath: recording.path,
        );
        await pump();
        for (final type in [MessageType.image, MessageType.voice]) {
          expect(rowOf(type).deliveryStatus, MessageDeliveryStatus.failed);
        }
        expect(outbox.uploads, isEmpty);

        provider.refreshBoxDeviceLists();
        await pump();
        for (final type in [MessageType.image, MessageType.voice]) {
          await provider.retryFailedMessage(rowOf(type).tempId!);
          await pump();
        }

        expect(outbox.uploads, hasLength(2));
        expect(mediaUpload.encrypted, hasLength(2), reason: 'not re-encrypted');
        expect(
          provider.messages.where((m) => m.messageType == MessageType.voice),
          hasLength(1),
        );
        expect(outbox.delivered, hasLength(2));
        for (final type in [MessageType.image, MessageType.voice]) {
          final sent = rowOf(type);
          expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
          expect(sent.mediaUrl, startsWith('box:'));
        }
        expect(mediaUpload.oldPathUploads, isEmpty);
        expect(emitted, isNot(contains('sendMessage')));
      },
    );

    group("a voice note's plaintext recording is deleted once uploaded", () {
      late File recording;

      setUp(() {
        final dir = Directory.systemTemp.createTempSync('box_voice_');
        addTearDown(() => dir.deleteSync(recursive: true));
        recording = File('${dir.path}/rec.m4a')
          ..writeAsBytesSync([1, 2, 3, 4]);
      });

      Future<void> sendVoice() => provider.sendVoiceMessage(
        recipientId: 2,
        duration: 7,
        conversationId: 10,
        localAudioPath: recording.path,
      );

      test('on the retry that uploads it', () async {
        bob([1]);
        outbox.uploadAnswer = const BoxRefused(BoxCode.quotaExceeded);
        await sendVoice();
        await pump();
        final failed = rowOf(MessageType.voice);
        expect(failed.deliveryStatus, MessageDeliveryStatus.failed);
        expect(recording.existsSync(), isTrue, reason: 'nothing uploaded yet');

        outbox.uploadAnswer = null;
        await provider.retryFailedMessage(failed.tempId!);
        await pump();
        expect(recording.existsSync(), isFalse);
        expect(
          rowOf(MessageType.voice).deliveryStatus,
          MessageDeliveryStatus.sent,
        );
      });

      test(
        'when its row left the chat during the upload, even though the '
        'frames then failed: a retry re-sends them, never the recording',
        () async {
          bob([1]);
          outbox
            ..uploadHold = Completer<void>()
            ..refuse.add(1);
          final sending = sendVoice();
          // Reading the recording is real I/O, not a microtask.
          for (var i = 0; i < 1000 && outbox.uploads.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(outbox.uploads, hasLength(1));
          provider.clearMessages();
          outbox.uploadHold!.complete();
          await sending;
          await pump();
          expect(recording.existsSync(), isFalse);
          expect(outbox.delivered, hasLength(1));
          expect(provider.messages, isEmpty);
        },
      );
    });
  });
}
