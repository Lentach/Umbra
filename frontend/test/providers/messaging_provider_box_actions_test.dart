import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
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

/// The real plaintext store; Signal and the device lists are faked. An
/// outbound "ciphertext" is `3:` + base64(plaintext), so every frame handed
/// to the box can be read back; an inbound one decrypts to [inbound].
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  final Map<int, VerifiedDeviceList> lists = {};
  final Set<(int, int)> sessions = {};
  String inbound = '{}';

  /// Per local id, overriding [inbound]: for deliveries read concurrently.
  final Map<int, String> inboundFor = {};

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
  }) async => inboundFor[messageId] ?? inbound;

  @override
  Future<bool> carriesOwnIdentity(String ciphertext) async => true;

  @override
  Future<bool> siblingPreKeyWouldReplace(
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

  /// Devices whose `send` the box refuses.
  final Set<int> refuse = {};

  /// While set, every `deliver` that starts waits for it (captured at start,
  /// so clearing it lets later sends through while earlier ones hang).
  Completer<void>? gate;
  final List<(ContactOutbound, BoxFrame)> delivered = [];
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
  Future<bool> deliver(ContactOutbound to, Uint8List body) async {
    delivered.add((to, BoxFrame.decode(body)!));
    final held = gate;
    if (held != null) await held.future;
    return !refuse.contains(to.peerDeviceId);
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

/// [inner] whose [setString] shows the new value only once it committed,
/// after an await — as `NativeContentStore` does on Android — so two
/// read-modify-writes overlap unless something serializes them.
class _SlowWriteKv implements ContentKv {
  _SlowWriteKv(this.inner);

  final ContentKv inner;

  @override
  Future<void> reload() => inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      inner.authoritativeSnapshot();

  @override
  String? getString(String key) => inner.getString(key);

  @override
  int? getInt(String key) => inner.getInt(key);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  Future<bool> setString(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) => inner.setInt(key, value);

  @override
  Future<bool> remove(String key) => inner.remove(key);
}

class _Link implements BoxSiblingLink {
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

VerifiedDeviceList _enrolled(List<int> live) => VerifiedDeviceList.enrolled(
  version: 3,
  listHash: 'H' * 44,
  devices: [
    for (final id in live)
      DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
  ],
);

ContactOutbound _address(int device) =>
    ContactOutbound(peerDeviceId: device, sid: 'sid-$device', sealPub: 'seal');

ContactOutbound _selfQueue(int device) =>
    ContactOutbound(peerDeviceId: device, sid: 'self-$device', sealPub: 'seal');

Map<String, dynamic> _conv({int? serverPin}) => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
  'pinnedMessageId': ?serverPin,
};

const _bob = ContactRecord(
  userId: 2,
  username: 'bob',
  tag: '0002',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: 10),
);

const _carol = ContactRecord(
  userId: 3,
  username: 'carol',
  tag: '0003',
  state: ContactState.friend,
  legacy: ContactLegacy(conversationId: 11),
);

const Map<String, dynamic> _carolConv = {
  'id': 11,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 3, 'username': 'carol', 'tag': '0003'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late _Outbox outbox;
  late _Link link;
  late ContactStore store;
  late List<(String, Object?)> emitted;
  late List<BoxActionFailure> failures;
  var nextLocal = kFirstLocalMessageId;

  MessagingProvider newProvider() {
    final p = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10)
      ..setEmitCallback((event, data) => emitted.add((event, data)))
      ..boxOutbox = outbox
      ..boxSiblings = link;
    p.boxActionFailures.listen(failures.add);
    return p;
  }

  ConversationsProvider newConversations({int? serverPin}) =>
      ConversationsProvider()
        ..contactStore = store
        ..setCurrentUserId(1)
        ..setEmitCallback((event, data) => emitted.add((event, data)))
        ..onConversationsList([_conv(serverPin: serverPin), _carolConv])
        ..openConversation(10);

  Future<void> pump([int turns = 60]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> setUpWith({int? serverPin}) async {
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
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    outbox = _Outbox()
      ..addresses[2] = {1: _address(1), 2: _address(2)}
      ..siblings[3] = _selfQueue(3);
    link = _Link()..contacts[2] = _bob;
    emitted = [];
    failures = [];
    conversations = newConversations(serverPin: serverPin);
    await store.settled;
    provider = newProvider()..refreshBoxDeviceLists();
    await pump();
  }

  setUp(setUpWith);

  List<String> events() => [for (final (e, _) in emitted) e];

  Map<String, dynamic> envelopeOf(BoxFrame frame) =>
      jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

  DateTime nowMs() => DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );

  BoxInboxEntry entry({
    int peer = 2,
    int device = 1,
    bool viaSelf = false,
    DateTime? receivedAt,
  }) => BoxInboxEntry(
    rid: viaSelf ? 'self-rid' : 'rid',
    id: 'm${nextLocal - kFirstLocalMessageId}',
    localId: nextLocal++,
    peerUserId: peer,
    senderDeviceId: device,
    signal: '2:AQID',
    receivedAt: receivedAt ?? DateTime.now().toUtc(),
    acked: true,
    viaSelfQueue: viaSelf,
  );

  /// Bob's box message [text] under wire id [wire], sent [ago] before now
  /// (or at [at]).
  Future<MessageModel> fromBob(
    String text, {
    required String wire,
    Duration ago = const Duration(minutes: 10),
    DateTime? at,
    E2eReplyQuote? quote,
  }) async {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(
        text,
        msgId: wire,
        sentAt: at ?? DateTime.now().toUtc().subtract(ago),
        replyQuote: quote,
      ),
    );
    final e = entry();
    expect(await provider.consumeBoxEntry(e, _bob), isTrue);
    await pump();
    return provider.messages.singleWhere((m) => m.id == e.localId);
  }

  /// OUR box message to Bob as sibling device 3 sent it: its sent copy.
  Future<MessageModel> fromSibling(String text, {required String wire}) async {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(
        text,
        msgId: wire,
        sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        sentTo: 2,
      ),
    );
    final e = entry(peer: 1, device: 3, viaSelf: true);
    expect(await provider.consumeBoxEntry(e, null), isTrue);
    await pump();
    return provider.messages.singleWhere((m) => m.id == e.localId);
  }

  /// Our own box message, sent from this device over the box.
  Future<MessageModel> mine(String text) async {
    provider.sendMessage(text);
    await pump();
    final row = provider.messages.last;
    expect(isLocalMessageId(row.id), isTrue, reason: 'went over the box');
    outbox.delivered.clear();
    emitted.clear();
    return row;
  }

  /// An action frame from Bob's device 1, delivered at [receivedAt].
  Future<bool> bobDoes(
    Map<String, dynamic> envelope, {
    DateTime? receivedAt,
  }) async {
    encryption.inbound = jsonEncode(envelope);
    final done = await provider.consumeBoxEntry(
      entry(receivedAt: receivedAt),
      _bob,
    );
    await pump();
    return done;
  }

  /// A sent copy of OUR action from sibling device 3, naming Bob.
  Future<bool> siblingDoes(Map<String, dynamic> envelope) async {
    encryption.inbound = jsonEncode(envelope);
    final done = await provider.consumeBoxEntry(
      entry(peer: 1, device: 3, viaSelf: true),
      null,
    );
    await pump();
    return done;
  }

  Map<String, dynamic> action(
    String type, {
    required int s,
    required String w,
    DateTime? at,
    String? emoji,
    bool? on,
    String content = '',
    int? to,
  }) => E2eEnvelope.buildAction(
    type,
    targetSender: s,
    targetWire: w,
    sentAt: at ?? nowMs(),
    emoji: emoji,
    on: on,
    content: content,
    sentTo: to,
  );

  Future<Map<String, dynamic>?> recordOf(int id) =>
      encryption.store.getDecryptedContent(id);

  MessageModel? row(int id) =>
      provider.messages.where((m) => m.id == id).firstOrNull;

  /// A fresh app on the same disk: the wire-id cache is per instance.
  Future<void> restart() async {
    provider.dispose();
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final lists = encryption.lists;
    final sessions = encryption.sessions;
    encryption = _Encryption(service)
      ..lists.addAll(lists)
      ..sessions.addAll(sessions);
    conversations = newConversations();
    await store.settled;
    provider = newProvider()..refreshBoxDeviceLists();
    await provider.onMessageHistory({
      'conversationId': 10,
      'messages': <Object>[],
    });
    await pump(120);
  }

  void expectNoServerAction() => expect(
    events(),
    isNot(
      anyOf([
        contains('addReaction'),
        contains('removeReaction'),
        contains('pinMessage'),
        contains('editMessage'),
        contains('deleteMessage'),
      ]),
    ),
  );

  group('send (E19a)', () {
    test(
      'a reaction on a box message goes to every peer device and, as a sent '
      'copy naming the peer, to every sibling — never as addReaction — and '
      'survives a restart in the record (E19d)',
      () async {
        final msg = await fromBob('hi', wire: 'wire-bob-0001');

        expect(await provider.addReaction(msg.id, '👍'), isTrue);
        await pump();

        expectNoServerAction();
        expect(
          outbox.delivered.map((d) => d.$1.sid),
          unorderedEquals(['sid-1', 'sid-2', 'self-3']),
        );
        for (final (to, frame) in outbox.delivered) {
          final env = envelopeOf(frame);
          expect(env['t'], 'react');
          expect(env['tg'], {'s': 2, 'w': 'wire-bob-0001'});
          expect(env['e'], '👍');
          expect(env['on'], isTrue);
          if (to.sid.startsWith('self-')) {
            expect(env['to'], 2);
          } else {
            expect(env.containsKey('to'), isFalse);
          }
        }
        expect(row(msg.id)!.reactions, {
          '👍': [1],
        });

        await restart();
        expect(row(msg.id)!.reactions, {
          '👍': [1],
        });
      },
    );

    test(
      'a reaction NO device took fails and is taken back (E19l)',
      () async {
        final msg = await fromBob('hi', wire: 'wire-bob-0002');
        outbox.refuse.addAll([1, 2, 3]);

        expect(await provider.addReaction(msg.id, '👍'), isFalse);
        await pump();

        expect(row(msg.id)!.reactions, isEmpty);
        expect((await recordOf(msg.id))?['reactions'], isNull);

        // Nothing was taken, so nothing is owed a retry.
        outbox
          ..delivered.clear()
          ..refuse.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered, isEmpty);
      },
    );

    test(
      'a reaction some device took stays; a later reaction on the same '
      'target supersedes the retry owed to the device that refused (E19l)',
      () async {
        final msg = await fromBob('hi', wire: 'wire-bob-0006');
        outbox.refuse.add(2);

        expect(await provider.addReaction(msg.id, '👍'), isTrue);
        await pump();
        expect(row(msg.id)!.reactions, {
          '👍': [1],
        });
        expect((await recordOf(msg.id))?['reactions'], {
          '👍': [1],
        });

        outbox
          ..delivered.clear()
          ..refuse.clear();
        expect(await provider.removeReaction(msg.id, '👍'), isTrue);
        await pump();
        expect(outbox.delivered, hasLength(3));

        outbox.delivered.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'the old 👍 is not re-sent');
      },
    );

    test(
      'an older reaction settling after a newer one was taken leaves no '
      'retry: the newer owns every device (E19l)',
      () async {
        final msg = await fromBob('hi', wire: 'wire-bob-0007');
        final slow = outbox.gate = Completer<void>();
        final older = provider.addReaction(msg.id, '👍');
        await pump();
        outbox.gate = null;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(await provider.addReaction(msg.id, '❤️'), isTrue);

        // Device 2 refuses the older one only.
        outbox.refuse.add(2);
        slow.complete();
        expect(await older, isTrue);
        await pump();

        outbox
          ..delivered.clear()
          ..refuse.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered, isEmpty);
      },
    );

    test(
      'a box action whose route is gone fails visibly, never as a server '
      'event (decision 25)',
      () async {
        final msg = await mine('mine');
        outbox.addresses.remove(2);

        provider.deleteMessage(msg.id, forEveryone: true);
        await pump();

        expect(failures, [BoxActionFailure.delete]);
        expect(row(msg.id), isNotNull);
        expectNoServerAction();
      },
    );

    test(
      'delete-for-everyone of our box message: a del frame per device, the '
      'row and record gone, no deleteMessage emit',
      () async {
        final msg = await mine('regret');

        provider.deleteMessage(msg.id, forEveryone: true);
        await pump();

        expectNoServerAction();
        expect(outbox.delivered, hasLength(3));
        for (final (_, frame) in outbox.delivered) {
          final env = envelopeOf(frame);
          expect(env['t'], 'del');
          expect(env['tg'], {'s': 1, 'w': msg.wireId});
        }
        expect(row(msg.id), isNull);
        expect(await recordOf(msg.id), isNull);
        expect(failures, isEmpty);
      },
    );

    test(
      'a delete NO device took keeps the row and says so',
      () async {
        final msg = await mine('stays');
        outbox.refuse.addAll([1, 2, 3]);

        provider.deleteMessage(msg.id, forEveryone: true);
        await pump();

        expect(row(msg.id), isNotNull);
        expect(await recordOf(msg.id), isNotNull);
        expect(failures, [BoxActionFailure.delete]);
      },
    );

    test(
      'a delete one peer device refused (queue_full) still deletes here, '
      'and the retry sends the same del frame to that device alone until it '
      'takes it (E19l)',
      () async {
        final msg = await mine('regret');
        outbox.refuse.add(2);

        provider.deleteMessage(msg.id, forEveryone: true);
        await pump();

        expect(failures, isEmpty);
        expect(row(msg.id), isNull);
        expect(await recordOf(msg.id), isNull);
        final sent = envelopeOf(
          outbox.delivered.singleWhere((d) => d.$1.sid == 'sid-2').$2,
        );

        // Still refused: tried again, still owed.
        outbox.delivered.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered.map((d) => d.$1.sid), ['sid-2']);

        outbox
          ..delivered.clear()
          ..refuse.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered.map((d) => d.$1.sid), ['sid-2']);
        expect(envelopeOf(outbox.delivered.single.$2), sent);

        outbox.delivered.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'healed: nothing owed');
        expect(failures, isEmpty);
      },
    );

    /// [body] with the whole setup rebuilt in fake time: a future made in
    /// the real zone never completes inside `fakeAsync`.
    void inFakeTime(void Function(FakeAsync clock) body) => fakeAsync((clock) {
      var ready = false;
      unawaited(setUpWith().then((_) => ready = true));
      clock.elapse(const Duration(seconds: 1));
      expect(ready, isTrue);
      body(clock);
    });

    MessageModel mineNow(FakeAsync clock, String text) {
      MessageModel? sent;
      unawaited(mine(text).then((m) => sent = m));
      clock.elapse(const Duration(seconds: 1));
      return sent!;
    }

    test('the retry runs on its own: first after 30 s (E19l)', () {
      inFakeTime((clock) {
        final msg = mineNow(clock, 'regret');
        outbox.refuse.add(2);
        provider.deleteMessage(msg.id, forEveryone: true);
        clock.elapse(const Duration(seconds: 1));
        expect(row(msg.id), isNull);
        outbox
          ..delivered.clear()
          ..refuse.clear();
        clock.elapse(const Duration(seconds: 27));
        expect(outbox.delivered, isEmpty);
        clock.elapse(const Duration(seconds: 3));
        expect(outbox.delivered.map((d) => d.$1.sid), ['sid-2']);
      });
    });

    test('a retry keeps trying for 30 days of refusals, then stops (E19l)', () {
      inFakeTime((clock) {
        final msg = mineNow(clock, 'regret');
        final other = mineNow(clock, 'another');
        outbox.refuse.add(2);
        provider.deleteMessage(msg.id, forEveryone: true);
        clock.elapse(const Duration(days: 29));
        provider.deleteMessage(other.id, forEveryone: true);
        clock.elapse(const Duration(days: 1, hours: 1));
        outbox
          ..delivered.clear()
          ..refuse.clear();
        provider.refreshBoxDeviceLists();
        clock.elapse(const Duration(seconds: 1));
        // Only the delete sent a day ago is still owed.
        expect(outbox.delivered, hasLength(1));
        expect(envelopeOf(outbox.delivered.single.$2)['tg'], {
          's': 1,
          'w': other.wireId,
        });
      });
    });

    test(
      'an edit of our box message within the window goes as an edit frame '
      'and rewrites the record; never editMessage',
      () async {
        final msg = await mine('typo');

        provider.editMessage(msg.id, 'fixed');
        await pump();

        expectNoServerAction();
        expect(outbox.delivered, hasLength(3));
        final env = envelopeOf(outbox.delivered.first.$2);
        expect(env['t'], 'edit');
        expect(env['content'], 'fixed');
        expect(env['tg'], {'s': 1, 'w': msg.wireId});
        final edited = row(msg.id)!;
        expect(edited.content, 'fixed');
        expect(edited.editedAt?.millisecondsSinceEpoch, env['ts']);
        final record = await recordOf(msg.id);
        expect(record?['content'], 'fixed');

        await restart();
        expect(row(msg.id)!.content, 'fixed');
        expect(row(msg.id)!.editedAt, isNotNull);
      },
    );

    test('an edit NO device took reverts the row and the record and says so', () async {
      final msg = await mine('typo');
      outbox.refuse.addAll([1, 2, 3]);

      provider.editMessage(msg.id, 'fixed');
      await pump();

      expect(row(msg.id)!.content, 'typo');
      expect((await recordOf(msg.id))?['content'], 'typo');
      expect(failures, [BoxActionFailure.edit]);
    });

    test(
      'an edit one sibling refused stays, and the retry sends that sibling '
      'the same edit alone (E19l)',
      () async {
        final msg = await mine('typo');
        outbox.refuse.add(3);

        provider.editMessage(msg.id, 'fixed');
        await pump();

        expect(failures, isEmpty);
        expect(row(msg.id)!.content, 'fixed');
        expect((await recordOf(msg.id))?['content'], 'fixed');
        final sent = envelopeOf(
          outbox.delivered.singleWhere((d) => d.$1.sid == 'self-3').$2,
        );

        outbox
          ..delivered.clear()
          ..refuse.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered.map((d) => d.$1.sid), ['self-3']);
        expect(envelopeOf(outbox.delivered.single.$2), sent);

        outbox.delivered.clear();
        provider.refreshBoxDeviceLists();
        await pump();
        expect(outbox.delivered, isEmpty);
      },
    );

    test(
      'two edits in flight: the older one settling LAST keeps the newer on '
      'screen and in the record, as on every peer (E19b)',
      () async {
        final msg = await mine('typo');
        final slow = outbox.gate = Completer<void>();
        provider.editMessage(msg.id, 'first');
        await pump();
        outbox.gate = null;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        provider.editMessage(msg.id, 'second');
        await pump();
        expect((await recordOf(msg.id))?['content'], 'second');

        slow.complete();
        await pump();
        expect(row(msg.id)!.content, 'second');
        expect((await recordOf(msg.id))?['content'], 'second');
        await restart();
        expect(row(msg.id)!.content, 'second');
      },
    );

    test(
      'an older edit failing while a newer one is in flight reverts nothing: '
      'the newer edit owns the row',
      () async {
        final msg = await mine('typo');
        final slow = outbox.gate = Completer<void>();
        provider.editMessage(msg.id, 'first');
        await pump();
        final newer = outbox.gate = Completer<void>();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        provider.editMessage(msg.id, 'second');
        await pump();

        // The older edit fails while the newer one is still in flight.
        outbox.refuse.addAll([1, 2, 3]);
        slow.complete();
        await pump();
        expect(failures, [BoxActionFailure.edit]);
        expect(row(msg.id)!.content, 'second');

        outbox.refuse.clear();
        newer.complete();
        await pump();
        expect(row(msg.id)!.content, 'second');
        expect((await recordOf(msg.id))?['content'], 'second');
      },
    );

    test(
      'pinning a box message sends a pin frame, shows it, and clears an old '
      'server pin with ONE unpinMessage (decision 45)',
      () async {
        await setUpWith(serverPin: 555);
        final msg = await fromBob('pin me', wire: 'wire-bob-0003');

        provider.pinMessage(10, msg.id);
        await pump();

        expect(events(), isNot(contains('pinMessage')));
        expect(events().where((e) => e == 'unpinMessage'), hasLength(1));
        final env = envelopeOf(outbox.delivered.first.$2);
        expect(env['t'], 'pin');
        expect(env['on'], isTrue);
        expect(env['tg'], {'s': 2, 'w': 'wire-bob-0003'});
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);

        // The server's own answer to that unpin leaves the E2E pin alone.
        conversations.onMessageUnpinned({'conversationId': 10});
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);

        // Pinning again: the server holds no pin any more, so no emit.
        emitted.clear();
        provider.unpinMessage(10);
        await pump();
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);
        expect(events(), isEmpty);
        provider.pinMessage(10, msg.id);
        await pump();
        expect(events(), isEmpty);
      },
    );

    test('a pin NO device took restores what it displaced and says so', () async {
      await setUpWith(serverPin: 555);
      final msg = await fromBob('pin me', wire: 'wire-bob-0004');
      outbox.refuse.addAll([1, 2, 3]);

      provider.pinMessage(10, msg.id);
      await pump();

      expect(conversations.getConversationById(10)!.pinnedMessageId, 555);
      expect(events(), isNot(contains('unpinMessage')));
      expect(failures, [BoxActionFailure.pin]);
      expect(conversations.boxPinOf(10)?.pinned ?? false, isFalse);
    });

    test(
      'a pin survives a restart: the chat resolves it when it opens',
      () async {
        final msg = await fromBob('pinned', wire: 'wire-bob-0005');
        provider.pinMessage(10, msg.id);
        await pump();
        await store.settled;

        await restart();

        final conv = conversations.getConversationById(10)!;
        expect(conv.pinnedMessageId, msg.id);
        expect(conv.pinnedMessagePreview?.content, 'pinned');
      },
    );

    test(
      'an old-path row keeps its server events (decision 46)',
      () async {
        provider
          ..pinMessage(10, 77)
          ..deleteMessage(77, forEveryone: true);
        expect(events(), containsAllInOrder(['pinMessage', 'deleteMessage']));
        expect(outbox.delivered, isEmpty);
      },
    );
  });

  group('receive (E19b-E19d)', () {
    test(
      "a peer's reaction lands on the held target, persisted; a repeat is "
      'idempotent; remove takes it off; a new emoji replaces the old one',
      () async {
        final msg = await fromBob('react to me', wire: 'wire-bob-0010');
        final mineRow = await mine('and me');

        expect(
          await bobDoes(action('react', s: 1, w: mineRow.wireId!, emoji: '🔥', on: true)),
          isTrue,
        );
        await bobDoes(action('react', s: 1, w: mineRow.wireId!, emoji: '🔥', on: true));
        expect(row(mineRow.id)!.reactions, {
          '🔥': [2],
        });
        expect((await recordOf(mineRow.id))?['reactions'], {
          '🔥': [2],
        });

        await bobDoes(action('react', s: 1, w: mineRow.wireId!, emoji: '😂', on: true));
        expect(row(mineRow.id)!.reactions, {
          '😂': [2],
        });

        await bobDoes(action('react', s: 1, w: mineRow.wireId!, emoji: '😂', on: false));
        expect(row(mineRow.id)!.reactions, isEmpty);
        expect(row(msg.id)!.reactions, isEmpty, reason: 'only the target');
      },
    );

    test(
      'an action naming nothing held in ITS chat applies nothing: an unknown '
      "target, a pin of one, another chat's message, and our own action "
      'through the public request queue',
      () async {
        expect(
          await bobDoes(action('react', s: 2, w: 'wire-unknown-01', emoji: '🔥', on: true)),
          isTrue,
        );
        expect(provider.messages, isEmpty);
        await bobDoes(action('pin', s: 2, w: 'wire-unknown-01', on: true));
        expect(conversations.boxPinOf(10)?.pinned ?? false, isFalse);

        final msg = await fromBob('in chat 10', wire: 'wire-bob-0015');
        encryption.inbound = jsonEncode(
          action('react', s: 2, w: 'wire-bob-0015', emoji: '💀', on: true),
        );
        expect(await provider.consumeBoxEntry(entry(peer: 3), _carol), isTrue);
        await pump();
        expect(row(msg.id)!.reactions, isEmpty, reason: "carol's chat is 11");
        expect((await recordOf(msg.id))?['reactions'], isNull);

        // Bob's message can never land in Carol's chat: nothing parks.
        encryption.inbound = jsonEncode(
          action('react', s: 2, w: 'wire-bob-0016', emoji: '💀', on: true),
        );
        expect(await provider.consumeBoxEntry(entry(peer: 3), _carol), isTrue);
        await pump();
        expect(
          await encryption.store.parkedBoxActions(11, (
            senderId: 2,
            wireId: 'wire-bob-0016',
          )),
          isEmpty,
        );

        encryption.inbound = jsonEncode(
          action('react', s: 2, w: 'wire-bob-0015', emoji: '💀', on: true, to: 2),
        );
        expect(
          await provider.consumeBoxEntry(entry(peer: 1, device: 3), null),
          isTrue,
        );
        await pump();
        expect(row(msg.id)!.reactions, isEmpty, reason: 'request queue');
      },
    );

    test(
      "an edit is honoured only from the target's own sender, within 15 "
      'minutes of its send, text only, last writer wins',
      () async {
        final msg = await fromBob('first', wire: 'wire-bob-0020');
        final sent = msg.createdAt;

        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0020', content: 'second', at: sent.add(const Duration(minutes: 3))),
        );
        expect(row(msg.id)!.content, 'second');
        expect((await recordOf(msg.id))?['content'], 'second');

        // Older than the edit already applied: ignored.
        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0020', content: 'stale', at: sent.add(const Duration(minutes: 2))),
        );
        expect(row(msg.id)!.content, 'second');

        // Our own sibling cannot edit Bob's words.
        await siblingDoes(
          action('edit', s: 2, w: 'wire-bob-0020', content: 'forged', to: 2),
        );
        expect(row(msg.id)!.content, 'second');

        final late = await fromBob('late', wire: 'wire-bob-0021', ago: const Duration(minutes: 20));
        await bobDoes(action('edit', s: 2, w: 'wire-bob-0021', content: 'too late'));
        expect(row(late.id)!.content, 'late');

        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0020', content: 'x' * 20000, at: sent.add(const Duration(minutes: 4))),
        );
        expect(row(msg.id)!.content, 'second', reason: 'decision 18');

        encryption.inbound = jsonEncode(
          E2eEnvelope.build(
            '',
            messageType: 'PING',
            msgId: 'wire-bob-0022',
            sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
          ),
        );
        final e = entry();
        await provider.consumeBoxEntry(e, _bob);
        await pump();
        await bobDoes(action('edit', s: 2, w: 'wire-bob-0022', content: 'words'));
        expect(row(e.localId)!.content, isEmpty, reason: 'text only');
      },
    );

    test('Bob cannot edit or delete OUR message', () async {
      final ours = await mine('mine');
      await bobDoes(action('edit', s: 1, w: ours.wireId!, content: 'pwned'));
      await bobDoes(action('del', s: 1, w: ours.wireId!));
      expect(row(ours.id)!.content, 'mine');
      expect(await recordOf(ours.id), isNotNull);
    });

    test(
      "a sibling's sent copy of our reaction and our edit applies as OUR "
      'account (E19b)',
      () async {
        final msg = await fromBob('hey', wire: 'wire-bob-0030');
        final ours = await mine('tpyo');

        await siblingDoes(action('react', s: 2, w: 'wire-bob-0030', emoji: '❤️', on: true, to: 2));
        expect(row(msg.id)!.reactions, {
          '❤️': [1],
        });

        await siblingDoes(action('edit', s: 1, w: ours.wireId!, content: 'typo', to: 2));
        expect(row(ours.id)!.content, 'typo');
      },
    );

    test(
      'delete-for-everyone from the sender: row, record and pin go, every '
      "reply's quote words go (RAM and record), and a late copy of the "
      'message is dropped even after a restart (E19c)',
      () async {
        final original = await fromBob('secret words', wire: 'wire-bob-0040');
        final reply = await fromBob(
          'replying',
          wire: 'wire-bob-0041',
          ago: const Duration(minutes: 5),
          quote: (
            wireId: 'wire-bob-0040',
            senderId: 2,
            type: 'TEXT',
            snippet: 'secret words',
          ),
        );
        expect(reply.replyTo?.content, 'secret words');
        provider.pinMessage(10, original.id);
        await pump();

        expect(await bobDoes(action('del', s: 2, w: 'wire-bob-0040')), isTrue);

        expect(row(original.id), isNull);
        expect(await recordOf(original.id), isNull);
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);
        expect(row(reply.id)!.replyTo?.content, isEmpty);
        final replyRecord = await recordOf(reply.id);
        expect(jsonEncode(replyRecord), isNot(contains('secret words')));

        await restart();
        expect(row(reply.id)!.replyTo?.content ?? '', isEmpty);
        encryption.inbound = jsonEncode(
          E2eEnvelope.build(
            'secret words',
            msgId: 'wire-bob-0040',
            sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
          ),
        );
        final e = entry();
        expect(await provider.consumeBoxEntry(e, _bob), isTrue);
        await pump();
        expect(row(e.localId), isNull);
        expect(await recordOf(e.localId), isNull);
      },
    );

    test(
      'a delete for a message this device never got leaves a tombstone: the '
      'message arriving afterwards is dropped, and a reply quoting it loses '
      'its snippet',
      () async {
        final reply = await fromBob(
          'about that',
          wire: 'wire-bob-0051',
          quote: (
            wireId: 'wire-bob-0050',
            senderId: 2,
            type: 'TEXT',
            snippet: 'never seen here',
          ),
        );
        expect(await bobDoes(action('del', s: 2, w: 'wire-bob-0050')), isTrue);
        expect(row(reply.id)!.replyTo?.content, isEmpty);

        encryption.inbound = jsonEncode(
          E2eEnvelope.build('never seen here', msgId: 'wire-bob-0050'),
        );
        final e = entry();
        expect(await provider.consumeBoxEntry(e, _bob), isTrue);
        await pump();
        expect(row(e.localId), isNull);
      },
    );

    test(
      'a pin from the peer shows ours; last writer wins on the clamped ts; an '
      'unpin clears it (E19b)',
      () async {
        final ours = await mine('pin this');
        final t0 = nowMs().subtract(const Duration(minutes: 1));

        await bobDoes(action('pin', s: 1, w: ours.wireId!, on: true, at: t0));
        expect(conversations.getConversationById(10)!.pinnedMessageId, ours.id);

        await bobDoes(action('pin', s: 1, w: ours.wireId!, on: false, at: t0.add(const Duration(seconds: 10))));
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);

        // A pin older than that unpin arrives late: stays unpinned.
        await bobDoes(action('pin', s: 1, w: ours.wireId!, on: true, at: t0.add(const Duration(seconds: 5))));
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);
      },
    );

    test(
      'a server pin of an old-path row replaces the E2E pin; newest wins '
      '(decision 45)',
      () async {
        final msg = await fromBob('box pin', wire: 'wire-bob-0060');
        await bobDoes(action('pin', s: 2, w: 'wire-bob-0060', on: true));
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);

        conversations.onMessagePinned({
          'conversationId': 10,
          'pinnedMessageId': 900,
        });
        expect(conversations.getConversationById(10)!.pinnedMessageId, 900);
        expect(conversations.boxPinOf(10)?.pinned ?? false, isFalse);

        // A later E2E pin wins again, and a server snapshot keeps an E2E
        // pin that is still in force.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await bobDoes(action('pin', s: 2, w: 'wire-bob-0060', on: true));
        conversations.onConversationsList([_conv(), _carolConv]);
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);
      },
    );

    test(
      "a server pin never stamps this device's clock into the register: a "
      "peer's E2E pin sent after the E2E pin it replaced still wins (E19f)",
      () async {
        final msg = await fromBob('box pin', wire: 'wire-bob-0061');
        final t0 = nowMs().subtract(const Duration(minutes: 2));
        await bobDoes(action('pin', s: 2, w: 'wire-bob-0061', on: true, at: t0));

        conversations.onMessagePinned({
          'conversationId': 10,
          'pinnedMessageId': 900,
        });
        expect(conversations.boxPinOf(10)!.at, t0);

        // Newer than the register, older than this device's "now".
        await bobDoes(
          action('pin', s: 2, w: 'wire-bob-0061', on: true, at: t0.add(const Duration(minutes: 1))),
        );
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);
      },
    );

    test('an E2E action never lands on a server row (decision 46)', () async {
      // A server row whose record carries Bob's wire id (PR2.1 stamps both
      // paths): the E2E delete resolves to it, and must leave it alone.
      await encryption.store.saveDecryptedContent(
        77,
        // `senderId` too: without the local-id rule nothing else stops it.
        {'content': 'old path', 'senderId': 2},
        conversationId: 10,
        createdAt: DateTime.now().toUtc(),
        wire: (senderId: 2, wireId: 'wire-old-0001'),
      );
      expect(await bobDoes(action('del', s: 2, w: 'wire-old-0001')), isTrue);
      expect(await recordOf(77), isNotNull);

      // Nor is one parked for a server row that is still there: it is
      // never a box target (no tombstone stands in for this check).
      await encryption.store.saveDecryptedContent(
        78,
        {'content': 'old path too', 'senderId': 2},
        conversationId: 10,
        createdAt: DateTime.now().toUtc(),
        wire: (senderId: 2, wireId: 'wire-old-0002'),
      );
      await bobDoes(action('react', s: 2, w: 'wire-old-0002', emoji: '🔥', on: true));
      expect(
        await encryption.store.parkedBoxActions(10, (
          senderId: 2,
          wireId: 'wire-old-0002',
        )),
        isEmpty,
      );
      expect((await recordOf(78))?['reactions'], isNull);
    });
  });

  group('an action read before its target (E19k)', () {
    test(
      "a sibling's reaction read before the peer message it names lands "
      'once that message is stored, and is then dropped from the park',
      () async {
        await siblingDoes(
          action('react', s: 2, w: 'wire-bob-0100', emoji: '❤️', on: true, to: 2),
        );
        expect(provider.messages, isEmpty);

        final msg = await fromBob('late', wire: 'wire-bob-0100');
        expect(row(msg.id)!.reactions, {
          '❤️': [1],
        });
        expect((await recordOf(msg.id))?['reactions'], {
          '❤️': [1],
        });
        expect(
          await encryption.store.parkedBoxActions(10, (
            senderId: 2,
            wireId: 'wire-bob-0100',
          )),
          isEmpty,
        );
      },
    );

    test('several parked for one target apply in ts order', () async {
      final t0 = nowMs().subtract(const Duration(minutes: 5));
      final now = DateTime.now().toUtc();
      // Read in an order that is neither the ts order nor its reverse.
      for (final (i, emoji, second) in [(3, '😂', 2), (2, '🔥', 3), (1, '👍', 1)]) {
        await bobDoes(
          action('react', s: 2, w: 'wire-bob-0101', emoji: emoji, on: true, at: t0.add(Duration(seconds: second))),
          receivedAt: now.subtract(Duration(seconds: i)),
        );
      }
      final msg = await fromBob('all three', wire: 'wire-bob-0101', at: t0);
      expect(row(msg.id)!.reactions, {
        '🔥': [2],
      });
    });

    test(
      'two actions parked at once are both kept: the park is serialized '
      'in-process (the cross-context lock passes through off web)',
      () async {
        encryption.store.debugSetContentKv(
          _SlowWriteKv(await encryption.store.contentKv),
        );
        const wire = (senderId: 2, wireId: 'wire-bob-0110');
        final at = DateTime.now().toUtc();
        await Future.wait([
          encryption.store.parkBoxAction(10, wire, {'n': 1}, receivedAt: at),
          encryption.store.parkBoxAction(10, wire, {'n': 2}, receivedAt: at),
        ]);
        expect(
          [for (final a in await encryption.store.parkedBoxActions(10, wire)) a['n']],
          unorderedEquals([1, 2]),
        );
      },
    );

    test('at most 5 000 parked actions are kept: the oldest go first', () async {
      // A full park, one action per target, received a second apart.
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final kv = await encryption.store.contentKv;
      await kv.setString('e2e_1_boxact_v1', jsonEncode({
        for (var i = 0; i < 5000; i++)
          '10|2:wire-cap-$i': [
            {'n': i, 'r': now - (5000 - i) * 1000},
          ],
      }));
      const fresh = (senderId: 2, wireId: 'wire-cap-new');
      await encryption.store.parkBoxAction(
        10,
        fresh,
        {'n': -1},
        receivedAt: DateTime.now().toUtc(),
      );
      Future<int> count(String w) async =>
          (await encryption.store.parkedBoxActions(10, (senderId: 2, wireId: w))).length;
      expect(await count('wire-cap-new'), 1);
      expect(await count('wire-cap-0'), 0, reason: 'the oldest went');
      expect(await count('wire-cap-1'), 1);
      expect(await count('wire-cap-4999'), 1);
    });

    test(
      "a sibling's pin read before its target pins it when it lands; a "
      'parked pin older than the register loses (E19f)',
      () async {
        final t0 = nowMs().subtract(const Duration(minutes: 2));
        await siblingDoes(
          action('pin', s: 2, w: 'wire-bob-0102', on: true, at: t0, to: 2),
        );
        await bobDoes(
          action('pin', s: 2, w: 'wire-bob-0102', on: false, at: t0.add(const Duration(seconds: 10))),
        );
        await fromBob('unpinned since', wire: 'wire-bob-0102');
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);

        await siblingDoes(action('pin', s: 2, w: 'wire-bob-0103', on: true, to: 2));
        expect(conversations.getConversationById(10)!.pinnedMessageId, isNull);
        final msg = await fromBob('pin me', wire: 'wire-bob-0103');
        expect(conversations.getConversationById(10)!.pinnedMessageId, msg.id);
        expect(conversations.boxPinOf(10)!.pinned, isTrue);
      },
    );

    test(
      "the peer's reaction to OUR message, read before our sibling's copy "
      'of it, lands on that copy',
      () async {
        await bobDoes(action('react', s: 1, w: 'wire-mine-0104', emoji: '🔥', on: true));
        final copy = await fromSibling('from my phone', wire: 'wire-mine-0104');
        expect(copy.senderId, 1);
        expect(row(copy.id)!.reactions, {
          '🔥': [2],
        });
        expect((await recordOf(copy.id))?['reactions'], {
          '🔥': [2],
        });
      },
    );

    test(
      "a parked edit keeps the live rules: the target's sender only, text, "
      'within 15 minutes of its send, last writer wins on ts',
      () async {
        final sent = nowMs().subtract(const Duration(minutes: 10));
        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0105', content: 'third', at: sent.add(const Duration(minutes: 3))),
        );
        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0105', content: 'second', at: sent.add(const Duration(minutes: 2))),
        );
        // Our sibling cannot edit Bob's words, parked or not.
        await siblingDoes(
          action('edit', s: 2, w: 'wire-bob-0105', content: 'forged', at: sent.add(const Duration(minutes: 4)), to: 2),
        );
        final msg = await fromBob('first', wire: 'wire-bob-0105', at: sent);
        expect(row(msg.id)!.content, 'third');
        expect((await recordOf(msg.id))?['content'], 'third');

        final late = nowMs().subtract(const Duration(minutes: 20));
        await bobDoes(
          action('edit', s: 2, w: 'wire-bob-0106', content: 'too late', at: late.add(const Duration(minutes: 16))),
        );
        final old = await fromBob('late', wire: 'wire-bob-0106', at: late);
        expect(row(old.id)!.content, 'late');
        expect((await recordOf(old.id))?['content'], 'late');
      },
    );

    test(
      'a parked action survives a restart; one parked past 30 days expires',
      () async {
        await bobDoes(action('react', s: 2, w: 'wire-bob-0107', emoji: '👍', on: true));
        final now = DateTime.now().toUtc();
        await bobDoes(
          action('react', s: 2, w: 'wire-bob-0108', emoji: '👍', on: true),
          receivedAt: now.subtract(const Duration(days: 31)),
        );
        await bobDoes(
          action('react', s: 2, w: 'wire-bob-0109', emoji: '👍', on: true),
          receivedAt: now.subtract(const Duration(days: 29)),
        );

        await restart();

        final kept = await fromBob('kept', wire: 'wire-bob-0107');
        expect(row(kept.id)!.reactions, {
          '👍': [2],
        });
        final expired = await fromBob('expired', wire: 'wire-bob-0108');
        expect(row(expired.id)!.reactions, isEmpty);
        final aged = await fromBob('aged', wire: 'wire-bob-0109');
        expect(row(aged.id)!.reactions, {
          '👍': [2],
        });
      },
    );
  });
}
