import 'dart:typed_data';

import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/box/box_wire.dart';
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
  late _AccountSocket account;
  late _RecordingConnection connection;
  late _QuietEncryption encryption;
  late FakeBoxSockets sockets;
  late List<String> boxUrls;

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
    encryption = _QuietEncryption();
    connection = _RecordingConnection(socketService: account)
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
        boxClient: (baseUrl) {
          boxUrls.add(baseUrl);
          return BoxClient(baseUrl: baseUrl, socketFactory: sockets.call);
        },
      );
  });

  tearDown(() => connection.disconnect(isLogout: true));

  test(
    "connect() opens the box on the account's server; the request queue is "
    'published once the account socket is ready, and not again after the '
    'server accepted it',
    () async {
      await connection.connect(1, 'token', 'http://api.test');
      expect(boxUrls, ['http://api.test']);
      expect(sockets.last.url, 'http://api.test/box');
      sockets.last.serverConnect('S1');
      await pumpEventQueue();

      // Nothing is published before this connect's E2E is ready: a device on
      // the link gate (no identity) holds the PRIMARY's token.
      account.serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      expect(connection.published, isEmpty);
      encryption.onE2EReady!();
      await pumpEventQueue();
      expect(connection.published, [
        {'sid': address['sid'], 'sealPub': isA<String>()},
      ]);

      account
        ..serve('requestQueueSet', {'success': true})
        ..drop()
        ..serve('socketReady', {'deviceId': 2});
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

  test('logout closes the box; the next account gets its own', () async {
    await connection.connect(1, 'token', 'http://api.test');
    final first = sockets.last;
    connection.disconnect(isLogout: true);
    expect(first.disposed, isTrue);

    await connection.connect(2, 'token', 'http://api.test', immediate: true);
    expect(boxUrls, hasLength(2));
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
      boxes.last.serverConnect('S1');
      await pumpEventQueue();
      lockedAccount.serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      expect(booted.published, isEmpty, reason: 'the vault is locked');

      locked = false;
      await encryption.onPasscodeLockRestore!();
      // A locked vault parks E2E init until the unlock; it is ready now.
      encryption.onE2EReady!();
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
      sockets.last.serverConnect('S1');
      await pumpEventQueue();
      account.serve('socketReady', {'deviceId': 2});
      await pumpEventQueue();
      expect(asks(), 0, reason: 'E2E is not ready');

      encryption.onE2EReady!();
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
}
