import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata-privacy item 5 on REAL Signal, BOTH sides: two friends' devices,
/// each the shipped reader (`consumeBoxEntry`) and friend encrypt path
/// (`encryptForFriend`) over a real [EncryptionProvider]. The box side is
/// stood in by [_Link], which keeps `BoxSession`'s and `BoxFriendHandoff`'s
/// rules: a re-key at most once per box session (a reconnect of the same
/// account resumes that session; only a new one resets it), a taken handoff
/// is acked and handed back unless the friend already acked ours, and a
/// pass hands a device our queue only when it has not acked it, not this
/// connect, and not within [_resend] of the last handoff (`handedAt`, kept
/// in the contact store across sessions).
///
/// What is under test is whether two devices that re-key each other at the
/// same moment ever hold each other's queue.
class _Enc extends EncryptionProvider {
  _Enc(this._device, this._peer, this._peerDevice);

  final int _device;
  final int _peer;
  final int _peerDevice;

  @override
  bool get isE2EReady => true;

  @override
  bool get hadIdentityReset => false;

  @override
  int get ownDeviceId => _device;

  @override
  bool get ownDeviceIdConfirmed => true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId == _peer
      ? VerifiedDeviceList.enrolled(
          version: 1,
          listHash: 'H' * 44,
          devices: [
            DeviceListEntry(
              deviceId: _peerDevice,
              platform: 'test',
              addedAtMs: 0,
            ),
          ],
        )
      : null;
}

String _sid(String c) => '${c * 42}E';
final String _sealPub = '${'b' * 42}w';

/// The test's clock: the resend gate and the "asked" window read it.
DateTime _now = DateTime.utc(2026, 9, 27);

/// `kFriendHandoffResend`.
const Duration _resend = Duration(hours: 24);

class _Side {
  _Side(this.userId, this.device, this.peerId, this.peerDevice, this.sid);

  final int userId;
  final int device;
  final int peerId;
  final int peerDevice;

  /// This side's queue for the peer.
  final String sid;
  late final _Enc enc = _Enc(device, peerId, peerDevice);
  late final MessagingProvider reader;
  late final _Link link;
  late _Side other;
  int otp = 0;

  ContactRecord get peerRecord => ContactRecord(
    userId: peerId,
    username: 'p$peerId',
    tag: '0000',
    state: ContactState.friend,
  );

  /// Why this side's reader refused a friend frame, oldest first.
  List<String> get refusals => [
    for (final entry in E2eDiagLog.entries)
      if (entry.contains('BOX_FRIEND_HANDOFF_REFUSED') &&
          entry.contains('peer: $peerId,'))
        RegExp(r'why: (\w+)').firstMatch(entry)!.group(1)!,
  ];
}

/// One frame in flight.
typedef _Mail = ({_Side to, String signal, bool viaRequest});

class _Link implements BoxFriendLink {
  _Link(this.side, this.mail);

  final _Side side;
  final List<_Mail> mail;

  // The contact store: kept across box sessions.

  /// The peer queue this side holds, once taken (`outbound`).
  String? learned;

  /// The peer device acked our queue (`ContactQueue.ackedBy`).
  bool acked = false;

  /// When the peer device was last handed our queue (`handedAt`).
  DateTime? handedAt;

  // One box session.

  final Set<int> _rekeyed = {};
  final Map<int, DateTime> _asked = {};

  /// Re-keys that went out, over every session.
  int rekeys = 0;

  // One connect.

  bool _handed = false;

  Future<bool> _send(String json, {bool fresh = false}) async {
    final frame = await side.reader.encryptForFriend(
      side.peerId,
      side.peerDevice,
      json,
      fresh: fresh,
    );
    if (frame == null) return false;
    mail.add((
      to: side.other,
      signal: frame.signalCiphertext,
      viaRequest: learned == null,
    ));
    return true;
  }

  String get _handoff => jsonEncode(
    E2eEnvelope.buildQueueHandoff(sid: side.sid, sealPub: _sealPub),
  );

  void _noteHanded() {
    _handed = true;
    handedAt = _now;
  }

  /// `BoxFriendHandoff._handTo` for the one friend device.
  Future<void> _pass() async {
    if (acked || _handed) return;
    final last = handedAt;
    if (last != null && _now.difference(last) < _resend) return;
    if (await _send(_handoff)) _noteHanded();
  }

  /// The account socket came back: the same box session resumes.
  Future<void> reconnect() {
    _handed = false;
    return _pass();
  }

  /// A new box session (the app started again, or another login).
  Future<void> restart() {
    _rekeyed.clear();
    _asked.clear();
    return reconnect();
  }

  @override
  bool get onBox => true;

  @override
  ContactRecord? contactOf(int userId) =>
      userId == side.peerId ? side.peerRecord : null;

  @override
  Future<FriendWrite> takeFriendHandoff(
    int userId,
    int deviceId, {
    required String sid,
    required String sealPub,
  }) async {
    learned = sid;
    await _send(jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid)));
    if (!acked && await _send(_handoff)) _noteHanded();
    return FriendWrite.stored;
  }

  @override
  Future<FriendWrite> friendAcked(int userId, int deviceId, String sid) async {
    if (sid != side.sid) return FriendWrite.refused;
    acked = true;
    return FriendWrite.stored;
  }

  @override
  Future<void> rekeyFriend(int userId, int deviceId) async {
    if (!_rekeyed.add(deviceId)) return;
    if (await _send(_handoff, fresh: true)) {
      rekeys++;
      _noteHanded();
    }
  }

  @override
  bool awaitingFriendRekeyFrom(int userId, int deviceId) {
    final at = _asked[deviceId];
    return at != null && _now.difference(at) <= kFriendRekeyWindow;
  }

  @override
  void friendRekeyAnswered(int userId, int deviceId) =>
      _asked.remove(deviceId);

  @override
  void friendSessionStarted(int userId, int deviceId) =>
      _asked[deviceId] = _now;

  @override
  void handOffTo(int userId) {
    _handed = false;
    unawaited(_pass());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Side a;
  late _Side b;
  late List<_Mail> mail;
  var nextLocal = kFirstLocalMessageId;

  Map<String, dynamic> bundleOf(_Side side, int otp) {
    final upload = side.enc.encryptionService.getKeysForUpload()!;
    final otps = (upload['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>();
    return {
      ...(upload['keyBundle'] as Map).cast<String, dynamic>(),
      'oneTimePreKeyId': otps[otp]['keyId'],
      'oneTimePreKeyPublic': otps[otp]['publicKey'],
    };
  }

  Future<void> wire(_Side side) async {
    side.enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        side.enc.onOwnKeyBundleStatus({'exists': false});
      }
      if (event == 'fetchPreKeyBundle') {
        side.enc.onPreKeyBundleResponse({
          'userId': side.peerId,
          'deviceId': side.peerDevice,
          'bundle': bundleOf(side.other, side.other.otp++),
        });
      }
    });
    await side.enc.initializeE2E(side.userId);
    side
      ..link = _Link(side, mail)
      ..reader = (MessagingProvider()
        ..setEncryptionProvider(side.enc)
        ..setCurrentUserId(side.userId)
        ..setToken('tok')
        ..setIncomingMessageSoundEnabledForTest(false)
        ..onConnect(false)
        ..setEmitCallback((event, data) {})
        ..boxFriends = side.link);
  }

  /// Delivers every frame in flight, and whatever reading them sends.
  Future<void> pump() async {
    for (var round = 0; round < 20 && mail.isNotEmpty; round++) {
      final batch = [...mail];
      mail.clear();
      for (final m in batch) {
        await m.to.reader.consumeBoxEntry(
          BoxInboxEntry(
            rid: m.viaRequest ? 'request-rid' : 'friend-rid',
            id: 'm${nextLocal - kFirstLocalMessageId}',
            localId: nextLocal++,
            peerUserId: m.to.peerId,
            senderDeviceId: m.to.peerDevice,
            signal: m.signal,
            receivedAt: DateTime.now().toUtc(),
            acked: true,
            viaRequestQueue: m.viaRequest,
          ),
          m.to.peerRecord,
        );
      }
      await pumpEventQueue();
    }
    expect(mail, isEmpty, reason: 'the pump must settle');
  }

  bool converged() =>
      a.link.learned == b.sid &&
      b.link.learned == a.sid &&
      a.link.acked &&
      b.link.acked;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    _now = DateTime.utc(2026, 9, 27);
    mail = [];
    a = _Side(1, 2, 5, 3, _sid('A'));
    b = _Side(5, 3, 1, 2, _sid('B'));
    a.other = b;
    b.other = a;
    await wire(a);
    await wire(b);
    // The old path: a wrote to b, b answered — an established session each
    // way, and no window open on either side.
    final first = (await a.reader.encryptForFriend(5, 3, '{"t":"x"}'))!;
    await b.enc.encryptionService.decrypt(1, first.signalCiphertext, deviceId: 2);
    final reply = (await b.reader.encryptForFriend(1, 2, '{"t":"y"}'))!;
    await a.enc.encryptionService.decrypt(5, reply.signalCiphertext, deviceId: 3);
    a.link._asked.clear();
    b.link._asked.clear();
    E2eDiagLog.clear();
  });

  tearDown(E2eDiagLog.clear);

  test(
    'two devices that re-key each other at the same moment each read the '
    "other's re-key — a re-key counts as asking (owner, decision 49) — and "
    "hold each other's queue after one delivery, for good",
    () async {
      await a.link.rekeyFriend(5, 3);
      await b.link.rekeyFriend(1, 2);
      await pump();

      expect(converged(), isTrue);
      expect(a.refusals, isEmpty);
      expect(b.refusals, isEmpty);
      expect((a.link.rekeys, b.link.rekeys), (1, 1));

      // Acked both ways: a reconnect and a new box session hand nothing off.
      _now = _now.add(_resend);
      await a.link.reconnect();
      await b.link.restart();
      expect(mail, isEmpty);
    },
  );
}
