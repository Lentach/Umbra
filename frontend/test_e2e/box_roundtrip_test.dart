// THE BOX, END TO END (metadata-privacy PR1.3, gate G4).
//
// Drives the app's REAL box client — `BoxClient` over the production
// `IoBoxSocket`, real Ed25519 signatures — against the real `/box` namespace
// and Postgres, next to two logged-in accounts whose own sockets stay up the
// whole time. The box has no account on its path; this file is where that is
// checked against the running stack rather than the box module alone
// (`backend/src/box/box.int-spec.ts` covers the server in isolation):
//
//   1. round trip: createQueue → the sid handed over (in-test; the app uses
//      Signal) → send while the owner is away → subscribe delivers it → ack
//      deletes it at rest → a fresh connection re-subscribes and gets what
//      came after → deleteQueue removes the queue;
//      the box connections are their own engine.io sessions, never the
//      account sockets' (design §4.6), and no box row the round trip wrote
//      carries either account;
//   2. createQueue is throttled per client address: a throttled address is
//      refused on the ack — also on a fresh connection — while another
//      address still proceeds (PR1.0's `X-Real-IP` resolution, through the
//      real stack).
//   3. item 5 (slice (d), the migration handoff, decision 47): the same two
//      accounts become friends on the old path; one side's `BoxSession`
//      starts while the other still "predates the box" and hands nothing;
//      the other then starts, finds the first side's request queue in its
//      friends list and hands its queue off; the first side hands its own
//      back with no reconnect; a box message round-trips; no `messages` row
//      appears and neither queue row names an account. The same two
//      registrations: nothing is added to the register bucket.
//
// Opt-in, and it MUST stay that way: it registers two accounts, and
// `/auth/register` is 10 per HOUR per IP with an in-memory counter that the
// shared `e2e-wire` run already spends to the edge. It runs on the
// `e2e-isolated-probes` stack (`.github/workflows/ci.yml`):
//
//   cd frontend && flutter test test_e2e/box_roundtrip_test.dart \
//     --dart-define=BOX_PROBE=true
//
// Local runs need `E2E_DB_CONTAINER` for any stack but `fireplace-db-1`.

// Why ignored: `IoBoxSocket.withHeaders` and `engineId` are the harness's
// only reach into the production socket (a proxy header, the engine session).
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_first_contact.dart';
import 'package:fireplace/services/box/box_frame.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/services/box/box_outbox.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/box/queue_seal.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption/prekey_identity.dart';
import 'package:fireplace/utils/e2e_envelope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/box_fakes.dart' show PointyGcmSealer;
import 'support/e2e_test_client.dart';

const bool _enabled = bool.fromEnvironment('BOX_PROBE');

const Duration _wait = Duration(seconds: 15);

final Random _random = Random.secure();

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A throwaway client address. The box keys its throttle on it, so every run
/// takes fresh ones: a 15-minute bucket spent by the last run stays spent.
String _randomIp() =>
    '10.${_random.nextInt(256)}.${_random.nextInt(256)}.${1 + _random.nextInt(254)}';

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(_wait);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited ${_wait.inSeconds} s for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Connects [box] (if it is not already) and waits until every queue in its
/// set is subscribed on the new connection.
Future<void> _ready(BoxClient box) async {
  if (box.state == BoxState.ready) return;
  final ready = box.states.firstWhere((s) => s == BoxState.ready);
  box.connect();
  await ready.timeout(
    _wait,
    onTimeout: () => throw TimeoutException('box not ready: ${box.state}'),
  );
}

/// Every row of [table] whose [column] holds [key], as column → JSON value.
Future<List<Map<String, Object?>>> _rows(
  String table,
  String column,
  Uint8List key,
) async {
  final rows = await e2eSql(
    'SELECT to_jsonb(t)::text FROM public.$table t '
    "WHERE t.$column = decode('${_hex(key)}', 'hex')",
  );
  // e2eSql splits on its `|` separator; one JSON column comes back whole.
  return [
    for (final row in rows)
      (jsonDecode(row.join('|')) as Map).cast<String, Object?>(),
  ];
}

/// Whether [row] names [client]'s account: its id as a JSON value, or its
/// username or session token inside a text value or — as UTF-8 — inside a
/// bytea one (`to_jsonb` renders bytea as `\x<hex>`; every box column that
/// could smuggle an identifier is bytea). The id is not searched as bytes:
/// a 2–3 byte needle turns up by chance in a 16 KiB random blob.
bool _carriesAccount(Map<String, Object?> row, E2eClient client) {
  final needles = [client.username, client.accessToken];
  final hexNeedles = [for (final n in needles) _hex(utf8.encode(n))];
  return row.values.any(
    (v) =>
        v == client.userId ||
        v == '${client.userId}' ||
        (v is String &&
            (needles.any(v.contains) ||
                (v.startsWith(r'\x') && hexNeedles.any(v.contains)))),
  );
}

/// One device's own storage for its contact store.
class _MemKv implements ContentKv {
  final Map<String, Object> _rows = {};

  @override
  Future<void> reload() async {}

  @override
  Future<Map<String, Object>?> authoritativeSnapshot() async => null;

  @override
  String? getString(String key) => _rows[key] as String?;

  @override
  int? getInt(String key) => _rows[key] as int?;

  @override
  bool containsKey(String key) => _rows.containsKey(key);

  @override
  Set<String> getKeys() => _rows.keys.toSet();

  @override
  Future<bool> setString(String key, String value) async {
    _rows[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _rows[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _rows.remove(key);
    return true;
  }
}

/// One single-device account running the app's box layer for item 5 (slice
/// (d)): the shipped [BoxSession] — friend handoff, inbox, queue keys — over
/// the production box socket, beside [me]'s logged-in account socket, with
/// its own contact store naming [friend] a friend. The messaging reader is
/// stood in by a plain decrypt that hands a handoff or an ack to the session
/// (`messaging_provider_box_friend_test` drives the real reader's checks on
/// real Signal); what is proven here is the rest of the chain against the
/// real server: friends list addresses, request queues, routing, sealing.
class _AppSide {
  _AppSide(this.me, this.friend, this.client);

  final E2eClient me;
  final E2eClient friend;
  final BoxClient client;
  late final ContactStore store;
  late final BoxSession session;

  /// Chat messages read over the box, as their text.
  final List<String> read = [];

  Future<void> start() async {
    store = ContactStore(
      open: () async => _MemKv(),
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(me.userId);
    await store.update(
      friend.userId,
      (_) => ContactRecord(
        userId: friend.userId,
        username: friend.username,
        tag: friend.tag,
        state: ContactState.friend,
      ),
    );
    me.events.discard('requestQueueSet');
    session = BoxSession(
      box: client,
      store: store,
      emit: (event, data) => me.socketService.socket!.emit(event, data),
      // webcrypto's native library does not load under `flutter test` on
      // every box; the seal is the same AES-256-GCM either way.
      seal: QueueSeal(cipher: PointyGcmSealer()),
    )..start();
    session
      ..consumer = _read
      ..encryptForFriend = _encrypt
      ..friendLiveDevices = ((user) async => user == friend.userId ? {1} : null)
      ..e2eReady()
      ..accountReady(1);
    await me.events.next(
      'requestQueueSet',
      where: (p) => p is Map && p['success'] == true,
      reason: '${me.label} publishes its request queue',
    );
  }

  /// The friends list as the server serves it at connect.
  Future<void> takeFriendsList() async {
    me.events.discard('friendsList');
    me.socketService.getFriends();
    session.onFriendsList(
      await me.events.next('friendsList', reason: '${me.label} friends list'),
    );
  }

  Future<BoxFrame?> _encrypt(
    int user,
    int device,
    String json, {
    bool fresh = false,
  }) async {
    if (!await me.encryption.hasSession(user, deviceId: device)) {
      await me.encryption.buildSession(
        user,
        await me.fetchBundleFor(user, deviceId: device),
        deviceId: device,
        expectedIdentityBase64: null,
      );
    }
    return BoxFrame.fromSignalCiphertext(
      await me.encryption.encrypt(user, json, deviceId: device),
      senderDeviceId: 1,
    );
  }

  Future<bool> _read(BoxInboxEntry entry) async {
    if (entry.peerUserId != friend.userId) return true;
    final json = await me.encryption.decrypt(
      entry.peerUserId,
      entry.signal!,
      deviceId: entry.senderDeviceId,
    );
    final handoff = E2eEnvelope.parseQueueHandoff(json);
    if (handoff != null) {
      return await session.takeFriendHandoff(
            entry.peerUserId,
            entry.senderDeviceId,
            sid: handoff.sid,
            sealPub: handoff.sealPub,
          ) !=
          FriendWrite.retryLater;
    }
    if (entry.viaRequestQueue) return true;
    final acked = E2eEnvelope.parseQueueHandoffAck(json);
    if (acked != null) {
      return await session.friendAcked(
            entry.peerUserId,
            entry.senderDeviceId,
            acked,
          ) !=
          FriendWrite.retryLater;
    }
    read.add(E2eEnvelope.parse(json).content);
    return true;
  }

  ContactRecord get record => store.byUserId(friend.userId)!;

  ContactOutbound? get address => record.outbound.firstOrNull;
}

/// One account's app for slice (f)'s first contact (decision 6), strangers
/// as far as its store knows: the real `BoxSession`, `BoxInbox` gate and
/// `BoxFirstContact` records against the real server's `searchUsers`
/// answer and the real box. The reader is stood in, like [_AppSide]'s:
/// `messaging_provider_box_first_contact_test` drives the shipped reader's
/// checks on real Signal; what is proven here is the wire.
class _FirstContactSide {
  _FirstContactSide(this.me, this.peer, this.client);

  final E2eClient me;
  final E2eClient peer;
  final BoxClient client;
  late final ContactStore store;
  late final BoxSession session;
  final List<String> read = [];

  Future<void> start() async {
    store = ContactStore(
      open: () async => _MemKv(),
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(me.userId);
    await store.setSelf(
      UserModel(id: me.userId, username: me.username, tag: me.tag),
    );
    me.events.discard('requestQueueSet');
    session = BoxSession(
      box: client,
      store: store,
      emit: (event, data) => me.socketService.socket!.emit(event, data),
      seal: QueueSeal(cipher: PointyGcmSealer()),
    )..start();
    session
      ..consumer = _read
      ..encryptForFriend = _encrypt
      ..friendLiveDevices = ((user) async => user == peer.userId ? {1} : null)
      ..e2eReady()
      ..accountReady(1);
    final published =
        await me.events.next(
              'requestQueueSet',
              where: (p) => p is Map && p['success'] == true,
              reason: '${me.label} publishes its request queue',
            )
            as Map;
    session.onRequestQueueSet(published);
  }

  /// One `searchUsers` of [who]'s handle, as the server answers it.
  Future<FirstContactPeer> search(E2eClient who) async {
    me.events.discard('searchUsersResult');
    me.socketService.socket!.emit('searchUsers', {
      'handle': '${who.username}#${who.tag}',
    });
    final answer =
        await me.events.next('searchUsersResult', reason: '${me.label} search')
            as List;
    final found = FirstContactPeer.fromSearchEntry(answer.single);
    expect(found, isNotNull, reason: 'the answer names a reachable device');
    return found!;
  }

  Future<BoxFrame?> _encrypt(
    int user,
    int device,
    String json, {
    bool fresh = false,
  }) async => BoxFrame.fromSignalCiphertext(
    await me.encryption.encrypt(user, json, deviceId: device),
    senderDeviceId: 1,
  );

  /// A request is kept undecrypted (E15c); from the account we asked, a
  /// handoff is the accept (E15d) and an ack is taken; a message is read.
  Future<bool> _read(BoxInboxEntry entry) async {
    if (entry.peerUserId != peer.userId) return true;
    if (entry.carriedClaim case final claim?) {
      await session.firstContact.keep(
        userId: entry.peerUserId,
        deviceId: entry.senderDeviceId,
        signal: entry.signal!,
        claim: BoxFirstContact.parseClaim(claim)!,
      );
      return true;
    }
    final json = await me.encryption.decrypt(
      entry.peerUserId,
      entry.signal!,
      deviceId: entry.senderDeviceId,
    );
    if (E2eEnvelope.parseQueueHandoff(json) case final handoff?) {
      await session.firstContact.befriend(
        entry.peerUserId,
        avatarUrl: E2eEnvelope.profileOf(json)?.avatarUrl,
      );
      return await session.takeFriendHandoff(
            entry.peerUserId,
            entry.senderDeviceId,
            sid: handoff.sid,
            sealPub: handoff.sealPub,
          ) !=
          FriendWrite.retryLater;
    }
    if (E2eEnvelope.parseQueueHandoffAck(json) case final acked?) {
      return await session.friendAcked(
            entry.peerUserId,
            entry.senderDeviceId,
            acked,
          ) !=
          FriendWrite.retryLater;
    }
    read.add(E2eEnvelope.parse(json).content);
    return true;
  }

  ContactRecord? get record => store.byUserId(peer.userId);

  E2eProfile get profile =>
      (username: me.username, tag: me.tag, avatarUrl: null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();
  final baseUrl = e2eBaseUrl();
  const signer = Ed25519BoxSigner();

  // The skip lives on the GROUP and the hooks inside it: a test-level `skip:`
  // still runs `setUpAll`, which would spend both registrations only to skip
  // (`identity_reset_teardown_test.dart` records the lesson).
  group(
    'the box (metadata-privacy PR1.3)',
    () {
      late E2eClient alice;
      late E2eClient bob;
      var clientsBuilt = false;
      final boxes = <BoxClient>[];

      /// A box client over the production socket; [onSocket] sees every
      /// connection it opens. [ip] stands in for the proxy's `X-Real-IP`.
      BoxClient box({void Function(IoBoxSocket)? onSocket, String? ip}) {
        final client = BoxClient(
          baseUrl: baseUrl,
          socketFactory: (url) {
            final socket = ip == null
                ? IoBoxSocket(url)
                : IoBoxSocket.withHeaders(url, {'x-real-ip': ip});
            onSocket?.call(socket);
            return socket;
          },
        );
        boxes.add(client);
        return client;
      }

      setUpAll(() async {
        await requireBackendUp(baseUrl);
        alice = E2eClient('boxa', baseUrl);
        bob = E2eClient('boxb', baseUrl);
        clientsBuilt = true;
        await alice.registerFresh();
        await bob.registerFresh();
        await alice.connectSocket();
        await bob.connectSocket();
      });

      tearDownAll(() {
        for (final client in boxes) {
          client.dispose();
        }
        if (clientsBuilt) {
          alice.dispose();
          bob.dispose();
        }
      });

      test(
        'round trip: a message waits for its owner, is delivered on subscribe, '
        'is gone at rest after the ack; the box never shares a session with '
        'the account sockets and stores nothing of either account',
        () async {
          IoBoxSocket? aliceSocket;
          IoBoxSocket? bobSocket;
          final aliceBox = box(onSocket: (s) => aliceSocket = s);
          final bobBox = box(onSocket: (s) => bobSocket = s);
          await _ready(aliceBox);
          await _ready(bobBox);

          final engines = [
            aliceSocket!.engineId,
            bobSocket!.engineId,
            alice.socketService.socket!.io.engine?.id,
            bob.socketService.socket!.io.engine?.id,
          ];
          expect(engines, everyElement(isNotNull));
          expect(
            engines.toSet(),
            hasLength(4),
            reason:
                'a box connection multiplexed onto an account socket lets the '
                'server tie every queue on it to that account: $engines',
          );

          final key = signer.mint();
          final created = await aliceBox.createQueue(QueueKind.normal, key);
          expect(created, isA<BoxOk<QueueAddress>>());
          final address = (created as BoxOk<QueueAddress>).value;
          final queue = BoxQueueAuth(rid: address.rid, key: key);

          // Alice hands bob the sid; nothing else about the queue leaves her.
          final payload = _randomBytes(kBoxBlobBytes);
          expect(await bobBox.send(address.sid, payload), isA<BoxOk<void>>());

          final stored = await _rows('box_msgs', 'rid', address.rid);
          expect(stored, hasLength(1), reason: 'held for an owner who is away');
          expect(stored.single['blob'], '\\x${_hex(payload)}');

          final got = <BoxDelivery>[];
          final deliveries = aliceBox.deliveries.listen(got.add);
          addTearDown(deliveries.cancel);
          final subscribed = await aliceBox.subscribe([queue]);
          expect(subscribed, isA<BoxOk<List<BoxRefusal>>>());
          expect((subscribed as BoxOk<List<BoxRefusal>>).value, isEmpty);
          await _until(() => got.isNotEmpty, 'the held message');
          final delivered = got.single;
          expect(delivered.rid, address.rid);
          expect(delivered.blob, payload);

          expect(await aliceBox.ack(queue, delivered.id), isA<BoxOk<void>>());
          expect(
            await _rows('box_msgs', 'rid', address.rid),
            isEmpty,
            reason: 'ack deletes the message at rest',
          );

          // Nothing the box holds for this queue names either account. The
          // queue row is read after the ack, so its counters are back to 0 and
          // cannot collide with a user id. The controls: the same check finds
          // the account in the users row, and in a bytea value rendered by
          // the same `to_jsonb` path.
          final usersRow =
              'SELECT to_jsonb(u)::text FROM public.users u '
              'WHERE u.id = ${alice.userId}';
          final bytesRow =
              'SELECT to_jsonb(t)::text FROM (SELECT '
              "convert_to('${alice.username}', 'UTF8') AS b) t";
          for (final control in [usersRow, bytesRow]) {
            final row = (await e2eSql(control)).single.join('|');
            expect(
              _carriesAccount(
                (jsonDecode(row) as Map).cast<String, Object?>(),
                alice,
              ),
              isTrue,
              reason: 'the check must be able to see an account: $control',
            );
          }
          // The round trip writes no notifier row: the harness has no push
          // transport, so `box_notifiers` is outside this check.
          final boxRows = [
            ...stored,
            ...await _rows('box_queues', 'rid', address.rid),
          ];
          expect(boxRows, hasLength(2));
          for (final row in boxRows) {
            expect(_carriesAccount(row, alice), isFalse, reason: '$row');
            expect(_carriesAccount(row, bob), isFalse, reason: '$row');
          }

          // A fresh connection re-signs the whole set over its own socket id;
          // without that, nothing sent after the reconnect would arrive.
          aliceBox.close();
          got.clear();
          await _ready(aliceBox);
          final next = _randomBytes(kBoxBlobBytes);
          expect(await bobBox.send(address.sid, next), isA<BoxOk<void>>());
          await _until(() => got.isNotEmpty, 'the message sent after the ack');
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(got.map((d) => d.blob), [next]);
          expect(await aliceBox.ack(queue, got.single.id), isA<BoxOk<void>>());

          expect(await aliceBox.deleteQueue(queue), isA<BoxOk<void>>());
          expect(await _rows('box_queues', 'rid', address.rid), isEmpty);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'createQueue is throttled per client address: the throttled address '
        'is refused on the ack while another address proceeds',
        () async {
          final throttledIp = _randomIp();
          var otherIp = _randomIp();
          while (otherIp == throttledIp) {
            otherIp = _randomIp();
          }
          final throttled = box(ip: throttledIp);
          final other = box(ip: otherIp);
          await _ready(throttled);
          await _ready(other);

          // One key throughout: createQueue is idempotent per key, so the
          // loop spends the address's bucket without minting a queue a call.
          final throttledKey = signer.mint();
          QueueAddress? throttledQueue;
          BoxResult<QueueAddress>? refusal;
          var admitted = 0;
          while (refusal == null && admitted < 1000) {
            final answer = await throttled.createQueue(
              QueueKind.normal,
              throttledKey,
            );
            if (answer is BoxOk<QueueAddress>) {
              admitted++;
              throttledQueue = answer.value;
            } else {
              refusal = answer;
            }
          }
          expect(admitted, greaterThan(0));
          expect(
            refusal,
            isA<BoxRefused<QueueAddress>>()
                .having((r) => r.code, 'code', BoxCode.rateLimited)
                .having(
                  (r) => r.retryAfter,
                  'retryAfter',
                  greaterThan(Duration.zero),
                ),
            reason: 'no refusal after $admitted createQueue calls',
          );

          final otherKey = signer.mint();
          final proceeded = await other.createQueue(QueueKind.normal, otherKey);
          expect(
            proceeded,
            isA<BoxOk<QueueAddress>>(),
            reason: 'one address spent its bucket; this one has its own',
          );
          expect(
            await throttled.createQueue(QueueKind.normal, throttledKey),
            isA<BoxRefused<QueueAddress>>(),
          );
          // The bucket belongs to the ADDRESS, not the connection: a fresh
          // socket from it is still refused (else reconnecting resets it).
          final reconnected = box(ip: throttledIp);
          await _ready(reconnected);
          expect(
            await reconnected.createQueue(QueueKind.normal, signer.mint()),
            isA<BoxRefused<QueueAddress>>().having(
              (r) => r.code,
              'code',
              BoxCode.rateLimited,
            ),
          );

          // Leave no queue behind on a shared dev database.
          for (final queue in [
            BoxQueueAuth(rid: throttledQueue!.rid, key: throttledKey),
            BoxQueueAuth(
              rid: (proceeded as BoxOk<QueueAddress>).value.rid,
              key: otherKey,
            ),
          ]) {
            expect(await other.deleteQueue(queue), isA<BoxOk<void>>());
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'item 5: an existing friendship moves onto the box — the side that '
        "updates later hands its queue into the other side's request queue, "
        'that side hands its own back with no reconnect, a box message then '
        'round-trips, and the migration writes no messages row',
        () async {
          // Signal keys and the content store need the mocked platform
          // storage (the harness's other e2e files do the same).
          FlutterSecureStorage.setMockInitialValues({});
          SharedPreferences.setMockInitialValues({});
          await alice.initializeAndUploadKeys();
          await bob.initializeAndUploadKeys();
          alice.socketService.sendFriendRequest(bob.userId);
          final request =
              await bob.events.next(
                    'newFriendRequest',
                    where: (p) =>
                        p is Map &&
                        p['sender'] is Map &&
                        (p['sender'] as Map)['id'] == alice.userId,
                    reason: 'friend request',
                  )
                  as Map;
          bob.socketService.acceptFriendRequest(request['id'] as int);
          await alice.events.next('friendRequestAccepted', reason: 'accept');

          final a = _AppSide(alice, bob, box(ip: _randomIp()));
          await a.start();
          // Bob's app predates the box: the list names his device with no
          // request queue, so alice hands nothing off and makes no queue.
          await a.takeFriendsList();
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(a.record.queues, isEmpty);
          expect(a.address, isNull);

          // Bob updates. Alice's session hears nothing new from its server.
          final b = _AppSide(bob, alice, box(ip: _randomIp()));
          await b.start();
          await b.takeFriendsList();
          await _until(
            () =>
                a.address != null &&
                b.address != null &&
                (a.record.queues.firstOrNull?.ackedBy.contains(1) ?? false) &&
                (b.record.queues.firstOrNull?.ackedBy.contains(1) ?? false),
            "both sides hold the other's queue and both queues are acked",
          );
          expect(a.address!.sid, b.record.queues.single.sid);
          expect(b.address!.sid, a.record.queues.single.sid);

          // A box message now round-trips on the addresses the handoff gave.
          final text = 'box-${_randomIp()}';
          final frame = (await a._encrypt(
            bob.userId,
            1,
            jsonEncode(E2eEnvelope.build(text)),
          ))!;
          expect(
            await a.session.deliver(a.address!, frame.encode()),
            BoxSendOutcome.taken,
          );
          await _until(() => b.read.contains(text), 'bob reads it');

          // Nothing of the migration or the message is a server row.
          final rows = await e2eSql(
            'SELECT count(*) FROM public.messages '
            'WHERE sender_id IN (${alice.userId}, ${bob.userId})',
          );
          expect(rows.single.single, '0');
          for (final (side, account) in [(a, alice), (b, bob)]) {
            final queue = side.record.queues.single;
            final stored = await _rows(
              'box_queues',
              'rid',
              boxB64Decode(queue.rid, 32)!,
            );
            expect(stored, hasLength(1));
            for (final client in [alice, bob]) {
              expect(
                _carriesAccount(stored.single, client),
                isFalse,
                reason: "${account.label}'s queue names ${client.label}",
              );
            }
          }
          a.session.dispose();
          b.session.dispose();
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'slice (f), first contact (decision 6): a search names the request '
        'queue, a claim-bearing request is kept unread, the accept checks it '
        'against the key a second search serves and hands a queue back, a '
        'message goes each way — and no server row is written for any of it',
        () async {
          // Runs after item 5 on the same two accounts (their keys, uploaded
          // there; no registration is spent): the box knows neither side,
          // since each store here starts empty.
          Future<int> count(String table, String where) async => int.parse(
            (await e2eSql(
              'SELECT count(*) FROM public.$table WHERE $where',
            )).single.single,
          );
          final pair = '(${alice.userId}, ${bob.userId})';
          Future<List<int>> serverRows() async => [
            await count(
              'friend_requests',
              'sender_id IN $pair AND receiver_id IN $pair',
            ),
            await count(
              'conversations',
              'user_one_id IN $pair AND user_two_id IN $pair',
            ),
            await count('messages', 'sender_id IN $pair'),
          ];
          final before = await serverRows();

          final a = _FirstContactSide(alice, bob, box(ip: _randomIp()));
          final b = _FirstContactSide(bob, alice, box(ip: _randomIp()));
          await a.start();
          await b.start();

          // A searches: the answer names B's device and its request queue.
          final bobServed = await a.search(bob);
          expect(bobServed.userId, bob.userId);
          expect(bobServed.allOnBox, isTrue);
          expect(bobServed.addresses.single.sid, b.store.requestQueue!.sid);

          // The request (E15b): our queue, and the claim outside Signal.
          expect(
            await a.session.firstContact.asked(
              userId: bob.userId,
              profile: bobServed.profile,
              addresses: bobServed.addresses,
              bundles: bobServed.servedBundles,
            ),
            isTrue,
          );
          final ours = (await a.session.firstContactQueue(bob.userId))!;
          await alice.encryption.buildSession(
            bob.userId,
            bobServed.devices.single.bundle,
            expectedIdentityBase64: bobServed.identityKey,
          );
          final signal = BoxFrame.fromSignalCiphertext(
            await alice.encryption.encrypt(
              bob.userId,
              jsonEncode(
                E2eEnvelope.buildFriendRequest(
                  sid: ours.sid,
                  sealPub: ours.sealPub,
                  profile: a.profile,
                ),
              ),
            ),
            senderDeviceId: 1,
          )!;
          expect(signal.kind, BoxFrameKind.preKey);
          expect(
            await a.session.deliver(
              bobServed.addresses.single,
              BoxFrame(
                kind: signal.kind,
                senderDeviceId: 1,
                senderUserId: alice.userId,
                signal: signal.signal,
                carriedClaim: BoxFirstContact.encodeClaim((
                  username: alice.username,
                  tag: alice.tag,
                )),
              ).encode(),
            ),
            BoxSendOutcome.taken,
          );

          // B's inbox journals it; the request is KEPT, not decrypted.
          await _until(
            () => b.record?.boxOrigin?.kept.length == 1,
            'bob keeps the request',
          );
          expect(b.record!.state, ContactState.pendingIn);
          expect(b.record!.username, alice.username);

          // The accept (E15d): one search of the claimed handle; the kept
          // frame must carry the key the server serves for that account.
          final aliceServed = await b.search(alice);
          expect(aliceServed.userId, alice.userId);
          final kept = b.record!.boxOrigin!.kept.single;
          expect(
            ciphertextMatchesIdentity(kept.signal, aliceServed.identityKey!),
            isTrue,
          );
          final offered = E2eEnvelope.parseFriendRequest(
            await bob.encryption.decrypt(alice.userId, kept.signal),
          )!;
          expect(offered.sid, ours.sid);
          expect(
            await b.session.firstContact.befriend(
              alice.userId,
              profile: aliceServed.profile,
              addresses: aliceServed.addresses,
              bundles: aliceServed.servedBundles,
            ),
            isTrue,
          );
          expect(
            await b.session.acceptFirstContact(
              alice.userId,
              1,
              sid: offered.sid,
              sealPub: offered.sealPub,
              profile: b.profile,
            ),
            FriendWrite.stored,
          );

          // A reads the accept from its own queue and becomes a friend.
          await _until(
            () =>
                a.record?.state == ContactState.friend &&
                a.record!.outbound.isNotEmpty &&
                (a.record!.queues.first.ackedBy.contains(1)),
            'alice takes the accept',
          );
          expect(a.record!.outbound.single.sid, b.record!.queues.single.sid);

          // A message each way on the addresses first contact gave.
          final hello = 'fc-${_randomIp()}';
          final back = 'fc-${_randomIp()}';
          final toBob = (await a._encrypt(
            bob.userId,
            1,
            jsonEncode(E2eEnvelope.build(hello)),
          ))!;
          expect(
            await a.session.deliver(a.record!.outbound.single, toBob.encode()),
            BoxSendOutcome.taken,
          );
          final toAlice = (await b._encrypt(
            alice.userId,
            1,
            jsonEncode(E2eEnvelope.build(back)),
          ))!;
          expect(
            await b.session.deliver(
              b.record!.outbound.single,
              toAlice.encode(),
            ),
            BoxSendOutcome.taken,
          );
          await _until(
            () => b.read.contains(hello) && a.read.contains(back),
            'a message each way',
          );

          // The server wrote nothing for the friendship or the messages.
          expect(await serverRows(), before);
          a.session.dispose();
          b.session.dispose();
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: _enabled
        ? false
        : 'set --dart-define=BOX_PROBE=true (needs a fresh register bucket)',
  );
}
