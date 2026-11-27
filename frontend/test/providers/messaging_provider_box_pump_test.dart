import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/encryption_provider.dart' show CalmConfirm;
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friend_gate.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../support/box_send_harness.dart';

/// Invariant slice 3a: a message the friend write gate refused WAITS (a
/// persisted `q` row) and one single-flight pump per friend sends it when a
/// state change opens the gate. No timer, no timeout, no "end of drain".
/// The gate here is a switch; the real gate's clauses are the crossing
/// test's and the session tests'.

/// The friend's gate as a switch (`closed`), over the scripted box.
class _SwitchOutbox extends ScriptedSendOutbox implements BoxFriendGateOutbox {
  bool closed = true;

  /// Devices whose stored address is stale: a permit naming one is refused.
  final Set<int> staleDevices = {};

  @override
  FriendPermit? permitFor(
    int friend, {
    Iterable<ContactOutbound> to = const [],
    bool goodbye = false,
  }) => closed || to.any((a) => staleDevices.contains(a.peerDeviceId))
      ? null
      : FriendPermit.ungated(friend);

  @override
  Future<BoxSendOutcome> deliverFriend(
    ContactOutbound to,
    Uint8List body, {
    BoxSendMode? mode,
    FriendPermit? permit,
  }) async => closed
      ? BoxSendOutcome.failed
      : deliver(to, body, mode: mode);

  @override
  Future<BoxResult<BoxMediaRef>> uploadMediaFriend(
    ContactOutbound to,
    Uint8List framed, {
    FriendPermit? permit,
  }) => uploadMedia(to, framed);
}

/// A text with `HUGE` in it seals to more than one frame: it can never go.
class _PumpEncryption extends ScriptedSendEncryption {
  _PumpEncryption(super.store);

  /// A test holds the pump right AFTER it read the waiting records
  /// ([readDone] says it did; the pump goes on when [afterRead] completes).
  Completer<void>? afterRead;
  Completer<void>? readDone;

  /// The re-offer of the held frames fails ([drainReleasedFrames] throws).
  bool drainThrows = false;

  /// The calm tap's eligibility check and key confirmation, as a confirmed
  /// tap (the real ones are the crossing test's).
  @override
  Future<bool> calmHoldEligible(int userId) async => true;

  @override
  Future<CalmConfirm> confirmCalmKey(
    int peerId,
    int deviceId,
    String frameIdentityBase64, {
    required int noteAtMs,
    Duration timeout = const Duration(seconds: 10),
  }) async => CalmConfirm.confirmed;

  @override
  Future<void> drainReleasedFrames(int peerId) async {
    if (drainThrows) throw StateError('re-offer failed');
  }

  @override
  Future<Map<String, Map<String, dynamic>>> boxUnsentWaiting(int userId) async {
    final records = await super.boxUnsentWaiting(userId);
    final gate = afterRead;
    if (gate != null) {
      afterRead = null;
      readDone?.complete();
      await gate.future;
    }
    return records;
  }

  @override
  Future<String> encrypt(
    int recipientId,
    String plaintext, {
    int deviceId = 1,
    bool Function(String? remoteIdentity)? admit,
  }) {
    if (plaintext.contains('HUGE')) {
      encryptCalls.add((recipientId, deviceId));
      return Future.value(
        '3:${base64Encode(Uint8List(BoxFrame.maxSignalBytes + 1))}',
      );
    }
    return super.encrypt(
      recipientId,
      plaintext,
      deviceId: deviceId,
      admit: admit,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BoxSendHarness h;
  late _PumpEncryption encryption;
  late _SwitchOutbox outbox;

  late MessagingProvider provider;

  setUp(() async {
    outbox = _SwitchOutbox();
    h = await BoxSendHarness.create(
      encryption: (store) => encryption = _PumpEncryption(store),
      outbox: outbox,
    );
    provider = h.provider;
    h.bob([1]);
    await h.pump();
  });

  tearDown(() => h.dispose());

  /// The texts written to Bob's queue so far, in order.
  List<String> sent() => [
    for (final (_, frame) in outbox.delivered) utf8.decode(frame.signal),
  ];

  bool has(List<String> texts, String word) =>
      texts.where((t) => t.contains(word)).isNotEmpty;

  Future<void> typed(String text) async {
    provider.sendMessage(text);
    await h.pump();
    // Distinct milliseconds, so the order is the record's `at`.
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }

  MessageModel rowOf(String text) =>
      provider.messages.lastWhere((m) => m.content == text);

  /// A state change opened the gate: the gate switch flips and the pump is
  /// kicked, as the app's wiring does.
  Future<void> open() async {
    outbox.closed = false;
    provider.kickSendPump(2);
    await h.pump(80);
  }

  test('a send the gate refuses WAITS: a failed row that says it waits, the '
      'reason is the calm line only while one is pending, and the record '
      'carries q', () async {
    await typed('one');

    final row = rowOf('one');
    expect(row.deliveryStatus, MessageDeliveryStatus.failed);
    expect(row.waitingToSend, isTrue);
    expect(provider.sendWaitReason(row), SendWaitReason.other);
    provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    expect(provider.sendWaitReason(row), SendWaitReason.calmLineUntapped);
    expect(outbox.delivered, isEmpty);
    expect(encryption.encryptCalls, isEmpty);
    final waiting = await encryption.boxUnsentWaiting(1);
    expect(waiting.keys, [row.tempId]);
  });

  test('the waiting reason: the red bar first, then the untapped calm line, '
      'then any other; it is read live', () async {
    await typed('one');
    final row = rowOf('one');
    expect(provider.sendWaitReason(row), SendWaitReason.other);

    provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    expect(provider.sendWaitReason(row), SendWaitReason.calmLineUntapped);

    encryption.redPeers.add(2);
    expect(
      provider.sendWaitReason(row),
      SendWaitReason.redBarPending,
      reason: 'the red bar wins over an untapped calm line',
    );

    provider.clearCalmHoldForTest(2);
    expect(provider.sendWaitReason(row), SendWaitReason.redBarPending);

    encryption.redPeers.clear();
    expect(
      provider.sendWaitReason(row),
      SendWaitReason.other,
      reason: 'after the accept, while the mailbox is still unknown',
    );
  });

  test('RESTART: the waiting rows survive a new provider on the same '
      'storage, still wait with the chat NOT loaded, and go out by '
      'themselves, in order, to the NEW queue once the gate opens; nothing '
      'was ever written to the old one', () async {
    await typed('one');
    await typed('two');
    expect(outbox.delivered, isEmpty);
    provider.dispose();

    // The app starts again; the friend's queue changed meanwhile (the
    // handoff was read).
    h.provider = h.newProvider();
    provider = h.provider;
    outbox.addresses[2] = {
      1: const ContactOutbound(
        peerDeviceId: 1,
        sid: 'sid-new',
        sealPub: 'seal-new',
        idk: null,
      ),
    };
    provider.refreshBoxDeviceLists(); // the connect's lookups, as at start
    expect(provider.messages, isEmpty, reason: 'the chat is not loaded');
    await h.pump();
    expect(outbox.delivered, isEmpty, reason: 'still waiting, no timer');

    // The gate opens (the friend's handoff was stored) and the REAL
    // start-up kick runs: it finds the stored records, since no chat is
    // loaded to name the friend. No direct `kickSendPump` here.
    outbox.closed = false;
    provider.kickSendPumps();
    await h.pump(80);

    expect(sent(), hasLength(2));
    expect(has([sent()[0]], 'one'), isTrue);
    expect(has([sent()[1]], 'two'), isTrue);
    expect(
      outbox.delivered.map((d) => d.$1.sid),
      everyElement('sid-new'),
      reason: 'the new queue, never the old one',
    );
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
  });

  test('NO TIMER, NO LOOKUP: with the handoff of the friend never read, '
      'every kick except an address store (reconnect, list refresh, box '
      'ready, '
      'journal judged, conversations loaded, E2E ready) leaves the rows '
      'waiting: nothing is written to ANY queue and nothing is looked up',
      () async {
    await typed('one');
    await typed('two');
    final lookups = [...encryption.forcedFetches];
    final emitted = [...h.emitted];

    for (var round = 0; round < 3; round++) {
      provider
        ..refreshBoxDeviceLists() // a reconnect and a finished list refresh
        ..onBoxReady()
        ..kickSendPumps() // journal judged, conversations loaded, E2E ready
        ..kickSendPump(2);
      await h.pump(80);
    }

    expect(outbox.delivered, isEmpty, reason: 'no queue was written');
    expect(outbox.uploads, isEmpty);
    expect(outbox.deletes, isEmpty);
    expect(outbox.modes, isEmpty);
    expect(encryption.forcedFetches, lookups, reason: 'no lookup');
    expect(h.emitted, emitted, reason: 'nothing asked of the server');
    expect(encryption.encryptCalls, isEmpty, reason: 'nothing was sealed');
    expect(rowOf('one').waitingToSend, isTrue);
    expect(rowOf('two').waitingToSend, isTrue);
    expect(
      (await encryption.boxUnsentWaiting(1)).length,
      2,
      reason: 'still on disk',
    );
  });

  test('ORDER: two waiting rows and one typed while the first is going out '
      'arrive 1, 2, 3; a Retry on row 2 meanwhile only kicks: each row is '
      'sealed once', () async {
    await typed('one');
    await typed('two');
    final two = rowOf('two');
    outbox
      ..hold = Completer<void>()
      ..closed = false;
    provider.kickSendPump(2);
    await h.pump(80); // row 1 is in the box's hands

    expect(sent(), hasLength(1));
    await typed('three'); // joins the END of the line, no overtaking
    await provider.retryFailedMessage(two.tempId!);
    await h.pump();
    expect(sent(), hasLength(1), reason: 'nothing overtook row 1');

    outbox.hold!.complete();
    outbox.hold = null;
    await h.pump(120);

    final texts = sent();
    expect(texts, hasLength(3), reason: 'once each: $texts');
    expect(has([texts[0]], 'one'), isTrue);
    expect(has([texts[1]], 'two'), isTrue);
    expect(has([texts[2]], 'three'), isTrue);
    expect(encryption.encryptCalls, hasLength(3), reason: 'each sealed once');
  });

  test('P3-2: the 4 s timeout retry never touches a waiting row: the row keeps '
      'its record WITH q, nothing is sealed, and the pump still sends it',
      () async {
    await typed('one');
    final tempId = rowOf('one').tempId!;
    expect(rowOf('one').waitingToSend, isTrue);

    // The gate opened but the box refuses the write (a passing failure) and
    // the 4 s timer of an earlier failed attempt fires on the waiting row.
    outbox
      ..closed = false
      ..refuse.add(1);
    provider.retrySendInPlaceForTest(tempId);
    await h.pump();

    expect(rowOf('one').waitingToSend, isTrue);
    expect(rowOf('one').deliveryStatus, MessageDeliveryStatus.failed);
    expect(
      (await encryption.boxUnsentWaiting(1)).keys,
      [tempId],
      reason: 'a row that looks waiting has a waiting record',
    );
    await open();
    expect(has(sent(), 'one'), isTrue);
  });

  test('P3-1: a stale address of a device that is NOT live cannot hold the '
      'line: the pump judges the same targets a send uses (the live ones)',
      () async {
    // Device 9 holds an address of ours but is no live device of the friend.
    h.bob([1], addressed: [1, 9]);
    await h.pump();
    await typed('one');
    expect(rowOf('one').waitingToSend, isTrue);
    outbox
      ..closed = false
      ..staleDevices.add(9);
    provider.kickSendPump(2);
    await h.pump(80);

    expect(has(sent(), 'one'), isTrue, reason: 'it goes to the live device');
    expect(rowOf('one').waitingToSend, isFalse);
  });

  test('P424: Retry on an ordinary failed row while the gate is closed joins '
      'the END of the line (a waiting row), it is not attempted', () async {
    outbox
      ..closed = false
      ..refuse.add(1);
    await typed('one');
    expect(rowOf('one').waitingToSend, isFalse, reason: 'an ordinary failure');
    expect(rowOf('one').deliveryStatus, MessageDeliveryStatus.failed);
    outbox
      ..refuse.clear()
      ..closed = true
      ..delivered.clear();

    await provider.retryFailedMessage(rowOf('one').tempId!);
    await h.pump();

    expect(rowOf('one').waitingToSend, isTrue);
    expect(outbox.delivered, isEmpty, reason: 'nothing attempted');
    final record = (await encryption.boxUnsentWaiting(1))[rowOf('one').tempId];
    expect(record, isNotNull);
    expect(record!['qa'], isNotNull, reason: 'it was given a place at the END');
  });

  test('K521: confirming the calm tap kicks the pump: the waiting row goes '
      'with no other state change', () async {
    await typed('one');
    provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    outbox.closed = false;
    expect(outbox.delivered, isEmpty);

    await provider.confirmCalmHold(2);
    await h.pump(80);

    expect(has(sent(), 'one'), isTrue);
    expect(rowOf('one').waitingToSend, isFalse);
  });

  test('P3-5: the unawaited re-offer of the held frames THROWS: the tap '
      'still ends the hold, nothing is stuck, the row keeps waiting and the '
      'next kick releases it', () async {
    await typed('one');
    provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    encryption.drainThrows = true;

    await provider.confirmCalmHold(2);
    await h.pump(20);

    expect(provider.hasCalmHold(2), isFalse, reason: 'the hold ended');
    expect(rowOf('one').waitingToSend, isTrue, reason: 'still waiting');
    expect(outbox.delivered, isEmpty);
    expect((await encryption.boxUnsentWaiting(1)).keys, hasLength(1));

    await open(); // the next state change kicks the pump

    expect(has(sent(), 'one'), isTrue, reason: 'released at the next kick');
    expect(rowOf('one').waitingToSend, isFalse);
  });

  test('P3-3: a RAM-only picture whose upload went but whose frames failed '
      'for a PASSING reason stays WAITING (its record names the box: url): '
      'the next kick sends the frames from it, with no second upload', () async {
    outbox.closed = true;
    final ok = await provider.sendImageMessage(
      XFile.fromData(
        Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
        name: 'a.jpg',
      ),
      2,
    );
    await h.pump();
    expect(ok, isFalse, reason: 'the gate was closed');
    expect(outbox.uploads, isEmpty, reason: 'nothing uploaded for a closed gate');
    final tempId = provider.messages.single.tempId!;
    expect(provider.messages.single.waitingToSend, isTrue);

    // The gate opens, the upload goes, the box refuses the frames: passing.
    outbox.refuse.add(1);
    await open();
    expect(outbox.uploads, hasLength(1));
    var row = provider.messages.single;
    expect(row.waitingToSend, isTrue, reason: 'passing failure: still waiting');
    expect(row.deliveryStatus, MessageDeliveryStatus.failed);

    // The box takes frames again: the next kick sends it, never re-uploads.
    outbox.refuse.clear();
    outbox.delivered.clear();
    provider.kickSendPump(2);
    await h.pump(80);

    row = provider.messages.single;
    expect(outbox.uploads, hasLength(1), reason: 'the file is never re-sent');
    expect(outbox.delivered, isNotEmpty, reason: 'the frames went');
    expect(row.deliveryStatus, MessageDeliveryStatus.sent);
    expect(row.waitingToSend, isFalse);
    expect(row.tempId, tempId);
  });

  test('STRICT ORDER: row 1 fails for a passing reason: row 2 does NOT '
      'overtake it, both stay waiting and go later, in order', () async {
    await typed('one');
    await typed('two');
    outbox.refuse.add(1); // the box refuses the write: a passing failure
    outbox.closed = false;
    provider.kickSendPump(2);
    await h.pump(80);

    expect(has(sent(), 'two'), isFalse, reason: 'two never got ahead of one');
    expect(rowOf('one').waitingToSend, isTrue);
    expect(rowOf('two').waitingToSend, isTrue);

    outbox.refuse.clear();
    outbox.delivered.clear();
    provider.kickSendPump(2);
    await h.pump(80);

    final texts = sent();
    expect(texts, hasLength(2));
    expect(has([texts[0]], 'one'), isTrue);
    expect(has([texts[1]], 'two'), isTrue);
  });

  test('a row that can never go (too long) becomes an ordinary failed row '
      'and the pump goes on with the next', () async {
    await typed('HUGE one');
    await typed('two');
    await open();

    final huge = rowOf('HUGE one');
    expect(huge.deliveryStatus, MessageDeliveryStatus.failed);
    expect(huge.waitingToSend, isFalse);
    expect(has(sent(), 'two'), isTrue);
    expect(rowOf('two').deliveryStatus, MessageDeliveryStatus.sent);
    final waiting = await encryption.boxUnsentWaiting(1);
    expect(waiting, isEmpty, reason: 'the failed one no longer waits');
    expect(
      (await encryption.boxUnsent(1, 10)).keys,
      contains(huge.tempId),
      reason: 'but it is kept on the device, with its own Retry',
    );
  });

  test('DUPLICATE GUARD: a record whose own copy is already stored is '
      'dropped, not sent again', () async {
    // A normal send, stored.
    outbox.closed = false;
    await typed('stored');
    expect(sent(), hasLength(1));
    final stored = rowOf('stored');
    expect(stored.deliveryStatus, MessageDeliveryStatus.sent);
    outbox.delivered.clear();

    // The app died between the store and the drop: its waiting record is
    // still on disk, with the same wire id.
    await encryption.saveBoxUnsent(1, 'temp_dead_1', {
      'c': 10,
      'at': DateTime.now().millisecondsSinceEpoch,
      'w': stored.wireId,
      'type': 'TEXT',
      'content': 'stored',
      'q': 1,
    });
    provider.kickSendPump(2);
    await h.pump(80);

    expect(outbox.delivered, isEmpty, reason: 'not sent again');
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
    expect((await encryption.boxUnsent(1, 10)).keys, isNot(contains('temp_dead_1')));
  });

  test("a waiting row ends with its chat's disappearing timer: the record "
      'of a row past its timer is never sent', () async {
    await encryption.saveBoxUnsent(1, 'temp_old_1', {
      'c': 10,
      'at': DateTime.now().millisecondsSinceEpoch - 120 * 1000,
      'w': 'wire-old-1234',
      'type': 'TEXT',
      'content': 'too late',
      'ttl': 60,
      'q': 1,
    });
    await open();

    expect(outbox.delivered, isEmpty);
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
  });

  test('UNFRIEND: the waiting rows become ordinary failed rows, kept for '
      'their own Retry or delete; nothing is sent', () async {
    await typed('one');
    await typed('two');

    provider.onFriendshipEnded(2, conversationIds: const [10]);
    await h.pump(60);

    for (final text in ['one', 'two']) {
      final row = rowOf(text);
      expect(row.deliveryStatus, MessageDeliveryStatus.failed);
      expect(row.waitingToSend, isFalse);
    }
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
    expect((await encryption.boxUnsent(1, 10)).length, 2);
    await open();
    expect(outbox.delivered, isEmpty, reason: 'no waiting row is left');
  });

  test('ACCOUNT SWITCH mid-release stops the pump: nothing more is sent '
      'for the old account', () async {
    E2eDiagLog.clear(); // the log is process-wide: count this test only
    await typed('one');
    await typed('two');
    outbox
      ..hold = Completer<void>()
      ..closed = false;
    provider.kickSendPump(2);
    await h.pump(80);
    expect(sent(), hasLength(1));

    provider.setCurrentUserId(7); // another account signs in
    outbox.hold!.complete();
    outbox.hold = null;
    await h.pump(120);

    expect(sent(), hasLength(1), reason: 'row two was not sent for account 1');
    expect(
      E2eDiagLog.entries.where((e) => e.contains('BOX_RETRY_NO_ROUTE')),
      isEmpty,
      reason: 'row two was not attempted under the new account: that would '
          'fail it as a row with no route',
    );
    expect(
      E2eDiagLog.entries.where((e) => e.contains('SEND_START')),
      hasLength(3),
      reason: 'two typed rows and the pump send of row one, no more',
    );
    expect(rowOf('two').waitingToSend, isTrue, reason: 'still waiting');
    expect(
      encryption.encryptCalls,
      hasLength(1),
      reason: 'row two was not even sealed for the old account',
    );
  });

  test('DELETE works on a waiting row: its record and row are dropped', () async {
    await typed('one');
    final row = rowOf('one');

    provider.deleteMessage(row.id, forEveryone: false);
    await h.pump();

    expect(provider.messages, isEmpty);
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
    await open();
    expect(outbox.delivered, isEmpty);
  });

  test("DELETE between the pump's read and its send: nothing is sealed or "
      'sent, nothing written, the record stays gone', () async {
    await typed('one');
    final row = rowOf('one');
    final gate = encryption.afterRead = Completer<void>();
    encryption.readDone = Completer<void>();
    outbox.closed = false;
    provider.kickSendPump(2);
    await encryption.readDone!.future; // the pump holds the record now

    provider.deleteMessage(row.id, forEveryone: false);
    gate.complete();
    await h.pump(120);

    expect(outbox.delivered, isEmpty);
    expect(encryption.encryptCalls, isEmpty);
    expect(provider.messages, isEmpty);
    expect(await encryption.boxUnsentWaiting(1), isEmpty);
  });

  test('PRUNE: a waiting row stays past 30 days and past 200 newer '
      'ordinary rows (store-level test in the unsent store test file); the '
      'pump still sends such an old row', () async {
    await encryption.saveBoxUnsent(1, 'temp_ancient_1', {
      'c': 10,
      'at': DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 31).inMilliseconds,
      'w': 'wire-ancient-12',
      'type': 'TEXT',
      'content': 'ancient',
      'q': 1,
    });
    await open();

    expect(has(sent(), 'ancient'), isTrue);
  });
}
