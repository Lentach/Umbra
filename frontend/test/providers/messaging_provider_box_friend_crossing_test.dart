import 'dart:async';
import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
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

  /// The peer's held list: enrolled, or — single-device by construction —
  /// not (its device is then 1).
  bool peerEnrolled = true;

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId != _peer
      ? null
      : peerEnrolled
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
      : const VerifiedDeviceList.notEnrolled();
}

String _sid(String c) => '${c * 42}E';
final String _sealPub = '${'b' * 42}w';

/// Key storage of one install, apart from every other's.
class _MemoryStorage extends DualStorage {
  _MemoryStorage() : super(const FlutterSecureStorage());

  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async =>
      _store[key] = value;

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(_store);
}

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
  final Set<int> _heard = {};

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
    _heard.clear();
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
  void friendRekeyAnswered(int userId, int deviceId) => _asked.remove(deviceId);

  @override
  void friendSessionStarted(int userId, int deviceId) =>
      _asked[deviceId] = _now;

  /// `BoxFriendHandoff.friendHeard`: an unacked device that is heard from
  /// is handed our queue again now, once per session.
  @override
  void friendHeard(int userId, int deviceId) {
    if (acked || handedAt == null || _handed || !_heard.add(deviceId)) return;
    handedAt = null;
    handOffTo(userId);
  }

  @override
  void handOffTo(int userId) {
    _handed = false;
    unawaited(_pass());
  }

  // Slice (e): the crossing never moves a device list.
  @override
  void friendDevicesChanged(int userId) {}

  @override
  Future<bool> sendListUpdate(
    int userId,
    int deviceId,
    Map<String, dynamic> auth,
  ) async => false;

  @override
  Future<bool> announceOwnList(Map<String, dynamic> auth) async => false;
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
    a = _Side(1, 1, 5, 3, _sid('A'));
    b = _Side(5, 3, 1, 1, _sid('B'));
    a.other = b;
    b.other = a;
    await wire(a);
    await wire(b);
    // The old path: a wrote to b, b answered — an established session each
    // way, and no window open on either side.
    final first = (await a.reader.encryptForFriend(5, 3, '{"t":"x"}'))!;
    await b.enc.encryptionService.decrypt(1, first.signalCiphertext);
    final reply = (await b.reader.encryptForFriend(1, 1, '{"t":"y"}'))!;
    await a.enc.encryptionService.decrypt(
      5,
      reply.signalCiphertext,
      deviceId: 3,
    );
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
      await b.link.rekeyFriend(1, 1);
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

      // Both sides now sit on the session the OTHER started; each one's ack
      // and hand-back were read from an archived state (traps: libsignal's
      // shallow-copy trial decrypt). Traffic after that must still read.
      for (var i = 0; i < 3; i++) {
        for (final (from, to) in [(a, b), (b, a)]) {
          final text = '{"t":"m","n":$i,"from":${from.userId}}';
          final frame = (await from.reader.encryptForFriend(
            from.peerId,
            from.peerDevice,
            text,
          ))!;
          expect(
            await to.enc.encryptionService.decrypt(
              to.peerId,
              frame.signalCiphertext,
              deviceId: to.peerDevice,
            ),
            text,
          );
        }
      }
    },
  );

  group('a friend device that lost its storage (decision 88)', () {
    /// Only a NOT enrolled account re-mints on a login (an enrolled one
    /// gates), and B holds A's list as such.
    setUp(() => b.enc.peerEnrolled = false);

    /// Before the wipe the pair was on the box: each held the other's queue
    /// and had acked it.
    void onTheBox() {
      a.link
        ..learned = b.sid
        ..acked = true;
      b.link
        ..learned = a.sid
        ..acked = true;
    }

    /// A's device after a wipe and a password login: empty key storage, so a
    /// NEW identity (an un-enrolled account re-mints), and the contact
    /// restored from the backup — B's queue in `outbound`, but no queue of
    /// its own (`toBackupJson` drops `queues`), so it holds a new one for B,
    /// handed to nobody yet. Its storage is its own: [a] goes on holding the
    /// OLD identity, as a device that never lost it would.
    Future<_Side> restoreA() async {
      final restored = _Side(1, 1, 5, 3, _sid('C'))..other = b;
      restored.enc.encryptionService.debugSetDualStorage(_MemoryStorage());
      b.other = restored;
      await wire(restored);
      restored.link.learned = b.sid;
      E2eDiagLog.clear();
      return restored;
    }

    /// [from] writes to [to] on the session the handoffs left; [to] reads it.
    Future<void> expectTraffic(_Side from, _Side to) async {
      const text = '{"t":"m"}';
      final frame = (await from.reader.encryptForFriend(
        from.peerId,
        from.peerDevice,
        text,
      ))!;
      expect(
        await to.enc.encryptionService.decrypt(
          to.peerId,
          frame.signalCiphertext,
          deviceId: to.peerDevice,
        ),
        text,
      );
    }

    test('hands its new queue over the queue we gave it, and we take it: '
        'what we write reaches the restored device', () async {
      onTheBox();
      final restored = await restoreA();

      await restored.link.restart();
      await pump();

      expect(b.refusals, isEmpty);
      expect(b.link.learned, restored.sid);
      expect(restored.link.acked, isTrue);
      await expectTraffic(b, restored);
      await expectTraffic(restored, b);
    });

    test(
      'from a friend held as ENROLLED, a new identity is refused like '
      'any unasked PreKey handoff: its revoked device could mint one',
      () async {
        b.enc.peerEnrolled = true;
        onTheBox();
        final restored = await restoreA();

        await restored.link.restart();
        await pump();

        expect(b.refusals, ['prekey_unasked']);
        expect(b.link.learned, a.sid);
      },
    );

    test('a handoff refused before the fix is taken when it is handed '
        'again: the session it started already stands', () async {
      onTheBox();
      final restored = await restoreA();
      await restored.link.restart();
      // The prod shape (0.2.58): B read the frame — the decrypt moved its
      // session to the new identity — and refused the handoff.
      final refused = mail.single;
      mail.clear();
      await b.enc.encryptionService.decrypt(1, refused.signal);

      _now = _now.add(_resend);
      await restored.link.restart();
      await pump();

      expect(b.refusals, isEmpty);
      expect(b.link.learned, restored.sid);
      expect(restored.link.acked, isTrue);
      await expectTraffic(b, restored);
    });

    /// [device] — holding A's identity, but not the restored install — hands
    /// B a queue of its own (sid R) on a fresh session, unasked.
    Future<void> handOffFrom(_Side device) async {
      final frame = (await device.reader.encryptForFriend(
        5,
        3,
        jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: _sid('R'), sealPub: _sealPub),
        ),
        fresh: true,
      ))!;
      mail.add((to: b, signal: frame.signalCiphertext, viaRequest: false));
      await pump();
    }

    test("a PreKey handoff under the friend's UNCHANGED identity is still "
        'refused when we did not ask: a revoked device holds that identity '
        'and our queue', () async {
      onTheBox();

      await handOffFrom(a);

      expect(b.refusals, ['prekey_unasked']);
      expect(b.link.learned, a.sid);
    });

    test('once the new identity is taken, a device still holding the OLD '
        'one cannot take the address back', () async {
      onTheBox();
      final restored = await restoreA();
      await restored.link.restart();
      await pump();
      expect(b.link.learned, restored.sid);

      await handOffFrom(a);

      expect(b.refusals, ['prekey_unasked']);
      expect(b.link.learned, restored.sid);
    });
  });
}
