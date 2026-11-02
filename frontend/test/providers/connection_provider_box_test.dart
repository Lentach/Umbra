import 'dart:typed_data';

import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_wire.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/box_fakes.dart';

/// The account socket, driven by hand: records handlers so the test can
/// deliver `socketReady` / `requestQueueSet` / a drop.
class _AccountSocket extends SocketService {
  final Map<String, List<void Function(dynamic)>> _handlers = {};
  void Function(dynamic)? _onDisconnect;

  @override
  bool get isConnected => true;
  @override
  void connect({required String baseUrl, required String token}) {}
  @override
  void disconnect() {}
  @override
  void on(String event, void Function(dynamic) callback) =>
      _handlers.putIfAbsent(event, () => []).add(callback);
  @override
  void onConnect(void Function() callback) {}
  @override
  void onDisconnect(void Function(dynamic) callback) =>
      _onDisconnect = callback;
  @override
  void getConversations() {}
  @override
  void getFriendRequests() {}
  @override
  void getFriends() {}
  @override
  void getBlockedList() {}

  void serve(String event, Object? payload) {
    for (final handler in _handlers[event] ?? const <void Function(dynamic)>[]) {
      handler(payload);
    }
  }

  void drop() => _onDisconnect?.call('transport close');
}

class _RecordingConnection extends ConnectionProvider {
  _RecordingConnection({required super.socketService});

  final published = <Object?>[];
  final events = <String>[];

  @override
  void emit(String event, dynamic data) {
    events.add(event);
    if (event == 'setRequestQueue') published.add(data);
  }
}

/// No local-plaintext maintenance: nothing here is about stored messages.
class _QuietEncryption extends EncryptionProvider {
  @override
  Future<void> loadRetiredIds() async {}
  @override
  Future<void> drainPurgeBacklog() async {}
  @override
  Future<void> sweepDestroyablePlaintext() async {}
  @override
  Future<void> reconcileStoredPlaintext(
    Future<Set<int>?> Function(Set<int> batch) askServer, {
    bool force = false,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentKv kv;
  late ContactStore store;
  late _AccountSocket account;
  late _RecordingConnection connection;
  late _QuietEncryption encryption;
  late FakeBoxSockets sockets;
  late List<String> boxUrls;
  // The device id the install's stored session names (every tab shares it).
  int? storedDeviceId;

  final address = {
    'rid': boxB64(Uint8List(32)..fillRange(0, 32, 0x21)),
    'sid': boxB64(Uint8List(32)..fillRange(0, 32, 0x22)),
    'nid': boxB64(Uint8List(16)..fillRange(0, 16, 0x23)),
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = await PrefsContentKv.open();
    account = _AccountSocket();
    sockets = FakeBoxSockets()
      ..respond = (_, f) => switch (f.event) {
        'createQueue' => {'ok': true, ...address},
        'subscribe' => {'ok': true, 'refused': <Object?>[]},
        _ => {'ok': true},
      };
    boxUrls = [];
    storedDeviceId = 2;
    encryption = _QuietEncryption();
    connection = _RecordingConnection(socketService: account)
      ..setProviders(
        encryption: encryption,
        friends: FriendsProvider(),
        conversations: ConversationsProvider(),
        messaging: MessagingProvider(),
        contactStore: store = ContactStore(
          open: () async => kv,
          lock: <T>(_, action) => action(),
          accepts: (_) => true,
        ),
        boxClient: (baseUrl) {
          boxUrls.add(baseUrl);
          return BoxClient(baseUrl: baseUrl, socketFactory: sockets.call);
        },
        storedSessionDeviceId: () async => storedDeviceId,
      );
  });

  tearDown(() => connection.disconnect(isLogout: true));

  test(
    "the box opens on the account's server once E2E is ready; the request "
    'queue is published once the account socket is ready, and not again '
    'after the server accepted it',
    () async {
      await connection.connect(1, 'token', 'http://api.test');
      expect(boxUrls, ['http://api.test']);
      account.serve('socketReady', {'deviceId': 2});
      encryption.onE2EReady!();
      expect(sockets.last.url, 'http://api.test/box');
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      expect(connection.published, [
        {'sid': address['sid'], 'sealPub': isA<String>()},
      ]);

      // Nothing is published before THIS connect's E2E is ready: a link
      // rebind adopts the identity on the old token.
      account
        ..serve('requestQueueSet', {'success': true})
        ..drop()
        ..serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      expect(connection.published, hasLength(1));
      encryption.onE2EReady!();
      await pumpEventQueue();
      expect(connection.published, hasLength(1));
    },
  );

  test('a reconnect of the same account keeps its box session', () async {
    await connection.connect(1, 'token', 'http://api.test');
    await connection.connect(1, 'token', 'http://api.test', immediate: true);
    expect(boxUrls, hasLength(1));
  });

  // Mutation: drop `..listsByHandle = isFriend` (or the `friend` state from
  // `keepsDeviceListFor`) in `ConnectionProvider.connect`.
  test('a friend in the contact store is looked up by handle and its list is '
      'kept; anyone else is neither (decision 114, E114a)', () async {
    await connection.connect(1, 'token', 'http://api.test');
    await store.update(
      5,
      (_) => const ContactRecord(
        userId: 5,
        username: 'bob',
        tag: '0005',
        state: ContactState.friend,
      ),
    );
    await store.update(
      6,
      (_) => const ContactRecord(
        userId: 6,
        username: 'eve',
        tag: '0006',
        state: ContactState.former,
      ),
    );

    expect(encryption.listIsByHandle(5), isTrue);
    expect(encryption.keepsDeviceListFor!(5), isTrue);
    expect(encryption.listIsByHandle(6), isFalse, reason: 'no longer a friend');
    expect(encryption.keepsDeviceListFor!(6), isFalse);
    expect(encryption.listIsByHandle(7), isFalse, reason: 'no record at all');
    expect(encryption.keepsDeviceListFor!(7), isFalse);
  });

  test('logout closes the box; the next account gets its own', () async {
    await connection.connect(1, 'token', 'http://api.test');
    encryption.onE2EReady!();
    final first = sockets.last;
    connection.disconnect(isLogout: true);
    expect(first.disposed, isTrue);

    await connection.connect(2, 'token', 'http://api.test', immediate: true);
    expect(boxUrls, hasLength(2));
  });

  group('a resume probes the box socket', () {
    const judged = Duration(milliseconds: 100);

    Set<Object?> ridsSubscribedOn(FakeBoxSocket socket) => {
      for (final f in socket.emitted)
        if (f.event == 'subscribe')
          for (final sub in f.frame['subs']! as List<Object?>)
            (sub! as Map<Object?, Object?>)['rid'],
    };

    test(
      'and replaces one that still claims to be connected but has heard no '
      'ping, even when the account socket survived; the new one resubscribes',
      () async {
        await connection.connect(1, 'token', 'http://api.test');
        encryption.onE2EReady!();
        final suspended = sockets.last..serverConnect('S1');
        await pumpEventQueue();
        final held = ridsSubscribedOn(suspended);
        expect(held, isNotEmpty, reason: 'the session holds a queue');

        // iOS suspended the page: the box transport died, but socket.io only
        // notices at its ping timeout, so the socket still says connected.
        suspended.lastHeardAt = DateTime.now().subtract(
          const Duration(minutes: 2),
        );
        connection.ensureReconnectIfNeeded();
        await Future<void>.delayed(kBoxResumeGrace + judged);
        await pumpEventQueue();

        expect(suspended.disposed, isTrue);
        expect(sockets.sockets, hasLength(2));
        final fresh = sockets.last;
        expect(fresh.connectCalled, isTrue);
        expect(boxUrls, hasLength(1), reason: 'the box session is kept');

        fresh.serverConnect('S2');
        await pumpEventQueue();
        expect(ridsSubscribedOn(fresh), held);
      },
    );

    test('and keeps one the server pings (decision 76)', () async {
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      final live = sockets.last..serverConnect('S1');
      await pumpEventQueue();
      live.lastHeardAt = DateTime.now().subtract(const Duration(minutes: 2));

      connection.ensureReconnectIfNeeded();
      // The ping the suspension held back lands once the page runs again.
      live.serverPing();
      await Future<void>.delayed(kBoxResumeGrace + judged);
      await pumpEventQueue();

      expect(live.disposed, isFalse);
      expect(sockets.sockets, hasLength(1));
    });
  });

  test('without a box factory wired nothing is opened', () async {
    final bare = _RecordingConnection(socketService: _AccountSocket())
      ..setProviders(
        encryption: _QuietEncryption(),
        friends: FriendsProvider(),
        conversations: ConversationsProvider(),
        messaging: MessagingProvider(),
      );
    addTearDown(bare.disconnect);
    await bare.connect(1, 'token', 'http://api.test');
    expect(sockets.sockets, isEmpty);
  });

  test(
    'a publish retry still pending at logout never lands on the next '
    "account's socket",
    () async {
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      account.serve('socketReady', {'deviceId': 2});
      encryption.onE2EReady!();
      await pumpEventQueue();
      account.serve('requestQueueSet', {
        'success': false,
        'error': 'rate_limited',
        'retryAfterMs': 5,
      });

      connection.disconnect(isLogout: true);
      await connection.connect(2, 'token', 'http://api.test', immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();
      expect(
        connection.published,
        hasLength(1),
        reason: "account 1's request sid would be filed under account 2",
      );
    },
  );

  test(
    'a web vault that booted locked publishes the request queue once the '
    'unlock re-opens the store',
    () async {
      var locked = true;
      final encryption = _QuietEncryption();
      final boxes = FakeBoxSockets()..respond = sockets.respond;
      final lockedAccount = _AccountSocket();
      final booted = _RecordingConnection(socketService: lockedAccount)
        ..setProviders(
          encryption: encryption,
          friends: FriendsProvider(),
          conversations: ConversationsProvider(),
          messaging: MessagingProvider(),
          contactStore: ContactStore(
            open: () async {
              if (locked) {
                throw const ContentStoreUnavailable('web-locked', locked: true);
              }
              return kv;
            },
            lock: <T>(_, action) => action(),
            accepts: (_) => true,
          ),
          boxClient: (baseUrl) =>
              BoxClient(baseUrl: baseUrl, socketFactory: boxes.call),
        );
      addTearDown(() => booted.disconnect(isLogout: true));

      await booted.connect(1, 'token', 'http://api.test');
      lockedAccount.serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      // A locked vault parks E2E init, so the box waits for the unlock.
      expect(boxes.sockets, isEmpty);

      locked = false;
      await encryption.onPasscodeLockRestore!();
      encryption.onE2EReady!();
      boxes.last.serverConnect('S1');
      await pumpEventQueue();
      expect(booted.published, [
        {'sid': address['sid'], 'sealPub': isA<String>()},
      ]);
    },
  );

  test(
    'the sibling swap is wired: asked once the box, the account socket and '
    'E2E are ready; its answer reaches the session; a change of the OWN '
    "device list asks again, a peer's does not",
    () async {
      final encryption = _QuietEncryption();
      final wired = _RecordingConnection(socketService: account)
        ..setProviders(
          encryption: encryption,
          friends: FriendsProvider(),
          conversations: ConversationsProvider(),
          messaging: MessagingProvider(),
          contactStore: ContactStore(
            open: () async => kv,
            lock: <T>(_, action) => action(),
            accepts: (_) => true,
          ),
          boxClient: (baseUrl) =>
              BoxClient(baseUrl: baseUrl, socketFactory: sockets.call),
        );
      addTearDown(() => wired.disconnect(isLogout: true));
      int asks() =>
          wired.events.where((e) => e == 'getOwnRequestQueues').length;

      await wired.connect(1, 'token', 'http://api.test');
      account.serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      expect(asks(), 0, reason: 'E2E is not ready');

      encryption.onE2EReady!();
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      expect(asks(), 1);

      account.serve('ownRequestQueues', {
        'success': false,
        'error': 'rate_limited',
        'retryAfterMs': 5,
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();
      expect(asks(), 2, reason: 'the answer reached the session');

      account.serve('ownRequestQueues', {'success': false, 'error': 'internal'});
      encryption.invalidateDeviceList(42);
      await pumpEventQueue();
      expect(asks(), 2, reason: "a peer's list says nothing about siblings");
      encryption.invalidateDeviceList(1);
      await pumpEventQueue();
      expect(asks(), 3);
    },
  );

  // Issue #205: a device that cannot do E2E duty under its session — the
  // link gate (identity incomplete, stale material) or a server that could
  // not be asked — must not collect messages it can never show.
  group('a device that is not (or no longer) a linked device', () {
    int framesOn(FakeBoxSocket socket, String event) =>
        socket.emitted.where((f) => f.event == event).length;

    Set<Object?> deletedOn(FakeBoxSocket socket) => {
      for (final f in socket.emitted)
        if (f.event == 'deleteQueue') f.frame['rid'],
    };

    // Mutation: start the box in `connect` regardless of E2E.
    test('opens no box while E2E is not ready (the link gate), and opens it '
        'once E2E is', () async {
      await connection.connect(1, 'token', 'http://api.test');
      account.serve('socketReady', {'deviceId': 1});
      await pumpEventQueue();
      expect(
        sockets.sockets,
        isEmpty,
        reason: 'a gated device would subscribe and drain its queues',
      );

      encryption.onE2EReady!();
      await pumpEventQueue();
      expect(sockets.sockets, hasLength(1));
      expect(sockets.last.connectCalled, isTrue);
    });

    test('a reconnect before E2E is ready does not open it either', () async {
      await connection.connect(1, 'token', 'http://api.test');
      await connection.connect(1, 'token', 'http://api.test', immediate: true);
      expect(sockets.sockets, isEmpty);
    });

    // Mutation: drop the retire from `_onOwnDeviceRevoked`.
    test('deviceRevoked deletes every queue this device holds, subscribes '
        'nothing more and closes the box', () async {
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      final box = sockets.last..serverConnect('S1');
      await pumpEventQueue();
      expect(store.requestQueue, isNotNull, reason: 'the session made one');
      final subscribes = framesOn(box, 'subscribe');

      account.serve('deviceRevoked', {'deviceId': 2});
      await pumpEventQueue();

      expect(deletedOn(box), contains(address['rid']));
      expect(framesOn(box, 'subscribe'), subscribes);
      expect(box.disposed, isTrue);
    });

    // Mutation: drop `forgetAll` from `retireRevokedDevice`.
    test('deviceRevoked while the box connection is down reconnects it '
        'subscribing no queue, and deletes them', () async {
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      final first = sockets.last..serverConnect('S1');
      await pumpEventQueue();
      expect(framesOn(first, 'subscribe'), isPositive);
      first.serverDrop();

      account.serve('deviceRevoked', {'deviceId': 2});
      await pumpEventQueue();
      final box = sockets.last;
      expect(box, isNot(same(first)), reason: 'opened again to delete');
      box.serverConnect('S2');
      await pumpEventQueue();

      final resubscribed = [
        for (final f in box.emitted)
          if (f.event == 'subscribe') ...f.frame['subs']! as List<Object?>,
      ];
      expect(resubscribed, isEmpty);
      expect(deletedOn(box), contains(address['rid']));
      expect(box.disposed, isTrue);
    });

    test('a revoked device that never got E2E opens the box only to delete '
        'its queues, never to subscribe them', () async {
      // A first session left this device's queues in the store.
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      expect(store.requestQueue, isNotNull);
      connection.disconnect(isLogout: true);

      // Signed in again on the link gate; the server says it was revoked.
      encryption.clearAll();
      await connection.connect(1, 'token', 'http://api.test', immediate: true);
      expect(sockets.sockets, hasLength(1), reason: 'the gate opens no box');
      account.serve('deviceRevoked', {'deviceId': 2});
      await pumpEventQueue();
      expect(sockets.sockets, hasLength(2), reason: 'opened only to delete');
      final box = sockets.last..serverConnect('S2');
      await pumpEventQueue();

      expect(deletedOn(box), contains(address['rid']));
      expect(framesOn(box, 'subscribe'), 0);
      expect(box.disposed, isTrue);
    });

    // Mutation: drop the `rehomed` condition in `_onOwnDeviceRevoked`.
    for (final reason in ['reset', 'restored']) {
      test("a $reason eviction of the recovering install's own old id "
          '(rehomed) deletes nothing: another of its tabs holds the same '
          'queues', () async {
        await connection.connect(1, 'token', 'http://api.test');
        encryption.onE2EReady!();
        final box = sockets.last..serverConnect('S1');
        await pumpEventQueue();

        account.serve('deviceRevoked', {
          'deviceId': 2,
          'reason': reason,
          'rehomed': true,
        });
        await pumpEventQueue();

        expect(deletedOn(box), isEmpty);
      });

      // Mutation: gate the delete on `reason == null` again.
      test('a $reason eviction of any other device deletes its queues',
          () async {
        await connection.connect(1, 'token', 'http://api.test');
        encryption.onE2EReady!();
        final box = sockets.last..serverConnect('S1');
        await pumpEventQueue();

        account.serve('deviceRevoked', {
          'deviceId': 2,
          'reason': reason,
          'rehomed': false,
        });
        await pumpEventQueue();

        expect(deletedOn(box), contains(address['rid']));
      });
    }

    // Mutation: drop the store-owner check from `retireRevokedDevice`.
    test('another account signing in while the delete waits for the box '
        'never loses its queues', () async {
      // Account 1's queues are in the store; account 2's too.
      await connection.connect(2, 'token', 'http://api.test');
      encryption.onE2EReady!();
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      expect(store.requestQueue, isNotNull);
      connection.disconnect(isLogout: true);
      encryption.clearAll();
      await connection.connect(1, 'token', 'http://api.test', immediate: true);

      // Account 1 is revoked before its box connects, logs out, and
      // account 2 signs in on the same install at once.
      account.serve('deviceRevoked', {'deviceId': 2});
      await pumpEventQueue();
      final retiring = sockets.last;
      connection.disconnect(isLogout: true);
      await connection.connect(2, 'token', 'http://api.test', immediate: true);
      expect(store.userId, 2);
      retiring.serverConnect('S2');
      await pumpEventQueue();

      expect(deletedOn(retiring), isEmpty);
      expect(store.requestQueue, isNotNull);
    });

    // Mutation: drop the stored-session check from `_onOwnDeviceRevoked`.
    test('a gate-shaped revoke (no reason) after a sibling tab adopted a '
        'reset session deletes nothing', () async {
      await connection.connect(1, 'token', 'http://api.test');
      encryption.onE2EReady!();
      final box = sockets.last..serverConnect('S1');
      await pumpEventQueue();

      // Another tab of this install ran the §6.2 reset: the shared session
      // now names its new device; this tab missed the live eviction and
      // reconnects on its old token, which the connect gate refuses.
      storedDeviceId = 7;
      account.serve('deviceRevoked', {'deviceId': 2});
      await pumpEventQueue();

      expect(deletedOn(box), isEmpty);
      expect(box.disposed, isTrue, reason: 'the box still closes');
    });
  });
}
