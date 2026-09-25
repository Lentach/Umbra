import 'dart:convert';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_siblings.dart';
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
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == 1 ? own : null;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => userId == 1 ? own : throw StateError('no list in this test');

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
  final List<(int, String)> acked = [];
  SiblingWrite answer = SiblingWrite.stored;

  /// This device's self-queue; any other own-account rid is the request queue.
  static const selfRid = 'self-rid';

  @override
  bool viaSelfQueue(String rid) => rid == selfRid;

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
    final conversations = ConversationsProvider()..setCurrentUserId(1);
    provider = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback((event, data) => emitted.add(event))
      ..boxSiblings = link;
  });

  BoxInboxEntry sibling({int device = 3, String rid = _Link.selfRid}) =>
      BoxInboxEntry(
    rid: rid,
    id: 'm${nextLocal - kFirstLocalMessageId}',
    localId: nextLocal++,
    peerUserId: 1,
    senderDeviceId: device,
    signal: '3:AQID',
    receivedAt: DateTime.utc(2026, 9, 25),
    acked: true,
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
    'a chat message from a sibling (part B) and an unknown type are '
    'finished without showing anything',
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
    'a sibling the own verified list names REVOKED is withheld, never '
    'decrypted',
    () async {
      encryption.own = _enrolled([2], revoked: [3]);
      inbound(E2eEnvelope.buildQueueHandoff(sid: _sid, sealPub: _sealPub));
      expect(await consume(sibling()), isFalse);
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
    'a failed decrypt follows the box policy — no session waits, a Bad MAC '
    'is final — and never asks the server to re-key the own account',
    () async {
      encryption.inbound = NoSessionException('none');
      expect(await consume(sibling()), isFalse);
      encryption.inbound = Exception('InvalidMessageException: Bad Mac!');
      expect(await consume(sibling()), isTrue);
      expect(emitted, isNot(contains('requestSessionRebuild')));
      expect(provider.messages, isEmpty);
    },
  );

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
    },
  );
}
