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

/// One frame the box took: where, what, and how it is kept (E61a).
typedef _Sent = ({ContactOutbound to, BoxFrame frame, BoxSendMode? mode});

class _Outbox implements BoxOutbox {
  final Map<int, Map<int, ContactOutbound>> addresses = {};
  final Map<int, ContactOutbound> siblings = {};
  final List<_Sent> delivered = [];

  /// While set, the box refuses every `send`.
  bool refuseAll = false;
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
  Future<bool> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    delivered.add((to: to, frame: BoxFrame.decode(body)!, mode: mode));
    return !refuseAll;
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

const Map<String, dynamic> _bobConv = {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

const Map<String, dynamic> _carolConv = {
  'id': 11,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 3, 'username': 'carol', 'tag': '0003'},
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

String _wire(int n) => 'wire-bob-${n.toString().padLeft(4, '0')}';

/// Receipts and typing over the box (metadata-privacy slice (g), decisions
/// 61–62, E61a–E61f): Alice (user 1, device 1; sibling device 3) and Bob
/// (user 2, devices 1 and 2) in box chat 10.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late _Outbox outbox;
  late _Link link;
  late ContactStore store;
  late List<(String, Object?)> emitted;
  var switchOn = false;
  var nextLocal = kFirstLocalMessageId;

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setEmitCallback((event, data) => emitted.add((event, data)))
    ..boxOutbox = outbox
    ..boxSiblings = link
    ..receiptsAndTyping = (() => switchOn);

  ConversationsProvider newConversations() => ConversationsProvider()
    ..contactStore = store
    ..setCurrentUserId(1)
    ..setEmitCallback((event, data) => emitted.add((event, data)))
    ..onConversationsList([_bobConv, _carolConv])
    ..openConversation(10);

  Future<void> pump([int turns = 60]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> setUpWith() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    switchOn = false;
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
    conversations = newConversations();
    await store.settled;
    provider = newProvider()..refreshBoxDeviceLists();
    await pump();
  }

  setUp(setUpWith);

  List<String> events() => [for (final (e, _) in emitted) e];

  Map<String, dynamic> envelopeOf(_Sent sent) =>
      jsonDecode(utf8.decode(sent.frame.signal)) as Map<String, dynamic>;

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

  /// Bob's box message [text] under wire id [wire]; its local id.
  Future<int> fromBob(
    String text, {
    required String wire,
    int turns = 60,
  }) async {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(
        text,
        msgId: wire,
        sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
    );
    final e = entry();
    expect(await provider.consumeBoxEntry(e, _bob), isTrue);
    await pump(turns);
    return e.localId;
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

  /// A frame from Bob's device 1. True when it is finished with.
  Future<bool> bobDoes(Map<String, dynamic> envelope) async {
    encryption.inbound = jsonEncode(envelope);
    final done = await provider.consumeBoxEntry(entry(), _bob);
    await pump();
    return done;
  }

  /// A frame from our sibling device 3, on our self-queue.
  Future<bool> siblingDoes(Map<String, dynamic> envelope) async {
    encryption.inbound = jsonEncode(envelope);
    final done = await provider.consumeBoxEntry(
      entry(peer: 1, device: 3, viaSelf: true),
      null,
    );
    await pump();
    return done;
  }

  Map<String, dynamic> receipt(E2eReceiptKind kind, List<String> wires) =>
      E2eEnvelope.buildReceipt(kind, wires);

  Map<String, dynamic> typing(E2eTypingKind kind, {required bool on}) =>
      E2eEnvelope.buildTyping(kind, on: on);

  MessageModel? row(int id) =>
      provider.messages.where((m) => m.id == id).firstOrNull;

  /// A fresh app on the same disk.
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

  /// Shows Carol's chat instead of Bob's: nothing of Bob's is read here.
  void showCarol() {
    conversations.openConversation(11);
    provider.setActiveConversationIdForTest(11);
  }

  /// Every frame handed to the box went to one of Bob's devices, [mode].
  void expectPeerFramesOnly(BoxSendMode mode) {
    expect(outbox.delivered, isNotEmpty);
    for (final sent in outbox.delivered) {
      expect(sent.to.sid, startsWith('sid-'), reason: 'never a sent copy');
      expect(sent.mode, mode);
    }
  }

  /// [body] with the whole setup rebuilt in fake time: a future made in
  /// the real zone never completes inside `fakeAsync`.
  void inFakeTime(void Function(FakeAsync clock) body) => fakeAsync((clock) {
    var ready = false;
    unawaited(setUpWith().then((_) => ready = true));
    clock.elapse(const Duration(seconds: 1));
    expect(ready, isTrue);
    switchOn = true;
    body(clock);
  });

  /// Runs [step] to completion in fake time, [taking] that long.
  void settle(
    FakeAsync clock,
    Future<Object?> Function() step, {
    Duration taking = const Duration(milliseconds: 50),
  }) {
    var done = false;
    unawaited(step().then((_) => done = true));
    clock.elapse(taking);
    expect(done, isTrue);
  }

  group('with the switch OFF (E61c)', () {
    test('nothing is sent and every rcpt and typ received is ignored', () async {
      await fromBob('hi', wire: _wire(1));
      provider
        ..onBoxReadsIdle()
        ..markConversationRead(10)
        ..emitTyping()
        ..sendRecordingVoiceIndicator(2, 10, isRecording: true);
      await pump();
      expect(outbox.delivered, isEmpty);
      expect(events(), isNot(anyOf(contains('typing'), contains('recordingVoice'))));

      final own = await mine('yo');
      expect(await bobDoes(receipt(E2eReceiptKind.read, [own.wireId!])), isTrue);
      expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.sent);
      expect(await bobDoes(typing(E2eTypingKind.text, on: true)), isTrue);
      expect(await bobDoes(typing(E2eTypingKind.voice, on: true)), isTrue);
      expect(provider.isPartnerTyping(10), isFalse);
      expect(provider.isPartnerRecordingVoice(10), isFalse);
    });
  });

  group('delivered (E61d)', () {
    setUp(() {
      switchOn = true;
      showCarol();
    });

    test(
      "one quiet rcpt d per drain to each of Bob's live devices, batching "
      'his box messages this device took; each wire id reported once',
      () async {
        for (final n in [1, 2, 3]) {
          await fromBob('m$n', wire: _wire(n));
        }
        expect(outbox.delivered, isEmpty, reason: 'not before the drain ends');

        provider.onBoxReadsIdle();
        await pump();
        expectPeerFramesOnly(BoxSendMode.quiet);
        expect(
          outbox.delivered.map((s) => s.to.sid),
          unorderedEquals(['sid-1', 'sid-2']),
        );
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent), {
            't': 'rcpt',
            'k': 'd',
            'w': [_wire(1), _wire(2), _wire(3)],
          });
        }

        outbox.delivered.clear();
        provider.onBoxReadsIdle();
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'nothing new was taken');

        await fromBob('m4', wire: _wire(4));
        provider.onBoxReadsIdle();
        await pump();
        expect(outbox.delivered, hasLength(2));
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent)['w'], [_wire(4)]);
        }
      },
    );

    test('101 taken in one drain go as frames of 100 and 1', () async {
      for (var n = 1; n <= 101; n++) {
        await fromBob('m$n', wire: _wire(n), turns: 15);
      }
      provider.onBoxReadsIdle();
      await pump();
      expect(outbox.delivered, hasLength(4));
      final byDevice = <String, List<int>>{};
      for (final sent in outbox.delivered) {
        (byDevice[sent.to.sid] ??= []).add(
          (envelopeOf(sent)['w'] as List).length,
        );
      }
      expect(byDevice['sid-1'], unorderedEquals([100, 1]));
      expect(byDevice['sid-2'], unorderedEquals([100, 1]));
    });
  });

  group('read (E61d)', () {
    setUp(() => switchOn = true);

    test(
      "showing Bob's chat sends one quiet rcpt r naming his box messages not "
      'yet reported read; a later drain sends no d for them',
      () async {
        final own = await mine('mine, never named');
        await fromBob('m1', wire: _wire(1));
        expectPeerFramesOnly(BoxSendMode.quiet);
        expect(
          outbox.delivered.map((s) => s.to.sid),
          unorderedEquals(['sid-1', 'sid-2']),
        );
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent), {
            't': 'rcpt',
            'k': 'r',
            'w': [_wire(1)],
          });
        }

        outbox.delivered.clear();
        provider.markConversationRead(10);
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'already reported read');

        await fromBob('m2', wire: _wire(2));
        expect(outbox.delivered, hasLength(2));
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent)['w'], [_wire(2)]);
          expect(envelopeOf(sent)['w'], isNot(contains(own.wireId)));
        }

        outbox.delivered.clear();
        provider.onBoxReadsIdle();
        await pump();
        expect(outbox.delivered, isEmpty, reason: 'read already said it');
      },
    );

    test(
      "Bob's messages stored while his chat was not shown are reported read "
      'when it opens after a restart (the stored rows merge in last)',
      () async {
        showCarol();
        await fromBob('m1', wire: _wire(1));
        expect(outbox.delivered, isEmpty);

        await restart();
        expectPeerFramesOnly(BoxSendMode.quiet);
        expect(outbox.delivered, hasLength(2));
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent), {
            't': 'rcpt',
            'k': 'r',
            'w': [_wire(1)],
          });
        }
      },
    );

    test(
      'a message reported read comes back read after a restart, and its '
      'receipt is never sent again',
      () async {
        final bobs = await fromBob('m1', wire: _wire(1));
        expect(outbox.delivered, hasLength(2));
        expect(row(bobs)!.deliveryStatus, MessageDeliveryStatus.read);

        outbox.delivered.clear();
        await restart();
        expect(row(bobs)!.deliveryStatus, MessageDeliveryStatus.read);
        provider.markConversationRead(10);
        await pump();
        expect(outbox.delivered, isEmpty);
      },
    );

    test(
      'a read receipt no device took leaves the message unreported, and the '
      'next time the chat is shown it is sent again',
      () async {
        outbox.refuseAll = true;
        final bobs = await fromBob('m1', wire: _wire(1));
        expect(outbox.delivered, hasLength(2));
        expect(row(bobs)!.deliveryStatus, MessageDeliveryStatus.delivered);

        outbox
          ..refuseAll = false
          ..delivered.clear();
        provider.markConversationRead(10);
        await pump();
        expect(outbox.delivered, hasLength(2));
        for (final sent in outbox.delivered) {
          expect(envelopeOf(sent), {
            't': 'rcpt',
            'k': 'r',
            'w': [_wire(1)],
          });
        }
        expect(row(bobs)!.deliveryStatus, MessageDeliveryStatus.read);
      },
    );
  });

  group('typing sent (E61e)', () {
    test(
      "typing goes live to each of Bob's devices at most once per 5 s per "
      'chat, and never on the account socket',
      () {
        inFakeTime((clock) {
          provider.emitTyping();
          clock.elapse(const Duration(milliseconds: 100));
          expectPeerFramesOnly(BoxSendMode.live);
          expect(outbox.delivered, hasLength(2));
          for (final sent in outbox.delivered) {
            expect(envelopeOf(sent), {'t': 'typ', 'k': 't', 'on': true});
          }

          outbox.delivered.clear();
          clock.elapse(const Duration(seconds: 1));
          provider.emitTyping();
          clock.elapse(const Duration(seconds: 3));
          provider.emitTyping();
          clock.elapse(const Duration(milliseconds: 100));
          expect(outbox.delivered, isEmpty, reason: 'inside 5 s');

          clock.elapse(const Duration(milliseconds: 900));
          provider.emitTyping();
          clock.elapse(const Duration(milliseconds: 100));
          expect(outbox.delivered, hasLength(2), reason: '5 s after the first');
          expect(events(), isNot(contains('typing')));
        });
      },
    );

    test('the voice indicator goes live on each recording change', () {
      inFakeTime((clock) {
        for (final on in [true, false, true]) {
          provider.sendRecordingVoiceIndicator(2, 10, isRecording: on);
          clock.elapse(const Duration(milliseconds: 100));
        }
        expectPeerFramesOnly(BoxSendMode.live);
        expect(
          [for (final sent in outbox.delivered) envelopeOf(sent)],
          [
            for (final on in [true, false, true])
              for (var i = 0; i < 2; i++) {'t': 'typ', 'k': 'v', 'on': on},
          ],
        );
        expect(events(), isNot(contains('recordingVoice')));
      });
    });

    test(
      'while recording, voice on goes again every 5 s; off stops it',
      () {
        inFakeTime((clock) {
          List<bool> ons() => [
            for (final sent in outbox.delivered)
              envelopeOf(sent)['on'] as bool,
          ];
          provider.sendRecordingVoiceIndicator(2, 10, isRecording: true);
          clock.elapse(const Duration(milliseconds: 100));
          expect(ons(), [true, true]);
          clock.elapse(const Duration(seconds: 5));
          expect(ons(), [true, true, true, true]);
          clock.elapse(const Duration(seconds: 5));
          expect(ons(), hasLength(6));

          outbox.delivered.clear();
          provider.sendRecordingVoiceIndicator(2, 10, isRecording: false);
          clock.elapse(const Duration(seconds: 20));
          expect(ons(), [false, false]);
        });
      },
    );
  });

  group('rcpt received (E61f)', () {
    setUp(() => switchOn = true);

    test(
      'moves our own box message forward only — a d after r never '
      'downgrades — and the step survives a restart',
      () async {
        final own = await mine('hello');
        expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.sent);

        await bobDoes(receipt(E2eReceiptKind.delivered, [own.wireId!]));
        expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.delivered);
        await bobDoes(receipt(E2eReceiptKind.read, [own.wireId!]));
        expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.read);
        await bobDoes(receipt(E2eReceiptKind.delivered, [own.wireId!]));
        expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.read);

        await restart();
        expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.read);
      },
    );

    test('a delivered tick is kept across a restart too', () async {
      final own = await mine('hello');
      await bobDoes(receipt(E2eReceiptKind.delivered, [own.wireId!]));
      await restart();
      expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.delivered);
    });

    test(
      'a receipt naming a message we do not hold, or one Bob sent, changes '
      'nothing and is finished',
      () async {
        final own = await mine('ours');
        showCarol();
        final bobs = await fromBob('his', wire: _wire(1));
        expect(
          await bobDoes(
            receipt(E2eReceiptKind.read, [_wire(1), 'wire-unknown-01']),
          ),
          isTrue,
        );
        for (final id in [bobs, own.id]) {
          final record = await encryption.store.getDecryptedContent(id);
          expect(record, containsPair('senderId', anything));
          expect(record, isNot(containsPair('tick', anything)));
        }
      },
    );
  });

  group('typ received (E61e)', () {
    test('text typing shows until 6 s after the last frame', () {
      inFakeTime((clock) {
        settle(clock, () => bobDoes(typing(E2eTypingKind.text, on: true)));
        expect(provider.isPartnerTyping(10), isTrue);
        clock.elapse(const Duration(seconds: 5));
        settle(clock, () => bobDoes(typing(E2eTypingKind.text, on: true)));
        clock.elapse(const Duration(milliseconds: 5800));
        expect(provider.isPartnerTyping(10), isTrue, reason: 'renewed');
        clock.elapse(const Duration(milliseconds: 300));
        expect(provider.isPartnerTyping(10), isFalse);
      });
    });


    test(
      'voice shows until 12 s after the last on, with no off needed',
      () {
        inFakeTime((clock) {
          settle(clock, () => bobDoes(typing(E2eTypingKind.voice, on: true)));
          clock.elapse(const Duration(seconds: 10));
          settle(clock, () => bobDoes(typing(E2eTypingKind.voice, on: true)));
          clock.elapse(const Duration(milliseconds: 11800));
          expect(provider.isPartnerRecordingVoice(10), isTrue, reason: 'renewed');
          clock.elapse(const Duration(milliseconds: 300));
          expect(provider.isPartnerRecordingVoice(10), isFalse);
        });
      },
    );

    test(
      'voice shows from on to off, and any message from Bob clears both',
      () async {
        switchOn = true;
        await bobDoes(typing(E2eTypingKind.voice, on: true));
        expect(provider.isPartnerRecordingVoice(10), isTrue);
        await bobDoes(typing(E2eTypingKind.voice, on: false));
        expect(provider.isPartnerRecordingVoice(10), isFalse);

        await bobDoes(typing(E2eTypingKind.text, on: true));
        await bobDoes(typing(E2eTypingKind.voice, on: true));
        expect(provider.isPartnerTyping(10), isTrue);
        await fromBob('here', wire: _wire(1));
        expect(provider.isPartnerTyping(10), isFalse);
        expect(provider.isPartnerRecordingVoice(10), isFalse);
      },
    );
  });

  group('dropped', () {
    setUp(() => switchOn = true);

    test('a malformed rcpt or typ is dropped whole and finished', () async {
      final own = await mine('hello');
      expect(
        await bobDoes({
          't': 'rcpt',
          'k': 'r',
          'w': [own.wireId, 'bad'],
        }),
        isTrue,
      );
      expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.sent);
      expect(
        await bobDoes({'t': 'typ', 'k': 't', 'on': 'yes'}),
        isTrue,
      );
      expect(provider.isPartnerTyping(10), isFalse);
    });

    test('a sibling self-queue copy of rcpt or typ is dropped', () async {
      final own = await mine('hello');
      expect(
        await siblingDoes({
          ...receipt(E2eReceiptKind.read, [own.wireId!]),
          'to': 2,
        }),
        isTrue,
      );
      expect(row(own.id)!.deliveryStatus, MessageDeliveryStatus.sent);
      expect(
        await siblingDoes({...typing(E2eTypingKind.text, on: true), 'to': 2}),
        isTrue,
      );
      expect(provider.isPartnerTyping(10), isFalse);
    });
  });
}
