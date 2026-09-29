import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_authority_engine.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata-privacy slice (e), decisions 50–51, on REAL Signal and a REAL
/// device-list cache: this device S is account 1's device 2; friend F is
/// account 5, whose DAK signs its lists. F links device 4: its handoff on
/// S's public request queue carries F's list OUTSIDE Signal, judged before
/// Signal sees the frame (E50b), and adopted only under the DAK the server
/// served (E50a) — every linked device holds the account identity key.
class _Me extends EncryptionProvider {
  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => 2;

  @override
  bool get ownDeviceIdConfirmed => true;
}

class _Link implements BoxFriendLink {
  final List<String> learned = [];
  final List<int> devicesChanged = [];
  final List<(int, int)> rekeyed = [];

  @override
  bool get onBox => true;

  @override
  ContactRecord? contactOf(int userId) => userId == _friend ? _record : null;

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
  bool awaitingFriendRekeyFrom(int userId, int deviceId) => false;

  @override
  void friendRekeyAnswered(int userId, int deviceId) {}

  @override
  void friendSessionStarted(int userId, int deviceId) {}

  @override
  void friendHeard(int userId, int deviceId) {}

  @override
  void handOffTo(int userId) {}

  @override
  void friendDevicesChanged(int userId) => devicesChanged.add(userId);

  @override
  Future<bool> sendListUpdate(
    int userId,
    int deviceId,
    Map<String, dynamic> auth,
  ) async => true;

  /// Every own list announced (E50d), and whether the box takes the next.
  final List<Map<String, dynamic>> announced = [];
  bool announceTaken = true;

  @override
  Future<bool> announceOwnList(Map<String, dynamic> auth) async {
    announced.add(auth);
    return announceTaken;
  }
}

/// Covers friend 5 on device 3: what makes the connect refresh look up the
/// own list at all.
class _Outbox implements BoxOutbox {
  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) =>
      peerUserId == _friend
      ? const {
          3: ContactOutbound(peerDeviceId: 3, sid: 'sid-3', sealPub: 'pub'),
        }
      : const {};

  @override
  Map<int, ContactOutbound> siblingAddresses() => const {};

  @override
  Iterable<int> coveredPeers() => const [_friend];

  @override
  Future<bool> deliver(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
  }) async => true;

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

const int _friend = 5;
String _sid(String c) => '${c * 42}E';
final String _sealPub = '${'b' * 42}w';

const _record = ContactRecord(
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
  late DeviceAuthorityEngine dak;
  late Map<String, dynamic> enrollment;
  late IdentityKeyPair identity;
  late Map<String, dynamic>? Function() served;
  late int lookups;
  var nextLocal = kFirstLocalMessageId;
  Map<String, dynamic>? Function()? ownServed;

  List<DeviceListEntry> devices(Set<int> live, {Set<int> revoked = const {}}) =>
      [
        for (final d in {...live, ...revoked}.toList()..sort())
          DeviceListEntry(
            deviceId: d,
            platform: 'web',
            addedAtMs: d * 1000,
            revokedAtMs: revoked.contains(d) ? 9000 : null,
          ),
      ];

  Map<String, dynamic> signed(
    DeviceAuthorityEngine engine,
    Map<String, dynamic> enrolled,
    int version,
    List<DeviceListEntry> entries,
  ) {
    final list = engine.signList(
      DeviceList(userId: _friend, version: version, devices: entries),
    );
    return {
      'dakPub': enrolled['dakPub'],
      'enrollmentSig': enrolled['enrollmentSig'],
      'enrollmentCreatedAt': enrolled['createdAt'],
      'listVersion': version,
      'listSignature': list['listSignature'],
      'listCanonical': list['listCanonical'],
    };
  }

  Map<String, dynamic> genuine(int version, List<DeviceListEntry> entries) =>
      signed(dak, enrollment, version, entries);

  /// What a REVOKED device of F can sign: it holds F's identity key.
  Map<String, dynamic> forged(int version, List<DeviceListEntry> entries) {
    final rogue = DeviceAuthorityEngine();
    final rogueEnrollment = rogue.mintEnrollment(
      userId: _friend,
      identity: identity,
      createdAtMs: 555,
    );
    return signed(rogue, rogueEnrollment, version, entries);
  }

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
    identity = await f.identityKeyPairForLinking();
    dak = DeviceAuthorityEngine();
    enrollment = dak.mintEnrollment(
      userId: _friend,
      identity: identity,
      createdAtMs: 1234,
    );
    lookups = 0;
    served = () => genuine(1, devices({3}));
    enc = _Me()..keepsDeviceListFor = (peer) => peer == _friend;
    enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'getDeviceList' && (data as Map)['userId'] == _friend) {
        lookups++;
        enc.onDeviceList({'userId': _friend, 'authorization': served()});
      }
      if (event == 'getDeviceList' && (data as Map)['userId'] == 1) {
        enc.onDeviceList({'userId': 1, 'authorization': ownServed?.call()});
      }
      if (event == 'fetchPreKeyBundle') {
        enc.onPreKeyBundleResponse({
          'userId': _friend,
          'deviceId': (data as Map)['deviceId'] ?? 1,
          'bundle': bundleOf(f, 5),
        });
      }
    });
    await enc.initializeE2E(1);
    // F's account identity pinned, as its first bundle would.
    await enc.encryptionService.debugSavePeerIdentity(
      _friend,
      base64Encode(identity.getPublicKey().serialize()),
    );
    // The list the SERVER served: F on device 3 only.
    await enc.getVerifiedDeviceList(_friend);
    lookups = 0;
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

  /// F's new device 4 hands S its queue on S's request queue; its first
  /// message, on a session built from S's bundle.
  Future<bool> handoffFromDevice4({String? carried}) async {
    await f.buildSession(
      1,
      bundleOf(enc.encryptionService, 0),
      deviceId: 2,
      expectedIdentityBase64: null,
    );
    final signal = await f.encrypt(
      1,
      jsonEncode(E2eEnvelope.buildQueueHandoff(sid: _sid('N'), sealPub: _sealPub)),
      deviceId: 2,
    );
    return s.consumeBoxEntry(
      BoxInboxEntry(
        rid: 'request-rid',
        id: 'm$nextLocal',
        localId: nextLocal++,
        peerUserId: _friend,
        senderDeviceId: 4,
        signal: signal,
        receivedAt: DateTime.now().toUtc(),
        acked: true,
        viaRequestQueue: true,
        carriedList: carried,
      ),
      _record,
    );
  }

  test("a friend's newly linked device is taken on the list its own handoff "
      'carries — no server lookup (decision 50)', () async {
    expect(
      await handoffFromDevice4(carried: jsonEncode(genuine(2, devices({3, 4})))),
      isTrue,
    );

    expect(link.learned, [_sid('N')]);
    expect(enc.cachedDeviceList(_friend)?.liveDeviceIds, [3, 4]);
    expect(lookups, 0);
  });

  test('with no list carried, a device the held list does not name is '
      'refused, as before slice (e)', () async {
    expect(await handoffFromDevice4(), isTrue);

    expect(link.learned, isEmpty);
    expect(lookups, 0);
  });

  test('E50a: a list a revoked device signed under a DAK of its own is not '
      'adopted — the one lookup decides — and Signal never sees the frame, so '
      'no session is stored for the claimed device', () async {
    expect(
      await handoffFromDevice4(carried: jsonEncode(forged(9, devices({3, 4})))),
      isTrue,
    );

    expect(link.learned, isEmpty);
    expect(enc.cachedDeviceList(_friend)?.liveDeviceIds, [3]);
    expect(lookups, 1);
    expect(await enc.hasSessionWith(_friend, deviceId: 4), isFalse);
  });

  test('a revoke carried on a request-queue frame that is itself refused '
      'still runs the rotation pass: the list is adopted before any check '
      'and stands (E50e)', () async {
    served = () => genuine(2, devices({3, 4}));
    enc.invalidateDeviceList(_friend);
    await enc.getVerifiedDeviceList(_friend);
    lookups = 0;

    // A replay of F's genuine revoke under junk Signal bytes.
    expect(
      await s.consumeBoxEntry(
        BoxInboxEntry(
          rid: 'request-rid',
          id: 'm$nextLocal',
          localId: nextLocal++,
          peerUserId: _friend,
          senderDeviceId: 3,
          signal: '2:AAAA',
          receivedAt: DateTime.now().toUtc(),
          acked: true,
          viaRequestQueue: true,
          carriedList: jsonEncode(genuine(3, devices({3}, revoked: {4}))),
        ),
        _record,
      ),
      isTrue,
    );

    expect(link.learned, isEmpty);
    expect(enc.cachedDeviceList(_friend)?.liveDeviceIds, [3]);
    expect(link.devicesChanged, [_friend]);
    expect(lookups, 0);
  });

  test('a list_update from a live device that revokes one adopts it with no '
      'lookup and runs the handoff pass, which rotates our queue (E50d/E50e)', () async {
    served = () => genuine(2, devices({3, 4}));
    enc.invalidateDeviceList(_friend);
    await enc.getVerifiedDeviceList(_friend);
    lookups = 0;

    await f.buildSession(
      1,
      bundleOf(enc.encryptionService, 1),
      deviceId: 2,
      expectedIdentityBase64: null,
    );
    final update = await f.encrypt(
      1,
      jsonEncode(
        E2eEnvelope.buildListUpdate(genuine(3, devices({3}, revoked: {4}))),
      ),
      deviceId: 2,
    );
    expect(
      await s.consumeBoxEntry(
        BoxInboxEntry(
          rid: 'friend-rid',
          id: 'm$nextLocal',
          localId: nextLocal++,
          peerUserId: _friend,
          senderDeviceId: 3,
          signal: update,
          receivedAt: DateTime.now().toUtc(),
          acked: true,
        ),
        _record,
      ),
      isTrue,
    );

    expect(enc.cachedDeviceList(_friend)?.liveDeviceIds, [3]);
    expect(link.devicesChanged, [_friend]);
    expect(lookups, 0);
  });

  group('E50d: a revoke of OUR device is announced by this survivor', () {
    late DeviceAuthorityEngine ownDak;
    late Map<String, dynamic> ownEnrollment;

    Map<String, dynamic> own(int version, Set<int> live, {Set<int> revoked = const {}}) {
      final list = ownDak.signList(
        DeviceList(
          userId: 1,
          version: version,
          devices: [
            for (final d in {...live, ...revoked}.toList()..sort())
              DeviceListEntry(
                deviceId: d,
                platform: 'web',
                addedAtMs: d * 1000,
                revokedAtMs: revoked.contains(d) ? 9000 : null,
              ),
          ],
        ),
      );
      return {
        'dakPub': ownEnrollment['dakPub'],
        'enrollmentSig': ownEnrollment['enrollmentSig'],
        'enrollmentCreatedAt': ownEnrollment['createdAt'],
        'listVersion': version,
        'listSignature': list['listSignature'],
        'listCanonical': list['listCanonical'],
      };
    }

    setUp(() async {
      ownDak = DeviceAuthorityEngine();
      ownEnrollment = ownDak.mintEnrollment(
        userId: 1,
        identity: await enc.encryptionService.identityKeyPairForLinking(),
        createdAtMs: 1,
      );
      s.boxOutbox = _Outbox();
    });

    Future<void> connectWith(Map<String, dynamic> ownList) async {
      ownServed = () => ownList;
      s
        ..onConnect(true)
        ..refreshBoxDeviceLists();
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('the first own list is only a baseline, and a link alone is never '
        'announced: the new device announces itself', () async {
      await connectWith(own(1, {1, 2}));
      await connectWith(own(2, {1, 2, 3}));

      expect(link.announced, isEmpty);
      expect(enc.announcedOwnList?.version, 2);
    });

    test('a list that revokes a device we had announced goes to every '
        'friend device once; a box that did not take it all is tried again '
        "on the next connect's own lookup", () async {
      await connectWith(own(1, {1, 2, 3}));
      link.announceTaken = false;
      final revoke = own(2, {1, 2}, revoked: {3});

      await connectWith(revoke);
      expect(link.announced, hasLength(1));
      expect(enc.announcedOwnList?.version, 1, reason: 'not taken: owed');

      link.announceTaken = true;
      await connectWith(revoke);
      expect(link.announced, hasLength(2));
      expect(link.announced.last['listVersion'], 2);
      expect(enc.announcedOwnList?.version, 2);

      await connectWith(revoke);
      expect(link.announced, hasLength(2), reason: 'announced: done');
    });

    test('a device the list revoked is no survivor: it announces nothing', () async {
      await connectWith(own(1, {1, 2, 3}));
      await connectWith(own(2, {1, 3}, revoked: {2}));

      expect(link.announced, isEmpty);
    });
  });

  group('decision 51: when the connect asks the server for a friend list', () {
    Future<_Me> restart() async {
      final next = _Me()..keepsDeviceListFor = (peer) => peer == _friend;
      next.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          next.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await next.initializeE2E(1);
      return next;
    }

    test('a box peer whose list the server answers but that never verifies '
        'still lets the stamp be written, even when its answer comes last — '
        'else every later start would re-ask for every friend', () async {
      final broken = {
        ...genuine(2, devices({3})),
        'listSignature': genuine(3, devices({3, 4}))['listSignature'],
      };
      final next = _Me()..keepsDeviceListFor = (peer) => peer == _friend;
      next.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          next.onOwnKeyBundleStatus({'exists': false});
        }
        if (event == 'getDeviceList' || event == 'getDeviceLists') {
          final d = data as Map;
          final users = d['userIds'] as List? ?? [d['userId']];
          for (final user in users.cast<int>()) {
            // Our own answer first; the friend's refused one arrives last.
            Future<void>.delayed(
              Duration(milliseconds: user == _friend ? 50 : 0),
              () => next.onDeviceList({
                'userId': user,
                'authorization': user == _friend ? broken : null,
              }),
            );
          }
        }
      });
      await next.initializeE2E(1);
      next.invalidateDeviceList(_friend);
      expect(next.encryptionService.boxListsReadyAtMs, isNull);
      final m = MessagingProvider()
        ..setEncryptionProvider(next)
        ..setCurrentUserId(1)
        ..onConnect(false)
        ..setEmitCallback((event, data) {})
        ..boxFriends = link
        ..boxOutbox = _Outbox()
        ..refreshBoxDeviceLists();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(next.cachedDeviceList(_friend), isNull, reason: 'refused');
      expect(next.encryptionService.boxListsReadyAtMs, isNotNull);
      m.dispose();
    });

    test('a device never stamped box-ready owes each box peer one server '
        'answer, and is stamped only once none is owed — a stamp written '
        'first would waive the check for good', () async {
      // enc (setUp) started with no stamp; the server already answered for
      // the friend since.
      expect(enc.peerListOwedByServer(77), isTrue);
      expect(enc.peerListOwedByServer(_friend), isFalse);

      enc.markBoxListsReady(const [_friend, 77]);
      expect(enc.encryptionService.boxListsReadyAtMs, isNull);
      expect((await restart()).peerListOwedByServer(_friend), isTrue);

      enc.markBoxListsReady(const [_friend]);
      expect(enc.encryptionService.boxListsReadyAtMs, isNotNull);
      await pumpEventQueue();
      expect(enc.peerListOwedByServer(77), isFalse);

      final next = await restart();
      expect(next.peerListOwedByServer(_friend), isFalse);
      expect(next.cachedDeviceList(_friend)?.liveDeviceIds, [3]);
    });

    test('a stamp older than the box TTL — found at start, or on a '
        'reconnect of a process that slept through it — owes every peer '
        'again, whatever this process verified before', () async {
      enc.markBoxListsReady(const [_friend]);
      // The stamp write above is not awaited: let it land before the older
      // stamp below, or it can overwrite that one and the test reads fresh.
      await pumpEventQueue();
      expect(enc.peerListOwedByServer(_friend), isFalse);

      await enc.encryptionService.markBoxListsReady(
        DateTime.now()
            .subtract(kBoxRedeliveryWindow + const Duration(hours: 1))
            .millisecondsSinceEpoch,
      );
      expect(enc.peerListOwedByServer(_friend), isTrue);
      expect((await restart()).peerListOwedByServer(_friend), isTrue);
    });
  });
}
