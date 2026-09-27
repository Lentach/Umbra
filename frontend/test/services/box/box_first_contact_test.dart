import 'dart:convert';

import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First contact over request queues (metadata-privacy slice (f), E15c,
/// E15i, decision 54): a stranger's request is kept undecrypted, capped, and
/// forgotten after the box TTL.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 9, 27, 12);
  late ContactStore store;
  late DateTime now;
  late BoxFirstContact contact;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    now = t0;
    contact = BoxFirstContact(store: store, now: () => now);
  });

  const ana = (username: 'ana', tag: '0342');

  group('the claim', () {
    test('is a username and a tag, nothing else', () {
      expect(
        BoxFirstContact.parseClaim('{"u":"ana","g":"0342"}'),
        (username: 'ana', tag: '0342'),
      );
    });

    test('that is not JSON, lacks a field, or runs over is no claim', () {
      for (final raw in [
        null,
        'not json',
        '[]',
        '{"u":"ana"}',
        '{"g":"0342"}',
        '{"u":"","g":"0342"}',
        '{"u":"ana","g":""}',
        '{"u":"${'a' * 65}","g":"0342"}',
        '{"u":"ana","g":"${'1' * 17}"}',
        '{"u":7,"g":"0342"}',
      ]) {
        expect(BoxFirstContact.parseClaim(raw), isNull, reason: '$raw');
      }
    });
  });

  group('keeping a request (E15c)', () {
    test(
      "a stranger's request becomes a pending request under its claimed "
      'name, its Signal bytes kept for the accept',
      () async {
        expect(
          await contact.keep(
            userId: 342,
            deviceId: 2,
            signal: '3:AAAA',
            claim: ana,
          ),
          isTrue,
        );
        final record = store.byUserId(342)!;
        expect(record.state, ContactState.pendingIn);
        expect(record.username, 'ana');
        expect(record.tag, '0342');
        expect(record.avatarUrl, isNull, reason: 'no photo before the accept');
        expect(record.boxOrigin?.at, t0);
        expect(record.boxOrigin?.kept.single.signal, '3:AAAA');
      },
    );

    test(
      "a second device's request joins the first, a device's newer one joins "
      'its own (the oldest beyond three goes), and the request keeps its '
      'first time',
      () async {
        await contact.keep(userId: 342, deviceId: 2, signal: '3:A', claim: ana);
        now = t0.add(const Duration(hours: 1));
        await contact.keep(userId: 342, deviceId: 3, signal: '3:B', claim: ana);
        for (final signal in ['3:C', '3:D', '3:E']) {
          await contact.keep(
            userId: 342,
            deviceId: 2,
            signal: signal,
            claim: ana,
          );
        }

        final origin = store.byUserId(342)!.boxOrigin!;
        expect(origin.at, t0);
        expect(
          [
            for (final k in origin.kept)
              if (k.deviceId == 2) k.signal,
          ],
          ['3:C', '3:D', '3:E'],
        );
        expect(
          [
            for (final k in origin.kept)
              if (k.deviceId == 3) k.signal,
          ],
          ['3:B'],
        );
      },
    );

    test(
      'a later frame naming a pending requester never renames it nor pushes '
      'its frame out: the frame and its claim are unauthenticated',
      () async {
        await contact.keep(userId: 342, deviceId: 2, signal: '3:A', claim: ana);
        await contact.keep(
          userId: 342,
          deviceId: 2,
          signal: '3:M',
          claim: (username: 'mallory', tag: '0001'),
        );

        final record = store.byUserId(342)!;
        expect(record.username, 'ana');
        expect(record.tag, '0342');
        expect(
          [for (final k in record.boxOrigin!.kept) (k.signal, k.claim)],
          [
            ('3:A', ana),
            ('3:M', (username: 'mallory', tag: '0001')),
          ],
        );
      },
    );

    test(
      'a request from an account we asked long ago keeps the name our own '
      'search verified, not the claim',
      () async {
        await contact.asked(userId: 343, profile: ana, addresses: const []);
        now = t0.add(BoxFirstContact.lifetime + const Duration(days: 1));
        await contact.keep(
          userId: 343,
          deviceId: 1,
          signal: '3:M',
          claim: (username: 'mallory', tag: '0001'),
        );

        final record = store.byUserId(343)!;
        expect(record.state, ContactState.pendingIn);
        expect((record.username, record.tag), ('ana', '0342'));
      },
    );

    test(
      'a friend, a blocked account, an account we asked and a request the '
      'server carries are never turned into a box request',
      () async {
        for (final (id, state, requestId) in [
          (10, ContactState.friend, null),
          (11, ContactState.blocked, null),
          (12, ContactState.pendingOut, null),
          (13, ContactState.pendingIn, 77),
        ]) {
          await store.update(
            id,
            (_) => ContactRecord(
              userId: id,
              username: 'u$id',
              tag: '00$id',
              state: state,
              legacy: ContactLegacy(requestId: requestId),
            ),
          );
          expect(
            await contact.keep(
              userId: id,
              deviceId: 1,
              signal: '3:X',
              claim: ana,
            ),
            isFalse,
          );
          final record = store.byUserId(id)!;
          expect(record.state, state);
          expect(record.boxOrigin, isNull);
          expect(record.username, 'u$id');
        }
      },
    );

    test(
      'a claim naming a former contact is not kept: an unauthenticated frame '
      'cannot turn the queue material the record holds into a request',
      () async {
        const queue = ContactQueue(
          rid: 'r',
          sid: 's',
          nid: 'n',
          authPriv: 'a',
          sealPriv: 'sp',
          sealPub: 'p',
        );
        await store.update(
          20,
          (_) => const ContactRecord(
            userId: 20,
            username: 'old',
            tag: '0020',
            state: ContactState.former,
            queues: [queue],
          ),
        );
        expect(
          await contact.keep(
            userId: 20,
            deviceId: 1,
            signal: '3:X',
            claim: ana,
          ),
          isFalse,
        );
        final record = store.byUserId(20)!;
        expect(record.state, ContactState.former);
        expect(record.boxOrigin, isNull);
        expect(record.queues.single.rid, 'r');
      },
    );

    test(
      'at most 50 requests are kept: the oldest goes, a pending one we sent '
      'never does',
      () async {
        await store.update(
          999,
          (_) => ContactRecord(
            userId: 999,
            username: 'asked',
            tag: '0999',
            state: ContactState.pendingOut,
            boxOrigin: ContactBoxOrigin(
              at: t0.subtract(const Duration(days: 1)),
            ),
          ),
        );
        for (var i = 0; i < 51; i++) {
          now = t0.add(Duration(minutes: i));
          await contact.keep(
            userId: 100 + i,
            deviceId: 1,
            signal: '3:$i',
            claim: (username: 'u$i', tag: '$i'),
          );
        }
        final kept = [
          for (final r in store.all)
            if (r.state == ContactState.pendingIn) r.userId,
        ];
        expect(kept, hasLength(50));
        expect(kept, isNot(contains(100)), reason: 'the oldest');
        expect(kept, contains(150));
        expect(store.byUserId(999)?.state, ContactState.pendingOut);
      },
    );
  });

  group('asking and becoming friends (E15b, E15d, E15e)', () {
    const address = ContactOutbound(
      peerDeviceId: 2,
      sid: 'req-sid',
      sealPub: 'pub',
    );

    test(
      'asking a former contact swept from a server request makes a box '
      'request: the old request id goes',
      () async {
        await store.update(
          30,
          (_) => const ContactRecord(
            userId: 30,
            username: 'old',
            tag: '0030',
            state: ContactState.former,
            legacy: ContactLegacy(requestId: 77),
          ),
        );
        expect(
          await contact.asked(userId: 30, profile: ana, addresses: [address]),
          isTrue,
        );
        final record = store.byUserId(30)!;
        expect(record.state, ContactState.pendingOut);
        expect(record.legacy.requestId, isNull);
      },
    );

    test(
      "our request makes a pending one we sent, holding the peer's request "
      'addresses; a friend or a blocked account is never re-asked',
      () async {
        expect(
          await contact.asked(userId: 343, profile: ana, addresses: [address]),
          isTrue,
        );
        final record = store.byUserId(343)!;
        expect(record.state, ContactState.pendingOut);
        expect(record.boxOrigin?.at, t0);
        expect(record.boxOrigin?.addresses.single.sid, 'req-sid');

        for (final (id, state) in [
          (10, ContactState.friend),
          (11, ContactState.blocked),
        ]) {
          await store.update(
            id,
            (_) => ContactRecord(
              userId: id,
              username: 'u$id',
              tag: '00$id',
              state: state,
            ),
          );
          expect(
            await contact.asked(userId: id, profile: ana, addresses: [address]),
            isFalse,
          );
          expect(store.byUserId(id)?.state, state);
        }
      },
    );

    test(
      'a request either way becomes a friendship under its local chat id; '
      'the verified profile replaces the claim and the kept frames go',
      () async {
        await contact.keep(userId: 342, deviceId: 2, signal: '3:A', claim: ana);
        expect(
          await contact.befriend(
            342,
            profile: (username: 'ana', tag: '0342'),
            avatarUrl: 'https://h/media/avatars/a.jpg',
            addresses: [address],
          ),
          isTrue,
        );
        final record = store.byUserId(342)!;
        expect(record.state, ContactState.friend);
        expect(record.legacy.conversationId, 281474976710656 + 342);
        expect(record.avatarUrl, 'https://h/media/avatars/a.jpg');
        expect(record.boxOrigin?.kept, isEmpty);
        expect(record.boxOrigin?.addresses.single.sid, 'req-sid');

        await contact.asked(userId: 343, profile: ana, addresses: [address]);
        expect(await contact.befriend(343), isTrue);
        expect(store.byUserId(343)?.state, ContactState.friend);
      },
    );

    test(
      'nothing but a pending box request becomes a friendship here: a server '
      'request, a blocked account and a stranger stay as they are',
      () async {
        await store.update(
          13,
          (_) => const ContactRecord(
            userId: 13,
            username: 'u13',
            tag: '0013',
            state: ContactState.pendingIn,
            legacy: ContactLegacy(requestId: 77),
          ),
        );
        await store.update(
          11,
          (_) => const ContactRecord(
            userId: 11,
            username: 'u11',
            tag: '0011',
            state: ContactState.blocked,
          ),
        );
        expect(await contact.befriend(13), isFalse);
        expect(await contact.befriend(11), isFalse);
        expect(await contact.befriend(404), isFalse);
        expect(store.byUserId(13)?.state, ContactState.pendingIn);
        expect(store.byUserId(11)?.state, ContactState.blocked);
        expect(store.byUserId(404), isNull);
      },
    );
  });

  group('a search answer (wire.md "First contact")', () {
    final sid = 'A' * 42 + 'E';
    final pub = 'B' * 42 + 'Q';
    Map<String, dynamic> bundle(String ik, {bool otp = true}) => {
      'registrationId': 7,
      'identityPublicKey': ik,
      'signedPreKeyId': 1,
      'signedPreKeyPublic': 'spk',
      'signedPreKeySignature': 'sig',
      if (otp) 'oneTimePreKeyId': 9,
      if (otp) 'oneTimePreKeyPublic': 'otp',
    };
    Map<String, dynamic> entry(List<Map<String, dynamic>> devices) => {
      'id': 342,
      'username': 'ana',
      'tag': '0342',
      'profilePictureUrl': 'https://h/media/avatars/a.jpg',
      'devices': devices,
      'authorization': {'listVersion': 2},
    };

    test(
      'reads each device with its bundle and request address, one identity '
      'for the account',
      () {
        final peer = FirstContactPeer.fromSearchEntry(
          entry([
            {
              'deviceId': 1,
              'bundle': bundle('IK'),
              'requestSid': sid,
              'sealPub': pub,
            },
            {
              'deviceId': 2,
              'bundle': bundle('IK'),
              'requestSid': sid,
              'sealPub': pub,
            },
          ]),
        )!;
        expect(peer.userId, 342);
        expect(peer.profile, (username: 'ana', tag: '0342'));
        expect(peer.avatarUrl, 'https://h/media/avatars/a.jpg');
        expect(peer.identityKey, 'IK');
        expect(peer.allOnBox, isTrue);
        expect(peer.addresses.map((a) => a.peerDeviceId), [1, 2]);
        expect(peer.authorization, {'listVersion': 2});
      },
    );

    test(
      'a device with no request address is not on the box, and devices that '
      'disagree on the identity name none',
      () {
        final partial = FirstContactPeer.fromSearchEntry(
          entry([
            {
              'deviceId': 1,
              'bundle': bundle('IK'),
              'requestSid': sid,
              'sealPub': pub,
            },
            {
              'deviceId': 2,
              'bundle': bundle('IK'),
              'requestSid': null,
              'sealPub': null,
            },
          ]),
        )!;
        expect(partial.allOnBox, isFalse);
        expect(partial.addresses.map((a) => a.peerDeviceId), [1]);

        final split = FirstContactPeer.fromSearchEntry(
          entry([
            {
              'deviceId': 1,
              'bundle': bundle('IK'),
              'requestSid': sid,
              'sealPub': pub,
            },
            {
              'deviceId': 2,
              'bundle': bundle('OTHER'),
              'requestSid': sid,
              'sealPub': pub,
            },
          ]),
        )!;
        expect(split.identityKey, isNull);
        expect(
          FirstContactPeer.fromSearchEntry(entry(const [])),
          isNull,
          reason: 'no device to reach',
        );
        expect(FirstContactPeer.fromSearchEntry({'id': 342}), isNull);
      },
    );

    test(
      "the copy a sibling gets carries no one-time pre-key: the searcher's "
      'own session already spent it',
      () {
        final peer = FirstContactPeer.fromSearchEntry(
          entry([
            {
              'deviceId': 1,
              'bundle': bundle('IK'),
              'requestSid': sid,
              'sealPub': pub,
            },
          ]),
        )!;
        final copy = FirstContactPeer.fromSearchEntry(
          jsonDecode(jsonEncode(peer.toSiblingJson())),
        )!;
        expect(copy.userId, 342);
        expect(copy.identityKey, 'IK');
        expect(copy.devices.single.bundle, bundle('IK', otp: false));
        expect(copy.addresses.single.sid, sid);
      },
    );
  });

  group('forgetting (decision 54, E15i)', () {
    test(
      'a decline drops the request and tells nobody; a request the server '
      'carries is not ours to drop',
      () async {
        await contact.keep(userId: 342, deviceId: 2, signal: '3:A', claim: ana);
        expect(await contact.decline(342), isTrue);
        expect(store.byUserId(342), isNull);

        await store.update(
          13,
          (_) => const ContactRecord(
            userId: 13,
            username: 'u13',
            tag: '0013',
            state: ContactState.pendingIn,
            legacy: ContactLegacy(requestId: 77),
          ),
        );
        expect(await contact.decline(13), isFalse);
        expect(store.byUserId(13)?.state, ContactState.pendingIn);
      },
    );

    test(
      'a received request is forgotten 30 d after it began, a sent one only '
      'once an accept sent on its last day could no longer arrive (60 d); '
      'a younger one and a friendship are kept',
      () async {
        await contact.keep(userId: 342, deviceId: 2, signal: '3:A', claim: ana);
        await store.update(
          400,
          (_) => ContactRecord(
            userId: 400,
            username: 'asked',
            tag: '0400',
            state: ContactState.pendingOut,
            boxOrigin: ContactBoxOrigin(at: t0),
          ),
        );
        await store.update(
          401,
          (_) => ContactRecord(
            userId: 401,
            username: 'friend',
            tag: '0401',
            state: ContactState.friend,
            boxOrigin: ContactBoxOrigin(at: t0),
          ),
        );
        now = t0.add(BoxFirstContact.lifetime);
        final young = await contact.keep(
          userId: 500,
          deviceId: 1,
          signal: '3:Y',
          claim: ana,
        );
        expect(young, isTrue);

        expect(await contact.expired(), isEmpty, reason: 'exactly 30 d: kept');
        now = now.add(const Duration(milliseconds: 1));
        expect(await contact.expired(), [342], reason: 'the sent one waits');
        expect(
          BoxFirstContact.shownPending(store.byUserId(400)!, now),
          isFalse,
          reason: 'but is no longer shown as pending (decision 54)',
        );
        now = t0.add(BoxFirstContact.sentLifetime);
        expect(await contact.expired(), [342]);
        now = now.add(const Duration(milliseconds: 1));
        expect(
          await contact.expired(),
          unorderedEquals([342, 400, 500]),
          reason: '500 is 30 d old by now too',
        );
        await contact.forget([342, 400]);
        expect(store.byUserId(342), isNull);
        expect(store.byUserId(400), isNull);
        expect(store.byUserId(500)?.state, ContactState.pendingIn);
        expect(store.byUserId(401)?.state, ContactState.friend);
      },
    );

    test(
      "a decline of a request whose record holds our lapsed request's queue "
      'hides it but keeps the queue, so it can still be deleted: the record '
      'is due at once and goes only once forgotten',
      () async {
        const queue = ContactQueue(
          rid: 'r',
          sid: 's',
          nid: 'n',
          authPriv: 'a',
          sealPriv: 'sp',
          sealPub: 'p',
        );
        await contact.asked(userId: 343, profile: ana, addresses: const []);
        await store.update(343, (r) => r!.copyWith(queues: [queue]));
        now = t0.add(BoxFirstContact.lifetime + const Duration(days: 1));
        await contact.keep(userId: 343, deviceId: 1, signal: '3:A', claim: ana);

        expect(await contact.decline(343), isTrue);
        final record = store.byUserId(343)!;
        expect(record.state, ContactState.former);
        expect(record.queues.single.rid, 'r');
        expect(record.boxOrigin?.kept, isEmpty);
        expect(await contact.expired(), [343]);
        expect(
          await contact.keep(
            userId: 343,
            deviceId: 1,
            signal: '3:B',
            claim: ana,
          ),
          isFalse,
          reason: 'a hidden record takes no new frame',
        );

        await contact.forget([343]);
        expect(store.byUserId(343), isNull);
      },
    );

    test(
      'the cap evicts a request holding a queue the same way: hidden, its '
      'queue kept for deletion',
      () async {
        const queue = ContactQueue(
          rid: 'r',
          sid: 's',
          nid: 'n',
          authPriv: 'a',
          sealPriv: 'sp',
          sealPub: 'p',
        );
        await contact.asked(userId: 99, profile: ana, addresses: const []);
        await store.update(99, (r) => r!.copyWith(queues: [queue]));
        now = t0.add(BoxFirstContact.lifetime + const Duration(days: 1));
        await contact.keep(userId: 99, deviceId: 1, signal: '3:A', claim: ana);
        for (var i = 0; i < BoxFirstContact.maxKept; i++) {
          now = now.add(const Duration(minutes: 1));
          await contact.keep(
            userId: 100 + i,
            deviceId: 1,
            signal: '3:$i',
            claim: (username: 'u$i', tag: '$i'),
          );
        }
        final record = store.byUserId(99)!;
        expect(record.state, ContactState.former);
        expect(record.queues.single.rid, 'r');
      },
    );
  });
}
