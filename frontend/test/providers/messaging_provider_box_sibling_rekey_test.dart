import 'dart:convert';

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
import 'package:shared_preferences/shared_preferences.dart';

/// Decision 37 on REAL Signal (libsignal, no crypto faked). This device S is
/// account 1's device 2: the shipped reader (`consumeBoxEntry`) and encrypt
/// path (`encryptForOwnDevice`) over a real [EncryptionProvider]. Its sibling
/// D, device 3, is a real [EncryptionService] in its own storage namespace
/// (99) — two devices' disjoint stores, as in
/// `encryption_service_per_device_test`. Stood in: the own verified list,
/// the confirmed device id and the account-identity gate (E1): D mints its
/// own identity here, which E1 would refuse.
class _OwnDevices extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 2;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == 1
      ? VerifiedDeviceList.enrolled(
          version: 3,
          listHash: 'H' * 44,
          devices: [
            for (final id in [2, 3])
              DeviceListEntry(deviceId: id, platform: 'test', addedAtMs: 0),
          ],
        )
      : null;

  @override
  Future<bool> carriesOwnIdentity(String ciphertext) async => true;
}

/// The box side, as `BoxSession` answers it; the re-key's own sends are
/// `box_session_siblings_test`'s.
class _Link implements BoxSiblingLink {
  final List<String> learned = [];
  final List<String> acked = [];
  final List<int> rekeyed = [];
  final Set<int> awaiting = {};

  @override
  Future<SiblingWrite> takeSiblingHandoff(
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async {
    learned.add(sid);
    return SiblingWrite.stored;
  }

  @override
  Future<SiblingWrite> siblingAcked(int deviceId, String sid) async {
    acked.add(sid);
    return SiblingWrite.stored;
  }

  @override
  ContactRecord? contactOf(int userId) => null;

  @override
  Future<void> rekeySibling(int deviceId) async => rekeyed.add(deviceId);

  @override
  bool awaitingRekeyFrom(int deviceId) => awaiting.contains(deviceId);

  @override
  void rekeyAnswered(int deviceId) => awaiting.remove(deviceId);
}

String _sid(String c) => '${c * 42}E';
final String _sealPub = '${'b' * 42}w';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EncryptionService d;
  late _OwnDevices enc;
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
    d = EncryptionService();
    await d.initialize(
      99,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    bundleFetches = 0;
    enc = _OwnDevices();
    enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'fetchPreKeyBundle') {
        enc.onPreKeyBundleResponse({
          'userId': 1,
          'deviceId': (data as Map)['deviceId'] ?? 1,
          'bundle': bundleOf(d, bundleFetches++),
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
      ..boxSiblings = link;
  });

  /// D → S, as D's box would deliver it into S's self-queue.
  Future<bool> deliver(String signal) => s.consumeBoxEntry(
    BoxInboxEntry(
      rid: 'self-rid',
      id: 'm${nextLocal - kFirstLocalMessageId}',
      localId: nextLocal++,
      peerUserId: 1,
      senderDeviceId: 3,
      signal: signal,
      receivedAt: DateTime.now().toUtc(),
      acked: true,
      viaSelfQueue: true,
    ),
    null,
  );

  Future<String> fromD(Map<String, dynamic> envelope) =>
      d.encrypt(1, jsonEncode(envelope), deviceId: 2);

  Map<String, dynamic> handoff(String sid) =>
      E2eEnvelope.buildQueueHandoff(sid: sid, sealPub: _sealPub);

  test(
    'D loses its session and re-keys; S refuses the replacing PreKey unread '
    'and re-keys on a FRESH session with the old state archived; D, which '
    'asked, takes it; both directions read again',
    () async {
      final sBundle = enc.encryptionService;

      // First contact: S holds no session with D, so D's PreKey is read.
      await d.buildSession(
        1,
        bundleOf(sBundle, 0),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      final first = await fromD(handoff(_sid('A')));
      expect(first, startsWith('3:'));
      expect(await deliver(first), isTrue);
      // Until S answers, D keeps sending PreKey messages under the SAME base
      // key: an initiator's repeat replaces nothing and is read.
      final repeat = await fromD(handoff(_sid('B')));
      expect(repeat, startsWith('3:'));
      expect(await deliver(repeat), isTrue);
      expect(link.learned, [_sid('A'), _sid('B')]);
      expect(link.rekeyed, isEmpty);

      // S answers; D now holds an acknowledged session.
      final answer = (await s.encryptForOwnDevice(
        3,
        jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: _sid('A'))),
      ))!;
      expect(answer.kind, BoxFrameKind.whisper);
      await d.decrypt(1, answer.signalCiphertext, deviceId: 2);
      // Sent by D on that session, not yet delivered when D loses it.
      final inFlight = await fromD(
        E2eEnvelope.buildQueueHandoffAck(sid: _sid('F')),
      );
      expect(inFlight, startsWith('2:'));

      // D loses its session and re-keys from S's bundle: a PreKey message
      // under a NEW base key, which would replace S's session with D.
      await d.deleteSession(1, deviceId: 2);
      await d.buildSession(
        1,
        bundleOf(sBundle, 1),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      final dRekey = await fromD(handoff(_sid('C')));
      expect(dRekey, startsWith('3:'));

      // S did not ask: finished unread, answered by its own re-key, and its
      // session with D untouched.
      expect(await deliver(dRekey), isTrue);
      expect(link.learned, [_sid('A'), _sid('B')]);
      expect(link.rekeyed, [3]);
      expect(
        await enc.encryptionService.siblingPreKeyWouldReplace(1, 3, dRekey),
        isTrue,
      );

      // The re-key's handoff (`BoxSession.rekeySibling`): a FRESH session
      // built from D's bundle over the current one, so a PreKey message.
      final sRekey = (await s.encryptForOwnDevice(
        3,
        jsonEncode(handoff(_sid('S'))),
        fresh: true,
      ))!;
      expect(sRekey.kind, BoxFrameKind.preKey);
      expect(bundleFetches, 1);
      link.awaiting.add(3);

      // D asked for this re-key, so it takes S's PreKey although it replaces
      // D's own new session.
      expect(
        await d.siblingPreKeyWouldReplace(1, 2, sRekey.signalCiphertext),
        isTrue,
      );
      expect(
        jsonDecode(await d.decrypt(1, sRekey.signalCiphertext, deviceId: 2)),
        handoff(_sid('S')),
      );

      // Both directions read again, and S's re-key is answered.
      final next = await fromD(
        E2eEnvelope.buildQueueHandoffAck(sid: _sid('S')),
      );
      expect(next, startsWith('2:'));
      expect(await deliver(next), isTrue);
      expect(link.acked, [_sid('S')]);
      expect(link.awaiting, isEmpty);
      expect(link.rekeyed, [3]);
      final copy = (await s.encryptForOwnDevice(3, '{"t":"copy"}'))!;
      expect(copy.kind, BoxFrameKind.whisper);
      expect(
        await d.decrypt(1, copy.signalCiphertext, deviceId: 2),
        '{"t":"copy"}',
      );

      // Archived, not deleted: D's message sent on the old session before
      // the loss still reads. Nothing is asserted after it, on purpose: a
      // message read from the archive promotes that state back to current,
      // and libsignal_protocol_dart 0.8.2 trial-decrypts on a SHALLOW copy
      // of the current state (`SessionState.fromSessionState`), so the new
      // session it was first tried on is mangled as well.
      expect(await deliver(inFlight), isTrue);
      expect(link.acked, [_sid('S'), _sid('F')]);
    },
  );

  test(
    'a whisper message, or a PreKey message from a sibling this device holds '
    'no session with, would replace nothing',
    () async {
      await d.buildSession(
        1,
        bundleOf(enc.encryptionService, 0),
        deviceId: 2,
        expectedIdentityBase64: null,
      );
      final first = await fromD(handoff(_sid('A')));
      final service = enc.encryptionService;
      expect(await service.siblingPreKeyWouldReplace(1, 3, first), isFalse);
      expect(await deliver(first), isTrue);
      final answer = (await s.encryptForOwnDevice(3, '{"t":"x"}'))!;
      await d.decrypt(1, answer.signalCiphertext, deviceId: 2);
      final whisper = await fromD(handoff(_sid('B')));
      expect(whisper, startsWith('2:'));
      expect(await service.siblingPreKeyWouldReplace(1, 3, whisper), isFalse);
      expect(await service.siblingPreKeyWouldReplace(1, 3, 'junk'), isFalse);
    },
  );
}
