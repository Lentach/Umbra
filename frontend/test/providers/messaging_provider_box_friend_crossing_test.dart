import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friend_gate.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/device_list/device_list_cache.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption/signal_stores.dart';
import 'package:fireplace/services/encryption_service.dart'
    show AccountIdentityMismatch;
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/box_send_harness.dart';
import '../support/chat_seed.dart';
import '../support/verify_pinned.dart';

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

  /// A send reads the device lists a connect verified: when set, both
  /// accounts' lists are local (the peer's per [peerEnrolled]) and a plain
  /// read asks nobody.
  bool localLists = false;

  /// Forced lookups asked of this provider: a person's tap owes one. A test
  /// may make one refresh what the box serves.
  final List<int> forcedLookups = [];
  Future<void> Function()? onForcedLookup;

  /// What was asked of the device-list cache, in order.
  final List<String> lookupLog = [];

  /// Runs once inside the next [calmHoldEligible] (a hold may change while
  /// the check waits).
  Future<void> Function()? onEligibility;

  /// Runs first inside [drainReleasedFrames] (the drain after a tap), before
  /// the box reads anything: the moment between the key being confirmed and
  /// the drain starting.
  Future<void> Function()? beforeDrain;

  @override
  Future<void> drainReleasedFrames(int peerId) async {
    await beforeDrain?.call();
    return super.drainReleasedFrames(peerId);
  }

  /// Runs first inside [holdForeignFrame], the await the red hold takes to
  /// be set (review 3, P3-1): the window between the refusal and the bar.
  Future<void> Function()? onHoldForeign;

  @override
  Future<void> holdForeignFrame(int userId, String ciphertext) async {
    await onHoldForeign?.call();
    return super.holdForeignFrame(userId, ciphertext);
  }

  /// While set, an encrypt for the friend waits for it AFTER Signal sealed
  /// (the ratchet moved), before the frame is handed back: a seal in flight.
  Completer<void>? afterSeal;

  /// Signals that an encrypt reached [afterSeal].
  Completer<void>? sealing;

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
    bool Function(String? remoteIdentity)? admit,
  }) async {
    final sealed = await super.encrypt(
      recipientId,
      plaintext,
      deviceId: deviceId,
      admit: admit,
    );
    final wait = afterSeal;
    if (wait != null && recipientId == _peer) {
      sealing?.complete();
      await wait.future;
    }
    return sealed;
  }

  @override
  Future<bool> calmHoldEligible(int peerId) async {
    final hook = onEligibility;
    onEligibility = null;
    await hook?.call();
    return super.calmHoldEligible(peerId);
  }

  @override
  void invalidateDeviceList(int userId, {bool byPerson = false}) {
    lookupLog.add('invalidate ${byPerson ? 'by person' : 'by event'}');
    super.invalidateDeviceList(userId, byPerson: byPerson);
  }

  @override
  Future<VerifiedDeviceList> getVerifiedDeviceList(
    int userId, {
    bool forceRefresh = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!forceRefresh) {
      if (localLists) return cachedDeviceList(userId)!;
      return super.getVerifiedDeviceList(userId, timeout: timeout);
    }
    lookupLog.add('lookup');
    forcedLookups.add(userId);
    await onForcedLookup?.call();
    return cachedDeviceList(userId)!;
  }

  @override
  VerifiedDeviceList? cachedDeviceList(int userId) => userId != _peer
      ? (localLists
            ? VerifiedDeviceList.enrolled(
                version: 1,
                listHash: 'G' * 44,
                devices: [
                  DeviceListEntry(
                    deviceId: _device,
                    platform: 'test',
                    addedAtMs: 0,
                  ),
                ],
              )
            : null)
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

/// A box whose address for the friend is the queue the contact record holds
/// NOW (the handoff moves it), as the real outbox reads it.
class _LearnedOutbox extends SendOutbox implements BoxFriendGateOutbox {
  _LearnedOutbox(this._queue, this._idk, this._anchor) {
    _gate = FriendGate(
      addressesOf: (friend) => addressesFor(friend).values,
      anchorOf: (_) => _anchor(),
      journalJudged: () => judged,
    )
      ..calmHeld = ((friend) => calmHeld?.call(friend) ?? false);
  }

  final String Function() _queue;

  /// The identity the address was learned under (its `idk`).
  final String? Function() _idk;

  /// The friend's pinned identity now.
  final String? Function() _anchor;
  late final FriendGate _gate;

  /// What the app wires from the provider (`connection_provider`): the
  /// gate's own calm clause.
  bool Function(int friend)? calmHeld;

  /// Whether the journal was judged this session (the gate's last clause).
  bool judged = true;

  @override
  FriendPermit? permitFor(
    int friend, {
    Iterable<ContactOutbound> to = const [],
    bool goodbye = false,
  }) => _gate.permitFor(friend, to: to, goodbye: goodbye);

  @override
  Future<BoxSendOutcome> deliverFriend(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
    FriendPermit? permit,
  }) async => _gate.refusalOf(permit, to.sid) != null
      ? BoxSendOutcome.failed
      : deliver(to, body, mode: mode);

  @override
  Future<BoxResult<BoxMediaRef>> uploadMediaFriend(
    ContactOutbound to,
    Uint8List framed, {
    FriendPermit? permit,
  }) => uploadMedia(to, framed);

  @override
  Iterable<int> coveredPeers() => const [1];
  @override
  Map<int, ContactOutbound> addressesFor(int peerUserId) => peerUserId == 1
      ? {
          1: ContactOutbound(
            peerDeviceId: 1,
            sid: _queue(),
            sealPub: boxAddress(1).sealPub,
            idk: _idk(),
          ),
        }
      : const {};
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
  late MessagingProvider reader;
  late final _Link link;
  late _Side other;
  int otp = 0;

  /// Frames this side's reader held (not finished): the box journal keeps
  /// them and offers them again.
  final List<BoxInboxEntry> held = [];

  /// Every request this side's encryption provider sent (the own-bundle
  /// check apart): a bundle fetch, a lookup. A calm hold sends none.
  final List<String> emits = [];

  /// What the server serves for a bundle fetch: the bundle as it is, or
  /// whatever a test makes of it (null: the server has none).
  Map<String, dynamic>? Function(Map<String, dynamic> bundle) serve =
      (bundle) => bundle;

  /// While set, a bundle answer waits for it.
  Completer<void>? gate;

  int get fetches => emits.where((e) => e == 'fetchPreKeyBundle').length;

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

  /// The identity the held address was learned under.
  String? learnedIdk;

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
    final frame = await side.reader.sealForFriend(
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
    required String? learnedUnder,
  }) async {
    learned = sid;
    learnedIdk = learnedUnder ?? learnedIdk;
    await _send(jsonEncode(E2eEnvelope.buildQueueHandoffAck(sid: sid)));
    if (!acked && await _send(_handoff)) _noteHanded();
    return FriendWrite.stored;
  }

  @override
  Future<FriendWrite> friendAcked(
    int userId,
    int deviceId,
    String sid, {
    required String? learnedUnder,
  }) async {
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
  Future<void> friendRelays(
    int userId,
    int deviceId, {
    required bool relays,
  }) async {}

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

/// Whether the row [tempId] of [p] waits to be sent (persisted, sent by the
/// pump when the friend's gate opens).
bool _waits(MessagingProvider p, String? tempId) =>
    p.messages.any((m) => m.tempId == tempId && m.waitingToSend);

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

  /// A reader as the app builds one at start.
  MessagingProvider newReader(_Side side) => MessagingProvider()
    ..setEncryptionProvider(side.enc)
    ..setCurrentUserId(side.userId)
    ..setToken('tok')
    ..setIncomingMessageSoundEnabledForTest(false)
    ..onConnect(false)
    ..setEmitCallback((event, data) {})
    ..boxFriends = side.link;

  Future<void> wire(_Side side) async {
    side.enc.setEmitCallback((event, data) {
      if (event == 'checkOwnKeyBundle') {
        side.enc.onOwnKeyBundleStatus({'exists': false});
        return;
      }
      side.emits.add(event);
      if (event == 'fetchPreKeyBundle') {
        final bundle = bundleOf(side.other, side.other.otp++);
        unawaited(() async {
          await side.gate?.future;
          side.enc.onPreKeyBundleResponse({
            'userId': side.peerId,
            'deviceId': side.peerDevice,
            'bundle': side.serve(bundle),
          });
        }());
      }
    });
    await side.enc.initializeE2E(side.userId);
    side
      ..link = _Link(side, mail)
      ..reader = newReader(side);
  }

  /// Delivers every frame in flight, and whatever reading them sends.
  Future<void> pump() async {
    for (var round = 0; round < 20 && mail.isNotEmpty; round++) {
      final batch = [...mail];
      mail.clear();
      for (final m in batch) {
        final entry = BoxInboxEntry(
          rid: m.viaRequest ? 'request-rid' : 'friend-rid',
          id: 'm${nextLocal - kFirstLocalMessageId}',
          localId: nextLocal++,
          peerUserId: m.to.peerId,
          senderDeviceId: m.to.peerDevice,
          signal: m.signal,
          receivedAt: DateTime.now().toUtc(),
          acked: true,
          viaRequestQueue: m.viaRequest,
        );
        if (!await m.to.reader.consumeBoxEntry(entry, m.to.peerRecord)) {
          m.to.held.add(entry);
        }
      }
      await pumpEventQueue();
    }
    expect(mail, isEmpty, reason: 'the pump must settle');
  }

  /// The box journal offers what [side] held again, in order.
  Future<void> reoffer(_Side side) async {
    final again = [...side.held];
    side.held.clear();
    for (final entry in again) {
      if (!await side.reader.consumeBoxEntry(entry, side.peerRecord)) {
        side.held.add(entry);
      }
    }
    await pumpEventQueue();
    await pump();
  }

  /// The user accepts the friend's new key on [side] (the dialog's confirm),
  /// and the box journal offers what was held again, in order.
  Future<void> acceptAndReoffer(_Side side) async {
    expect(await side.enc.acknowledgePeerIdentity(side.peerId), isTrue);
    await reoffer(side);
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
    // Sessions already established: a wrote to b, b answered — an established
    // session each way, and no window open on either side.
    final first = (await a.reader.sealForFriend(5, 3, '{"t":"x"}'))!;
    await b.enc.encryptionService.decrypt(1, first.signalCiphertext);
    final reply = (await b.reader.sealForFriend(1, 1, '{"t":"y"}'))!;
    await a.enc.encryptionService.decrypt(
      5,
      reply.signalCiphertext,
      deviceId: 3,
    );
    a.link._asked.clear();
    b.link._asked.clear();
    E2eDiagLog.clear();
    a.emits.clear(); // the key upload of the start-up is not a request
    b.emits.clear();
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
          final frame = (await from.reader.sealForFriend(
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
            // No sibling record here, so this device vouches no relay
            // (E101b): the frame is the text as it was.
            E2eEnvelope.toFriend(text, relays: false),
          );
        }
      }
    },
  );

  group('a friend device that lost its storage (decision 88)', () {
    /// Only a NOT enrolled account re-mints on a login (an enrolled one
    /// gates), and B holds A's list as such.
    setUp(() async {
      b.enc.peerEnrolled = false;
      // Calm needs the PERSISTED list too (the cache alone is not enough).
      await b.enc.encryptionService.recordPeerDeviceList(1, null);
    });

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
    Future<_Side> restoreA({String? sid}) async {
      final restored = _Side(1, 1, 5, 3, sid ?? _sid('C'))..other = b;
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
      final frame = (await from.reader.sealForFriend(
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
        E2eEnvelope.toFriend(text, relays: false),
      );
    }

    test('is HELD until we accept its new key (decision 143); then the '
        'handoff is taken and what we write reaches the restored device, '
        'both ways', () async {
      onTheBox();
      b.enc.keyChangeWarnings = () => true; // decision 143's hold
      final restored = await restoreA();

      await restored.link.restart();
      await pump();

      // Under the new identity nothing is read: no decrypt, no handoff.
      expect(b.held, hasLength(1));
      expect(b.refusals, isEmpty);
      expect(b.link.learned, a.sid, reason: 'the old address stands');
      expect(b.enc.peersWithHeldMessages, contains(1));
      // Warnings ON: never the calm line, never a request.
      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersCalmHeld, isEmpty);
      expect(b.emits, isEmpty);

      await acceptAndReoffer(b);

      expect(b.held, isEmpty);
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
        b.enc.keyChangeWarnings = () => true; // decision 143's hold
        final restored = await restoreA();

        await restored.link.restart();
        await pump();

        // Held first (a new identity), then, accepted, refused like any
        // unasked PreKey handoff.
        expect(b.held, hasLength(1));
        await acceptAndReoffer(b);

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
      final frame = (await device.reader.sealForFriend(
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
      b.enc.keyChangeWarnings = () => true; // decision 143's hold
      final restored = await restoreA();
      await restored.link.restart();
      await pump();
      await acceptAndReoffer(b);
      expect(b.link.learned, restored.sid);

      await handOffFrom(a);

      // The pin is the restored identity now: the old one is foreign, held
      // and unread, and never takes the address back.
      expect(b.refusals, isEmpty);
      expect(b.held, hasLength(1));
      expect(b.link.learned, restored.sid);
    });

    // ---- Decision 152 (option C): the calm hold and the person's tap ----

    Future<String> idOf(_Side s) async =>
        (await s.enc.encryptionService.getKeyBundleForReupload())![
                'identityPublicKey']
            as String;

    Future<String?> anchorOfA() =>
        b.enc.encryptionService.peerTofuIdentityBase64(1);

    /// The restored device's handoff reaches B and waits calmly.
    Future<_Side> calmRestore() async {
      onTheBox();
      final restored = await restoreA();
      await restored.link.restart();
      await pump();
      return restored;
    }

    /// The person taps the waiting line on [side]; when the key was
    /// confirmed the box drains again (what `onHeldFramesReleased` does).
    Future<void> tap(_Side side) async {
      var released = 0;
      Future<void>? running;
      // What the app wires: the drain reads the held frames and completes.
      // The tap no longer waits for it; the test does.
      side.enc.onHeldFramesReleased = (_) {
        released++;
        return running = reoffer(side);
      };
      await side.reader.confirmCalmHold(side.peerId);
      await pumpEventQueue(times: 100);
      if (running != null) await running;
      await pumpEventQueue(); // the released rows' sends finish
      expect(released, lessThanOrEqualTo(1), reason: 'one release per key');
    }

    /// Nothing but the calm line: no warning, no candidate, no request.
    void expectCalm(_Side s, {int held = 1}) {
      expect(s.held, hasLength(held));
      expect(s.reader.calmHoldState(s.peerId), CalmHoldState.waiting);
      expect(s.enc.peersCalmHeld, contains(s.peerId));
      expect(s.enc.peersWithHeldMessages, contains(s.peerId));
      expect(s.enc.peersWithChangedIdentity, isEmpty);
      expect(s.emits, isEmpty, reason: 'a frame alone asks nobody');
    }

    /// The visible (red) hold: the pill's set, no calm line.
    void expectRed(_Side s, {int held = 1}) {
      expect(s.held, hasLength(held));
      expect(s.reader.calmHoldState(s.peerId), isNull);
      expect(s.enc.peersCalmHeld, isEmpty);
      expect(s.enc.peersWithHeldMessages, contains(s.peerId));
      expect(s.enc.peersWithChangedIdentity, contains(s.peerId));
    }

    test('K1: a restored not-enrolled friend waits CALMLY, with no request '
        'at all; one tap takes its key, the handoff and the held frame, '
        'both ways', () async {
      onTheBox();
      final before = await anchorOfA();
      expect(before, isNotNull);
      final restored = await restoreA();

      await restored.link.restart();
      await pump();

      expectCalm(b);
      expect(await anchorOfA(), before);
      expect(b.link.learned, a.sid, reason: 'the old address stands');
      expect(b.enc.peerKeyChangeLog(1), isEmpty);

      final firstAt = b.held.single.receivedAt;
      await tap(b);

      expect(b.held, isEmpty);
      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersCalmHeld, isEmpty);
      expect(b.enc.peersWithHeldMessages, isEmpty);
      expect(b.enc.peersWithChangedIdentity, isEmpty);
      expect(await anchorOfA(), await idOf(restored));
      expect(
        b.enc.peerKeyChangeLog(1).single,
        firstAt.millisecondsSinceEpoch - 1,
        reason: 'the note sits just above the first message held for it',
      );
      expect(b.refusals, isEmpty);
      expect(b.link.learned, restored.sid);
      expect(restored.link.acked, isTrue);
      expect(b.fetches, 1, reason: 'the tap asked once');
      await expectTraffic(b, restored);
      await expectTraffic(restored, b);
    });

    test('K2: a friend held as ENROLLED gets the visible hold at once: '
        'nothing is delivered, nothing is asked, and its real device still '
        'reads our next message', () async {
      b.enc.peerEnrolled = true;
      await b.enc.encryptionService.recordPeerDeviceList(1, {
        'listVersion': 1,
        'dakPub': 'x',
      });
      onTheBox();
      final before = await anchorOfA();
      final restored = await restoreA();

      await restored.link.restart();
      await pump();

      expectRed(b);
      expect(b.emits, isEmpty);
      expect(b.refusals, isEmpty);
      expect(b.link.learned, a.sid);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
      b.other = a;
      await expectTraffic(b, a);
    });

    test('K3: a device still holding the OLD key, after the new one was '
        'taken, waits calmly too, but the tap finds the served key is the '
        'new one: refused, red hold, anchor untouched', () async {
      final restored = await calmRestore();
      await tap(b);
      expect(await anchorOfA(), await idOf(restored));
      expect(b.link.learned, restored.sid);
      b.emits.clear();

      await handOffFrom(a);

      expectCalm(b);
      expect(b.fetches, 0);
      await tap(b);

      expectRed(b);
      expect(await anchorOfA(), await idOf(restored));
      expect(b.enc.peerKeyChangeLog(1), hasLength(1));
      expect(b.link.learned, restored.sid);
      expect(b.refusals, isEmpty);
    });

    test('K5: a served bundle whose signed pre-key was not signed by the '
        "frame's key is refused: red hold, no anchor move, no note", () async {
      final before = await anchorOfA();
      final forged = bundleOf(a, 0)['signedPreKeySignature'];
      b.serve = (bundle) => {...bundle, 'signedPreKeySignature': forged};
      await calmRestore();

      await tap(b);

      expectRed(b);
      expect(b.fetches, 1);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
      expect(b.link.learned, a.sid);
    });

    test('K6: a VERIFIED friend gets the visible hold at once, no calm line '
        'and no request', () async {
      expect(await b.enc.encryptionService.verifyPinned(1), isTrue);
      onTheBox();
      final before = await anchorOfA();
      final restored = await restoreA();

      await restored.link.restart();
      await pump();

      expectRed(b);
      expect(b.emits, isEmpty);
      expect(await anchorOfA(), before);
    });

    test('K7: two frames under the same new key share ONE calm hold; one '
        'tap takes the key once and both frames drain', () async {
      final restored = await calmRestore();
      final second = (await restored.reader.sealForFriend(
        5,
        3,
        jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: _sid('S'), sealPub: _sealPub),
        ),
        fresh: true,
      ))!;
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'second',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 1,
        signal: second.signalCiphertext,
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );
      expect(await b.reader.consumeBoxEntry(entry, b.peerRecord), isFalse);
      b.held.add(entry);

      expectCalm(b, held: 2);

      await tap(b);

      expect(b.fetches, 1, reason: 'one tap, one request');
      expect(b.enc.peerKeyChangeLog(1), hasLength(1));
      expect(await anchorOfA(), await idOf(restored));
      expect(b.held, isEmpty);
    });

    test('K8: after a restart the journal re-offers the frame and the calm '
        'line returns; the tap works as before', () async {
      final restored = await calmRestore();
      // The process dies: RAM holds and the reader go, the journal stays.
      b.enc.encryptionService.releaseCalm(1);
      b.reader.dispose();
      b.reader = newReader(b);
      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersWithHeldMessages, isEmpty);

      await reoffer(b);

      expectCalm(b);
      await tap(b);

      expect(b.held, isEmpty);
      expect(await anchorOfA(), await idOf(restored));
      expect(b.link.learned, restored.sid);
    });

    test('K9: a stale served bundle is refreshed BEFORE it is read: the '
        'tap owes one forced lookup and then serves what it found', () async {
      var served = bundleOf(a, 0);
      b.enc
        ..isBoxOnlyPeer = ((_) => true)
        ..servedBundleFor = ((_, _) => served)
        ..onForcedLookup = () async => served = bundleOf(b.other, 1);
      final restored = await calmRestore();

      b.enc.lookupLog.clear();
      await tap(b);

      expect(b.enc.forcedLookups, [1]);
      expect(b.fetches, 0, reason: 'a box-only peer is never fetched by id');
      expect(
        b.enc.lookupLog.take(2),
        ['invalidate by person', 'lookup'],
        reason: 'a PERSON asked, and the refresh came before the read',
      );
      expect(await anchorOfA(), await idOf(restored));
      expect(b.held, isEmpty);
    });

    test("K10: the refreshed list no longer serves the frame's device: "
        'nothing is accepted, the hold turns red', () async {
      final before = await anchorOfA();
      b.enc
        ..isBoxOnlyPeer = ((_) => true)
        ..servedBundleFor = ((_, _) => null);
      await calmRestore();

      await tap(b);

      expectRed(b);
      expect(b.enc.forcedLookups, [1]);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
    });

    test('K11: the fresh list answer says ENROLLED (the lookup fails its '
        'check under the pinned key): refused, red, one lookup, no fetch, '
        'the bundle is never read', () async {
      final before = await anchorOfA();
      var read = 0;
      b.enc
        ..isBoxOnlyPeer = ((_) => true)
        ..servedBundleFor = ((_, _) {
          read++;
          return bundleOf(b.other, 1);
        })
        ..onForcedLookup = () async =>
            throw const DeviceListVerificationException(1, 'enrolled');
      await calmRestore();

      await tap(b);

      expectRed(b);
      expect(b.enc.forcedLookups, [1]);
      expect(b.fetches, 0);
      expect(read, 0);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
    });

    test('S1: killed between the build and the drain, the next start '
        'delivers the held frame: one note, no second request', () async {
      final restored = await calmRestore();
      await b.reader.confirmCalmHold(1); // confirmed; the drain never ran
      expect(await anchorOfA(), await idOf(restored));
      expect(b.held, hasLength(1));
      b.reader.dispose();
      b.reader = newReader(b);

      await reoffer(b);

      expect(b.held, isEmpty);
      expect(b.enc.peerKeyChangeLog(1), hasLength(1));
      expect(b.fetches, 1);
      expect(b.link.learned, restored.sid);
      await expectTraffic(restored, b);
    });

    test('M1: a foreign frame, offered again and again, and a second one '
        'from the same device, send NO request; only the tap does', () async {
      final restored = await calmRestore();
      for (var i = 0; i < 3; i++) {
        await reoffer(b);
      }
      _now = _now.add(_resend);
      await restored.link.restart();
      await pump();

      expectCalm(b, held: 2);
      expect(b.fetches, 0);

      await tap(b);

      expect(b.fetches, 1);
    });

    test("M2: the served key is NOT the frame's key: nothing is accepted "
        '(anchor, note, address), the hold turns red', () async {
      final before = await anchorOfA();
      await calmRestore();
      b.other = a; // the server still serves the OLD key

      await tap(b);

      expectRed(b);
      expect(b.fetches, 1);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
      expect(b.link.learned, a.sid);
    });

    test('single flight: a second tap while the first checks is ignored',
        () async {
      final restored = await calmRestore();
      b.gate = Completer<void>();
      var released = 0;
      b.enc.onHeldFramesReleased = (_) => released++;

      final first = b.reader.confirmCalmHold(1);
      await pumpEventQueue();
      expect(b.reader.calmHoldState(1), CalmHoldState.checking);
      final second = b.reader.confirmCalmHold(1);
      b.gate!.complete();
      await Future.wait([first, second]);
      await pumpEventQueue(); // the release is unawaited now

      expect(b.fetches, 1);
      expect(released, 1, reason: 'the key was confirmed once');
      expect(b.enc.peerKeyChangeLog(1), hasLength(1));
      expect(await anchorOfA(), await idOf(restored));
    });

    test('a transient failure keeps the calm line, tappable again; the '
        'next tap takes the key', () async {
      final before = await anchorOfA();
      final restored = await calmRestore();
      b.serve = (_) => null; // the server has no answer now

      await tap(b);

      expect(b.reader.calmHoldState(1), CalmHoldState.failed);
      expect(b.enc.peersCalmHeld, contains(1));
      expect(b.enc.peersWithChangedIdentity, isEmpty);
      expect(b.held, hasLength(1));
      expect(await anchorOfA(), before);

      b.serve = (bundle) => bundle;
      await tap(b);

      expect(b.fetches, 2);
      expect(b.held, isEmpty);
      expect(await anchorOfA(), await idOf(restored));
    });

    // ---- C-1: the journal offers the frame again WHILE the tap checks ----

    /// The tap on B stalls at the server; a connect offers the held frame
    /// again meanwhile; then the answer arrives.
    Future<void> tapAcrossReoffer() async {
      b.gate = Completer<void>();
      final tapped = tap(b);
      await pumpEventQueue();
      expect(b.reader.calmHoldState(1), CalmHoldState.checking);
      await reoffer(b);
      expect(b.reader.calmHoldState(1), CalmHoldState.checking);
      expect(b.held, hasLength(1));
      b.gate!.complete();
      b.gate = null;
      await tapped;
    }

    test('C-1a: a re-offer while the tap checks, then no answer: the line '
        'is tappable again and the second tap asks again', () async {
      final restored = await calmRestore();
      b.serve = (_) => null;

      await tapAcrossReoffer();

      expect(b.reader.calmHoldState(1), CalmHoldState.failed);
      expect(b.enc.peersCalmHeld, contains(1));
      expect(b.held, hasLength(1));

      b.serve = (bundle) => bundle;
      await tap(b);

      expect(b.fetches, 2);
      expect(b.held, isEmpty);
      expect(await anchorOfA(), await idOf(restored));
    });

    test('C-1b: a re-offer while the tap checks, then a served key that is '
        "not the frame's: the hold turns red, the calm line is gone", () async {
      final before = await anchorOfA();
      await calmRestore();
      b.other = a; // the server still serves the OLD key

      await tapAcrossReoffer();

      expectRed(b);
      expect(b.fetches, 1);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
    });

    test('C-1c: a re-offer while the tap checks, then the key is confirmed: '
        'accepted once and drained', () async {
      final restored = await calmRestore();

      await tapAcrossReoffer();

      expect(b.held, isEmpty);
      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersCalmHeld, isEmpty);
      expect(b.enc.peersWithHeldMessages, isEmpty);
      expect(b.fetches, 1);
      expect(b.enc.peerKeyChangeLog(1), hasLength(1));
      expect(await anchorOfA(), await idOf(restored));
      expect(b.link.learned, restored.sid);
    });

    test('the note is stamped from the EARLIEST frame held, whatever order '
        'the journal offered them in', () async {
      final restored = await calmRestore();
      final earlier = b.held.single.receivedAt.subtract(
        const Duration(seconds: 5),
      );
      final second = (await restored.reader.sealForFriend(
        5,
        3,
        jsonEncode(
          E2eEnvelope.buildQueueHandoff(sid: _sid('S'), sealPub: _sealPub),
        ),
        fresh: true,
      ))!;
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'earlier',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 1,
        signal: second.signalCiphertext,
        receivedAt: earlier,
        acked: true,
      );
      expect(await b.reader.consumeBoxEntry(entry, b.peerRecord), isFalse);
      b.held.add(entry);

      await tap(b);

      expect(
        b.enc.peerKeyChangeLog(1).single,
        earlier.millisecondsSinceEpoch - 1,
      );
    });

    // ---- C-4: the calm entry and the held marks move together ----

    test("C-4: a PreKey frame under the friend's PINNED key, arriving while "
        'another key waits calmly, leaves the line, the marks and the tap '
        'as they were', () async {
      final restored = await calmRestore();

      await handOffFrom(a);

      expect(b.refusals, ['prekey_unasked'], reason: 'read, and refused');
      expectCalm(b);

      await tap(b);

      expect(b.held, isEmpty);
      expect(await anchorOfA(), await idOf(restored));
    });

    // ---- C-5: guards a mutant used to survive ----

    test('a SECOND new key while one waits calmly is never calm: the hold '
        'turns red for both, nothing is asked', () async {
      final before = await anchorOfA();
      await calmRestore();
      final other = await restoreA(); // yet another identity for A

      await other.link.restart();
      await pump();

      expectRed(b, held: 2);
      expect(b.emits, isEmpty);
      expect(await anchorOfA(), before);
    });

    test('the tap confirms only when the frame key IS pinned after the '
        'build: warnings turned ON meanwhile refuse the accept, and the '
        'hold turns red with nothing released', () async {
      final before = await anchorOfA();
      await calmRestore();
      b.enc.keyChangeWarnings = () => true;
      var released = 0;
      b.enc.onHeldFramesReleased = (_) => released++;

      await b.reader.confirmCalmHold(1);

      expect(released, 0);
      expectRed(b);
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
    });

    // ---- The friendship ends while a frame waits calmly ----

    for (final state in [ContactState.blocked, ContactState.former]) {
      test('the friend is ${state.name} while a frame waits calmly: the next '
          'offer finishes the frame and clears the line and its marks',
          () async {
        await calmRestore();
        final gone = ContactRecord(
          userId: 1,
          username: 'p1',
          tag: '0000',
          state: state,
        );

        expect(await b.reader.consumeBoxEntry(b.held.single, gone), isTrue);

        expect(b.reader.calmHoldState(1), isNull);
        expect(b.enc.peersCalmHeld, isEmpty);
        expect(b.enc.peersWithHeldMessages, isEmpty);
        expect(b.enc.peersWithChangedIdentity, isEmpty);
        expect(b.emits, isEmpty);
      });
    }

    test('the friendship ends while a frame waits calmly, with no offer '
        'after it: the line and the marks are gone at once', () async {
      await calmRestore();

      b.reader.onFriendshipEnded(1);

      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersCalmHeld, isEmpty);
      expect(b.enc.peersWithHeldMessages, isEmpty);
      expect(b.enc.peersWithChangedIdentity, isEmpty);
    });

    test('S5: a PreKey frame whose body cannot be parsed is finished, '
        'never held, never asked about', () async {
      onTheBox();
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'junk',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 1,
        signal: '3:AAAA',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );

      expect(await b.reader.consumeBoxEntry(entry, b.peerRecord), isTrue);

      expect(b.reader.calmHoldState(1), isNull);
      expect(b.enc.peersCalmHeld, isEmpty);
      expect(b.enc.peersWithHeldMessages, isEmpty);
      expect(b.enc.peersWithChangedIdentity, isEmpty);
      expect(b.emits, isEmpty);
    });

    test('a whisper behind a calm-held frame WAITS: it is neither finished '
        'as undecryptable nor does it ask for a re-key', () async {
      await calmRestore();
      // A whisper of that friend that cannot read yet (its session is the
      // one the held frame would build).
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'whisper',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 1,
        signal: '2:AAAA',
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );

      expect(await b.reader.consumeBoxEntry(entry, b.peerRecord), isFalse);
      b.held.add(entry);

      expectCalm(b, held: 2);
      expect(b.link.rekeys, 0);
      // Held behind the frame, not failed: no failure policy ran for it.
      expect(
        E2eDiagLog.entries.where((e) => e.contains('BOX_DECRYPT_FAILED')),
        isEmpty,
      );
    });

    /// Frames written to the friend's OLD queue.
    List<BoxFrame> onOld(SendOutbox o) => [
      for (final (to, frame) in o.delivered)
        if (to.sid == a.sid) frame,
    ];

    /// Frames written to the restored install's NEW queue.
    List<BoxFrame> onNew(SendOutbox o, _Side restored) => [
      for (final (to, frame) in o.delivered)
        if (to.sid == restored.sid) frame,
    ];

    // ---- A send while the calm line waits (no old-session frame) ----

    /// B's chat with the friend over a fake box outbox, with local device
    /// lists (the send reads the lists a connect verified; here nothing may
    /// be looked up for it).
    Future<_LearnedOutbox> boxForB() async {
      final chats = ConversationsProvider()..setCurrentUserId(5);
      seedConversations(chats, [
        {
          'id': 10,
          'userOne': {'id': 5, 'username': 'b', 'tag': '0005'},
          'userTwo': {'id': 1, 'username': 'a', 'tag': '0001'},
          'createdAt': '2026-01-01T00:00:00.000Z',
          'unreadCount': 0,
          'lastMessage': null,
        },
      ]);
      chats.openConversation(10);
      final oldAnchor = b.enc.accountAnchorSync(1);
      final outbox = _LearnedOutbox(
        () => b.link.learned!,
        () => b.link.learnedIdk ?? oldAnchor,
        () => b.enc.accountAnchorSync(1),
      )
        ..calmHeld = b.reader.hasCalmHold;
      b.enc.localLists = true;
      b.reader
        ..setConversationsProvider(chats)
        ..setActiveConversationIdForTest(10)
        ..boxOutbox = outbox
        ..refreshBoxDeviceLists();
      await pumpEventQueue();
      b.emits.clear();
      b.enc.lookupLog.clear();
      b.enc.forcedLookups.clear();
      return outbox;
    }

    /// B writes [text] to the friend; returns the row.
    Future<MessageModel> writeFromB(String text) async {
      b.reader.sendMessage(text);
      await pumpEventQueue();
      return b.reader.messages.lastWhere((m) => m.content == text);
    }

    /// What the restored install reads from a frame B delivered.
    Future<String> readByRestored(_Side restored, BoxFrame frame) =>
        restored.enc.encryptionService.decrypt(
          5,
          frame.signalCiphertext,
          deviceId: 3,
        );

    test('E1: a message written while the calm line waits is NOT sealed on '
        'the old session and asks nobody; the tap sends it once, on the new '
        'session, and the restored install READS it', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();

      final row = await writeFromB('written during the hold');

      expect(outbox.delivered, isEmpty, reason: 'nothing on the old session');
      expect(b.emits, isEmpty, reason: 'a send fetches no bundle');
      expect(b.enc.lookupLog, isEmpty, reason: 'a send looks nobody up');
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(_waits(b.reader, row.tempId), isTrue);
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
      expectCalm(b);

      await tap(b);

      expect(outbox.delivered, hasLength(1), reason: 'sent exactly once');
      expect(
        outbox.delivered.single.$1.sid,
        restored.sid,
        reason: "written to the new install's queue (the handoff was taken "
            'before the release), not the old one',
      );
      expect(
        await readByRestored(restored, outbox.delivered.single.$2),
        contains('written during the hold'),
      );
      final sent = b.reader.messages.singleWhere((m) => m.tempId == row.tempId);
      expect(sent.deliveryStatus, MessageDeliveryStatus.sent);
      expect(_waits(b.reader, row.tempId), isFalse);
      await expectTraffic(b, restored);
      await expectTraffic(restored, b);
      expect(outbox.delivered, hasLength(1), reason: 'and not again');
    });

    test('E2: two messages written during the hold go out after the tap, '
        'in the order written, once each, and both are READ', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();

      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      expect(outbox.delivered, isEmpty);

      await tap(b);

      expect(outbox.delivered, hasLength(2));
      expect(
        outbox.delivered.map((d) => d.$1.sid),
        everyElement(restored.sid),
        reason: "both went to the new install's queue, not the old one",
      );
      final read = [
        for (final (_, frame) in outbox.delivered)
          await readByRestored(restored, frame),
      ];
      expect(read[0], contains('first'));
      expect(read[1], contains('second'));
    });

    test("E3: the tap is refused (the served key is not the frame's): the "
        'waiting message is SENT to the queue of the pinned identity once the '
        'red bar is up (the red bar never holds a send)', () async {
      final restored = await calmRestore();
      await tap(b);
      expect(await anchorOfA(), await idOf(restored));
      final outbox = await boxForB();
      await handOffFrom(a); // the OLD key again: calm, then refused
      expectCalm(b);

      final row = await writeFromB('into the refusal');
      expect(outbox.delivered, isEmpty);
      expect(_waits(b.reader, row.tempId), isTrue);

      await tap(b);

      expectRed(b);
      expect(outbox.delivered, hasLength(1), reason: 'sent once');
      expect(
        outbox.delivered.single.$1.sid,
        restored.sid,
        reason: "the pinned identity's queue (the one the app has pinned)",
      );
      expect(_waits(b.reader, row.tempId), isFalse);
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
    });

    /// A pump kick in the window of the refusal: the calm hold still closes
    /// the gate, and not one row is written (review 3, P3-1).
    ({bool? calmHeld, int? delivered}) inWindow = (calmHeld: null, delivered: null);

    void watchWindow(_Side side, SendOutbox outbox) {
      side.enc.onHoldForeign = () async {
        side.reader.kickSendPump(side.peerId);
        await pumpEventQueue(times: 50);
        inWindow = (
          calmHeld: side.reader.hasCalmHold(side.peerId),
          delivered: outbox.delivered.length,
        );
      };
    }

    test('P3-1 window, refused tap (key no longer eligible): between the '
        'refusal and the red hold no row goes out; after it the row is sent '
        'to the pinned queue', () async {
      await calmRestore();
      final outbox = await boxForB();
      final first = await writeFromB('first');
      b.enc.keyChangeWarnings = () => true;
      watchWindow(b, outbox);

      await tap(b);

      expect(inWindow.calmHeld, isTrue, reason: 'the calm hold closed the gate');
      expect(inWindow.delivered, 0, reason: 'nothing written in the window');
      expectRed(b);
      expect(onOld(outbox), hasLength(1), reason: 'sent after the red hold');
      expect(_waits(b.reader, first.tempId), isFalse);
    });

    test("P3-1 window, refused tap (the served key is not the frame's): "
        'between the refusal and the red hold no row goes out; after it the '
        'row is sent to the pinned queue', () async {
      final restored = await calmRestore();
      await tap(b);
      expect(await anchorOfA(), await idOf(restored));
      final outbox = await boxForB();
      await handOffFrom(a);
      expectCalm(b);
      final row = await writeFromB('into the refusal');
      watchWindow(b, outbox);

      await tap(b);

      expect(inWindow.calmHeld, isTrue, reason: 'the calm hold closed the gate');
      expect(inWindow.delivered, 0, reason: 'nothing written in the window');
      expectRed(b);
      expect(outbox.delivered, hasLength(1), reason: 'sent after the red hold');
      expect(outbox.delivered.single.$1.sid, restored.sid);
      expect(_waits(b.reader, row.tempId), isFalse);
    });

    test('E4: a transient failure of the tap keeps the message waiting, '
        'unsent; the next tap that succeeds sends it once', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('later');
      b.serve = (_) => null; // the server has no answer now

      await tap(b);

      expect(b.reader.calmHoldState(1), CalmHoldState.failed);
      expect(outbox.delivered, isEmpty);
      expect(_waits(b.reader, row.tempId), isTrue);

      b.serve = (bundle) => bundle;
      await tap(b);

      expect(outbox.delivered, hasLength(1));
      expect(
        await readByRestored(restored, outbox.delivered.single.$2),
        contains('later'),
      );
    });

    test('E5: a re-key answer while the line waits is not written on the '
        'old session and fetches no bundle', () async {
      await calmRestore();
      b.emits.clear();

      final frame = await b.reader.sealForFriend(
        1,
        1,
        '{"t":"x"}',
        fresh: true,
      );

      expect(frame, isNull);
      expect(b.emits, isEmpty);
    });

    test('E6: receipts, typing and an action are dropped while the line '
        'waits, and fetch nothing', () async {
      await calmRestore();
      final outbox = await boxForB();
      b.reader.receiptsAndTyping = () => true;

      b.reader.sendTypingIndicator(1, 10);
      await pumpEventQueue();

      expect(outbox.delivered, isEmpty);
      expect(b.emits, isEmpty);
      expect(b.enc.lookupLog, isEmpty);
    });

    test('F2: a reconnect between the write and the tap keeps the message '
        'waiting; the tap sends it once, to the queue the handoff names',
        () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('before the reconnect');
      expect(_waits(b.reader, row.tempId), isTrue);

      b.reader.onConnect(true);
      await pumpEventQueue();

      expectCalm(b);
      expect(_waits(b.reader, row.tempId), isTrue);
      expect(outbox.delivered, isEmpty);

      await tap(b);

      expect(outbox.delivered, hasLength(1), reason: 'sent exactly once');
      expect(outbox.delivered.single.$1.sid, restored.sid);
      expect(
        await readByRestored(restored, outbox.delivered.single.$2),
        contains('before the reconnect'),
      );
    });

    test('F4: the held messages go out one after the other: a first one '
        'the box takes slowly is still delivered first', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      outbox.beforeDeliver = (call) => call == 0
          ? Future<void>.delayed(const Duration(milliseconds: 60))
          : Future<void>.value();

      await tap(b);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(outbox.delivered, hasLength(2));
      final read = [
        for (final (_, frame) in outbox.delivered)
          await readByRestored(restored, frame),
      ];
      expect(read[0], contains('first'));
      expect(read[1], contains('second'));
    });

    // ---- The calm line turns visible, or is abandoned (F3, F5, F6, F7) ----

    for (final warnings in [false, true]) {
      test('F5: the friend became ${warnings ? 'warned about (warnings ON)' : 'verified'} '
          'while the line waited: the tap turns the hold red with no lookup '
          'and no bundle fetch, and the waiting message is sent to the pinned queue',
          () async {
        await calmRestore();
        final outbox = await boxForB();
        final row = await writeFromB('late');
        final before = await anchorOfA();
        if (warnings) {
          b.enc.keyChangeWarnings = () => true;
        } else {
          expect(await b.enc.encryptionService.verifyPinned(1), isTrue);
        }
        b.emits.clear();
        b.enc.lookupLog.clear();
        b.enc.forcedLookups.clear();

        await tap(b);

        expect(b.emits, isEmpty, reason: 'not one request');
        expect(b.enc.lookupLog, isEmpty);
        expectRed(b);
        expect(await anchorOfA(), before);
        expect(onOld(outbox), hasLength(1), reason: 'sent once, pinned queue');
        expect(outbox.delivered, hasLength(1));
        expect(_waits(b.reader, row.tempId), isFalse);
        expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
        expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
      });
    }

    test('a re-offer that finds the line no longer eligible turns it red '
        'and the waiting message is sent to the pinned queue', () async {
      await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('waiting');
      expect(await b.enc.encryptionService.verifyPinned(1), isTrue);

      await reoffer(b);

      expectRed(b);
      expect(_waits(b.reader, row.tempId), isFalse);
      expect(onOld(outbox), hasLength(1));
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
    });

    test('ONE lookup per tap, with the box refresh wired as the app wires '
        'it: the accept inside the tap does not drop the list it just '
        'fetched and asks the friend again (device: two searchUsers, 30 ms '
        'and 117 ms after the tap)', () async {
      final restored = await calmRestore();
      final served = bundleOf(restored, 0);
      b.enc
        ..isBoxOnlyPeer = ((_) => true)
        ..servedBundleFor = ((_, _) => served)
        // What `MessagingProvider.onDeviceListInvalidated` starts: the box
        // refresh reads the list again, forced when a lookup is owed.
        ..onDeviceListInvalidated = (user) => unawaited(
          b.enc
              .getVerifiedDeviceList(
                user,
                forceRefresh: b.enc.peerListOwedByServer(user),
              )
              .then<void>((_) {}, onError: (Object _) {}),
        );
      b.enc.forcedLookups.clear();
      b.enc.lookupLog.clear();

      await tap(b);
      await pumpEventQueue();

      expect(await anchorOfA(), await idOf(restored));
      expect(
        b.enc.lookupLog.where((e) => e == 'invalidate by person'),
        hasLength(1),
        reason: 'the accept inside the tap must not drop the list again',
      );

    });

    test('F7: the account switches while the tap waits for the lookup: the '
        'served bundle is abandoned, nothing is built, the anchor does not '
        'move', () async {
      final restored = await calmRestore();
      final before = await anchorOfA();
      b.enc
        ..isBoxOnlyPeer = ((_) => true)
        ..servedBundleFor = ((_, _) => bundleOf(restored, 0))
        ..onForcedLookup = () async => b.enc.onConnect(false); // epoch moves

      await tap(b);

      expect(b.enc.forcedLookups, [1], reason: 'the lookup did run');
      expect(await anchorOfA(), before);
      expect(b.enc.peerKeyChangeLog(1), isEmpty);
      expect(
        E2eDiagLog.entries.where((e) => e.contains('CALM_CONFIRMED')),
        isEmpty,
      );
    });

    test('F8: the contact store is closed when the anchor is to move (the '
        'stamp cannot be written): the accept is TRANSIENT, the calm line '
        'shows failed and can be tapped again, and no red hold is raised',
        () async {
      final restored = await calmRestore();
      final before = await anchorOfA();
      var stampOk = false;
      b.enc.encryptionService.onBeforeAnchorMoves = (_, _) async => stampOk;

      await tap(b);

      expect(await anchorOfA(), before, reason: 'the anchor did not move');
      expect(b.reader.calmHoldState(1), CalmHoldState.failed);
      expect(b.enc.peersWithChangedIdentity, isEmpty, reason: 'no red pill');
      expect(b.enc.peersCalmHeld, contains(1), reason: 'still the calm line');
      expect(b.enc.peersWithHeldMessages, contains(1));

      stampOk = true; // the store is open again: the same line, tapped again
      await tap(b);
      expect(await anchorOfA(), await idOf(restored), reason: 'accepted');
      expect(b.reader.calmHoldState(1), isNull);
    });

    test('F6: the hold was cleared and re-created while the tap waited: its '
        'late REFUSED answer is discarded, the new calm line stands',
        () async {
      await calmRestore();
      b
        ..other = a // the server still serves the OLD key: refused
        ..gate = Completer<void>();
      final tapped = tap(b);
      await pumpEventQueue();
      expect(b.reader.calmHoldState(1), CalmHoldState.checking);

      b.reader.onConnect(false); // clears the holds
      await reoffer(b); // the journal re-offers: a NEW calm hold
      expect(b.reader.calmHoldState(1), CalmHoldState.waiting);
      b.gate!.complete();
      b.gate = null;
      await tapped;

      expect(b.reader.calmHoldState(1), CalmHoldState.waiting);
      expect(b.enc.peersCalmHeld, contains(1));
      expect(b.enc.peersWithChangedIdentity, isEmpty);
    });

    // ---- The drain after the tap fails, stalls or is slow (2b) ----

    /// A tap whose drain is [drain] (what the app wires, replaced).
    Future<void> tapWithDrain(
      _Side side,
      Future<void> Function() drain, {
      bool awaitDrain = true,
    }) async {
      Future<void>? running;
      side.enc.onHeldFramesReleased = (_) => running = drain();
      await side.reader.confirmCalmHold(side.peerId);
      await pumpEventQueue();
      if (awaitDrain && running != null) {
        try {
          await running;
        } on Object {
          // a drain that throws is the case under test
        }
      }
      await pumpEventQueue();
    }

    test('2b-a: the drain throws and no handoff was learned: the message '
        'keeps waiting, nothing is written to the old queue, the tap does '
        'not throw, and the handoff read later releases it', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('stuck');

      await tapWithDrain(b, () async => throw StateError('drain broke'));

      expect(outbox.delivered, isEmpty, reason: 'the old queue is not used');
      expect(_waits(b.reader, row.tempId), isTrue);
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);

      await reoffer(b);

      expect(outbox.delivered, hasLength(1));
      expect(outbox.delivered.single.$1.sid, restored.sid);
    });

    test('2b-a2: the drain throws AFTER the handoff was learned: the message '
        'goes out once, to the learned queue', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      await writeFromB('learned');

      await tapWithDrain(b, () async {
        await reoffer(b);
        throw StateError('late failure');
      });

      expect(outbox.delivered, hasLength(1));
      expect(outbox.delivered.single.$1.sid, restored.sid);
    });

    test('2b-b: the drain never completes: the message keeps waiting, '
        'nothing is written to the old queue, and the handoff read later '
        'releases it (no dependence on the end of the drain)', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('stalled');

      await tapWithDrain(
        b,
        () => Completer<void>().future,
        awaitDrain: false,
      );

      expect(outbox.delivered, isEmpty);
      expect(_waits(b.reader, row.tempId), isTrue);

      await reoffer(b); // the handoff is read some other way

      expect(outbox.delivered, hasLength(1));
      expect(outbox.delivered.single.$1.sid, restored.sid);
      expect(_waits(b.reader, row.tempId), isFalse);
    });

    test('2b-c: a slow drain that completes within the bound: the message '
        'is released once, to the learned queue', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      await writeFromB('slow');

      await tapWithDrain(b, () async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await reoffer(b);
      });

      expect(outbox.delivered, hasLength(1));
      expect(outbox.delivered.single.$1.sid, restored.sid);
    });

    // ---- While the drain runs, the friend's handoff is not read yet: the
    // old queue is still the address, so nothing is sent (P1-1) ----

    test('P1-1a: a message typed while the drain runs waits too, and goes '
        'out once, after the earlier one, to the LEARNED queue', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      await writeFromB('earlier');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      var during = -1;

      await tapWithDrain(b, () async {
        await writeFromB('typed during the drain');
        during = outbox.delivered.length;
        await reoffer(b);
      });

      expect(during, 0, reason: 'nothing on the old queue meanwhile');
      expect(outbox.delivered, hasLength(2));
      expect(
        outbox.delivered.map((d) => d.$1.sid),
        everyElement(restored.sid),
      );
      final read = [
        for (final (_, f) in outbox.delivered) await readByRestored(restored, f),
      ];
      expect(read[0], contains('earlier'));
      expect(read[1], contains('typed during the drain'));
    });

    test('P1-1b: Retry on a held row while the drain runs stays held: the '
        'row keeps its waiting text and nothing is sent', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('held');
      var waits = false;
      var during = -1;

      await tapWithDrain(b, () async {
        waits = _waits(b.reader, row.tempId);
        await b.reader.retryFailedMessage(row.tempId!);
        await pumpEventQueue();
        during = outbox.delivered.length;
        await reoffer(b);
      });

      expect(waits, isTrue);
      expect(during, 0);
      expect(outbox.delivered, hasLength(1), reason: 'once, after the drain');
      expect(outbox.delivered.single.$1.sid, restored.sid);
    });

    test('P1-1c: typing and a receipt while the drain runs are not written '
        'to the old queue', () async {
      await calmRestore();
      final outbox = await boxForB();
      b.reader.receiptsAndTyping = () => true;
      var during = -1;

      await tapWithDrain(b, () async {
        b.reader.sendTypingIndicator(1, 10);
        await pumpEventQueue();
        during = outbox.delivered.length;
        await reoffer(b);
      });

      expect(during, 0);
    });

    test('P3-2: the release stops at the first row that does not end sent: '
        'the later row is never sent ahead of it and stays failed',
        () async {
      await calmRestore();
      final outbox = await boxForB();
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = await writeFromB('second');
      outbox.beforeDeliver = (call) async {
        if (call == 0) outbox.refuse.add(1); // the box refuses the first
      };

      await tap(b);

      expect(outbox.delivered, hasLength(1), reason: 'only the first tried');
      expect(
        b.reader.messages
            .singleWhere((m) => m.tempId == second.tempId)
            .deliveryStatus,
        MessageDeliveryStatus.failed,
      );
    });

    // ---- Slice 2b: the named window regressions of the write gate. Each
    // asserts the QUEUE: nothing is written to the OLD queue, and the message
    // arrives exactly once on the NEW one after the handoff is read ----

    /// The person's Retry of [row], settled.
    Future<void> retry(MessageModel row) async {
      await b.reader.retryFailedMessage(row.tempId!);
      await pumpEventQueue();
    }

    MessageModel rowOf(String text) =>
        b.reader.messages.lastWhere((m) => m.content == text);

    /// Nothing is on the old queue; each of [texts] arrived exactly once on
    /// the new queue, and nothing else did; the restored install READS them
    /// (each frame is decrypted once: Signal refuses a replay).
    Future<void> arrivedOnceOnNew(
      SendOutbox outbox,
      _Side restored,
      List<String> texts,
    ) async {
      expect(onOld(outbox), isEmpty, reason: 'nothing on the old queue');
      final read = [
        for (final f in onNew(outbox, restored))
          await readByRestored(restored, f),
      ];
      expect(read, hasLength(texts.length), reason: 'once each: $read');
      for (final text in texts) {
        expect(
          read.where((r) => r.contains(text)),
          hasLength(1),
          reason: '"$text" arrives exactly once on the new queue (got $read)',
        );
      }
    }

    test('encryptForFriend without a permit seals nothing', () async {
      expect(await a.reader.encryptForFriend(5, 3, '{"t":"x"}'), isNull);
      expect(
        E2eDiagLog.entries.where((e) => e.contains('BOX_FRIEND_NO_PERMIT')),
        isNotEmpty,
      );
    });

    test('window 1: released before the drain', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final held = await writeFromB('held row');
      var during = -1;
      b.enc.beforeDrain = () async {
        // The key is confirmed and the hold is gone, but the drain has not
        // read the handoff: the stored address is the old queue.
        await writeFromB('typed before the drain');
        await retry(held);
        during = outbox.delivered.length;
      };

      await tap(b);

      expect(during, 0, reason: 'nothing written before the drain');
      await arrivedOnceOnNew(outbox, restored, [
        'held row',
        'typed before the drain',
      ]);
    });

    for (final retrying in [false, true]) {
      test('window 2: guard off during the drain: '
          '${retrying ? 'a Retry' : 'a new send'}', () async {
        final restored = await calmRestore();
        final outbox = await boxForB();
        final held = await writeFromB('held row');
        var during = -1;

        await tapWithDrain(b, () async {
          if (retrying) {
            await retry(held);
          } else {
            await writeFromB('typed during the drain');
          }
          during = outbox.delivered.length;
          await reoffer(b);
        });

        expect(during, 0, reason: 'nothing written while the drain runs');
        await arrivedOnceOnNew(outbox, restored, [
          'held row',
          if (!retrying) 'typed during the drain',
        ]);
      });
    }

    for (final neverEnds in [true, false]) {
      for (final retrying in [false, true]) {
        test('window 3a: the drain ${neverEnds ? 'never ends' : 'throws'} '
            'with the handoff unread: '
            '${retrying ? 'a Retry' : 'a new send'}', () async {
          final restored = await calmRestore();
          final outbox = await boxForB();
          final held = await writeFromB('held row');

          await tapWithDrain(
            b,
            () => neverEnds
                ? Completer<void>().future
                : Future<void>.error(StateError('drain broke')),
            awaitDrain: !neverEnds,
          );

          // Nothing depends on the end of the drain: the rows keep waiting
          // (a Retry on one only kicks the pump) and the new send joins.
          if (retrying) {
            await retry(held);
          } else {
            await writeFromB('typed after');
          }
          expect(onOld(outbox), isEmpty, reason: 'the old queue stays unused');
          expect(outbox.delivered, isEmpty);
          expect(_waits(b.reader, held.tempId), isTrue);

          // The journal's re-offer reads the handoff later: the pump sends.
          await reoffer(b);

          await arrivedOnceOnNew(outbox, restored, [
            'held row',
            if (!retrying) 'typed after',
          ]);
        });
      }
    }

    /// A send that is mid-flight (it waits for the own device list) when the
    /// hold lands: the route it read holds the OLD address. [stage] says
    /// when its lookup finishes.
    Future<void> midFlightSend(String stage) async {
      onTheBox();
      final restored = await restoreA();
      final lookup = Completer<void>();
      b.enc.onForcedLookup = () => lookup.future;
      final outbox = await boxForB();
      b.reader.sendMessage('mid-flight');
      await pumpEventQueue();
      expect(outbox.delivered, isEmpty, reason: 'it waits for the own list');

      void release() => lookup.complete();
      await restored.link.restart();
      await pump(); // the hold lands
      expectCalm(b);
      switch (stage) {
        case 'pending':
          release();
          await pumpEventQueue();
          expect(outbox.delivered, isEmpty);
          await tap(b);
        case 'between':
          b.enc.beforeDrain = () async {
            release();
            await pumpEventQueue();
          };
          await tap(b);
        default:
          await tap(b);
          expect(b.link.learned, restored.sid, reason: 'handoff read');
          release();
          await pumpEventQueue();
      }

      expect(onOld(outbox), isEmpty, reason: 'nothing on the old queue');
      final row = rowOf('mid-flight');
      if (row.deliveryStatus == MessageDeliveryStatus.failed) await retry(row);
      await arrivedOnceOnNew(outbox, restored, ['mid-flight']);
    }

    test(
      'window 3b: address read before the guard',
      () => midFlightSend('after'),
    );

    test(
      'window 3b: address read before the guard, hold pending',
      () => midFlightSend('pending'),
    );

    test(
      'window 3b: address read before the guard, between the tap and the '
      'handoff',
      () => midFlightSend('between'),
    );

    // ---- The red bar never holds a send (owner reversal 2026-11-27) ----

    /// The red bar is up for B: its friend came back under a new identity
    /// and warnings are ON (the visible hold). B still has the OLD identity
    /// pinned, so the old queue is the address the app has.
    Future<_Side> redRestore() async {
      b.enc.keyChangeWarnings = () => true;
      onTheBox();
      final restored = await restoreA();
      await restored.link.restart();
      await pump();
      expectRed(b);
      return restored;
    }

    test('RED1: a message written while the red bar is up is SENT, to the '
        'queue of the identity the app has pinned (the old queue), as on '
        '0.2.111: not waiting, no lookup, no bundle fetch', () async {
      final restored = await redRestore();
      final outbox = await boxForB();

      final row = await writeFromB('during the red bar');

      expect(outbox.delivered, hasLength(1), reason: 'sent once');
      expect(onOld(outbox), hasLength(1), reason: "the pinned identity's queue");
      expect(onNew(outbox, restored), isEmpty);
      expect(b.emits, isEmpty);
      expect(b.enc.lookupLog, isEmpty);
      expect(_waits(b.reader, row.tempId), isFalse);
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
      expectRed(b);
    });

    test('RED2: two rows under the red bar go to the old queue in order; '
        'after the accept a row typed before the handoff read waits (the '
        'address is stale), and goes to the NEW queue once it is read; the '
        'first two are not sent again', () async {
      final restored = await redRestore();
      final outbox = await boxForB();
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      expect(onOld(outbox), hasLength(2), reason: 'both under the bar');

      expect(await b.enc.acknowledgePeerIdentity(b.peerId), isTrue);
      await b.enc.ensureSession(b.peerId, deviceId: b.peerDevice);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final third = await writeFromB('third');
      expect(outbox.delivered, hasLength(2), reason: 'stale address: waits');
      expect(_waits(b.reader, third.tempId), isTrue);
      expect(b.reader.sendWaitReason(third), SendWaitReason.other);

      await reoffer(b); // the handoff is read: the pump sends

      expect(onOld(outbox), hasLength(2), reason: 'nothing more on the old');
      final frames = onNew(outbox, restored);
      expect(frames, hasLength(1), reason: 'once, nowhere else');
      expect(await readByRestored(restored, frames.single), contains('third'));
    });

    test('a REFUSED tap lets the rows that waited for the calm line go out '
        '(decision: the pinned identity is unchanged, so its queue is '
        'still current): once each, in order, to the pinned queue, and a '
        'row typed after the refusal goes at once; the later accept and '
        'the handoff read send none of them again', () async {
      await calmRestore();
      final outbox = await boxForB();
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      expect(outbox.delivered, isEmpty, reason: 'the calm line holds them');
      b.enc.keyChangeWarnings = () => true; // no longer eligible: refused

      await tap(b);

      expectRed(b);
      expect(onOld(outbox), hasLength(2), reason: 'once each, pinned queue');
      expect(outbox.delivered, hasLength(2));
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
      final third = await writeFromB('third'); // typed after the refusal
      expect(onOld(outbox), hasLength(3), reason: 'goes at once');
      expect(_waits(b.reader, third.tempId), isFalse);

      expect(await b.enc.acknowledgePeerIdentity(b.peerId), isTrue);
      await b.enc.ensureSession(b.peerId, deviceId: b.peerDevice);
      await pumpEventQueue();
      await reoffer(b);

      expect(outbox.delivered, hasLength(3), reason: 'none sent again');
    });

    test('RED3: never accepted: every kick, a reconnect, a list refresh '
        'and the journal offered again send the row exactly once (to the '
        'pinned queue) and nothing again', () async {
      await redRestore();
      final outbox = await boxForB();
      final row = await writeFromB('never accepted');
      expect(onOld(outbox), hasLength(1));

      for (var i = 0; i < 3; i++) {
        b.reader
          ..kickSendPumps()
          ..kickSendPump(1);
        await pumpEventQueue();
        await reoffer(b);
      }
      expect(b.enc.lookupLog, isEmpty, reason: 'a kick asks nobody');
      expect(b.emits, isEmpty);

      for (var i = 0; i < 3; i++) {
        b.reader
          ..onConnect(true)
          ..refreshBoxDeviceLists();
        await pumpEventQueue();
        await reoffer(b);
      }

      expect(outbox.delivered, hasLength(1), reason: 'once, never again');
      expect(_waits(b.reader, row.tempId), isFalse);
      expectRed(b);
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
    });

    test('RED4: a restart while red: the persisted warning does not hold a '
        'send; only the unjudged journal does, and then the row goes once to '
        'the pinned queue', () async {
      await redRestore();
      var outbox = await boxForB();
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('e2e_5_peer_identity_changed_v1')!),
        contains(1),
        reason: 'the warning set is persisted',
      );

      b.reader.dispose();
      b.reader = newReader(b);
      outbox = (await boxForB())..judged = false;
      await writeFromB('after the restart');
      expect(outbox.delivered, isEmpty, reason: 'journal not judged yet');

      outbox.judged = true;
      b.reader.kickSendPumps();
      await pumpEventQueue();
      await reoffer(b);

      expectRed(b);
      expect(onOld(outbox), hasLength(1), reason: 'once, pinned queue');
      expect(outbox.delivered, hasLength(1));
    });

    test('RED5: background frames under the red bar are sealed as before '
        'the bar: the gate does not stop them', () async {
      await redRestore();
      await boxForB();
      b.reader.receiptsAndTyping = () => true;

      final plain = await b.reader.sealForFriend(1, 1, '{"t":"x"}');

      expect(plain, isNotNull);
      expect(b.emits, isEmpty);
      expect(b.enc.lookupLog, isEmpty);
    });

    test('RED6: an ordinary failed row (the box refused it, no red bar) is '
        'unchanged: failed, not waiting, with Retry', () async {
      onTheBox();
      final outbox = await boxForB();
      outbox.refuse.add(1);

      final row = await writeFromB('refused by the box');

      expect(outbox.delivered, hasLength(1), reason: 'the gate was open');
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(_waits(b.reader, row.tempId), isFalse);
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
      expect(b.enc.peersWithChangedIdentity, isEmpty);
    });

    test('RED7: the send-path mismatch (a session build bounces on the '
        'anchor, warnings ON) raises the red bar; the next message is NOT '
        'held by it: the gate lets it through (it ends as an ordinary '
        'failed row, no session, with Retry; nothing is written)', () async {
      onTheBox();
      b.enc.keyChangeWarnings = () => true;
      final restored = await restoreA();
      final outbox = await boxForB();
      b.enc.markSessionRebuild(b.peerId, deviceId: b.peerDevice);

      await expectLater(
        b.enc.ensureSession(b.peerId, deviceId: b.peerDevice),
        throwsA(isA<AccountIdentityMismatch>()),
      );
      expect(b.enc.peersWithChangedIdentity, contains(b.peerId));
      expect(b.enc.peersRefusedIdentity, contains(b.peerId));
      expect(restored.sid, isNot(a.sid));

      final row = await writeFromB('after the bounce');

      expect(b.reader.sendWaitReason(row), SendWaitReason.other);
      expect(b.reader.sendRefusedForIdentity(row.tempId), isFalse);
      expect(_waits(b.reader, row.tempId), isFalse, reason: 'not a waiting row');
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(outbox.delivered, isEmpty, reason: 'no usable session to seal on');
      expect(await b.enc.boxUnsentWaiting(b.userId), isEmpty);
    });

    // ---- Decision B: a friend whose identity is re-minted while it KEEPS
    // its queues and sid. The restored install holds the same queue sid and
    // re-announces it (its handoff of the SAME sid, under the new identity);
    // the receiver re-tags that address instead of replacing it ----

    /// The kept-queue friend: a new identity, the SAME queue sid, the
    /// contact (B's queue) kept; its re-announce reaches B.
    Future<_Side> keptRestore() async {
      onTheBox();
      final restored = await restoreA(sid: a.sid);
      expect(restored.sid, a.sid, reason: 'the queue is kept');
      await restored.link.restart(); // the re-announce of the same queue
      await pump();
      return restored;
    }

    /// Frames written to the queue [sid].
    List<BoxFrame> onSid(SendOutbox o, String sid) => [
      for (final (to, frame) in o.delivered)
        if (to.sid == sid) frame,
    ];

    test('KEPT1 (calm): the re-announce under the new identity is held '
        'calmly; after the tap the address is re-tagged and the waiting '
        'messages go to that SAME sid, once each, in order, with no lookup',
        () async {
      final restored = await keptRestore();
      expectCalm(b);
      final outbox = await boxForB();
      expect(outbox.addressesFor(1)[1]!.sid, a.sid);
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      expect(outbox.delivered, isEmpty, reason: 'the tag is stale: it waits');

      await tap(b);

      expect(outbox.delivered, hasLength(2), reason: 'once each, nowhere else');
      expect(onSid(outbox, a.sid), hasLength(2), reason: 'the SAME sid');
      expect(b.link.learned, a.sid);
      expect(b.link.learnedIdk, await idOf(restored), reason: 're-tagged');
      final read = [
        for (final (_, frame) in outbox.delivered)
          await readByRestored(restored, frame),
      ];
      expect(read[0], contains('first'));
      expect(read[1], contains('second'));
      expect(b.enc.lookupLog, isEmpty);
      expect(b.enc.forcedLookups, isEmpty);
    });

    test('KEPT2 (red): under the bar the rows are SENT to the kept sid '
        '(its tag is the pinned identity: still current), once each; after '
        'the accept a row waits until the re-announce is read and then goes '
        'to that SAME sid, and the restored install reads it', () async {
      b.enc.keyChangeWarnings = () => true;
      final restored = await keptRestore();
      expectRed(b);
      final outbox = await boxForB();
      await writeFromB('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('second');
      expect(onSid(outbox, a.sid), hasLength(2), reason: 'the red bar holds nothing');

      expect(await b.enc.acknowledgePeerIdentity(b.peerId), isTrue);
      await b.enc.ensureSession(b.peerId, deviceId: b.peerDevice);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await writeFromB('third');
      expect(outbox.delivered, hasLength(2), reason: 'the tag is stale until read');

      await reoffer(b); // the re-announce is read: the address is re-tagged

      expect(outbox.delivered, hasLength(3), reason: 'once each');
      expect(onSid(outbox, a.sid), hasLength(3), reason: 'the SAME sid');
      expect(b.link.learnedIdk, await idOf(restored));
      expect(
        await readByRestored(restored, outbox.delivered.last.$2),
        contains('third'),
      );
      // The acknowledge's own "by person" invalidation is the person's act;
      // no lookup was made for it, for a hold, a send or the pump.
      expect(b.enc.lookupLog.where((e) => e == 'lookup'), isEmpty);
      expect(b.enc.forcedLookups, isEmpty);
    });

    test('KEPT3: a re-announce of an unchanged queue under an unchanged '
        'identity changes nothing on the receiver and is acked', () async {
      onTheBox();
      final outbox = await boxForB();
      final before = (
        learned: b.link.learned,
        idk: b.link.learnedIdk,
        anchor: await anchorOfA(),
      );
      // The friend's queue goes due again (what `reannounceOwn` does) and
      // its pass hands the SAME sid.
      a.link
        ..acked = false
        ..handedAt = null;

      await a.link.reconnect();
      await pump();

      expect(b.link.learned, before.learned);
      expect(b.link.learned, a.sid);
      expect(b.link.learnedIdk, anyOf(before.idk, before.anchor));
      expect(await anchorOfA(), before.anchor, reason: 'no anchor moved');
      expect(b.held, isEmpty);
      expect(b.reader.hasCalmHold(1), isFalse);
      expect(b.enc.peersWithChangedIdentity, isNot(contains(1)));
      expect(b.refusals, isEmpty);
      expect(b.emits, isEmpty, reason: 'no bundle fetch');
      expect(b.enc.lookupLog, isEmpty);
      expect(a.link.acked, isTrue, reason: 'the friend acked it');
      // The gate stays open: a message goes to the same sid at once.
      await writeFromB('after the re-announce');
      expect(outbox.delivered, hasLength(1));
      expect(onSid(outbox, a.sid), hasLength(1));
      expect(
        await a.enc.encryptionService.decrypt(
          5,
          outbox.delivered.single.$2.signalCiphertext,
          deviceId: 3,
        ),
        contains('after the re-announce'),
      );
    });

    test('sealed before accept, written after', () async {
      onTheBox();
      // The friend reinstalled and kept its queue: the same address, learned
      // again under the new identity (the re-tag), so the stale-tag clause
      // has nothing to say; only the permit's identity can refuse.
      final restored = await restoreA(sid: a.sid);
      final outbox = await boxForB();
      b.enc
        ..afterSeal = Completer<void>()
        ..sealing = Completer<void>();
      b.reader.sendMessage('sealed under the old key');
      await b.enc.sealing!.future; // sealed, not written

      await restored.link.restart();
      await pump();
      await tap(b); // accepted; the handoff re-tags the same queue
      expect(b.link.learnedIdk, await idOf(restored));
      b.enc.afterSeal!.complete();
      b.enc.afterSeal = null;
      await pumpEventQueue();

      expect(outbox.delivered, isEmpty, reason: 'sealed under the old key');
      final row = rowOf('sealed under the old key');
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      await retry(row);
      expect(outbox.delivered, hasLength(1));
      expect(
        await readByRestored(restored, outbox.delivered.single.$2),
        contains('sealed under the old key'),
      );
    });

    test('sealed before the calm hold, written during it', () async {
      onTheBox();
      final restored = await restoreA();
      final outbox = await boxForB();
      b.enc
        ..afterSeal = Completer<void>()
        ..sealing = Completer<void>();
      b.reader.sendMessage('sealed before the hold');
      await b.enc.sealing!.future;

      await restored.link.restart();
      await pump(); // the hold lands while the frame is sealed
      expectCalm(b);
      b.enc.afterSeal!.complete();
      b.enc.afterSeal = null;
      await pumpEventQueue();

      expect(outbox.delivered, isEmpty, reason: 'not written during the hold');
      await tap(b);
      final row = rowOf('sealed before the hold');
      if (row.deliveryStatus == MessageDeliveryStatus.failed) await retry(row);
      await arrivedOnceOnNew(outbox, restored, ['sealed before the hold']);
    });

    test('F7b: the account switches while the session is built: the key IS '
        'accepted, but the calm hold is not released under the new account',
        () async {
      final restored = await calmRestore();
      b.enc.encryptionService.debugBeforeAutoAcceptSwap =
          () async => b.enc.onConnect(false);

      await tap(b);

      expect(await anchorOfA(), await idOf(restored), reason: 'accepted');
      expect(
        E2eDiagLog.entries.where((e) => e.contains('CALM_CONFIRMED')),
        isEmpty,
      );

    });

    test('F6b: the hold was replaced while the eligibility check waited: its '
        'late "not eligible" answer is discarded, the new calm line stands',
        () async {
      await calmRestore();
      b.enc.onEligibility = () async {
        b.reader.onConnect(false); // clears the hold
        await reoffer(b); // a NEW calm hold
        b.enc.keyChangeWarnings = () => true; // now the old tap sees "no"
      };

      await tap(b);

      expect(b.reader.calmHoldState(1), CalmHoldState.waiting);
      expect(b.enc.peersWithChangedIdentity, isEmpty);
    });

    test('a frame of the key the anchor already reached settles the hold '
        'and drops what waited: a later calm hold does not claim that row',
        () async {
      final restored = await calmRestore();
      await boxForB();
      final row = await writeFromB('stale');
      expect(_waits(b.reader, row.tempId), isTrue);
      // The key is confirmed some other way than the provider's tap.
      expect(
        await b.enc.confirmCalmKey(
          1,
          1,
          await idOf(restored),
          noteAtMs: 0,
        ),
        CalmConfirm.confirmed,
      );

      await reoffer(b); // the held frame now matches: the hold is settled
      expect(b.reader.calmHoldState(1), isNull);
      b.emits.clear(); // the direct confirm above fetched a bundle
      await handOffFrom(a); // the OLD key again: a new calm hold
      expectCalm(b);

      expect(_waits(b.reader, row.tempId), isFalse);
    });

    test('K211: the anchor reached the key that waits (address re-tagged, '
        'nothing else moves); a PreKey frame of that key with NO handoff '
        'settles the hold, and only the pump kick of that settle releases the '
        'waiting row, once', () async {
      final restored = await calmRestore();
      final outbox = await boxForB();
      final row = await writeFromB('waits for the settle');
      expect(_waits(b.reader, row.tempId), isTrue);
      expectCalm(b);

      // The key is confirmed some other way than the provider's tap, and the
      // address already carries it: the calm hold is the ONLY thing closing
      // the gate. Nothing wires a kick for this (no anchor-moved callback).
      expect(
        await b.enc.confirmCalmKey(1, 1, await idOf(restored), noteAtMs: 0),
        CalmConfirm.confirmed,
      );
      b.link.learnedIdk = await idOf(restored);
      await pumpEventQueue(times: 50);
      expect(b.reader.calmHoldState(1), CalmHoldState.waiting);
      expect(_waits(b.reader, row.tempId), isTrue, reason: 'the hold keeps it');
      expect(outbox.delivered, isEmpty);

      // A frame of the restored install, still a PreKey message, carrying no
      // handoff: no handoff is stored, nothing acks, nothing else kicks.
      final frame = (await restored.reader.sealForFriend(
        5,
        3,
        '{"t":"x"}',
      ))!;
      expect(
        frame.signalCiphertext,
        startsWith('${BoxFrameKind.preKey.byte}:'),
        reason: 'a PreKey frame, so the reader judges its identity',
      );
      final entry = BoxInboxEntry(
        rid: 'friend-rid',
        id: 'k211',
        localId: nextLocal++,
        peerUserId: 1,
        senderDeviceId: 1,
        signal: frame.signalCiphertext,
        receivedAt: DateTime.now().toUtc(),
        acked: true,
      );
      // Its payload is of no use here (the reader holds it for a later offer);
      // what matters is the identity judgement that comes BEFORE the decrypt.
      await b.reader.consumeBoxEntry(entry, b.peerRecord);
      await pumpEventQueue(times: 100);

      expect(b.reader.calmHoldState(1), isNull, reason: 'the hold settled');
      expect(outbox.delivered, hasLength(1), reason: 'released, exactly once');
      expect(outbox.delivered.single.$1.sid, b.link.learned);
      expect(_waits(b.reader, row.tempId), isFalse);
    });
  });
}
