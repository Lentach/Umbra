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

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:flutter_test/flutter_test.dart';

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
    },
    skip: _enabled
        ? false
        : 'set --dart-define=BOX_PROBE=true (needs a fresh register bucket)',
  );
}
