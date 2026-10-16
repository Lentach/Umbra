import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/box/box_catch_up.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_media_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_siblings.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box_hidden_notifier.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/media_crypto_service.dart';
import 'package:fireplace/services/plaintext_record_codec.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decision 102 catch-up sync between own devices 1 (this one) and 3. The
/// real plaintext store and contact store; Signal is faked: an outbound
/// "ciphertext" is `3:` + base64(plaintext), an inbound one decrypts to
/// [inbound].
class _Encryption extends EncryptionProvider {
  _Encryption(this.store) : super(service: store);

  final EncryptionService store;
  final Map<int, VerifiedDeviceList> lists = {};
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
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async => true;

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

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
}

class _Outbox implements BoxOutbox {
  final Map<int, ContactOutbound> siblings = {};
  final List<(ContactOutbound, BoxFrame, BoxSendMode?)> delivered = [];
  BoxSendOutcome answer = BoxSendOutcome.taken;

  /// What the box's media route holds, by base64url id.
  final Map<String, Uint8List> media = {};

  /// Each upload: the sid it was paid by and the framed body.
  final List<(String, Uint8List)> uploads = [];

  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) => const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => siblings;

  @override
  Iterable<int> coveredPeers() => const [];

  @override
  Future<BoxSendOutcome> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async {
    delivered.add((to, BoxFrame.decode(body)!, mode));
    return answer;
  }

  @override
  Future<int?> nextLocalId() async => null;

  @override
  Future<BoxResult<BoxMediaRef>> uploadMedia(
    ContactOutbound to,
    Uint8List framed,
  ) async {
    uploads.add((to.sid, framed));
    final id = Uint8List(kBoxMediaIdBytes)..[0] = 100 + uploads.length;
    media[boxB64(id)] = framed;
    return BoxOk(
      BoxMediaRef(id: id, bucket: 'd14', expiresAt: DateTime.utc(2026, 11)),
    );
  }

  @override
  Future<BoxResult<Uint8List>> downloadMedia(Uint8List id) async {
    final body = media[boxB64(id)];
    return body == null ? const BoxRefused(BoxCode.notFound) : BoxOk(body);
  }
}

class _Link implements BoxSiblingLink {
  @override
  ContactRecord? contactOf(int userId) => null;

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

/// On the box; nothing else of the friend side is read here.
class _Friends implements BoxFriendLink {
  @override
  bool get onBox => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A keyed stand-in for AES-256-GCM (webcrypto does not load under `flutter
/// test` here): the body is the plaintext XORed with the key, then a 16-byte
/// tag holding the IV; a wrong key or IV throws.
class _XorCrypto extends MediaCryptoService {
  static final Uint8List _key = Uint8List.fromList(List.filled(32, 7));
  static final Uint8List _iv = Uint8List.fromList(List.filled(12, 5));

  @override
  Future<EncryptedMedia> encrypt(Uint8List bytes) async {
    final out = Uint8List(bytes.length + 16);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ _key[i % 32];
    }
    out.setRange(bytes.length, bytes.length + 12, _iv);
    return EncryptedMedia(
      ciphertext: out,
      keyBase64: base64Encode(_key),
      ivBase64: base64Encode(_iv),
    );
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    String keyB64,
    String ivB64,
  ) async {
    final key = base64Decode(keyB64);
    final iv = base64Decode(ivB64);
    final length = ciphertext.length - 16;
    for (var i = 0; i < iv.length; i++) {
      if (ciphertext[length + i] != iv[i]) throw StateError('bad tag');
    }
    return Uint8List.fromList([
      for (var i = 0; i < length; i++) ciphertext[i] ^ key[i % key.length],
    ]);
  }
}

VerifiedDeviceList _enrolled(List<int> live) => VerifiedDeviceList.enrolled(
  version: 3,
  listHash: 'H' * 44,
  devices: [
    for (final id in live)
      DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
  ],
);

const ContactOutbound _selfQueue3 = ContactOutbound(
  peerDeviceId: 3,
  sid: 'self-3',
  sealPub: 'seal',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late ConversationsProvider conversations;
  late _Encryption encryption;
  late _Outbox outbox;
  late ContactStore store;
  late int cards;
  var nextEntry = kFirstLocalMessageId + 9000;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _Encryption(service)..lists[1] = _enrolled([1, 3]);
    final kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    outbox = _Outbox()..siblings[3] = _selfQueue3;
    cards = 0;
    conversations = ConversationsProvider()
      ..contactStore = store
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
    await store.settled;
    provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setActiveConversationIdForTest(10)
      ..setEmitCallback((_, _) {})
      ..boxOutbox = outbox
      ..boxSiblings = _Link()
      ..boxFriends = _Friends()
      ..boxCatchUp = BoxCatchUp(crypto: _XorCrypto())
      ..boxHiddenNotifier = BoxHiddenNotifier(
        isHidden: () => true,
        post: () async => cards++,
      );
  });

  tearDown(() => provider.dispose());

  Future<void> pump([int turns = 60]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  DateTime nowMs() => DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );

  Map<String, dynamic> envelopeOf(BoxFrame frame) =>
      jsonDecode(utf8.decode(frame.signal)) as Map<String, dynamic>;

  /// Own device 3's frame on our self-queue, decrypting to [envelope].
  Future<bool> fromSibling(Map<String, dynamic> envelope) {
    encryption.inbound = jsonEncode(envelope);
    final localId = nextEntry++;
    return provider.consumeBoxEntry(
      BoxInboxEntry(
        rid: 'self-rid',
        id: 'm$localId',
        localId: localId,
        peerUserId: 1,
        senderDeviceId: 3,
        signal: '2:AQID',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
        viaSelfQueue: true,
      ),
      null,
    );
  }

  /// A box message record as the store keeps it, sent [ago] before now.
  Map<String, dynamic> record(
    String text, {
    required int sender,
    required String wire,
    required Duration ago,
  }) => {
    'content': text,
    'senderId': sender,
    PlaintextRecordCodec.conversationIdKey: 10,
    PlaintextRecordCodec.createdAtKey: nowMs()
        .subtract(ago)
        .millisecondsSinceEpoch,
    PlaintextRecordCodec.wireIdKey: wire,
    PlaintextRecordCodec.wireSenderKey: sender,
  };

  /// Stores [text] here as box message [id].
  Future<void> hold(
    int id,
    String text, {
    required int sender,
    required String wire,
    required Duration ago,
  }) => encryption.saveDecryptedContent(
    id,
    {'content': text, 'senderId': sender},
    conversationId: 10,
    createdAt: nowMs().subtract(ago),
    wire: (senderId: sender, wireId: wire),
  );

  /// [records] (responder id → record) sealed and uploaded as sibling 3's
  /// answer would be; the `sync_resp` envelope pointing at it.
  Future<Map<String, dynamic>> answer(
    Map<int, Map<String, dynamic>> records,
  ) async {
    final prefix = HistoryBackupService.recordPrefix(1);
    final sealed = await _XorCrypto().encrypt(
      encodeCatchUpPayload(1, {
        for (final MapEntry(:key, :value) in records.entries)
          '$prefix$key': jsonEncode(value),
      }),
    );
    final ref = await outbox.uploadMedia(
      _selfQueue3,
      frameMediaToRung(sealed.ciphertext),
    );
    return BoxCatchUpEnvelope.response(
      media: boxB64((ref as BoxOk<BoxMediaRef>).value.id),
      key: sealed.keyBase64,
      iv: sealed.ivBase64,
      since: nowMs().subtract(const Duration(hours: 3)),
      count: records.length,
    );
  }

  Future<void> stampedAgo(Duration ago) => provider.boxCatchUp.save(1, (
    at: nowMs().subtract(ago),
    owed: null,
  ));

  group('request', () {
    test('goes quiet to one live sibling after an absence, once', () async {
      final away = nowMs().subtract(const Duration(hours: 2));
      await provider.boxCatchUp.save(1, (at: away, owed: null));

      await provider.catchUpTick();
      await provider.catchUpTick();

      expect(outbox.delivered, hasLength(1));
      final (to, frame, mode) = outbox.delivered.single;
      expect(to.peerDeviceId, 3);
      expect(mode, BoxSendMode.quiet);
      expect(envelopeOf(frame), {
        't': E2eEnvelope.typeSyncRequest,
        'since': away.subtract(kCatchUpMargin).millisecondsSinceEpoch,
      });
      final mark = await provider.boxCatchUp.load(1);
      expect(mark.owed, isNull);
      expect(mark.at!.isAfter(away), isTrue);
    });

    test('is not sent after a short reconnect', () async {
      await stampedAgo(const Duration(minutes: 3));

      await provider.catchUpTick();

      expect(outbox.delivered, isEmpty);
      final mark = await provider.boxCatchUp.load(1);
      expect(mark.owed, isNull);
      expect(
        nowMs().difference(mark.at!),
        lessThan(const Duration(minutes: 1)),
      );
    });

    test('stays owed until a sibling has a self-queue address', () async {
      await stampedAgo(const Duration(hours: 5));
      outbox.siblings.clear();

      await provider.catchUpTick();

      expect(outbox.delivered, isEmpty);
      expect((await provider.boxCatchUp.load(1)).owed, isNotNull);

      outbox.siblings[3] = _selfQueue3;
      await provider.catchUpTick();

      expect(outbox.delivered, hasLength(1));
      expect((await provider.boxCatchUp.load(1)).owed, isNull);
    });

    test('stays owed while the only sibling is full, sealing nothing more '
        'to it, and asks it once it is heard again', () async {
      await stampedAgo(const Duration(hours: 5));
      outbox.answer = BoxSendOutcome.full;

      await provider.catchUpTick();
      await provider.catchUpTick();

      expect(outbox.delivered, hasLength(1), reason: 'paused (E93a)');
      expect((await provider.boxCatchUp.load(1)).owed, isNotNull);

      outbox.answer = BoxSendOutcome.taken;
      await fromSibling({'t': 'alive'});
      await provider.catchUpTick();

      expect(outbox.delivered, hasLength(2));
      expect((await provider.boxCatchUp.load(1)).owed, isNull);
    });
  });

  test('the responder sends only the box messages since `since`', () async {
    const old = kFirstLocalMessageId + 1;
    const bobs = kFirstLocalMessageId + 2;
    const mine = kFirstLocalMessageId + 3;
    await hold(
      old,
      'before',
      sender: 2,
      wire: 'wire-old-0001',
      ago: const Duration(hours: 3),
    );
    await hold(
      bobs,
      'from bob',
      sender: 2,
      wire: 'wire-bob-0001',
      ago: const Duration(hours: 1),
    );
    await hold(
      mine,
      'from me',
      sender: 1,
      wire: 'wire-me-00001',
      ago: const Duration(minutes: 30),
    );
    final since = nowMs().subtract(const Duration(hours: 2));

    expect(await fromSibling(BoxCatchUpEnvelope.request(since)), isTrue);
    await pump();

    final (sid, framed) = outbox.uploads.single;
    expect(sid, 'self-3');
    final payload = decodeCatchUpPayload(
      1,
      await _XorCrypto().decrypt(
        Uint8List.fromList(unframeMedia(framed)!),
        base64Encode(List.filled(32, 7)),
        base64Encode(List.filled(12, 5)),
      ),
    )!;
    expect([for (final r in payload) r.id], [bobs, mine]);
    expect(
      [for (final r in payload) r.record['content']],
      [
        'from bob',
        'from me',
      ],
    );
    final (to, frame, mode) = outbox.delivered.single;
    expect(to.peerDeviceId, 3);
    expect(mode, BoxSendMode.quiet);
    expect(
      BoxCatchUpEnvelope.parseResponse(jsonEncode(envelopeOf(frame))),
      isA<BoxCatchUpResponse>()
          .having((r) => r.count, 'count', 2)
          .having((r) => r.since, 'since', since),
    );
  });

  group('import', () {
    const held = kFirstLocalMessageId + 1;

    /// Sibling 3's records, under ITS ids — the first one this device's id
    /// for another message.
    late Map<int, Map<String, dynamic>> theirs;

    setUp(() async {
      await hold(
        held,
        'held here',
        sender: 2,
        wire: 'wire-held-001',
        ago: const Duration(hours: 2),
      );
      await encryption.addBoxTombstone((
        senderId: 2,
        wireId: 'wire-gone-001',
      ));
      theirs = {
        held: record(
          'held here',
          sender: 2,
          wire: 'wire-held-001',
          ago: const Duration(hours: 2),
        ),
        held + 1: record(
          'deleted for everyone',
          sender: 2,
          wire: 'wire-gone-001',
          ago: const Duration(hours: 2),
        ),
        held + 2: record(
          'missed',
          sender: 2,
          wire: 'wire-new-0001',
          ago: const Duration(hours: 1),
        ),
        held + 3: record(
          'sent from 3',
          sender: 1,
          wire: 'wire-mine-001',
          ago: const Duration(minutes: 50),
        ),
        held + 4: {
          ...record(
            'gone by now',
            sender: 2,
            wire: 'wire-dead-001',
            ago: const Duration(days: 2),
          ),
          PlaintextRecordCodec.expiresAtKey: nowMs()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        },
      };
    });

    Future<Map<String, int>> idsByWire() async => {
      for (final MapEntry(:key, :value)
          in (await encryption.allLocalMessageRecords()).entries)
        value[PlaintextRecordCodec.wireIdKey] as String: key,
    };

    test('stores what is not held, tombstoned or expired, quietly', () async {
      expect(await fromSibling(await answer(theirs)), isTrue);
      await pump();

      expect(await encryption.allLocalMessageRecords(), hasLength(3));
      final ids = await idsByWire();
      expect(
        ids.keys,
        unorderedEquals(['wire-held-001', 'wire-new-0001', 'wire-mine-001']),
      );
      // The held message keeps its record; the sibling's id for it (the
      // same number) was never written over.
      expect(ids['wire-held-001'], held);
      expect(
        (await encryption.getDecryptedContent(held))?['content'],
        'held here',
      );
      expect(ids['wire-new-0001'], isNot(held));
      expect(
        [for (final m in provider.messages) m.content],
        containsAll(['missed', 'sent from 3']),
      );
      expect(conversations.lastMessages[10]?.content, 'sent from 3');
      expect(cards, 0);
    });

    test('a second response with the same records imports nothing', () async {
      expect(await fromSibling(await answer(theirs)), isTrue);
      await pump();
      final first = await idsByWire();

      // Another blob of the same records: deduped record by record.
      expect(await fromSibling(await answer(theirs)), isTrue);
      await pump();

      expect(await encryption.allLocalMessageRecords(), hasLength(3));
      expect(await idsByWire(), first);
      expect(
        provider.messages.where((m) => m.content == 'missed'),
        hasLength(1),
      );
    });
  });
}
