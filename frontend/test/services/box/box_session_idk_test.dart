// The identity tag of a friend's address (invariant decisions, slice 1):
// `ContactOutbound.idk` is the account identity the address was learned
// under. Tags and the anchor mirror only: nothing reads them to decide a send.

import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/utils/e2e_envelope.dart' show E2eProfile;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

const _idkX = 'IDENTITY-X';
const _idkY = 'IDENTITY-Y';

/// Counts the rows written, so "changes nothing" is observable.
class _CountingKv implements ContentKv {
  _CountingKv(this._inner);

  final ContentKv _inner;
  int writes = 0;

  @override
  Future<void> reload() => _inner.reload();

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() =>
      _inner.authoritativeSnapshot();

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Set<String> getKeys() => _inner.getKeys();

  @override
  Future<bool> setString(String key, String value) {
    writes++;
    return _inner.setString(key, value);
  }

  @override
  Future<bool> setInt(String key, int value) {
    writes++;
    return _inner.setInt(key, value);
  }

  @override
  Future<bool> remove(String key) => _inner.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingKv kv;
  late ContactStore store;
  late FakeBoxSockets sockets;
  late BoxSession session;

  /// What the sync anchor mirror answers, by friend.
  final anchors = <int, String?>{};

  String sidOf(int fill) => boxB64(_bytes(32, fill));
  final sealKeys = QueueSeal.mintKeyPair();
  String sealPub() => boxB64(sealKeys.publicKey);

  ContactOutbound addr(int device, int fill, {String? idk, bool rl = false}) =>
      ContactOutbound(
        peerDeviceId: device,
        sid: sidOf(fill),
        sealPub: sealPub(),
        idk: idk,
        relays: rl,
      );

  Future<void> friend(
    int id, {
    List<ContactOutbound> outbound = const [],
    ContactBoxOrigin? origin,
    ContactState state = ContactState.friend,
  }) => store.update(
    id,
    (_) => ContactRecord(
      userId: id,
      username: 'peer$id',
      tag: '0001',
      state: state,
      outbound: outbound,
      boxOrigin: origin,
    ),
  );

  ContactOutbound held(int id, int device) =>
      store.byUserId(id)!.outbound.singleWhere((o) => o.peerDeviceId == device);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    anchors.clear();
    kv = _CountingKv(await PrefsContentKv.open());
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    var n = 0;
    sockets = FakeBoxSockets()
      ..respond = (_, f) => switch (f.event) {
        'createQueue' => {
          'ok': true,
          'rid': boxB64(_bytes(32, 0x10 + ++n)),
          'sid': boxB64(_bytes(32, 0x60 + n)),
          'nid': boxB64(_bytes(16, 0x20 + n)),
        },
        'subscribe' => {'ok': true, 'refused': <Object?>[]},
        _ => {'ok': true},
      };
    session = BoxSession(
      box: BoxClient(
        baseUrl: 'http://box.test',
        socketFactory: sockets.call,
        httpClient: MockClient((_) async => throw StateError('no http')),
      ),
      store: store,
      emit: (_, _) {},
      seal: QueueSeal(cipher: PointyGcmSealer()),
      anchorOf: (peer) => anchors[peer],
    )..start();
    sockets.last.serverConnect('S1');
    await pumpEventQueue();
  });

  tearDown(() => session.dispose());

  group('a handoff stores the identity it was learned under', () {
    test('stored under X, the address is tagged X', () async {
      await friend(5);
      anchors[5] = _idkX;

      final taken = await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x70),
        sealPub: sealPub(),
        learnedUnder: _idkX,
      );

      expect(taken, FriendWrite.stored);
      expect(held(5, 3).idk, _idkX);
      expect(held(5, 3).sid, sidOf(0x70));
    });

    test('the SAME queue re-announced under Y after the anchor moved is '
        're-tagged Y (the shortcut compares the tag too)', () async {
      await friend(5);
      anchors[5] = _idkX;
      await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x70),
        sealPub: sealPub(),
        learnedUnder: _idkX,
      );
      final writes = kv.writes;

      // Same sid and key again under X: nothing to write.
      await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x70),
        sealPub: sealPub(),
        learnedUnder: _idkX,
      );
      expect(kv.writes, writes, reason: 'an identical handoff is a no-op');

      anchors[5] = _idkY;
      final taken = await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x70),
        sealPub: sealPub(),
        learnedUnder: _idkY,
      );

      expect(taken, FriendWrite.stored);
      expect(held(5, 3).idk, _idkY);
      expect(held(5, 3).sid, sidOf(0x70));
    });

    test('a handoff learned under another identity than the pinned anchor is '
        'finished and stores nothing', () async {
      await friend(5, outbound: [addr(3, 0x70, idk: _idkY)]);
      anchors[5] = _idkY;
      final writes = kv.writes;

      final taken = await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x71),
        sealPub: sealPub(),
        learnedUnder: _idkX,
      );

      expect(taken, FriendWrite.refused);
      expect(held(5, 3).sid, sidOf(0x70), reason: 'the current address stays');
      expect(held(5, 3).idk, _idkY);
      expect(kv.writes, writes);
    });

    test('no anchor pinned yet: the handoff is stored, tagged with what it '
        'was learned under', () async {
      await friend(5);

      final taken = await session.takeFriendHandoff(
        5,
        3,
        sid: sidOf(0x70),
        sealPub: sealPub(),
        learnedUnder: _idkX,
      );

      expect(taken, FriendWrite.stored);
      expect(held(5, 3).idk, _idkX);
    });

    test('a first contact accept tags the address and refuses a foreign '
        'identity the same way', () async {
      await friend(5);
      anchors[5] = _idkX;
      const E2eProfile profile = (
        username: 'me',
        tag: '0001',
        avatarUrl: null,
        avatar: null,
      );

      expect(
        await session.acceptFirstContact(
          5,
          3,
          sid: sidOf(0x70),
          sealPub: sealPub(),
          profile: profile,
          learnedUnder: _idkY,
        ),
        FriendWrite.refused,
      );
      expect(store.byUserId(5)!.outbound, isEmpty);

      expect(
        await session.acceptFirstContact(
          5,
          3,
          sid: sidOf(0x70),
          sealPub: sealPub(),
          profile: profile,
          learnedUnder: _idkX,
        ),
        FriendWrite.stored,
      );
      expect(held(5, 3).idk, _idkX);
    });

    test('friendRelays changing relays keeps the tag', () async {
      await friend(5, outbound: [addr(3, 0x70, idk: _idkX)]);

      await session.friendRelays(5, 3, relays: true);

      expect(held(5, 3).relays, isTrue);
      expect(held(5, 3).idk, _idkX);
      expect(held(5, 3).sid, sidOf(0x70));
    });
  });

  group('the migration and the stamp', () {
    test('untagged + pinned anchor -> tagged; untagged + no anchor -> left '
        'for its first pin; a second run changes nothing', () async {
      await friend(5, outbound: [addr(3, 0x70), addr(4, 0x71, idk: _idkY)]);
      await friend(
        6,
        outbound: [addr(3, 0x72)],
        origin: ContactBoxOrigin(at: DateTime.utc(2026), addresses: [addr(3, 0x73)]),
      );
      await friend(7, outbound: [addr(3, 0x74)]);
      anchors
        ..[5] = _idkX
        ..[6] = _idkX; // 7 has no anchor yet

      expect(await store.tagUntaggedAddresses((p) => anchors[p]), isTrue);

      expect(held(5, 3).idk, _idkX);
      expect(held(5, 4).idk, _idkY, reason: 'a tag already there is kept');
      expect(held(6, 3).idk, _idkX);
      expect(store.byUserId(6)!.boxOrigin!.addresses.single.idk, _idkX);
      expect(held(7, 3).idk, isNull);

      final writes = kv.writes;
      expect(await store.tagUntaggedAddresses((p) => anchors[p]), isTrue);
      expect(kv.writes, writes, reason: 'idempotent: nothing left to tag');

      // The first pin of friend 7 tags it.
      anchors[7] = _idkY;
      expect(await store.stampUntaggedAddresses(7, _idkY), isTrue);
      expect(held(7, 3).idk, _idkY);
    });

    test('a migration killed half way leaves the rest for the next run',
        () async {
      await friend(5, outbound: [addr(3, 0x70)]);
      await friend(6, outbound: [addr(3, 0x72)]);
      anchors
        ..[5] = _idkX
        ..[6] = _idkX;
      // Only friend 5 got through before the "kill".
      expect(await store.stampUntaggedAddresses(5, _idkX), isTrue);
      expect(held(6, 3).idk, isNull);

      expect(await store.tagUntaggedAddresses((p) => anchors[p]), isTrue);

      expect(held(5, 3).idk, _idkX);
      expect(held(6, 3).idk, _idkX);
    });

    test('the migration runs at E2E ready, from the box session', () async {
      await friend(5, outbound: [addr(3, 0x70)]);
      anchors[5] = _idkX;

      session
        ..accountReady(1)
        ..e2eReady();
      await pumpEventQueue();

      expect(held(5, 3).idk, _idkX);
    });

    test('stamp-before-move: an untagged address gets the OLD anchor', () async {
      await friend(5, outbound: [addr(3, 0x70)]);

      expect(await store.stampUntaggedAddresses(5, _idkX), isTrue);

      expect(held(5, 3).idk, _idkX);
      // The anchor then moves to Y: the tag keeps saying X.
      anchors[5] = _idkY;
      expect(await store.stampUntaggedAddresses(5, _idkY), isTrue);
      expect(held(5, 3).idk, _idkX, reason: 'a tagged address is not retagged');
    });

    test('a closed store cannot stamp, so the move is refused by the caller',
        () async {
      await friend(5, outbound: [addr(3, 0x70)]);
      store.close();

      expect(await store.stampUntaggedAddresses(5, _idkX), isFalse);
    });
  });
}
