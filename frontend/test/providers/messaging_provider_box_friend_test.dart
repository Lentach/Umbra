import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata-privacy item 5 (decision 47, E20c) on REAL Signal: this device S
/// is account 1's device 2 — the shipped reader (`consumeBoxEntry`) and the
/// friend encrypt path (`encryptForFriend`) over a real
/// [EncryptionProvider]. Friend F is account 5's device 3, a real
/// [EncryptionService] in its own storage namespace; a stranger X (account
/// 77) forges frames naming F. Stood in: the friend's verified list (device 3
/// live) and the box side ([_Link], `BoxSession`'s part, tested in
/// `box_session_friends_test`).
class _Me extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 2;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == _friend
      ? VerifiedDeviceList.enrolled(
          version: 1,
          listHash: 'H' * 44,
          devices: [
            const DeviceListEntry(deviceId: 3, platform: 'test', addedAtMs: 0),
          ],
        )
      : null;
}

class _Link implements BoxFriendLink {
  final List<String> learned = [];
  final List<(int, int)> rekeyed = [];
  final List<int> handedOffTo = [];
  final Set<(int, int)> awaiting = {};

  @override
  bool get onBox => true;

  @override
  ContactRecord? contactOf(int userId) =>
      userId == _friend ? _friendRecord : null;

  @override
  Future<FriendWrite> takeFriendHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async {
    learned.add(sid);
    return FriendWrite.stored;
  }

  @override
  Future<FriendWrite> friendAcked(int userId, int deviceId, String sid) async =>
      FriendWrite.stored;

  @override
  Future<void> rekeyFriend(int userId, int deviceId) async =>
      rekeyed.add((userId, deviceId));

  @override
  bool awaitingFriendRekeyFrom(int userId, int deviceId) =>
      awaiting.contains((userId, deviceId));

  @override
  void friendRekeyAnswered(int userId, int deviceId) =>
      awaiting.remove((userId, deviceId));

  @override
  void friendSessionStarted(int userId, int deviceId) =>
      awaiting.add((userId, deviceId));

  @override
  void handOffTo(int userId) => handedOffTo.add(userId);
}

const int _friend = 5;
String _sid(String c) => '${c * 42}E';
final String _sealPub = '${'b' * 42}w';

const _friendRecord = ContactRecord(
  userId: _friend,
  username: 'fred',
  tag: '0005',
  state: ContactState.friend,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EncryptionService f;
  late _Me enc;
  late MessagingProvider s;
  late _Link link;
  late int bundleFetches;
  var nextLocal = kFirstLocalMessageId;

  /// `fetchPreKeyBundle`'s flat bundle, on one-time prekey [otp].
  Map<String, dynamic> bundleOf(EncryptionService device, int otp) {
    final upload = device.getKeysForUpload()!;
    final otps = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>();
    return {
      ...(upload['keyBundle'] as Map).cast<String, dynamic>(),
      'oneTimePreKeyId': otps[otp]['keyId'],
      'oneTimePreKeyPublic': otps[otp]['publicKey'],
    };
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    f = EncryptionService();
    await f.initialize(
      _friend,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    bundleFetches = 0;
    enc = _Me();
    enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'fetchPreKeyBundle') {
        enc.onPreKeyBundleResponse({
          'userId': _friend,
          'deviceId': (data as Map)['deviceId'] ?? 1,
          'bundle': bundleOf(f, bundleFetches++),
        });
      }
    });
    await enc.initializeE2E(1);
    link = _Link();
    s = MessagingProvider()
      ..setEncryptionProvider(enc)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback((event, data) {})
      ..boxFriends = link;
  });

  /// A frame naming friend 5's [device], as S's box journals it: from S's
  /// public request queue unless [viaRequest] is false (S's own queue for
  /// the friend, whose sid only the friend's devices hold).
  Future<bool> deliver(
    String signal, {
    int device = 3,
    bool viaRequest = true,
    ContactRecord peer = _friendRecord,
  }) => s.consumeBoxEntry(
    BoxInboxEntry(
      rid: viaRequest ? 'request-rid' : 'friend-rid',
      id: 'm${nextLocal - kFirstLocalMessageId}',
      localId: nextLocal++,
      peerUserId: _friend,
      senderDeviceId: device,
      signal: signal,
      receivedAt: DateTime.now().toUtc(),
      acked: true,
      viaRequestQueue: viaRequest,
    ),
    peer,
  );

  Map<String, dynamic> handoff(String sid) =>
      E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: _sealPub);

  /// F's first message to S, on a session F builds from S's bundle [otp].
  Future<String> fromFreshF(Map<String, dynamic> envelope, int otp) async {
    await f.buildSession(
      1,
      bundleOf(enc.encryptionService, otp),
      deviceId: 2,
      expectedIdentityBase64: null,
    );
    return f.encrypt(1, jsonEncode(envelope), deviceId: 2);
  }

  test(
    'with no identity pinned for the friend, its PreKey handoff is finished '
    'unread and answered by our own handoff, which pins one from the '
    "server's bundle",
    () async {
      final first = await fromFreshF(handoff(_sid('A')), 0);
      expect(first, startsWith('3:'));

      expect(await deliver(first), isTrue);

      expect(link.learned, isEmpty);
      expect(link.handedOffTo, [_friend]);
    },
  );

  test(
    'a friend that started a session at the same time as us is read: its '
    'PreKey replaces the one this device just started to hand off',
    () async {
      // Our pass handed F our queue first: a session we initiated, pinning
      // F's identity from its bundle, never answered.
      final ours = (await s.encryptForFriend(
        _friend,
        3,
        jsonEncode(handoff(_sid('S'))),
      ))!;
      expect(ours.kind, BoxFrameKind.preKey);
      expect(bundleFetches, 1);
      expect(link.awaiting, {(_friend, 3)});

      final theirs = await fromFreshF(handoff(_sid('F')), 0);
      expect(
        await enc.encryptionService.preKeyWouldReplaceSession(
          _friend,
          3,
          theirs,
        ),
        isTrue,
      );
      expect(await deliver(theirs), isTrue);

      expect(link.learned, [_sid('F')]);
      expect(link.rekeyed, isEmpty);
      expect(link.awaiting, isEmpty, reason: 'answered');
      // S now speaks on F's session: F reads what S sends next.
      final ack = (await s.encryptForFriend(
        _friend,
        3,
        jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: _sid('F'))),
      ))!;
      expect(ack.kind, BoxFrameKind.whisper);
      expect(
        jsonDecode(await f.decrypt(1, ack.signalCiphertext, deviceId: 2)),
        E2eEnvelope.buildQueueHandoffAck(sid: _sid('F')),
      );
    },
  );

  test(
    "our re-key's fresh session opens NO window: a replacing PreKey that "
    'follows it is still refused (review: a revoked device could provoke '
    'the re-key and then use the window)',
    () async {
      await s.encryptForFriend(_friend, 3, '{"t":"x"}');
      link.awaiting.clear();

      final rekey = (await s.encryptForFriend(
        _friend,
        3,
        jsonEncode(handoff(_sid('K'))),
        fresh: true,
      ))!;
      expect(rekey.kind, BoxFrameKind.preKey);
      expect(link.awaiting, isEmpty);

      expect(await deliver(await fromFreshF(handoff(_sid('P')), 0)), isTrue);
      expect(link.learned, isEmpty);
    },
  );

  test(
    'a PreKey that would replace a session this device did NOT just start — '
    'one it wrote on long ago and that was never answered — is refused and '
    're-keyed, on the request queue and on our own queue alike',
    () async {
      await s.encryptForFriend(_friend, 3, '{"t":"x"}');
      // The window closed: the session is old, unanswered, not "asked".
      link.awaiting.clear();

      final viaRequest = await fromFreshF(handoff(_sid('R')), 0);
      expect(await deliver(viaRequest), isTrue);
      expect(link.learned, isEmpty);
      expect(link.rekeyed, [(_friend, 3)]);

      final viaOurQueue = await fromFreshF(handoff(_sid('Q')), 1);
      expect(await deliver(viaOurQueue, viaRequest: false), isTrue);
      expect(link.learned, isEmpty);
    },
  );

  test(
    'a PreKey handoff that would replace an ESTABLISHED session is finished '
    'unread and answered by our re-key, unless we asked for one',
    () async {
      // Established: S starts (pinning F's identity from its bundle), F
      // reads it and answers, S reads the answer.
      final pinned = (await s.encryptForFriend(_friend, 3, '{"t":"x"}'))!;
      expect(pinned.kind, BoxFrameKind.preKey);
      await f.decrypt(1, pinned.signalCiphertext, deviceId: 2);
      final reply = await f.encrypt(
        1,
        jsonEncode(handoff(_sid('B'))),
        deviceId: 2,
      );
      expect(reply, startsWith('2:'));
      expect(await deliver(reply), isTrue);
      expect(link.learned, [_sid('B')]);

      // F loses its session and starts again under a new base key.
      await f.deleteSession(1, deviceId: 2);
      final replacing = await fromFreshF(handoff(_sid('C')), 1);
      expect(replacing, startsWith('3:'));

      expect(await deliver(replacing), isTrue);
      expect(link.learned, [_sid('B')]);
      expect(link.rekeyed, [(_friend, 3)]);

      // Once S asked (its re-key went out), the same shape is read.
      link.awaiting.add((_friend, 3));
      final answer = await fromFreshF(handoff(_sid('D')), 2);
      expect(await deliver(answer), isTrue);
      expect(link.learned, [_sid('B'), _sid('D')]);
      expect(link.awaiting, isEmpty);
    },
  );

  test(
    "a stranger's PreKey frame naming the friend is finished before Signal "
    'sees it, and the session with the real friend stands',
    () async {
      await s.encryptForFriend(_friend, 3, '{"t":"x"}');
      final x = EncryptionService();
      await x.initialize(
        77,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: false),
      );
      await x.buildSession(
        1,
        bundleOf(enc.encryptionService, 0),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      final forged = await x.encrypt(
        1,
        jsonEncode(handoff(_sid('X'))),
        deviceId: 2,
      );

      expect(await deliver(forged), isTrue);

      expect(link.learned, isEmpty);
      expect(link.rekeyed, isEmpty);
      expect(link.handedOffTo, isEmpty);
      final next = (await s.encryptForFriend(_friend, 3, '{"t":"y"}'))!;
      expect(
        await f.decrypt(1, next.signalCiphertext, deviceId: 2),
        '{"t":"y"}',
      );
    },
  );

  test('nothing but a handoff is read from the request queue', () async {
    await s.encryptForFriend(_friend, 3, '{"t":"x"}');
    final message = await fromFreshF({
      'content': 'hi',
      'msgId': 'wire-00001',
    }, 0);

    expect(await deliver(message), isTrue);

    expect(link.learned, isEmpty);
    expect(s.messages, isEmpty);
  });

  test(
    "a handoff naming a device the friend's verified list does not name live "
    'is not read, even under the right identity',
    () async {
      await s.encryptForFriend(_friend, 3, '{"t":"x"}');
      // A fresh PreKey under the friend's own identity: first contact for
      // the (5, 4) address, so only the list can refuse it.
      final signal = await fromFreshF(handoff(_sid('R')), 0);

      expect(await deliver(signal, device: 4), isTrue);

      expect(link.learned, isEmpty);
    },
  );

  test(
    'a friend whose chat this device has not linked yet: its handoff over '
    'our queue for it is taken, and a message is HELD — neither shown nor '
    'dropped — and read once the chat is linked (found in the drive)',
    () async {
      await s.encryptForFriend(_friend, 3, '{"t":"x"}');
      final signal = await fromFreshF(handoff(_sid('Q')), 0);

      expect(await deliver(signal, viaRequest: false), isTrue);
      expect(link.learned, [_sid('Q')]);

      final message = await f.encrypt(
        1,
        jsonEncode({'content': 'hi', 'msgId': 'wire-00002'}),
        deviceId: 2,
      );
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'held',
        localId: nextLocal++,
        peerUserId: _friend,
        senderDeviceId: 3,
        signal: message,
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );
      expect(await s.consumeBoxEntry(entry, _friendRecord), isFalse);
      expect(await enc.recordExists(entry.localId), isNot(isTrue));

      // The conversations list linked the chat; the journal offers it again.
      final linked = _friendRecord.copyWith(
        legacy: const ContactLegacy(conversationId: 98),
      );
      expect(await s.consumeBoxEntry(entry, linked), isTrue);
      expect(await enc.recordExists(entry.localId), isTrue);
    },
  );
}
