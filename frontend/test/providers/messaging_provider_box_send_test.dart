import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

ContactOutbound _address(int device) => ContactOutbound(
  peerDeviceId: device,
  sid: 'sid-$device',
  sealPub: 'seal-$device',
);

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

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setActiveConversationIdForTest(10)
    ..setEmitCallback((event, data) => emitted.add(event))
    ..boxOutbox = outbox;

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
    emitted = [];
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

  test(
    'a chat with a disappearing timer stays on the old path: the box '
    'envelope carries no expiry yet',
    () async {
      await setUpWith(timer: 60);
      bob([1]);
      await send('vanishing');

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
    },
  );

  test(
    'a reply stays on the old path: the box envelope names no quoted '
    'message yet',
    () async {
      bob([1]);
      provider.sendMessage('re: that', replyToMessageId: 5);
      await pump();

      expect(outbox.delivered, isEmpty);
      expect(emitted, contains('sendMessage'));
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

  test('a ping stays on the old path', () async {
    bob([1]);
    provider.sendPing(2);
    await pump();

    expect(outbox.delivered, isEmpty);
    expect(emitted, contains('sendMessage'));
  });

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
}
