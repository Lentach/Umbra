import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:fake_async/fake_async.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_signer.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/box_fakes.dart';

const _signer = Ed25519BoxSigner();

/// Signs only once [gate] completes: a signature still being made while the
/// connection changes.
class _GatedSigner implements BoxSigner {
  final Completer<void> gate = Completer<void>();

  @override
  BoxAuthKey mint() => _signer.mint();

  @override
  Future<Uint8List> sign(BoxAuthKey key, List<int> message) async {
    await gate.future;
    return _signer.sign(key, message);
  }
}

Uint8List _bytes(int length, int fill) => Uint8List(length)..fillRange(0, length, fill);

/// A queue whose rid is [n] repeated (n < 256), with its own key.
BoxQueueAuth _queue(int n) =>
    BoxQueueAuth(rid: _bytes(kBoxRidBytes, n), key: _signer.mint());

bool _verifies(
  BoxAuthKey key,
  BoxSignedVerb verb,
  String sockId,
  List<int> fields,
  Object? sig,
) => ed.verify(
  ed.PublicKey(key.publicKey),
  boxSignedMessage(verb, sockId, fields),
  boxB64Decode(sig, kBoxSigBytes)!,
);

Map<String, Object?> _ok([Map<String, Object?> extra = const {}]) => {
  'ok': true,
  ...extra,
};

Map<String, Object?> _subscribed([List<Uint8List> refused = const []]) => _ok({
  'refused': [
    for (final rid in refused) {'rid': boxB64(rid), 'code': 'auth_failed'},
  ],
});

void main() {
  late FakeBoxSockets sockets;

  BoxClient client({http.Client? httpClient, BoxSigner signer = _signer}) =>
      BoxClient(
        baseUrl: 'http://box.test',
        signer: signer,
        socketFactory: sockets.call,
        httpClient: httpClient,
      );

  setUp(() => sockets = FakeBoxSockets());

  test(
    'offline, a call emits nothing and answers offline — never a refusal',
    () async {
      final box = client();
      final key = _signer.mint();
      expect(
        await box.createQueue(QueueKind.normal, key),
        isA<BoxUnknown<QueueAddress>>().having(
          (u) => u.reason,
          'reason',
          BoxUnknownReason.offline,
        ),
      );

      box.connect();
      final socket = sockets.last;
      expect(socket.url, 'http://box.test/box');
      expect(box.state, BoxState.connecting);
      // Connecting is not connected: socket.io would buffer this frame and
      // send it later under a signature bound to no live socket id.
      expect(
        await box.createQueue(QueueKind.normal, key),
        isA<BoxUnknown<QueueAddress>>(),
      );
      expect(socket.emitted, isEmpty);
    },
  );

  test(
    'signs every command over the id of the socket it goes out on',
    () async {
      final box = client()..connect();
      final first = sockets.last..serverConnect('S1');
      final key = _signer.mint();
      final address = {
        'rid': boxB64(_bytes(32, 1)),
        'sid': boxB64(_bytes(32, 2)),
        'nid': boxB64(_bytes(16, 3)),
      };
      sockets.respond = (_, f) => f.event == 'createQueue' ? _ok(address) : null;

      final created = await box.createQueue(QueueKind.request, key);
      final frame = first.emitted.single.frame;
      expect(frame.keys.toSet(), {'v', 'kind', 'authPub', 'sig'});
      expect(frame['v'], 1);
      expect(frame['kind'], 'request');
      expect(frame['authPub'], boxB64(key.publicKey));
      expect(
        _verifies(
          key,
          BoxSignedVerb.createQueue,
          'S1',
          createQueueFields(QueueKind.request, key.publicKey),
          frame['sig'],
        ),
        isTrue,
      );
      final value = (created as BoxOk<QueueAddress>).value;
      expect(value.rid, _bytes(32, 1));
      expect(value.sid, _bytes(32, 2));
      expect(value.nid, _bytes(16, 3));
    },
  );

  test(
    'a dropped connection fails every call in flight; a late answer changes nothing',
    () async {
      final box = client()..connect();
      final socket = sockets.last..serverConnect('S1');
      final sent = box.send(_bytes(32, 9), _bytes(kBoxBlobBytes, 7));
      final acked = box.ack(_queue(4), _bytes(16, 5));
      await pumpEventQueue();
      expect(socket.emitted.map((f) => f.event), ['send', 'ack']);

      socket.serverDrop();
      expect(
        await sent,
        isA<BoxUnknown<void>>().having(
          (u) => u.reason,
          'reason',
          BoxUnknownReason.disconnected,
        ),
      );
      expect(await acked, isA<BoxUnknown<void>>());
      expect(box.state, BoxState.offline);
      socket.emitted.first.answer(_ok());
    },
  );

  test(
    'a frame signed while its connection dropped never goes out, on either connection',
    () {
      fakeAsync((clock) {
        final signer = _GatedSigner();
        final box = client(signer: signer)..connect();
        final first = sockets.last..serverConnect('S1');
        clock.flushMicrotasks();
        BoxResult<void>? result;
        unawaited(box.ack(_queue(4), _bytes(16, 5)).then((r) => result = r));
        clock.flushMicrotasks();

        first.serverDrop();
        clock.elapse(const Duration(seconds: 3));
        final second = sockets.last..serverConnect('S2');
        clock.flushMicrotasks();
        expect(second, isNot(same(first)));

        // The signature over S1 is ready only now, with S2 live.
        signer.gate.complete();
        clock.flushMicrotasks();
        expect(
          result,
          isA<BoxUnknown<void>>().having(
            (u) => u.reason,
            'reason',
            BoxUnknownReason.disconnected,
          ),
        );
        expect(first.emitted, isEmpty);
        expect(second.emitted, isEmpty);
      });
    },
  );

  test('a call nobody answers times out as unknown', () {
    fakeAsync((clock) {
      final box = client()..connect();
      sockets.last.serverConnect('S1');
      BoxResult<void>? result;
      unawaited(
        box
            .send(_bytes(32, 1), _bytes(kBoxBlobBytes, 1))
            .then((r) => result = r),
      );
      clock.elapse(const Duration(seconds: 14));
      expect(result, isNull);
      clock.elapse(const Duration(seconds: 2));
      expect(
        result,
        isA<BoxUnknown<void>>().having(
          (u) => u.reason,
          'reason',
          BoxUnknownReason.timeout,
        ),
      );
    });
  });

  test(
    'each connection re-signs the WHOLE set over its own id, 256 per frame, '
    'and is ready only once every frame answered; a refused rid is lost',
    () {
      fakeAsync((clock) {
        final box = client();
        final queues = [for (var i = 0; i < 300; i++) _queue(i % 256)];
        // Distinct rids: byte 1 carries the high part of i.
        for (var i = 0; i < 300; i++) {
          queues[i].rid[1] = i >> 8;
        }
        final lost = <BoxRefusal>[];
        box.lostQueues.listen(lost.add);
        // Offline: the set keeps them for the connection.
        unawaited(box.subscribe(queues));
        box.connect();
        final first = sockets.last..serverConnect('S1');
        clock.flushMicrotasks();

        expect(first.emitted, hasLength(1));
        final chunk1 = first.emitted[0].frame['subs']! as List<Object?>;
        expect(chunk1, hasLength(256));
        expect(box.state, BoxState.connecting);
        first.emitted[0].answer(_subscribed());
        clock.flushMicrotasks();

        expect(first.emitted, hasLength(2));
        expect(first.emitted[1].frame['subs']! as List<Object?>, hasLength(44));
        expect(box.state, BoxState.connecting);
        final gone = queues[299].rid;
        first.emitted[1].answer(_subscribed([gone]));
        clock.flushMicrotasks();
        expect(box.state, BoxState.ready);
        expect(lost.single.rid, gone);
        expect(lost.single.code, BoxCode.authFailed);

        // The box reconnects by itself (its own reconnect manager, no token)
        // and re-signs over the NEW id; the lost rid is not re-subscribed.
        first.serverDrop();
        expect(box.state, BoxState.offline);
        clock.elapse(const Duration(seconds: 3));
        expect(sockets.sockets, hasLength(2));
        sockets.respond = (_, f) => _subscribed();
        final second = sockets.last..serverConnect('S2');
        clock.flushMicrotasks();
        final resent = [
          for (final f in second.emitted)
            ...(f.frame['subs']! as List<Object?>).cast<Map<String, Object?>>(),
        ];
        expect(resent, hasLength(299));
        expect(resent.map((e) => e['rid']), isNot(contains(boxB64(gone))));
        final entry = resent.first;
        final signedBy = queues.firstWhere((q) => boxB64(q.rid) == entry['rid']);
        expect(
          _verifies(
            signedBy.key,
            BoxSignedVerb.subscribe,
            'S2',
            signedBy.rid,
            entry['sig'],
          ),
          isTrue,
        );
        expect(
          _verifies(
            signedBy.key,
            BoxSignedVerb.subscribe,
            'S1',
            signedBy.rid,
            entry['sig'],
          ),
          isFalse,
        );
        expect(box.state, BoxState.ready);
      });
    },
  );

  test(
    'a rid refused for the per-socket cap (`limit`) is NOT gone: it stays in '
    'the set, is never reported lost, and the next connection offers it again',
    () {
      fakeAsync((clock) {
        final box = client();
        final kept = _queue(1);
        final capped = _queue(2);
        final lost = <BoxRefusal>[];
        box.lostQueues.listen(lost.add);
        unawaited(box.subscribe([kept, capped]));
        box.connect();
        final first = sockets.last..serverConnect('S1');
        clock.flushMicrotasks();
        first.emitted.single.answer(
          _ok({
            'refused': [
              {'rid': boxB64(capped.rid), 'code': 'limit'},
            ],
          }),
        );
        clock.flushMicrotasks();
        expect(box.state, BoxState.ready);
        expect(lost, isEmpty);
        expect(box.subscribed.map(boxB64), contains(boxB64(capped.rid)));

        // An explicit subscribe answers no refusal for it either: a caller
        // reading its list as "gone" would drop a live queue.
        BoxResult<List<BoxRefusal>>? answer;
        unawaited(box.subscribe([capped]).then((r) => answer = r));
        clock.flushMicrotasks();
        first.emitted.last.answer(
          _ok({
            'refused': [
              {'rid': boxB64(capped.rid), 'code': 'limit'},
            ],
          }),
        );
        clock.flushMicrotasks();
        expect(answer, isA<BoxOk<List<BoxRefusal>>>());
        expect((answer! as BoxOk<List<BoxRefusal>>).value, isEmpty);

        first.serverDrop();
        clock.elapse(const Duration(seconds: 3));
        sockets.respond = (_, f) => _subscribed();
        final second = sockets.last..serverConnect('S2');
        clock.flushMicrotasks();
        final resent = [
          for (final f in second.emitted)
            ...(f.frame['subs']! as List<Object?>).cast<Map<String, Object?>>(),
        ];
        expect(resent.map((e) => e['rid']), contains(boxB64(capped.rid)));
      });
    },
  );

  test(
    'a resubscribe the box refuses drops the connection and backs off',
    () {
      fakeAsync((clock) {
        final box = client();
        unawaited(box.subscribe([_queue(1)]));
        sockets.respond = (_, f) =>
            {'ok': false, 'code': 'rate_limited', 'retryAfterMs': 900};
        box.connect();
        sockets.last.serverConnect('S1');
        clock.flushMicrotasks();
        expect(sockets.last.disposed, isTrue);
        expect(box.state, BoxState.offline);

        sockets.respond = (_, f) => _subscribed();
        clock.elapse(const Duration(seconds: 3));
        sockets.last.serverConnect('S2');
        clock.flushMicrotasks();
        expect(box.state, BoxState.ready);
      });
    },
  );

  test('close() stops reconnecting', () {
    fakeAsync((clock) {
      final box = client()..connect();
      sockets.last.serverDrop();
      box.close();
      clock.elapse(const Duration(minutes: 1));
      expect(sockets.sockets, hasLength(1));
      expect(box.state, BoxState.offline);
    });
  });

  test(
    'a server outage longer than the fast backoff never ends the box: it keeps '
    'retrying until close() (device-found 2026-09-24: a 195 s backend restart '
    'left the app with no box until it was restarted)',
    () {
      fakeAsync((clock) {
        final box = client()..connect();
        // Every attempt refused, well past AppConstants.reconnectMaxAttempts.
        for (var i = 0; i < 12; i++) {
          sockets.last.refuseConnection();
          clock.elapse(const Duration(seconds: 31));
        }
        final attempts = sockets.sockets.length;
        expect(attempts, greaterThan(6), reason: 'still retrying');

        sockets.respond = (_, f) => _subscribed();
        sockets.last.serverConnect('S-back');
        clock.flushMicrotasks();
        expect(box.state, BoxState.ready);

        box.close();
        clock.elapse(const Duration(minutes: 5));
        expect(sockets.sockets, hasLength(attempts), reason: 'close() stops it');
      });
    },
  );

  test(
    'deleteQueue reads auth_failed as already gone, and the rid leaves the set',
    () async {
      final box = client();
      final keep = _queue(1);
      final doomed = _queue(2);
      unawaited(box.subscribe([keep, doomed]));
      box.connect();
      sockets.respond = (_, f) => switch (f.event) {
        'deleteQueue' => {'ok': false, 'code': 'auth_failed'},
        _ => _subscribed(),
      };
      sockets.last.serverConnect('S1');
      await pumpEventQueue();

      expect(await box.deleteQueue(doomed), isA<BoxOk<void>>());
      expect(box.subscribed.toList(), [keep.rid]);
      final frame = sockets.last.emitted.last.frame;
      expect(frame.keys.toSet(), {'v', 'rid', 'sig'});
      expect(
        _verifies(
          doomed.key,
          BoxSignedVerb.deleteQueue,
          'S1',
          doomed.rid,
          frame['sig'],
        ),
        isTrue,
      );
    },
  );

  test('msg frames become deliveries; an unreadable one is dropped', () async {
    final box = client()..connect();
    final got = <BoxDelivery>[];
    box.deliveries.listen(got.add);
    sockets.last
      ..serverConnect('S1')
      ..push({
        'rid': boxB64(_bytes(32, 1)),
        'id': boxB64(_bytes(16, 2)),
        'blob': boxB64(_bytes(kBoxBlobBytes, 3)),
      })
      ..push({'rid': boxB64(_bytes(32, 1)), 'id': 'short', 'blob': ''})
      ..push('not a map');
    expect(got, hasLength(1));
    expect(got.single.id, _bytes(16, 2));
    expect(got.single.blob, _bytes(kBoxBlobBytes, 3));
  });

  group('media', () {
    test(
      'the sid rides a header, the body is sent as is, 201 answers a ref',
      () async {
        late http.Request seen;
        final box = client(
          httpClient: MockClient((req) async {
            seen = req;
            return http.Response(
              jsonEncode({
                'id': boxB64(_bytes(32, 8)),
                'bucket': '4k',
                'expiresAt': '2026-10-07T00:00:00.000Z',
              }),
              201,
            );
          }),
        );
        final sid = _bytes(32, 5);
        final result = await box.uploadMedia(sid, _bytes(4096, 1));

        expect(seen.url.toString(), 'http://box.test/box/media');
        expect(seen.url.toString(), isNot(contains(boxB64(sid))));
        expect(seen.headers['Box-Sid'], boxB64(sid));
        expect(seen.bodyBytes, hasLength(4096));
        final ref = (result as BoxOk<BoxMediaRef>).value;
        expect(ref.id, _bytes(32, 8));
        expect(ref.bucket, '4k');
      },
    );

    test('an off-ladder body is refused before any request', () async {
      final box = client(
        httpClient: MockClient((_) async => fail('no request expected')),
      );
      await expectLater(
        box.uploadMedia(_bytes(32, 5), _bytes(5000, 1)),
        throwsArgumentError,
      );
    });

    test('a spent budget reads quota_exceeded', () async {
      final box = client(
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'quota_exceeded'}), 429),
        ),
      );
      final result = await box.uploadMedia(_bytes(32, 5), _bytes(4096, 1));
      expect(
        result,
        isA<BoxRefused<BoxMediaRef>>().having(
          (r) => r.code,
          'code',
          BoxCode.quotaExceeded,
        ),
      );
    });
  });
}
