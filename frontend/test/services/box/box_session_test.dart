import 'dart:typed_data';

import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_session.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/box_fakes.dart';

Uint8List _bytes(int length, int fill) =>
    Uint8List(length)..fillRange(0, length, fill);

Map<String, String> _address(int fill) => {
  'rid': boxB64(_bytes(32, fill)),
  'sid': boxB64(_bytes(32, fill + 1)),
  'nid': boxB64(_bytes(16, fill + 2)),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  late FakeBoxSockets sockets;
  late BoxSession session;
  late Map<String, String> address;
  late List<Map<String, Object?>> published;

  /// Answers the box like a server holding exactly the queues it created;
  /// [gone] rids are refused on subscribe, as a reaped queue is.
  final gone = <String>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    store = ContactStore(
      open: () async => kv,
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );
    await store.open(1);
    address = _address(0x10);
    gone.clear();
    sockets = FakeBoxSockets()
      ..respond = (_, f) => switch (f.event) {
        'createQueue' => {'ok': true, ...address},
        'subscribe' => {
          'ok': true,
          'refused': [
            for (final s in (f.frame['subs']! as List<Object?>))
              if (gone.contains((s! as Map)['rid']))
                {'rid': (s as Map)['rid'], 'code': 'auth_failed'},
          ],
        },
        _ => {'ok': true},
      };
    published = [];
    session = BoxSession(
      box: BoxClient(baseUrl: 'http://box.test', socketFactory: sockets.call),
      store: store,
      emit: (event, data) {
        if (event == 'setRequestQueue') {
          published.add(Map<String, Object?>.from(data! as Map));
        }
      },
    )..start();
  });

  tearDown(() => session.dispose());

  Future<void> boxUp(String sockId) async {
    sockets.last.serverConnect(sockId);
    await pumpEventQueue();
  }

  Future<void> accountReady(int? deviceId) async {
    session.accountReady(deviceId);
    await pumpEventQueue();
  }

  test(
    'publishes the request queue once BOTH the box and the account socket '
    'are up — box first',
    () async {
      await boxUp('S1');
      expect(published, isEmpty, reason: 'the account socket is not ready');
      await accountReady(2);
      expect(published, [
        {'sid': address['sid'], 'sealPub': store.requestQueue!.sealPub},
      ]);
    },
  );

  test('— account first', () async {
    await accountReady(2);
    expect(published, isEmpty, reason: 'no queue before the box is up');
    await boxUp('S1');
    expect(published.single['sid'], address['sid']);
  });

  test(
    'an accepted publish is not repeated on a same-device reconnect, and is '
    'repeated for a new device id (a reset re-homes the account)',
    () async {
      await boxUp('S1');
      await accountReady(2);
      session
        ..onRequestQueueSet({'success': true})
        ..accountLost();
      await accountReady(2);
      expect(published, hasLength(1));

      session.accountLost();
      await accountReady(5);
      expect(published, hasLength(2));
    },
  );

  test('a refused publish is sent again on the next ready', () async {
    await boxUp('S1');
    await accountReady(2);
    session.onRequestQueueSet({'success': false, 'error': 'internal'});
    await accountReady(2);
    expect(published, hasLength(2));
  });

  test('a rate-limited publish is sent again after retryAfterMs', () async {
    await boxUp('S1');
    await accountReady(2);
    session.onRequestQueueSet({
      'success': false,
      'error': 'rate_limited',
      'retryAfterMs': 5,
    });
    expect(published, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await pumpEventQueue();
    expect(published, hasLength(2));
  });

  test(
    'an answer lost with the account socket is sent again on the next ready',
    () async {
      await boxUp('S1');
      await accountReady(2);
      session.accountLost();
      await accountReady(2);
      expect(published, hasLength(2));
    },
  );

  test(
    'a request queue the box refuses on a reconnect (reaped) is replaced and '
    'the new address published',
    () async {
      await boxUp('S1');
      await accountReady(2);
      session.onRequestQueueSet({'success': true});
      final first = address;

      gone.add(first['rid']!);
      address = _address(0x40);
      sockets.last.serverDrop();
      await pumpEventQueue();
      // The box's own backoff opens the next connection (~1-2 s).
      for (var i = 0; i < 100 && sockets.sockets.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await boxUp('S2');

      expect(published.map((p) => p['sid']), [first['sid'], address['sid']]);
      expect(store.requestQueue?.rid, address['rid']);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'a store that opens only after both sockets are ready (web vault booted '
    'locked, then unlocked) still gets its queue published',
    () async {
      store.close();
      await boxUp('S1');
      await accountReady(2);
      expect(published, isEmpty, reason: 'no store, no queue');

      await store.open(1);
      session.storeOpened();
      await pumpEventQueue();
      expect(published.single['sid'], address['sid']);
    },
  );

  test('dispose closes the box connection', () async {
    await boxUp('S1');
    session.dispose();
    expect(sockets.last.disposed, isTrue);
  });
}
