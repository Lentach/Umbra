import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
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
}
