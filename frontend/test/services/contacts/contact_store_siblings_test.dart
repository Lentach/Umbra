import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/services/backup/history_backup.dart';
import 'package:fireplace/services/backup/history_backup_service.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/passcode_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

ContactQueue _queue(int fill) => ContactQueue(
  rid: boxB64(_bytes(32, fill)),
  sid: boxB64(_bytes(32, fill + 1)),
  nid: boxB64(_bytes(16, fill + 2)),
  authPriv: boxB64(_bytes(64, fill + 3)),
  sealPriv: boxB64(_bytes(32, fill + 4)),
  sealPub: boxB64(_bytes(32, fill + 5)),
);

String _sid(int fill) => boxB64(_bytes(32, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;

  ContactStore newStore() => ContactStore(
    open: () async => kv,
    lock: <T>(_, action) => action(),
    accepts: (_) => true,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = newStore();
    await store.open(1);
  });

  Future<ContactStore> reopened() async {
    final again = newStore();
    await again.open(1);
    return again;
  }

  test(
    'the self-queue and every sibling address survive a re-open, in ONE row '
    'outside the contact records',
    () async {
      final self = _queue(0x10);
      expect((await store.claimSelfQueue(self))?.rid, self.rid);
      expect(
        await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41)),
        SiblingWrite.stored,
      );

      final again = await reopened();
      expect(again.selfQueue?.sid, self.sid);
      expect(again.selfQueue?.authPriv, self.authPriv);
      expect(again.siblings.single.deviceId, 2);
      expect(again.siblings.single.sid, _sid(0x40));
      expect(again.siblings.single.sealPub, _sid(0x41));
      expect(again.all, isEmpty, reason: 'no contact record reads it');
      expect(kv.getKeys(), contains(ContactStore.siblingsKey(1)));
      expect(
        kv.getKeys().where((k) => k.startsWith(ContactStore.keyPrefix(1))),
        isEmpty,
      );
    },
  );

  test(
    'a self-queue already on disk (another tab claimed first) is kept and '
    'returned; the candidate is not stored',
    () async {
      final theirs = _queue(0x10);
      final other = newStore();
      await other.open(1);
      await other.claimSelfQueue(theirs);

      final kept = await store.claimSelfQueue(_queue(0x20));
      expect(kept?.rid, theirs.rid);
      expect(store.selfQueue?.rid, theirs.rid);
      expect((await reopened()).selfQueue?.rid, theirs.rid);
    },
  );

  test(
    'dropping the self-queue forgets only that rid, and keeps every sibling '
    'address',
    () async {
      final self = _queue(0x10);
      await store.claimSelfQueue(self);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));

      expect(await store.dropSelfQueue(_queue(0x20).rid), isTrue);
      expect(store.selfQueue?.rid, self.rid, reason: 'a different queue');

      expect(await store.dropSelfQueue(self.rid), isTrue);
      final again = await reopened();
      expect(again.selfQueue, isNull);
      expect(again.siblings.single.sid, _sid(0x40));
    },
  );

  test(
    "a sibling's newer handoff replaces its older address and keeps what it "
    'acknowledged of ours',
    () async {
      final self = _queue(0x10);
      await store.claimSelfQueue(self);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));
      await store.markSiblingAcked(2, self.sid);
      await store.learnSibling(3, sid: _sid(0x50), sealPub: _sid(0x51));

      await store.learnSibling(2, sid: _sid(0x60), sealPub: _sid(0x61));

      final again = await reopened();
      final two = again.siblings.singleWhere((s) => s.deviceId == 2);
      expect(two.sid, _sid(0x60));
      expect(two.sealPub, _sid(0x61));
      expect(two.ackedSelfSid, self.sid);
      expect(again.siblings.map((s) => s.deviceId), unorderedEquals([2, 3]));
    },
  );

  test(
    'an ack counts only for the CURRENT self-queue sid — an ack of a replaced '
    'queue is refused and records nothing',
    () async {
      final old = _queue(0x10);
      await store.claimSelfQueue(old);
      await store.dropSelfQueue(old.rid);
      final current = _queue(0x20);
      await store.claimSelfQueue(current);

      expect(await store.markSiblingAcked(2, old.sid), SiblingWrite.refused);
      expect(store.siblings, isEmpty);

      expect(await store.markSiblingAcked(2, current.sid), SiblingWrite.stored);
      final again = await reopened();
      expect(again.siblings.single.ackedSelfSid, current.sid);
      expect(again.siblings.single.sid, isNull, reason: 'no handoff from it yet');
    },
  );

  test(
    'a row a NEWER build wrote is never overwritten: every write is refused '
    'and nothing is read out of it',
    () async {
      final future = jsonEncode({
        'v': 2,
        'self': _queue(0x10).toJson(),
        'siblings': <Object>[],
      });
      await kv.setString(ContactStore.siblingsKey(1), future);
      final again = await reopened();

      expect(again.siblingsUnsupported, isTrue);
      expect(again.selfQueue, isNull);
      expect(await again.claimSelfQueue(_queue(0x20)), isNull);
      expect(
        await again.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41)),
        SiblingWrite.refused,
      );
      expect(await again.markSiblingAcked(2, _sid(0x11)), SiblingWrite.refused);
      expect(await again.dropSelfQueue(_queue(0x10).rid), isFalse);
      expect(kv.getString(ContactStore.siblingsKey(1)), future);
    },
  );

  test('an unreadable row (garbage, a lost seal key) is replaceable', () async {
    await kv.setString(ContactStore.siblingsKey(1), 'fps1:lost:garbage');
    final again = await reopened();
    expect(again.siblingsUnsupported, isFalse);
    expect(again.selfQueue, isNull);
    final self = _queue(0x10);
    expect((await again.claimSelfQueue(self))?.rid, self.rid);
    expect((await reopened()).selfQueue?.rid, self.rid);
  });

  test(
    'a write queued before a close (a passcode re-lock) never lands, and a '
    'closed store is told to try later',
    () async {
      final pending = store.learnSibling(
        2,
        sid: _sid(0x40),
        sealPub: _sid(0x41),
      );
      store.close();
      expect(await pending, SiblingWrite.retryLater);
      expect(kv.getString(ContactStore.siblingsKey(1)), isNull);
      expect(
        await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41)),
        SiblingWrite.retryLater,
      );
      expect(await store.claimSelfQueue(_queue(0x10)), isNull);
    },
  );

  test(
    'sibling writes never schedule a contact-backup upload: the backup does '
    'not carry this row',
    () async {
      var changes = 0;
      store.onChanged = () => changes++;
      final self = _queue(0x10);
      await store.claimSelfQueue(self);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));
      await store.markSiblingAcked(2, self.sid);
      await store.dropSelfQueue(self.rid);
      await store.settled;
      expect(changes, 0);
    },
  );

  test(
    'the history backup FILE carries neither the self-queue nor any sibling '
    'address',
    () async {
      final self = _queue(0x10);
      await store.claimSelfQueue(self);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));
      Uint8List? file;
      final codec = HistoryBackupCodec(
        kdf: FakePasscodeKdf(),
        sealer: FakeContentSealer(),
      );
      final counts = await HistoryBackupService(
        open: () async => kv,
        codec: codec,
        emit: (bytes, _) async => file = bytes,
      ).exportAndShare(userId: 1, passphrase: 'pw');

      expect(counts, (records: 0, contacts: 0));
      final payload = await codec.open(file!, 'pw');
      final carried = jsonEncode([payload.records, payload.contacts]);
      expect(carried, isNot(contains(self.authPriv)));
      expect(carried, isNot(contains(_sid(0x40))));
    },
  );

  test(
    'a rotation is ONE write — new self, the old one retiring with its '
    'time, siblings outside the live set gone — and survives a re-open',
    () async {
      final old = _queue(0x10);
      final next = _queue(0x20);
      final at = DateTime.utc(2026, 9, 25, 9);
      await store.claimSelfQueue(old);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));
      await store.learnSibling(3, sid: _sid(0x50), sealPub: _sid(0x51));

      expect(
        (await store.rotateSelfQueue(
          next,
          replaces: old.rid,
          live: {1, 2},
          now: at,
        ))?.rid,
        next.rid,
      );

      final again = await reopened();
      expect(again.selfQueue?.rid, next.rid);
      expect(again.retiringSelfQueues.single.queue.authPriv, old.authPriv);
      expect(again.retiringSelfQueues.single.since, at);
      expect(again.siblings.map((s) => s.deviceId), [2]);
    },
  );

  test(
    'a rotation of a self-queue this row no longer holds (another tab '
    'rotated first) is refused and changes nothing',
    () async {
      final current = _queue(0x10);
      await store.claimSelfQueue(current);
      await store.learnSibling(3, sid: _sid(0x50), sealPub: _sid(0x51));

      expect(
        await store.rotateSelfQueue(
          _queue(0x20),
          replaces: _queue(0x30).rid,
          live: {1},
          now: DateTime.utc(2026, 9, 25),
        ),
        isNull,
      );

      final again = await reopened();
      expect(again.selfQueue?.rid, current.rid);
      expect(again.retiringSelfQueues, isEmpty);
      expect(again.siblings.map((s) => s.deviceId), [3]);
    },
  );

  test(
    'a sibling that acked a stale sid forgets what it acked, keeping its '
    'address; a device with no entry gets none',
    () async {
      final current = _queue(0x10);
      await store.claimSelfQueue(current);
      await store.learnSibling(2, sid: _sid(0x40), sealPub: _sid(0x41));
      await store.markSiblingAcked(2, current.sid);

      expect(await store.forgetSiblingAck(2), SiblingWrite.stored);
      expect(await store.forgetSiblingAck(9), SiblingWrite.stored);

      final again = await reopened();
      expect(
        again.siblings.single,
        isA<SiblingAddress>()
            .having((s) => s.deviceId, 'deviceId', 2)
            .having((s) => s.sid, 'sid', _sid(0x40))
            .having((s) => s.ackedSelfSid, 'ackedSelfSid', isNull),
      );
    },
  );
}
