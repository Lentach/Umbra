import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_expiry.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart'
    show DuplicateMessageException, NoSessionException;
import 'package:shared_preferences/shared_preferences.dart';

/// The real store behind [EncryptionProvider]; only Signal and the device
/// list round trip are faked.
class _BoxEncryption extends EncryptionProvider {
  _BoxEncryption(this.store) : super(service: store);

  final EncryptionService store;

  /// What the next decrypt answers, or throws.
  Object inbound = jsonEncode(E2eEnvelope.build('hello'));
  final List<int?> decryptedIds = [];

  /// Plaintext writes that silently do not commit (quota, a locked vault):
  /// the save path reports nothing either way.
  bool dropSaves = false;

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
    if (dropSaves) return;
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

  bool e2eReady = true;

  @override
  bool get isE2EReady => e2eReady;

  @override
  bool get hadIdentityReset => false;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => null;

  /// No list reachable: device 1 decrypts, a device >= 2 is withheld (§12 (e)).
  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
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
    final answer = inbound;
    if (answer is Exception) throw answer;
    return answer as String;
  }
}

Map<String, dynamic> _conv(int id, int peerId, String peerName) => {
  'id': id,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': peerId, 'username': peerName, 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'disappearingTimer': null,
  'unreadCount': 0,
  'lastMessage': null,
};

ContactRecord _peer(
  int userId, {
  int? conversationId,
  ContactState state = ContactState.friend,
}) => ContactRecord(
  userId: userId,
  username: 'peer$userId',
  tag: '0002',
  state: state,
  legacy: ContactLegacy(conversationId: conversationId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _BoxEncryption encryption;
  late List<String> emitted;
  var nextLocal = kFirstLocalMessageId;

  final receivedAt = DateTime.utc(2026, 9, 24, 12);

  MessagingProvider newProvider() => MessagingProvider()
    ..setConversationsProvider(conversations)
    ..setEncryptionProvider(encryption)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setActiveConversationIdForTest(10)
    ..setEmitCallback((event, data) => emitted.add(event));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _BoxEncryption(service);
    conversations = ConversationsProvider()
      ..setCurrentUserId(1)
      ..onConversationsList([_conv(10, 2, 'bob'), _conv(11, 3, 'carol')])
      ..openConversation(10);
    emitted = [];
    provider = newProvider();
  });

  Future<void> pump([int turns = 40]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  BoxInboxEntry entry({int peer = 2, int device = 1}) => BoxInboxEntry(
    rid: 'rid',
    id: 'm${nextLocal - kFirstLocalMessageId}',
    localId: nextLocal++,
    peerUserId: peer,
    senderDeviceId: device,
    signal: '2:AQID',
    receivedAt: receivedAt,
    acked: true,
  );

  void envelope(String text, {DateTime? sentAt, String? msgId, String? type}) {
    encryption.inbound = jsonEncode(
      E2eEnvelope.build(text, sentAt: sentAt, msgId: msgId, type: type),
    );
  }

  Future<bool> deliver(BoxInboxEntry e, ContactRecord? peer) async {
    final done = provider.consumeBoxEntry(e, peer);
    await pump();
    return done;
  }

  test(
    'a box message for the chat on screen is decrypted, stored under its '
    'local id, shown and sounded — and never named to the server',
    () async {
      final sentAt = receivedAt.subtract(const Duration(minutes: 5));
      envelope('hi from the box', sentAt: sentAt, msgId: 'wire-0000001');
      final e = entry();
      // What the real decrypt leaves behind: the replay row for this id.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'e2e_1_decrypt_raw_v1_${e.localId}',
        '{"ciphertext":"2:AQID","plaintext":"x"}',
      );

      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);

      final shown = provider.messages.singleWhere((m) => m.id == e.localId);
      expect(shown.content, 'hi from the box');
      expect(shown.senderId, 2);
      expect(shown.createdAt, sentAt, reason: "the sender's clock");
      expect(encryption.decryptedIds, [e.localId], reason: 'replay-cache key');
      final record = await encryption.store.getDecryptedContent(e.localId);
      expect(record?['content'], 'hi from the box');
      expect(
        await encryption.store.rawReplayExists(e.localId),
        isFalse,
        reason: 'the record answers now; the replay row would crowd the cache',
      );
      expect(provider.incomingSoundRequestsForTest, 1);
      expect(emitted, isNot(contains('messageDelivered')));
    },
  );

  test(
    'a box message for a chat NOT on screen plays no sound: badge only '
    '(owner decision 11)',
    () async {
      envelope('psst');
      final e = entry(peer: 3);

      expect(await deliver(e, _peer(3, conversationId: 11)), isTrue);

      expect(provider.incomingSoundRequestsForTest, 0);
      expect(conversations.unreadCounts[11], 1);
      expect(conversations.lastMessages[11]?.id, e.localId);
      expect(provider.messages.where((m) => m.id == e.localId), isEmpty);
    },
  );

  test('a sender clock in the future is clamped to our receive time', () async {
    envelope('from tomorrow', sentAt: receivedAt.add(const Duration(days: 1)));
    final e = entry();
    await deliver(e, _peer(2, conversationId: 10));
    expect(
      provider.messages.singleWhere((m) => m.id == e.localId).createdAt,
      receivedAt,
    );
  });

  test(
    'a message this device already holds (same sender, same wire id) is '
    'finished with, not shown twice',
    () async {
      await encryption.store.saveDecryptedContent(
        500,
        {'content': 'hi'},
        conversationId: 10,
        wire: (senderId: 2, wireId: 'wire-0000009'),
      );
      envelope('hi', msgId: 'wire-0000009');
      final e = entry();

      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
      expect(provider.messages.where((m) => m.id == e.localId), isEmpty);
      expect(await encryption.store.getDecryptedContent(e.localId), isNull);
    },
  );

  test(
    'a sender device that cannot be verified yet is offered again later — '
    'nothing decrypted, nothing shown',
    () async {
      final e = entry(device: 2);
      expect(await deliver(e, _peer(2, conversationId: 10)), isFalse);
      expect(encryption.decryptedIds, isEmpty);
      expect(provider.messages, isEmpty);
    },
  );

  test(
    'no session yet: the peer is asked (once) to re-key, and the delivery '
    'waits to be offered again; a spent key is finished with',
    () async {
      encryption.inbound = NoSessionException('no session');
      expect(await deliver(entry(), _peer(2, conversationId: 10)), isFalse);
      expect(await deliver(entry(), _peer(2, conversationId: 10)), isFalse);
      expect(emitted.where((e) => e == 'requestSessionRebuild'), hasLength(1));

      encryption.inbound = DuplicateMessageException('spent');
      expect(await deliver(entry(), _peer(2, conversationId: 10)), isTrue);
      expect(provider.messages, isEmpty, reason: 'a duplicate shows nothing');
    },
  );

  test(
    'a Bad-MAC box message asks the peer to re-key once, and its loss is '
    'shown rather than silently dropped',
    () async {
      encryption.inbound = Exception('Bad Mac!');
      final e = entry();
      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
      expect(await deliver(entry(), _peer(2, conversationId: 10)), isTrue);
      expect(emitted.where((x) => x == 'requestSessionRebuild'), hasLength(1));
      expect(
        provider.messages.singleWhere((m) => m.id == e.localId).content,
        kDecryptionFailedLabel,
      );
    },
  );

  test(
    'E2E not ready: the delivery is handed back at once (the E2E-ready drain '
    'offers it again) — no wait that would hold later reads',
    () async {
      encryption.e2eReady = false;
      final watch = Stopwatch()..start();
      expect(await deliver(entry(), _peer(2, conversationId: 10)), isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(encryption.decryptedIds, isEmpty);
    },
  );

  test(
    'an envelope type this build does not know is dropped — and its '
    'plaintext replay row with it',
    () async {
      envelope('?', type: 'from_the_future');
      final e = entry();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'e2e_1_decrypt_raw_v1_${e.localId}',
        '{"ciphertext":"2:AQID","plaintext":"x"}',
      );
      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
      expect(provider.messages, isEmpty);
      expect(await encryption.store.rawReplayExists(e.localId), isFalse);
    },
  );

  test(
    'a box message with no session yet is kept, and decrypts once the '
    "session exists (the peer's PreKey message may still be on the old path)",
    () async {
      final e = entry();
      encryption.inbound = NoSessionException('no session');
      expect(await deliver(e, _peer(2, conversationId: 10)), isFalse);
      expect(provider.messages, isEmpty);

      envelope('arrived before its session');
      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
      expect(
        provider.messages.singleWhere((m) => m.id == e.localId).content,
        'arrived before its session',
      );
    },
  );

  test('a blocked peer, or one with no chat, gets nothing shown', () async {
    envelope('hi');
    expect(
      await deliver(
        entry(),
        _peer(2, conversationId: 10, state: ContactState.blocked),
      ),
      isTrue,
    );
    expect(await deliver(entry(), _peer(2)), isTrue);
    expect(await deliver(entry(), null), isTrue);
    expect(encryption.decryptedIds, isEmpty);
    expect(provider.messages, isEmpty);
  });

  test(
    'after a restart the box message is back when its chat opens — no '
    'server page will ever name it',
    () async {
      envelope('kept', msgId: 'wire-0000002');
      final e = entry();
      await deliver(e, _peer(2, conversationId: 10));

      provider.dispose();
      provider = newProvider();
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': <Object>[],
      });
      await pump(80);

      final back = provider.messages.singleWhere((m) => m.id == e.localId);
      expect(back.content, 'kept');
      expect(back.senderId, 2);
      expect(back.senderUsername, 'bob');
      expect(back.wireId, 'wire-0000002');
    },
  );

  test(
    'server actions never name a box message; delete-for-me removes it here',
    () async {
      envelope('local only');
      final e = entry();
      await deliver(e, _peer(2, conversationId: 10));
      emitted.clear();

      provider
        ..pinMessage(10, e.localId)
        ..deleteMessage(e.localId, forEveryone: true);
      expect(await provider.addReaction(e.localId, '👍'), isFalse);
      expect(emitted, isEmpty);
      expect(provider.messages.where((m) => m.id == e.localId), hasLength(1));

      provider.deleteMessage(e.localId, forEveryone: false);
      await pump();
      expect(emitted, isEmpty);
      expect(provider.messages.where((m) => m.id == e.localId), isEmpty);
      expect(await encryption.store.getDecryptedContent(e.localId), isNull);
    },
  );

  /// An unsaved row for peer 2 / chat 10 under [localId], then [then].
  Future<void> unsavedThen(int localId, Future<void> Function() then) async {
    envelope('from before');
    encryption.dropSaves = true;
    await deliver(
      BoxInboxEntry(
        rid: 'rid-a',
        id: 'first',
        localId: localId,
        peerUserId: 2,
        senderDeviceId: 1,
        signal: '2:AQID',
        receivedAt: receivedAt,
        acked: true,
      ),
      _peer(2, conversationId: 10),
    );
    encryption.dropSaves = false;
    envelope('this one');
    await then();
  }

  BoxInboxEntry sameId(int localId, int peer) => BoxInboxEntry(
    rid: 'rid-b',
    id: 'second',
    localId: localId,
    peerUserId: peer,
    senderDeviceId: 1,
    signal: '2:AQID',
    receivedAt: receivedAt,
    acked: true,
  );

  test(
    "a fresh connect (a user switch) drops the previous session's unsaved "
    'rows: the same local id, even from the same peer and chat, stores its '
    'own content',
    () async {
      final id = entry().localId;
      await unsavedThen(id, () async {
        provider.onConnect(false);
        expect(await deliver(sameId(id, 2), _peer(2, conversationId: 10)), isTrue);
      });
      final record = await encryption.store.getDecryptedContent(id);
      expect(record?['content'], 'this one');
    },
  );

  test(
    'an unsaved row is only ever stored for its own sender and chat',
    () async {
      final id = entry().localId;
      await unsavedThen(id, () async {
        expect(await deliver(sameId(id, 3), _peer(3, conversationId: 11)), isTrue);
      });
      final record = await encryption.store.getDecryptedContent(id);
      expect(record?['content'], 'this one');
    },
  );

  test(
    'a plaintext write that does not commit keeps the entry in the journal; '
    'the message is shown once, and the next offer only stores it',
    () async {
      envelope('keep me', msgId: 'wire-0000003');
      final e = entry();
      encryption.dropSaves = true;
      expect(await deliver(e, _peer(2, conversationId: 10)), isFalse);
      expect(provider.messages.where((m) => m.id == e.localId), hasLength(1));
      expect(await encryption.store.getDecryptedContent(e.localId), isNull);

      encryption.dropSaves = false;
      expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
      expect(encryption.decryptedIds, [e.localId], reason: 'never twice');
      expect(provider.messages.where((m) => m.id == e.localId), hasLength(1));
      expect(provider.incomingSoundRequestsForTest, 1);
      final record = await encryption.store.getDecryptedContent(e.localId);
      expect(record?['content'], 'keep me');
    },
  );

  test('an entry offered again after it was stored is not read twice', () async {
    envelope('once');
    final e = entry();
    await deliver(e, _peer(2, conversationId: 10));
    expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
    expect(encryption.decryptedIds, [e.localId]);
    expect(provider.messages.where((m) => m.id == e.localId), hasLength(1));
    expect(provider.incomingSoundRequestsForTest, 1);
  });

  test(
    'delete-for-me on an unsent row (a temp id) keeps its old path: the '
    'send it belongs to is not touched here',
    () async {
      provider.deleteMessage(-3, forEveryone: false);
      await pump();
      expect(emitted, ['deleteMessage']);
    },
  );

  group('item 3: replies, timers and pings over the box', () {
    const wire = 'wire-orig-0001';

    void inbound({
      String text = 'x',
      String messageType = 'TEXT',
      String? msgId,
      int? ttl,
      E2eReplyQuote? quote,
      DateTime? sentAt,
    }) => encryption.inbound = jsonEncode(
      E2eEnvelope.build(
        text,
        messageType: messageType,
        msgId: msgId,
        ttl: ttl,
        replyQuote: quote,
        sentAt: sentAt,
      ),
    );

    /// Received NOW: a timer's 1-day unread cap runs on the real clock.
    Future<MessageModel> receive({int peer = 2, int conversationId = 10}) async {
      final e = BoxInboxEntry(
        rid: 'rid',
        id: 'm${nextLocal - kFirstLocalMessageId}',
        localId: nextLocal++,
        peerUserId: peer,
        senderDeviceId: 1,
        signal: '2:AQID',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );
      expect(await deliver(e, _peer(peer, conversationId: conversationId)), isTrue);
      return provider.messages.singleWhere((m) => m.id == e.localId);
    }

    Future<void> restart() async {
      provider.dispose();
      provider = newProvider();
      await provider.onMessageHistory({
        'conversationId': 10,
        'messages': <Object>[],
      });
      await pump(80);
    }

    test(
      'a reply shows OUR copy of the quoted message when this device holds '
      "that sender's wire id — in the open chat or only on disk — and the "
      'snippet otherwise; a restart keeps it (E18a)',
      () async {
        inbound(text: 'the original', msgId: wire);
        final original = await receive();
        inbound(
          text: 'reply',
          quote: (wireId: wire, senderId: 2, type: 'TEXT', snippet: 'forged'),
        );
        final reply = await receive();
        expect(reply.replyTo?.id, original.id);
        expect(reply.replyTo?.senderId, 2);
        expect(reply.replyTo?.wireId, wire);
        expect(reply.replyTo?.senderUsername, 'bob');

        await encryption.store.saveDecryptedContent(
          500,
          {'content': 'mine, on disk only'},
          conversationId: 10,
          wire: (senderId: 1, wireId: 'wire-mine-0001'),
        );
        inbound(
          text: 'about yours',
          quote: (
            wireId: 'wire-mine-0001',
            senderId: 1,
            type: 'TEXT',
            snippet: 'mine',
          ),
        );
        final aboutMine = await receive();
        expect(aboutMine.replyTo?.id, 500);
        expect(aboutMine.replyTo?.senderUsername, 'alice');

        inbound(
          text: 'about something gone',
          quote: (
            wireId: 'wire-none-0001',
            senderId: 2,
            type: 'TEXT',
            snippet: 'what I said',
          ),
        );
        final unheld = await receive();
        expect(unheld.replyTo?.id, 0);
        expect(unheld.replyTo?.content, 'what I said');

        await restart();
        final back = provider.messages.singleWhere((m) => m.id == reply.id);
        expect(back.replyTo?.id, original.id);
        expect(back.replyTo?.wireId, wire);
        expect(back.replyTo?.senderId, 2);
        expect(
          provider.messages.singleWhere((m) => m.id == unheld.id).replyTo?.content,
          'what I said',
        );
      },
    );

    test(
      'a quote names a message by sender AND wire id: the same wire id from '
      'another sender, or a message of another chat, is never its quote',
      () async {
        await encryption.store.saveDecryptedContent(
          500,
          {'content': 'ours, same wire id'},
          conversationId: 10,
          wire: (senderId: 1, wireId: wire),
        );
        await encryption.store.saveDecryptedContent(
          501,
          {'content': "carol's"},
          conversationId: 11,
          wire: (senderId: 3, wireId: 'wire-carol-001'),
        );
        inbound(
          text: 'reply',
          quote: (wireId: wire, senderId: 2, type: 'TEXT', snippet: 'bob said'),
        );
        final reply = await receive();
        expect(reply.replyTo?.id, 0);
        expect(reply.replyTo?.content, 'bob said');

        inbound(
          text: 'reply',
          quote: (
            wireId: 'wire-carol-001',
            senderId: 3,
            type: 'TEXT',
            snippet: 'x',
          ),
        );
        expect((await receive()).replyTo?.id, 0);
      },
    );

    test(
      "a received message's timer starts only when it is SHOWN: until then "
      'no deadline and a record stamped with the 1-day unread cap from its '
      'SEND — a device offline for hours gets no fresh day; shown, it goes '
      'at now + its timer, once — a second show never restarts it (E18b, '
      'decision 41)',
      () async {
        conversations.setClientVisible(false);
        final sentAt = DateTime.now().toUtc().subtract(
          const Duration(hours: 20),
        );
        inbound(text: 'vanishing', ttl: 60, sentAt: sentAt);
        final row = await receive();

        expect(row.createdAt.millisecondsSinceEpoch, sentAt.millisecondsSinceEpoch);
        expect(row.disappearAfterSeconds, 60);
        expect(row.expiresAt, isNull, reason: 'in a hidden app: not shown');
        final unread = await encryption.store.getDecryptedContent(row.id);
        expect(
          unread?['_expiresAt'],
          sentAt.add(const Duration(days: 1)).millisecondsSinceEpoch,
          reason: 'the send + 1 day, never the arrival + 1 day',
        );
        expect(unread, isNot(contains('ttlFrom')));

        conversations.setClientVisible(true);
        final before = DateTime.now();
        provider.markConversationRead(10);
        final after = DateTime.now();
        await pump();

        final shown = provider.messages.singleWhere((m) => m.id == row.id);
        final deadline = shown.expiresAt!;
        expect(
          deadline.millisecondsSinceEpoch,
          inInclusiveRange(
            before.millisecondsSinceEpoch + 60000,
            after.millisecondsSinceEpoch + 60000,
          ),
        );
        final started = await encryption.store.getDecryptedContent(row.id);
        expect(started?['_expiresAt'], deadline.millisecondsSinceEpoch);
        expect(started?['ttlFrom'], deadline.millisecondsSinceEpoch - 60000);

        await Future<void>.delayed(const Duration(milliseconds: 5));
        provider.markConversationRead(10);
        await pump();
        expect(
          provider.messages.singleWhere((m) => m.id == row.id).expiresAt,
          deadline,
        );
        final again = await encryption.store.getDecryptedContent(row.id);
        expect(again?['_expiresAt'], deadline.millisecondsSinceEpoch);
      },
    );

    test(
      'an unread box message is destroyable only past its send + 1 day, by '
      'its own stamp; an old-path record with no server stamp never is by '
      'expiry (decision 41, `_recordExpiryDeadlineMs`)',
      () async {
        conversations.setClientVisible(false);
        final sentAt = DateTime.now().toUtc().subtract(
          const Duration(hours: 20),
        );
        inbound(text: 'unread', ttl: 60, sentAt: sentAt);
        final row = await receive();
        await encryption.store.saveDecryptedContent(
          700,
          {'content': 'old path, read-mode'},
          conversationId: 10,
          createdAt: sentAt,
          disappearAfterSeconds: 60,
        );

        Future<Set<int>> expiredAt(DateTime serverNow) async =>
            (await encryption.store.destroyableMessageIds(
              serverNow: serverNow,
              expiryGrace: kExpiryPurgeGrace,
            )).expired;

        final cap = sentAt.add(const Duration(days: 1));
        expect(await expiredAt(DateTime.now().toUtc()), isEmpty);
        expect(
          await expiredAt(cap.add(kExpiryPurgeGrace)),
          isEmpty,
          reason: 'not before the cap and its grace',
        );
        expect(
          await expiredAt(
            cap.add(kExpiryPurgeGrace).add(const Duration(seconds: 1)),
          ),
          {row.id},
          reason: 'the old-path record has no stamp: never by expiry',
        );
      },
    );

    test(
      'a message arriving in the chat on screen starts counting at once',
      () async {
        inbound(text: 'seen', ttl: 30);
        final before = DateTime.now();
        final row = await receive();
        expect(row.expiresAt, isNotNull);
        expect(
          row.expiresAt!.millisecondsSinceEpoch,
          greaterThanOrEqualTo(before.millisecondsSinceEpoch + 30000),
        );
      },
    );

    test(
      'a restart keeps an unstarted countdown unstarted and a started one at '
      'the deadline it started with — never restarted',
      () async {
        conversations.setClientVisible(false);
        inbound(text: 'unread one', ttl: 60);
        final unread = await receive();
        await restart();
        final stillUnread = provider.messages.singleWhere(
          (m) => m.id == unread.id,
        );
        expect(stillUnread.disappearAfterSeconds, 60);
        expect(stillUnread.expiresAt, isNull);

        conversations.setClientVisible(true);
        provider.markConversationRead(10);
        await pump();
        final deadline = provider.messages
            .singleWhere((m) => m.id == unread.id)
            .expiresAt;
        expect(deadline, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await restart();
        final back = provider.messages.singleWhere((m) => m.id == unread.id);
        expect(back.disappearAfterSeconds, 60);
        expect(back.expiresAt, deadline);
      },
    );

    test(
      'a timer outside 5 s..30 d, a malformed quote and a malformed media id '
      'are dropped — the message is not',
      () async {
        encryption.inbound = jsonEncode({
          'content': 'still here',
          'ttl': 4,
          're': {'s': 'bob', 'k': 'TEXT', 'x': 'x'},
          'boxMedia': 'short',
        });
        final row = await receive();
        expect(row.content, 'still here');
        expect(row.disappearAfterSeconds, isNull);
        expect(row.expiresAt, isNull);
        expect(row.replyTo, isNull);
        final record = await encryption.store.getDecryptedContent(row.id);
        expect(record, isNot(contains('_expiresAt')));
      },
    );

    test(
      'a ping plays its effect (no sound) in the chat on screen and comes '
      'back after a restart as a consumed ping (decision 43)',
      () async {
        inbound(text: '', messageType: 'PING');
        final ping = await receive();
        expect(ping.messageType, MessageType.ping);
        expect(provider.showPingEffect, isTrue);
        expect(provider.incomingSoundRequestsForTest, 0);

        await restart();
        final back = provider.messages.singleWhere((m) => m.id == ping.id);
        expect(back.messageType, MessageType.ping);
        expect(back.content, isEmpty);
        expect(provider.showPingEffect, isFalse);
      },
    );

    test(
      'a reply to a message this device holds but has not loaded shows OUR '
      "copy's words, never the peer's snippet — on screen, in its record and "
      'after a restart; a held message that disappears lends no words (E18a)',
      () async {
        await encryption.store.saveDecryptedContent(
          500,
          {'content': 'what bob really said', 'senderId': 2},
          conversationId: 10,
          wire: (senderId: 2, wireId: wire),
        );
        await encryption.store.saveDecryptedContent(
          501,
          {'content': 'fleeting words', 'senderId': 2},
          conversationId: 10,
          disappearAfterSeconds: 60,
          wire: (senderId: 2, wireId: 'wire-fleet-001'),
        );
        expect(provider.messages.where((m) => m.id >= 500), isEmpty);

        inbound(
          text: 'reply',
          quote: (wireId: wire, senderId: 2, type: 'TEXT', snippet: 'forged'),
        );
        final reply = await receive();
        expect(reply.replyTo?.id, 500);
        expect(reply.replyTo?.content, 'what bob really said');
        final record = await encryption.store.getDecryptedContent(reply.id);
        expect(
          record?['replyTo'],
          containsPair('content', 'what bob really said'),
        );

        inbound(
          text: 'reply 2',
          quote: (
            wireId: 'wire-fleet-001',
            senderId: 2,
            type: 'TEXT',
            snippet: 'fleeting words',
          ),
        );
        final toFleeting = await receive();
        expect(toFleeting.replyTo?.id, 501);
        expect(toFleeting.replyTo?.content, isEmpty);
        expect(toFleeting.replyTo?.quotedDisappears, isTrue);

        await restart();
        expect(
          provider.messages.singleWhere((m) => m.id == reply.id).replyTo?.content,
          'what bob really said',
        );
        expect(
          provider.messages
              .singleWhere((m) => m.id == toFleeting.id)
              .replyTo
              ?.content,
          isEmpty,
        );
      },
    );

    test(
      'a message whose first store is unproven keeps the countdown its show '
      'started: the store retried on the next offer records that start, and '
      'a restart keeps the same deadline (decision 41)',
      () async {
        encryption.dropSaves = true;
        inbound(text: 'seen once', ttl: 60);
        final e = BoxInboxEntry(
          rid: 'rid',
          id: 'm${nextLocal - kFirstLocalMessageId}',
          localId: nextLocal++,
          peerUserId: 2,
          senderDeviceId: 1,
          signal: '2:AQID',
          receivedAt: DateTime.now().toUtc(),
          acked: true,
        );
        expect(await deliver(e, _peer(2, conversationId: 10)), isFalse);
        final deadline = provider.messages
            .singleWhere((m) => m.id == e.localId)
            .expiresAt;
        expect(deadline, isNotNull, reason: 'shown in the open chat');

        encryption.dropSaves = false;
        expect(await deliver(e, _peer(2, conversationId: 10)), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await restart();
        expect(
          provider.messages.singleWhere((m) => m.id == e.localId).expiresAt,
          deadline,
        );
      },
    );
  });
}
