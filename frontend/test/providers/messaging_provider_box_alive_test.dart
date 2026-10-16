import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_sibling_alive.dart';
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

/// The real plaintext store; Signal and the own device list are faked. An
/// outbound "ciphertext" is `2:` + base64(plaintext), so a frame handed to
/// the box can be read back; an inbound one decrypts to [inbound].
class _Encryption extends EncryptionProvider {
  _Encryption(EncryptionService store) : super(service: store);

  String inbound = '{}';
  int deviceId = 1;
  final Set<int> siblingSessions = {};

  /// The account's own verified list (user 1); device 2 has a name.
  VerifiedDeviceList own = VerifiedDeviceList.enrolled(
    version: 3,
    listHash: 'H' * 44,
    devices: const [
      DeviceListEntry(deviceId: 1, platform: 'android', addedAtMs: 0),
      DeviceListEntry(
        deviceId: 2,
        platform: 'web',
        addedAtMs: 0,
        name: 'Laptop',
      ),
      DeviceListEntry(deviceId: 3, platform: 'ios', addedAtMs: 0),
    ],
  );

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => deviceId;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == 1 ? own : null;

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    bool batched = false,
    Duration timeout = const Duration(seconds: 10),
  }) async => userId == 1 ? own : throw StateError('no list in this test');

  @override
  Future<bool> hasSessionWith(int peerUserId, {int deviceId = 1}) async =>
      peerUserId == 1 && siblingSessions.contains(deviceId);

  @override
  Future<void> ensureSession(int recipientId, {int deviceId = 1}) async {}

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
  }) async => '2:${base64Encode(utf8.encode(plaintext))}';

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

typedef _Sent = ({ContactOutbound to, BoxFrame frame, BoxSendMode? mode});

class _Outbox implements BoxOutbox {
  final Map<int, ContactOutbound> siblings = {};
  final List<_Sent> delivered = [];
  BoxSendOutcome answer = BoxSendOutcome.taken;

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
    delivered.add((to: to, frame: BoxFrame.decode(body)!, mode: mode));
    return answer;
  }

  @override
  Future<int?> nextLocalId() async => null;

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
  static const selfRid = 'self-rid';

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

ContactOutbound _address(int device) => ContactOutbound(
  peerDeviceId: device,
  sid: '${String.fromCharCode(0x40 + device) * 42}E',
  sealPub: '${'b' * 42}w',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MessagingProvider provider;
  late _Encryption encryption;
  late _Outbox outbox;
  late ContactStore contacts;
  late DateTime now;
  var nextLocal = kFirstLocalMessageId;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      1,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    encryption = _Encryption(service);
    outbox = _Outbox();
    final kv = await PrefsContentKv.open();
    contacts = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await contacts.open(1);
    now = DateTime.utc(2026, 10, 16, 12);
    provider = MessagingProvider()
      ..setConversationsProvider(ConversationsProvider()..setCurrentUserId(1))
      ..setEncryptionProvider(encryption)
      ..setCurrentUserId(1)
      ..setToken('tok')
      ..setIncomingMessageSoundEnabledForTest(false)
      ..onConnect(false)
      ..setEmitCallback((event, data) {})
      ..boxSiblings = _Link()
      ..boxOutbox = outbox
      ..boxAlive = BoxSiblingAlive(store: contacts, now: () => now);
  });

  /// A connect's refresh, and everything the alive pass it starts writes.
  Future<void> connect() async {
    provider.refreshBoxDeviceLists();
    await pumpEventQueue();
    await contacts.settled;
  }

  BoxInboxEntry fromSibling(int device, {bool viaSelf = true}) => BoxInboxEntry(
    rid: viaSelf ? _Link.selfRid : 'request-rid',
    id: 'm${nextLocal - kFirstLocalMessageId}',
    localId: nextLocal++,
    peerUserId: 1,
    senderDeviceId: device,
    signal: '2:AQID',
    receivedAt: now,
    acked: true,
    viaSelfQueue: viaSelf,
  );

  group('alive', () {
    test('goes quiet to each live sibling with an address and a session, '
        'at most once per 24 h', () async {
      outbox.siblings.addAll({2: _address(2), 3: _address(3)});
      encryption.siblingSessions.add(2);

      await connect();
      expect(outbox.delivered, hasLength(1));
      final sent = outbox.delivered.single;
      expect(sent.to.peerDeviceId, 2);
      expect(sent.mode, BoxSendMode.quiet);
      expect(jsonDecode(utf8.decode(sent.frame.signal)), {'t': 'alive'});

      // Device 3 has no session: never built for an `alive` (E38b).
      encryption.siblingSessions.add(3);
      await connect();
      expect(
        [for (final s in outbox.delivered) s.to.peerDeviceId],
        [2, 3],
        reason: "device 2 already had today's",
      );

      now = now.add(kSiblingAliveEvery);
      await connect();
      expect(
        [for (final s in outbox.delivered) s.to.peerDeviceId],
        [2, 3, 2, 3],
      );
    });

    test('a sibling whose queue answered full gets no alive sealed while it '
        'stays paused (E93a)', () async {
      outbox
        ..siblings[2] = _address(2)
        ..answer = BoxSendOutcome.full;
      encryption.siblingSessions.add(2);

      await connect();
      outbox.answer = BoxSendOutcome.taken;
      await connect();
      await connect();
      expect(
        outbox.delivered,
        hasLength(1),
        reason: 'each seal moves its chain toward the 2000-step cap (E93a)',
      );

      now = now.add(kSiblingAliveEvery);
      await connect();
      expect(outbox.delivered, hasLength(1), reason: 'still paused');
    });

    test('one that failed is owed again on the next pass', () async {
      outbox
        ..siblings[2] = _address(2)
        ..answer = BoxSendOutcome.failed;
      encryption.siblingSessions.add(2);

      await connect();
      outbox.answer = BoxSendOutcome.taken;
      await connect();
      await connect();

      expect(outbox.delivered, hasLength(2));
    });
  });

  group('heard', () {
    test('every live sibling is first known at the pass', () async {
      await connect();
      expect(provider.siblingLastHeardAt(2), now);
      expect(provider.siblingLastHeardAt(3), now);
      expect(provider.siblingLastHeardAt(1), isNull, reason: 'this device');
    });

    test('any frame from a sibling read on our self-queue stamps it; one on '
        'the request queue does not', () async {
      await connect();
      final known = now;
      now = now.add(const Duration(days: 3));

      encryption.inbound = jsonEncode(E2eEnvelope.buildAlive());
      expect(
        await provider.consumeBoxEntry(fromSibling(3, viaSelf: false), null),
        isTrue,
      );
      await contacts.settled;
      expect(provider.siblingLastHeardAt(3), known);

      encryption.inbound = jsonEncode({'t': 'from_the_future'});
      expect(await provider.consumeBoxEntry(fromSibling(3), null), isTrue);
      await contacts.settled;
      expect(
        provider.siblingLastHeardAt(3),
        now,
        reason: 'not per type: an unknown one counts',
      );
    });
  });

  group('unlink question', () {
    test('is asked on the primary only, names the device as the Devices '
        'screen does, and Keep ends it', () async {
      await connect();
      expect(provider.siblingToUnlink, isNull, reason: 'first known now');

      now = now.add(const Duration(days: 31));
      expect(provider.siblingToUnlink, (deviceId: 2, name: 'Laptop'));

      encryption.deviceId = 2;
      expect(provider.siblingToUnlink, isNull, reason: 'not the primary');
      encryption.deviceId = 1;

      var notified = 0;
      provider.addListener(() => notified++);
      await provider.keepSibling(2);
      expect(notified, 1);
      expect(provider.siblingToUnlink, (deviceId: 3, name: 'ios · #3'));
    });

    test('a frame from the silent sibling ends the question', () async {
      await connect();
      now = now.add(const Duration(days: 31));
      final keptOff = BoxSiblingAlive(store: contacts, now: () => now);
      await keptOff.keep(3);
      expect(provider.siblingToUnlink?.deviceId, 2);

      var notified = 0;
      provider.addListener(() => notified++);
      encryption.inbound = jsonEncode(E2eEnvelope.buildAlive());
      expect(await provider.consumeBoxEntry(fromSibling(2), null), isTrue);
      await contacts.settled;
      await pumpEventQueue();

      expect(provider.siblingToUnlink, isNull);
      expect(notified, greaterThan(0));
    });
  });
}
