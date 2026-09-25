import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_siblings.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart'
    show NoSessionException;
import 'package:shared_preferences/shared_preferences.dart';

/// The real plaintext store; Signal and the device list are faked. An
/// outbound "ciphertext" is `2:` + base64(plaintext), so a frame handed to
/// the box can be read back.
class _SiblingEncryption extends EncryptionProvider {
  _SiblingEncryption(this.store) : super(service: store);

  final EncryptionService store;

  /// What the next decrypt answers, or throws.
  Object inbound = '{}';
  final List<(int, int, int?)> decrypts = [];
  final List<(int, int)> sessions = [];
  final List<(int, int)> encrypts = [];
  bool e2eReady = true;

  /// `socketReady` confirmed [ownDeviceId].
  bool idConfirmed = true;

  /// The own list is in the verified cache; false = dropped (a device was
  /// linked or revoked) and only a fetch answers.
  bool ownCached = true;

  /// A fetch of the own list fails (timeout, bad chain).
  bool ownFetchFails = false;

  /// What [carriesOwnIdentity] answers: false = a stranger's PreKey message.
  bool ownIdentity = true;
  final List<String> identityChecks = [];

  /// The account's own verified list (user 1).
  VerifiedDeviceList own = _enrolled([2, 3]);

  @override
  bool get isE2EReady => e2eReady;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 2;

  @override
  bool get ownDeviceIdConfirmed => idConfirmed;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) =>
      userId == 1 && ownCached ? own : null;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => userId == 1 && !ownFetchFails
      ? own
      : throw StateError('no list in this test');

  @override
  Future<String> decrypt(
    int senderId,
    String ciphertext, {
    int? messageId,
    int deviceId = 1,
  }) async {
    decrypts.add((senderId, deviceId, messageId));
    final answer = inbound;
    if (answer is Exception) throw answer;
    return answer as String;
  }

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
    encrypts.add((recipientId, deviceId));
    return '2:${base64Encode(utf8.encode(plaintext))}';
  }

  @override
  Future<bool> carriesOwnIdentity(String ciphertext) async {
    identityChecks.add(ciphertext);
    return ownIdentity;
  }

  /// What [siblingPreKeyWouldReplace] answers: true = a PreKey message that
  /// would replace our session with that sibling (decision 37).
  bool replaces = false;

  @override
  Future<bool> siblingPreKeyWouldReplace(
    int userId,
    int deviceId,
    String ciphertext,
  ) async => replaces;
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

class _Link implements BoxSiblingLink {
  /// Every handoff handed to the box: (device, sid, sealPub).
  final List<(int, String, String)> learned = [];
  /// Every ack handed to the box: (device, sid).
  final List<(int, String)> acked = [];
  SiblingWrite answer = SiblingWrite.stored;

  /// The contact records the store holds, by user id.
  final Map<int, ContactRecord> contacts = {};

  /// Every sibling a failed decrypt asked to re-key.
  final List<int> rekeyed = [];

  @override
  ContactRecord? contactOf(int userId) => contacts[userId];

  @override
  Future<void> rekeySibling(int deviceId) async => rekeyed.add(deviceId);

  /// Siblings this device re-keyed and has not heard back from.
  final Set<int> awaiting = {};

  @override
  bool awaitingRekeyFrom(int deviceId) => awaiting.contains(deviceId);

  @override
  void rekeyAnswered(int deviceId) => awaiting.remove(deviceId);

  /// A delivery journaled from this device's self-queue; any other
  /// own-account rid is the request queue.
  static const selfRid = 'self-rid';

  @override
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async {
    learned.add((deviceId, sid, sealPub));
    return answer;
  }

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async {
    acked.add((deviceId, sid));
    return answer;
  }
}

final String _sid = '${'A' * 42}E';
final String _sealPub = '${'b' * 42}w';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late _SiblingEncryption encryption;
  late _Link link;
  late List<String> emitted;
  var nextLocal = kFirstLocalMessageId;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _SiblingEncryption(service);
    link = _Link();
    emitted = [];
    final conversations = ConversationsProvider()
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
    provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback((event, data) => emitted.add(event))
      ..setActiveConversationIdForTest(10)
      ..boxSiblings = link;
  });

  BoxInboxEntry sibling({
    int device = 3,
    String rid = _Link.selfRid,
    DateTime? receivedAt,
    bool? viaSelfQueue,
  }) => BoxInboxEntry(
    rid: rid,
    id: 'm${nextLocal - kFirstLocalMessageId}',
    localId: nextLocal++,
    peerUserId: 1,
    senderDeviceId: device,
    signal: '3:AQID',
    receivedAt: receivedAt ?? DateTime.now().toUtc(),
    acked: true,
    viaSelfQueue: viaSelfQueue ?? rid == _Link.selfRid,
  );

  void inbound(Map<String, dynamic> envelope) =>
      encryption.inbound = jsonEncode(envelope);

  /// No contact record exists for the own account: a sibling entry is read
  /// before the contact-record refusals ever look.
  Future<bool> consume(BoxInboxEntry e) => provider.consumeBoxEntry(e, null);

  test(
    "a sibling's handoff is decrypted under the OWN account's session with "
    'that device and handed to the box (which stores, acks and hands ours '
    'back — `box_session_siblings_test`) — nothing is shown or emitted',
    () async {
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      final e = sibling();

      expect(await consume(e), isTrue);

      expect(encryption.decrypts, [(1, 3, e.localId)]);
      expect(link.learned, [(3, _sid, _sealPub)]);
      expect(provider.messages, isEmpty);
      expect(emitted, isEmpty, reason: 'the server hears nothing of it');
    },
  );

  test(
    'a handoff the store cannot take yet (closed by a re-lock) is kept for '
    'the next offer and NOT acknowledged; one a newer build refuses is '
    'finished, still unacknowledged',
    () async {
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      link.answer = SiblingWrite.retryLater;
      expect(await consume(sibling()), isFalse);
      link.answer = SiblingWrite.refused;
      expect(await consume(sibling()), isTrue);
      expect(link.learned, hasLength(2));
    },
  );

  test(
    'an ack is recorded for that sibling; a closed store keeps it for the '
    'next offer',
    () async {
      inbound(E2eEnvelope.buildQueueHandoffAck(sid: _sid));
      expect(await consume(sibling()), isTrue);
      expect(link.acked, [(3, _sid)]);

      link.answer = SiblingWrite.retryLater;
      expect(await consume(sibling()), isFalse);
      expect(link.learned, isEmpty, reason: 'an ack is never taken as one');
    },
  );

  test(
    'a chat message naming no peer and an unknown type are finished without '
    'showing anything',
    () async {
      for (final envelope in [
        E2eEnvelope.build('sent copy'),
        {'t': 'from_the_future'},
        {'t': 'queue_handoff', 'sid': 'not-an-id', 'sealPub': _sealPub},
      ]) {
        inbound(envelope);
        expect(await consume(sibling()), isTrue);
      }
      expect(provider.messages, isEmpty);
      expect(link.learned, isEmpty);
      expect(
        await encryption.store.getDecryptedContent(nextLocal - 3),
        isNull,
        reason: 'no plaintext record is written for it',
      );
    },
  );

  test(
    'a sibling the own verified list names REVOKED is finished at once, '
    'never decrypted — a revocation is a verdict, and the revoked device '
    'keeps its sid for our self-queue until the rotation deletes it',
    () async {
      encryption.own = _enrolled([2], revoked: [3]);
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      expect(await consume(sibling()), isTrue);
      expect(encryption.decrypts, isEmpty);
      expect(link.learned, isEmpty);
    },
  );

  test(
    'a frame naming our account but carrying ANOTHER identity key is a '
    'stranger on our public request queue: finished unread, before Signal '
    'sees it (a PreKey decrypt would replace the real sibling session)',
    () async {
      encryption.ownIdentity = false;
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      final e = sibling();

      expect(await consume(e), isTrue);

      expect(encryption.identityChecks, [e.signal]);
      expect(encryption.decrypts, isEmpty);
      expect(link.learned, isEmpty);
    },
  );

  test('nothing is read before E2E is ready', () async {
    encryption.e2eReady = false;
    inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
    expect(await consume(sibling()), isFalse);
    expect(encryption.decrypts, isEmpty);
  });

  test(
    'a failed decrypt follows the box policy — no session waits and re-keys '
    'that sibling from our side, a Bad MAC is final — and never asks the '
    'server to re-key the own account (E8)',
    () async {
      encryption.inbound = NoSessionException('none');
      expect(await consume(sibling()), isFalse);
      expect(link.rekeyed, [3]);
      encryption.inbound = Exception('InvalidMessageException: Bad Mac!');
      expect(await consume(sibling()), isTrue);
      expect(link.rekeyed, [3], reason: 'a Bad MAC is not a missing session');
      expect(emitted, isNot(contains('requestSessionRebuild')));
      expect(provider.messages, isEmpty);
    },
  );

  group('a sibling PreKey message that would replace our session '
      '(decision 37)', () {
    test(
      'from a sibling this device did not ask is finished unread and '
      'answered by our own re-key — on either queue',
      () async {
        encryption.replaces = true;
        inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
        expect(await consume(sibling()), isTrue);
        expect(await consume(sibling(rid: 'request-rid')), isTrue);

        expect(encryption.decrypts, isEmpty);
        expect(link.learned, isEmpty);
        expect(link.rekeyed, [3, 3]);
        expect(emitted, isEmpty);
      },
    );

    test(
      'from a sibling this device re-keyed is read, and answers that re-key',
      () async {
        encryption.replaces = true;
        link.awaiting.add(3);
        inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
        final e = sibling();

        expect(await consume(e), isTrue);

        expect(encryption.decrypts, [(1, 3, e.localId)]);
        expect(link.learned, [(3, _sid, _sealPub)]);
        expect(link.rekeyed, isEmpty);
        expect(link.awaiting, isEmpty);
      },
    );

    test(
      'an outstanding re-key is answered by any message from that sibling '
      'that decrypts, never by one that fails',
      () async {
        link.awaiting.addAll([3, 4]);
        encryption.inbound = Exception('InvalidMessageException: Bad Mac!');
        expect(await consume(sibling()), isTrue);
        expect(link.awaiting, {3, 4});

        inbound(E2eEnvelope.buildQueueHandoffAck(sid: _sid));
        expect(await consume(sibling()), isTrue);
        expect(link.awaiting, {4});
      },
    );
  });

  test(
    'encrypting for an own device builds that session and frames the Signal '
    'message as from THIS device; not before E2E is ready',
    () async {
      final frame = (await provider.encryptForOwnDevice(3, '{"t":"x"}'))!;
      expect(encryption.sessions, [(1, 3)]);
      expect(frame.kind, BoxFrameKind.whisper);
      expect(frame.senderDeviceId, 2);
      expect(utf8.decode(frame.signal), '{"t":"x"}');

      encryption.e2eReady = false;
      expect(await provider.encryptForOwnDevice(3, '{}'), isNull);
    },
  );

  test(
    'encrypting for an own device refuses every id the own VERIFIED list '
    'does not name live, and this device itself — the server says which '
    'siblings exist, never which may hold our self-queue',
    () async {
      encryption.own = _enrolled([2, 3], revoked: [4]);
      for (final phantomRevokedOrSelf in [9, 4, 2]) {
        expect(
          await provider.encryptForOwnDevice(phantomRevokedOrSelf, '{}'),
          isNull,
          reason: 'device $phantomRevokedOrSelf',
        );
      }
      expect(encryption.sessions, isEmpty, reason: 'no session is built');
      expect(encryption.encrypts, isEmpty);
    },
  );

  test(
    'on the public REQUEST queue, a frame from a device our verified list '
    'does not name live, or one with no session yet, is finished — never '
    'held for a drain that cannot read it (the real sibling hands off again '
    'on its next connect)',
    () async {
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      encryption.own = _enrolled([2], revoked: [3]);
      expect(await consume(sibling(rid: 'request-rid')), isTrue);
      expect(encryption.decrypts, isEmpty);

      encryption
        ..own = _enrolled([2, 3])
        ..inbound = NoSessionException('none');
      expect(await consume(sibling(rid: 'request-rid')), isTrue);
      expect(link.learned, isEmpty);
      expect(link.rekeyed, isEmpty, reason: 'anyone can fill that queue');
    },
  );

  group('the own live devices the rotation acts on (E6, E7)', () {
    test(
      'name this device and the live ids of the own verified list — fetched '
      'when the cache was dropped, whether or not any peer is box-covered',
      () async {
        encryption
          ..own = _enrolled([2, 3], revoked: [4])
          ..ownCached = false;
        final own = await provider.ownLiveDevices();
        expect(own?.self, 2);
        expect(own?.live, {2, 3});
      },
    );

    test(
      'are unknown while this device id is not confirmed by the server — a '
      'guessed id would prune the real sibling — or before E2E is ready',
      () async {
        encryption.idConfirmed = false;
        expect(await provider.ownLiveDevices(), isNull);
        encryption
          ..idConfirmed = true
          ..e2eReady = false;
        expect(await provider.ownLiveDevices(), isNull);
      },
    );
  });

  group('a sent copy from a sibling (E5)', () {
    const wire = 'wire-copy-0001';
    final sentAt = DateTime.utc(2026, 9, 24, 12);

    Map<String, dynamic> copy({Object? to = 2}) => {
      ...E2eEnvelope.build('hi bob', msgId: wire, sentAt: sentAt),
      'to': ?to,
    };

    setUp(() {
      link.contacts[2] = const ContactRecord(
        userId: 2,
        username: 'bob',
        tag: '0002',
        state: ContactState.friend,
        legacy: ContactLegacy(conversationId: 10),
      );
    });

    test(
      'is filed under the peer it names as OUR row — sent, from that '
      'sibling, under its wire id and time — and stored',
      () async {
        inbound(copy());
        final e = sibling();

        expect(await consume(e), isTrue);

        expect(
          provider.messages.single,
          isA<MessageModel>()
              .having((m) => m.id, 'id', e.localId)
              .having((m) => m.senderId, 'senderId', 1)
              .having((m) => m.conversationId, 'conversationId', 10)
              .having((m) => m.content, 'content', 'hi bob')
              .having((m) => m.originDeviceId, 'originDeviceId', 3)
              .having((m) => m.wireId, 'wireId', wire)
              .having((m) => m.createdAt, 'createdAt', sentAt)
              .having(
                (m) => m.deliveryStatus,
                'deliveryStatus',
                MessageDeliveryStatus.sent,
              ),
        );
        final record = await encryption.store.getDecryptedContent(e.localId);
        expect(record, containsPair('content', 'hi bob'));
        expect(record, containsPair('senderId', 1));
        expect(emitted, isEmpty, reason: 'the server hears nothing of it');
        expect(
          provider.incomingSoundRequestsForTest,
          0,
          reason: 'our own message never sounds',
        );
      },
    );

    test('a second copy of a wire id this device holds is dropped', () async {
      inbound(copy());
      expect(await consume(sibling()), isTrue);
      final second = sibling(device: 4);
      encryption.own = _enrolled([2, 3, 4]);
      expect(await consume(second), isTrue);

      expect(provider.messages, hasLength(1));
      expect(await encryption.store.getDecryptedContent(second.localId), isNull);
    });

    test(
      'is finished unshown on the public REQUEST queue, or naming our own '
      'account, or naming a peer in the wrong shape',
      () async {
        final cases = [
          (copy(), 'request-rid'),
          (copy(to: 1), _Link.selfRid),
          (copy(to: '2'), _Link.selfRid),
        ];
        for (final (envelope, rid) in cases) {
          inbound(envelope);
          expect(await consume(sibling(rid: rid)), isTrue, reason: '$envelope');
        }
        expect(provider.messages, isEmpty);
      },
    );

    test(
      'is taken by how it was JOURNALED: through a self-queue that has '
      'retired since, filed; through the request queue under what is now '
      'the self rid, refused',
      () async {
        inbound(copy());
        expect(
          await consume(sibling(rid: 'retired-rid', viaSelfQueue: true)),
          isTrue,
        );
        expect(provider.messages, hasLength(1));

        inbound({...copy(), 'msgId': 'wire-copy-0002'});
        // The default rid IS the self rid: only the journal flag differs.
        expect(await consume(sibling(viaSelfQueue: false)), isTrue);
        expect(provider.messages, hasLength(1));
      },
    );

    test(
      'for a contact this device does not hold yet is kept for the next '
      'offer until the box TTL has passed, then finished; for one it '
      'blocked, finished unshown',
      () async {
        inbound(copy());
        link.contacts.clear();
        expect(await consume(sibling()), isFalse);
        final old = DateTime.now().toUtc().subtract(const Duration(days: 31));
        expect(await consume(sibling(receivedAt: old)), isTrue);

        link.contacts[2] = const ContactRecord(
          userId: 2,
          username: 'bob',
          tag: '0002',
          state: ContactState.blocked,
          legacy: ContactLegacy(conversationId: 10),
        );
        expect(await consume(sibling()), isTrue);
        expect(provider.messages, isEmpty);
      },
    );
  });

  test(
    'a self-queue delivery still unreadable once the box TTL has passed is '
    'finished: no session, and an origin our list does not name at all '
    '(E8) — held while young, since the list may be stale',
    () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 31));
      encryption.inbound = NoSessionException('none');
      expect(await consume(sibling(receivedAt: old)), isTrue);

      encryption.decrypts.clear();
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      encryption.own = _enrolled([2]);
      expect(await consume(sibling()), isFalse, reason: 'young: held');
      expect(await consume(sibling(receivedAt: old)), isTrue);
      expect(encryption.decrypts, isEmpty);
    },
  );

  test(
    'a self-queue delivery whose origin cannot be decided NOW — the own list '
    'is not cached and its fetch fails — is held, never finished as revoked',
    () async {
      encryption
        ..ownCached = false
        ..ownFetchFails = true;
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      expect(await consume(sibling()), isFalse);
      expect(encryption.decrypts, isEmpty);
    },
  );
}
