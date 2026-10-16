import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_siblings.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decision 101 A: a friend's box message needs an address for one live
/// device of ours that relays; the devices it reached forward it to the
/// siblings it could not address, and those read it as the friend's.
///
/// The real plaintext store; Signal and the device lists are faked. An
/// outbound "ciphertext" is `3:` + base64(plaintext), so every frame handed
/// to the box can be read back; an inbound one decrypts to [inbound].
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  final Map<int, VerifiedDeviceList> lists = {};
  final Set<(int, int)> sessions = {};
  String inbound = '{}';

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 1;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => lists[userId];

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => lists[userId] ?? const VerifiedDeviceList.notEnrolled();

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async =>
      sessions.contains((peerUserId, deviceId));

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {
    clearSessionRebuild(recipientId, deviceId: deviceId);
    sessions.add((recipientId, deviceId));
  }

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => '3:${base64Encode(utf8.encode(plaintext))}';

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async => inbound;

  @override
  Future<bool> carriesOwnIdentity(String ciphertext) async => true;

  @override
  Future<bool> preKeyWouldReplaceSession(
    int userId,
    int deviceId,
    String ciphertext,
  ) async => false;

  @override
  Future<void> savePendingSendRecord(
    String key,
    Map<String, dynamic> data,
  ) async {}
}

class _Outbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};
  final Map<int, ContactOutbound> siblings = {};
  final List<(ContactOutbound, BoxFrame)> delivered = [];
  final List<BoxSendMode?> modes = [];
  int _next = kFirstLocalMessageId + 500;

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
    modes.add(mode);
    return BoxSendOutcome.taken;
  }

  @override
  Future<int?> nextLocalId() async => _next++;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async => throw UnimplementedError();

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async =>
      throw UnimplementedError();
}

class _Siblings implements BoxSiblingLink {
  final Map<int, ContactRecord> contacts = {};

  @override
  ContactRecord? contactOf(int userId) => contacts[userId];

  @override
  Future<void> rekeySibling(int deviceId) async {}

  @override
  bool awaitingRekeyFrom(int deviceId) => false;

  @override
  void rekeyAnswered(int deviceId) {}

  @override
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async => SiblingWrite.stored;

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async =>
      SiblingWrite.stored;
}

/// The friend side, as far as a friend's frame read goes: the records, and
/// every device noted as relaying.
class _Friends implements BoxFriendLink {
  final Map<int, ContactRecord> contacts = {};
  final List<(int, int)> relaysNoted = [];

  @override
  bool get onBox => false;

  @override
  ContactRecord? contactOf(int userId) => contacts[userId];

  @override
  Future<void> friendRelays(int userId, int deviceId) async =>
      relaysNoted.add((userId, deviceId));

  @override
  void friendHeard(int userId, int deviceId) {}

  @override
  void friendRekeyAnswered(int userId, int deviceId) {}

  @override
  void friendSessionStarted(int userId, int deviceId) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VerifiedDeviceList _enrolled(List<int> live) => VerifiedDeviceList.enrolled(
  version: 3,
  listHash: 'H' * 44,
  devices: [
    for (final id in live)
      DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
  ],
);

ContactOutbound _address(int device, {bool relays = false}) => ContactOutbound(
  peerDeviceId: device,
  sid: 'sid-$device',
  sealPub: 'seal',
  relays: relays,
);

ContactOutbound _selfQueue(int device) =>
    ContactOutbound(peerDeviceId: device, sid: 'self-$device', sealPub: 'seal');

const Map<String, dynamic> _conv = {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

const _bob = ContactRecord(
  userId: 2,
  username: 'bob',
  tag: '0002',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: 10),
);

const _wire = 'wire-bob-0001';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late _Outbox outbox;
  late _Siblings siblings;
  late _Friends friends;
  late List<String> emitted;
  var nextLocal = kFirstLocalMessageId;

  Future<void> pump([int turns = 60]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _Encryption(service)
      ..lists[2] = _enrolled([1, 2])
      ..lists[1] = _enrolled([1, 3]);
    final kv = await PrefsContentKv.open();
    final store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    outbox = _Outbox()..siblings[3] = _selfQueue(3);
    siblings = _Siblings()..contacts[2] = _bob;
    friends = _Friends()..contacts[2] = _bob;
    emitted = [];
    conversations = ConversationsProvider()
      ..contactStore = store
      ..setCurrentUserId(1)
      ..onConversationsList([_conv])
      ..openConversation(10);
    await store.settled;
    provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10)
      ..setEmitCallback((event, _) => emitted.add(event))
      ..boxOutbox = outbox
      ..boxSiblings = siblings
      ..boxFriends = friends;
  });

  tearDown(() => provider.dispose());

  /// Bob's devices [addressed] handed us queues, those in [relaying] said
  /// they relay; the connect's list refresh then runs.
  Future<void> bobAddressed(
    List<int> addressed, {
    Set<int> relaying = const {},
  }) async {
    outbox.addresses[2] = {
      for (final d in addressed) d: _address(d, relays: relaying.contains(d)),
    };
    provider.refreshBoxDeviceLists();
    await pump();
  }

  BoxInboxEntry entry({int peer = 2, int device = 1, bool viaSelf = false}) =>
      BoxInboxEntry(
        rid: viaSelf ? 'self-rid' : 'rid',
        id: 'm${nextLocal - kFirstLocalMessageId}',
        localId: nextLocal++,
        peerUserId: peer,
        senderDeviceId: device,
        signal: '2:AQID',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
        viaSelfQueue: viaSelf,
      );

  Map<String, dynamic> envelopeOf(BoxFrame frame) =>
      jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

  /// Bob's message [text] under [wire], as his device sealed it: `rl`, and
  /// `ad` when [ad] is given.
  String bobSays(String text, {String wire = _wire, List<int>? ad}) =>
      E2eEnvelope.toFriend(
        jsonEncode(
          E2eEnvelope.build(
            text,
            msgId: wire,
            sentAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 5),
            ),
          ),
        ),
        addressed: ad,
      );

  /// [envelope] read on Bob's queue, from his device 1.
  Future<bool> fromBob(String envelope) async {
    encryption.inbound = envelope;
    final done = await provider.consumeBoxEntry(entry(), _bob);
    await pump();
    return done;
  }

  /// [envelope] — Bob's, as his device 1 sealed it — relayed by our
  /// sibling 3 through our self-queue.
  Future<bool> relayedBySibling(String envelope, {int user = 2}) async {
    encryption.inbound = E2eEnvelope.buildRelay(
      user: user,
      device: 1,
      envelope: envelope,
    );
    final done = await provider.consumeBoxEntry(
      entry(peer: 1, device: 3, viaSelf: true),
      null,
    );
    await pump();
    return done;
  }

  Iterable<MessageModel> rowsOf(String wire) =>
      provider.messages.where((m) => m.senderId == 2 && m.wireId == wire);

  group('sending to a friend', () {
    test(
      'one addressed live device that relays covers the friend: frames go to '
      'it alone, the peer frame carries rl and ad, the sent copy neither',
      () async {
        await bobAddressed([1], relaying: {1});

        provider.sendMessage('hi');
        await pump();

        expect(emitted, isNot(contains('sendMessage')));
        expect(
          outbox.delivered.map((d) => d.$1.sid),
          unorderedEquals(['sid-1', 'self-3']),
        );
        final peer = envelopeOf(
          outbox.delivered.singleWhere((d) => d.$1.sid == 'sid-1').$2,
        );
        expect(peer, containsPair('rl', 1));
        expect(peer, containsPair('ad', [1]));
        expect(peer, containsPair('content', 'hi'));
        final copy = envelopeOf(
          outbox.delivered.singleWhere((d) => d.$1.sid == 'self-3').$2,
        );
        expect(copy.containsKey('rl'), isFalse);
        expect(copy.containsKey('ad'), isFalse);
        expect(copy, containsPair('to', 2));
        final row = provider.messages.last;
        expect(isLocalMessageId(row.id), isTrue);
        expect(row.deliveryStatus, MessageDeliveryStatus.sent);
      },
    );

    test(
      'every live device addressed: rl on every peer frame, no ad (nothing '
      'to relay)',
      () async {
        await bobAddressed([1, 2]);

        provider.sendMessage('all there');
        await pump();

        final peerFrames = [
          for (final (to, frame) in outbox.delivered)
            if (to.sid.startsWith('sid-')) envelopeOf(frame),
        ];
        expect(peerFrames, hasLength(2));
        for (final envelope in peerFrames) {
          expect(envelope, containsPair('rl', 1));
          expect(envelope.containsKey('ad'), isFalse);
        }
      },
    );

    test(
      'an unaddressed live device and no addressed one relaying keeps '
      "today's rule: the whole message takes the old path",
      () async {
        await bobAddressed([1]);

        provider.sendMessage('mixed');
        await pump();

        expect(outbox.delivered, isEmpty);
        expect(emitted, contains('sendMessage'));
        expect(isLocalMessageId(provider.messages.last.id), isFalse);
      },
    );
  });

  group('reading a friend frame', () {
    test('rl marks that device as relaying', () async {
      expect(await fromBob(bobSays('hello')), isTrue);
      expect(friends.relaysNoted, [(2, 1)]);
    });

    test(
      'a message whose ad leaves out live siblings is relayed, quiet, to '
      'each of them that has a self-queue — never to an addressed one — and '
      'only on its first read',
      () async {
        encryption.lists[1] = _enrolled([1, 3, 4, 5]);
        outbox.siblings[4] = _selfQueue(4);
        encryption.sessions
          ..add((1, 3))
          ..add((1, 4));
        final said = bobSays('hello', ad: [1, 3]);

        expect(await fromBob(said), isTrue);

        expect(outbox.delivered.map((d) => d.$1.sid), ['self-4']);
        expect(outbox.modes, [BoxSendMode.quiet]);
        final relay = envelopeOf(outbox.delivered.single.$2);
        expect(relay, containsPair('t', E2eEnvelope.typeRelay));
        expect(relay, containsPair('u', 2));
        expect(relay, containsPair('d', 1));
        expect(relay['e'], jsonDecode(said));

        // A retry of the same message is a duplicate here: nothing more.
        expect(await fromBob(said), isTrue);
        expect(outbox.delivered, hasLength(1));
      },
    );

    test('a message without ad reached every device: no relay', () async {
      encryption.lists[1] = _enrolled([1, 3]);
      encryption.sessions.add((1, 3));

      expect(await fromBob(bobSays('to all')), isTrue);

      expect(outbox.delivered, isEmpty);
    });

    test(
      "an action is relayed like a message; an edit of someone else's "
      'message is not',
      () async {
        encryption.lists[1] = _enrolled([1, 3]);
        encryption.sessions.add((1, 3));
        await fromBob(bobSays('hello', ad: [1]));
        outbox.delivered.clear();

        String bobActs(String type, {required int s, String? emoji}) =>
            E2eEnvelope.toFriend(
              jsonEncode(
                E2eEnvelope.buildAction(
                  type,
                  targetSender: s,
                  targetWire: _wire,
                  sentAt: DateTime.now().toUtc(),
                  emoji: emoji,
                  on: type == E2eEnvelope.typeReact ? true : null,
                  content: 'changed',
                ),
              ),
              addressed: [1],
            );

        await fromBob(bobActs(E2eEnvelope.typeReact, s: 2, emoji: '👍'));
        expect(outbox.delivered.map((d) => d.$1.sid), ['self-3']);
        expect(
          envelopeOf(outbox.delivered.single.$2)['e'],
          containsPair('t', E2eEnvelope.typeReact),
        );

        await fromBob(bobActs(E2eEnvelope.typeEdit, s: 1));
        expect(outbox.delivered, hasLength(1), reason: 'refused, not relayed');
      },
    );
  });

  group('a relayed frame on our self-queue', () {
    test(
      'is read as the friend message, from its device, in the friend chat, '
      'stored under its wire id',
      () async {
        expect(await relayedBySibling(bobSays('via 3', ad: [3])), isTrue);

        final row = rowsOf(_wire).single;
        expect(row.content, 'via 3');
        expect(row.conversationId, 10);
        expect(row.originDeviceId, 1);
        expect(isLocalMessageId(row.id), isTrue);
        expect(
          await encryption.store.wireHolder((senderId: 2, wireId: _wire)),
          row.id,
        );
      },
    );

    test('relayed first, then the direct copy: stored once', () async {
      await relayedBySibling(bobSays('once', ad: [3]));
      final first = rowsOf(_wire).single.id;

      expect(await fromBob(bobSays('once', ad: [3])), isTrue);

      expect(rowsOf(_wire).map((m) => m.id), [first]);
      expect(
        await encryption.store.wireHolder((senderId: 2, wireId: _wire)),
        first,
      );
    });

    test('the direct copy first, then relayed: stored once', () async {
      await fromBob(bobSays('once', ad: [3]));
      final first = rowsOf(_wire).single.id;

      expect(await relayedBySibling(bobSays('once', ad: [3])), isTrue);

      expect(rowsOf(_wire).map((m) => m.id), [first]);
    });

    test(
      "a relayed edit by the friend of the friend's message is honoured; "
      'one claiming our message is refused (E19b)',
      () async {
        await fromBob(bobSays('typo'));
        // Our own box message to Bob, as sibling 3 sent it.
        encryption.inbound = jsonEncode(
          E2eEnvelope.build(
            'mine',
            msgId: 'wire-mine-0001',
            sentAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 1),
            ),
            sentTo: 2,
          ),
        );
        await provider.consumeBoxEntry(
          entry(peer: 1, device: 3, viaSelf: true),
          null,
        );
        await pump();

        String edit(int targetSender, String wire) => jsonEncode(
          E2eEnvelope.buildAction(
            E2eEnvelope.typeEdit,
            targetSender: targetSender,
            targetWire: wire,
            sentAt: DateTime.now().toUtc(),
            content: 'edited',
          ),
        );

        expect(await relayedBySibling(edit(2, _wire)), isTrue);
        expect(rowsOf(_wire).single.content, 'edited');

        expect(await relayedBySibling(edit(1, 'wire-mine-0001')), isTrue);
        expect(
          provider.messages
              .singleWhere((m) => m.wireId == 'wire-mine-0001')
              .content,
          'mine',
        );
      },
    );

    test(
      'is never read when it is not a friend message or action: a relay '
      'inside a relay, or a non-friend sender',
      () async {
        final nested = E2eEnvelope.buildRelay(
          user: 2,
          device: 1,
          envelope: bobSays('deep'),
        );
        expect(await relayedBySibling(nested), isTrue);
        expect(await relayedBySibling(bobSays('stranger'), user: 9), isTrue);

        expect(provider.messages, isEmpty);
      },
    );

    test('from the public request queue is refused', () async {
      encryption.inbound = E2eEnvelope.buildRelay(
        user: 2,
        device: 1,
        envelope: bobSays('forged'),
      );
      final e = BoxInboxEntry(
        rid: 'req-rid',
        id: 'r1',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 3,
        signal: '2:AQID',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
        viaRequestQueue: true,
      );

      expect(await provider.consumeBoxEntry(e, null), isTrue);
      await pump();

      expect(provider.messages, isEmpty);
    });
  });
}
