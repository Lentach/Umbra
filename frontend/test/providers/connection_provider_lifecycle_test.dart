import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/auth_token_store.dart';
import 'package:fireplace/services/box/box_client.dart';
import 'package:fireplace/services/contacts/contact_backup_service.dart';
import 'package:fireplace/services/contacts/contact_store.dart';
import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/server_clock.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/box_fakes.dart';

const _url = 'http://api.test';

/// The account socket, driven by hand. Records every `connect` (by token) and
/// `disconnect` the provider asks for.
class _Socket extends SocketService {
  final connectTokens = <String>[];
  int disconnectCalls = 0;
  final Map<String, List<void Function(dynamic)>> _handlers = {};
  void Function()? _onConnect;
  void Function(dynamic)? _onDisconnect;

  @override
  bool get isConnected => true;

  /// A new socket each time, as the real service: the handlers of the one it
  /// replaces are gone with it.
  @override
  void connect({required String baseUrl, required String token}) {
    _handlers.clear();
    connectTokens.add(token);
  }

  @override
  void disconnect() => disconnectCalls++;
  @override
  void on(String event, void Function(dynamic) callback) =>
      _handlers.putIfAbsent(event, () => []).add(callback);
  @override
  void onConnect(void Function() callback) => _onConnect = callback;
  @override
  void onDisconnect(void Function(dynamic) callback) =>
      _onDisconnect = callback;
  @override
  void getServerTime() {}

  void transportConnect() => _onConnect?.call();

  void serve(String event, [Object? payload]) {
    for (final handler in List.of(
      _handlers[event] ?? const <void Function(dynamic)>[],
    )) {
      handler(payload);
    }
  }

  /// The transport dropped (the server or the network ended the socket).
  void drop() => _onDisconnect?.call('transport close');
}

class _Encryption extends EncryptionProvider {
  _Encryption(this.log);
  final List<String> log;

  @override
  void clearAll() {
    log.add('encryption.clearAll');
    super.clearAll();
  }

  @override
  void onConnect(bool isReconnect) {
    log.add('encryption.onConnect($isReconnect)');
    super.onConnect(isReconnect);
  }

  @override
  Future<void> initializeE2E(int userId) async {
    log.add('encryption.initializeE2E($userId)');
  }

  @override
  Future<void> forgetKeyChangeLog({int? peerId}) async {
    log.add('encryption.forgetKeyChangeLog($peerId)');
  }
}

class _Friends extends FriendsProvider {
  _Friends(this.log);
  final List<String> log;
  int contactsChanged = 0;

  @override
  void clearAll() {
    log.add('friends.clearAll');
    super.clearAll();
  }

  @override
  void onConnect(bool isReconnect) {
    log.add('friends.onConnect($isReconnect)');
    super.onConnect(isReconnect);
  }

  @override
  void onContactsChanged() {
    contactsChanged++;
    super.onContactsChanged();
  }
}

class _Conversations extends ConversationsProvider {
  _Conversations(this.log);
  final List<String> log;

  @override
  void clearAll() {
    log.add('conversations.clearAll');
    super.clearAll();
  }

  @override
  void onConnect(bool isReconnect) {
    log.add('conversations.onConnect($isReconnect)');
    super.onConnect(isReconnect);
  }
}

class _Messaging extends MessagingProvider {
  _Messaging(this.log);
  final List<String> log;

  @override
  void clearAll() {
    log.add('messaging.clearAll');
    super.clearAll();
  }

  @override
  void onConnect(bool isReconnect) {
    log.add('messaging.onConnect($isReconnect)');
    super.onConnect(isReconnect);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Socket socket;
  late ConnectionProvider connection;
  late List<String> log;
  late _Friends friends;

  /// Wires the four recording sub-providers, with whatever else a test needs.
  void wire({
    ContactStore? contactStore,
    ContactBackupService? contactBackup,
  }) {
    connection.setProviders(
      encryption: _Encryption(log),
      friends: friends = _Friends(log),
      conversations: _Conversations(log),
      messaging: _Messaging(log),
      contactStore: contactStore,
      contactBackup: contactBackup,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServerClock.instance.resetForTest();
    socket = _Socket();
    connection = ConnectionProvider(socketService: socket);
    log = [];
  });

  tearDown(() => connection.disconnect(isLogout: true));

  // MC-02. Mutation: `isReconnect = (_currentUserId != userId)`.
  group('connect() tells a reconnect from another account', () {
    setUp(() async {
      wire();
      await connection.connect(1, 'token', _url);
      log.clear();
    });

    // Decision 152: the permanent "keys updated" lines go with the contact.
    test("unfriending a contact removes that contact's permanent key-change "
        'lines', () async {
      friends.onRemoveConversationsForUser!(2);

      expect(log, contains('encryption.forgetKeyChangeLog(2)'));
    });

    test('the same account again keeps every list: onConnect(true) and no '
        'clearAll', () async {
      await connection.connect(1, 'token', _url, immediate: true);

      expect(log, [
        'encryption.onConnect(true)',
        'friends.onConnect(true)',
        'conversations.onConnect(true)',
        'messaging.onConnect(true)',
      ]);
    });

    test('another account clears every sub-provider once, then '
        'onConnect(false)', () async {
      await connection.connect(2, 'token', _url, immediate: true);

      expect(log, [
        'encryption.clearAll',
        'friends.clearAll',
        'conversations.clearAll',
        'messaging.clearAll',
        'encryption.onConnect(false)',
        'friends.onConnect(false)',
        'conversations.onConnect(false)',
        'messaging.onConnect(false)',
      ]);
    });
  });

  // MC-03 and 03a/03b/03c: the four `_connectGeneration != generation` checks
  // in connect(). Mutation, one per test: remove the check named.
  group('a newer connect() wins over one still waiting', () {
    late ContentKv kv;

    ContactStore storeOpening(Future<void> gate) => ContactStore(
      open: () async {
        await gate;
        return kv;
      },
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );

    setUp(() async {
      kv = await PrefsContentKv.open();
    });

    // MC-03a: the check after `await installRetiring`.
    test("on a revoked install's queue delete: one socket connect, with the "
        'new token', () async {
      final boxes = FakeBoxSockets()..respond = (_, _) => {'ok': true};
      wire();
      connection.retireRevokedInstall(
        2,
        baseUrl: _url,
        store: () => storeOpening(Future.value()),
        box: (url) => BoxClient(baseUrl: url, socketFactory: boxes.call),
      );
      await pumpEventQueue();

      final older = connection.connect(2, 'old', _url);
      await pumpEventQueue();
      expect(socket.connectTokens, isEmpty, reason: 'waits for the delete');
      final newer = connection.connect(2, 'new', _url, immediate: true);
      boxes.last.serverConnect('S1');
      await Future.wait([older, newer]);

      expect(socket.connectTokens, ['new']);
    });

    // MC-03: the check after the contact store's open.
    test('on the contact store open: one socket connect, with the new '
        'token', () async {
      final gate = Completer<void>();
      wire(contactStore: storeOpening(gate.future));

      final older = connection.connect(2, 'old', _url);
      await pumpEventQueue();
      expect(socket.connectTokens, isEmpty, reason: 'waits for the store');
      final newer = connection.connect(2, 'new', _url, immediate: true);
      gate.complete();
      await Future.wait([older, newer]);

      expect(socket.connectTokens, ['new']);
    });

    // MC-03b: the check inside the late-open callback.
    test('a store that opens after the budget hydrates once, for the newest '
        'connect only', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        wire(contactStore: storeOpening(gate.future));

        unawaited(connection.connect(2, 'old', _url));
        async.elapse(ConnectionProvider.kContactStoreOpenBudget);
        expect(socket.connectTokens, ['old'], reason: 'the budget ran out');
        unawaited(connection.connect(2, 'new', _url, immediate: true));
        async.elapse(ConnectionProvider.kContactStoreOpenBudget);
        expect(socket.connectTokens, ['old', 'new']);
        friends.contactsChanged = 0;

        gate.complete();
        async.flushMicrotasks();

        expect(friends.contactsChanged, 1);
        connection.disconnect(isLogout: true);
        async.flushMicrotasks();
      });
    });

    // MC-03c: the check after the contact-backup restore wait.
    test('on the contact backup restore: one socket connect, with the new '
        'token', () async {
      final gate = Completer<void>();
      final backup = ContactBackupService(
        api: ApiService(
          baseUrl: 'http://t',
          httpClient: MockClient((_) async {
            await gate.future;
            return http.Response('{}', 404);
          }),
        ),
        tokens: AuthTokenStore(useSecureStorage: false),
      );
      wire(contactStore: storeOpening(Future.value()), contactBackup: backup);
      final resolving = backup.onSession(userId: 2, token: 'old');

      final older = connection.connect(2, 'old', _url);
      await pumpEventQueue();
      expect(socket.connectTokens, isEmpty, reason: 'waits for the backup');
      final newer = connection.connect(2, 'new', _url, immediate: true);
      gate.complete();
      await Future.wait([older, newer, resolving]);

      expect(socket.connectTokens, ['new']);
    });
  });

  // CONN-01. Mutation: drop the `_connectGeneration++` from `disconnect()` /
  // `dispose()`.
  group('a connect() still waiting does not outlive the session', () {
    ContactStore storeOpening(Future<void> gate) => ContactStore(
      open: () async {
        await gate;
        return PrefsContentKv.open();
      },
      lock: <T>(_, action) => action(),
      accepts: (_) => true,
    );

    test('a logout while the contact store opens: no socket is opened once '
        'the store lands', () async {
      final gate = Completer<void>();
      wire(contactStore: storeOpening(gate.future));

      final waiting = connection.connect(2, 'token', _url);
      await pumpEventQueue();
      expect(socket.connectTokens, isEmpty, reason: 'waits for the store');
      connection.disconnect(isLogout: true);
      gate.complete();
      await waiting;
      await pumpEventQueue();

      expect(socket.connectTokens, isEmpty);
    });

    test('a dispose while the contact store opens: no socket is opened once '
        'the store lands', () async {
      final gate = Completer<void>();
      final doomedSocket = _Socket();
      final doomed = ConnectionProvider(socketService: doomedSocket)
        ..setProviders(
          encryption: _Encryption(log),
          friends: _Friends(log),
          conversations: _Conversations(log),
          messaging: _Messaging(log),
          contactStore: storeOpening(gate.future),
        );

      final waiting = doomed.connect(2, 'token', _url);
      await pumpEventQueue();
      expect(doomedSocket.connectTokens, isEmpty, reason: 'waits for the store');
      doomed.dispose();
      gate.complete();
      // Unfixed, the resumed connect may also throw on the disposed notifier;
      // the socket is what this test is about.
      await waiting.catchError((Object _) {});
      await pumpEventQueue();

      expect(doomedSocket.connectTokens, isEmpty);
    });
  });

  // CONN-06. Mutation: call `initializeE2E` from `_onSocketTransportConnect`
  // again instead of from the `socketReady` handler.
  group('E2E init waits for the server to finish authenticating', () {
    List<String> inits() =>
        log.where((e) => e.startsWith('encryption.initializeE2E')).toList();

    test('a transport connect emits nothing; socketReady starts it once', () {
      fakeAsync((async) {
        wire();
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();

        // The server binds its handlers at connect but sets the user only
        // after its JWT, user and revocation lookups: an event emitted now is
        // dropped there.
        socket.transportConnect();
        async.flushMicrotasks();
        expect(inits(), isEmpty, reason: 'auth is not finished');

        socket.serve('socketReady');
        async.flushMicrotasks();
        expect(inits(), ['encryption.initializeE2E(1)']);
        connection.disconnect(isLogout: true);
      });
    });

    test('a link that never turns ready is dropped by the watchdog without '
        'ever starting E2E', () {
      fakeAsync((async) {
        wire();
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();
        socket.transportConnect();
        final dropped = socket.disconnectCalls;

        async.elapse(const Duration(seconds: 11));

        expect(socket.disconnectCalls, dropped + 1);
        expect(inits(), isEmpty);
        connection.disconnect(isLogout: true);
      });
    });
  });

  // CONN-02. Mutation: pass the captured `token` from the debounce timer.
  group('a connect() the cooldown deferred', () {
    test('opens with the token a refresh brought while it waited', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'old', _url));
        async.flushMicrotasks();
        unawaited(connection.connect(1, 'old', _url));
        async.flushMicrotasks();
        expect(socket.connectTokens, ['old'], reason: 'deferred');

        connection.applyRefreshedAccessToken('fresh');
        async.elapse(AppConstants.reconnectConnectCooldown);

        expect(socket.connectTokens, ['old', 'fresh']);
        connection.disconnect(isLogout: true);
      });
    });

    // The control: with no refresh since, the caller's token is the newest.
    test('opens with its own token when nothing was refreshed since', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'old', _url));
        async.flushMicrotasks();
        unawaited(connection.connect(2, 'other', _url));
        async
          ..flushMicrotasks()
          ..elapse(AppConstants.reconnectConnectCooldown);

        expect(socket.connectTokens, ['old', 'other']);
        connection.disconnect(isLogout: true);
      });
    });
  });

  // CONN-05. Mutation: drop `_resumeProbeTimer?.cancel()` from `connect()`.
  test('a resume probe armed before a fresh connect does not replace the '
      'healthy socket that connect opened', () {
    fakeAsync((async) {
      unawaited(connection.connect(1, 'token', _url));
      async.flushMicrotasks();
      socket
        ..transportConnect()
        ..serve('socketReady');
      connection.ensureReconnectIfNeeded(); // arms the 6 s probe
      async.elapse(const Duration(seconds: 3));

      // The socket died; the reconnect completes inside the probe window.
      unawaited(connection.connect(1, 'token', _url));
      async.flushMicrotasks();
      socket
        ..transportConnect()
        ..serve('socketReady');
      final opened = socket.connectTokens.length;

      async.elapse(const Duration(seconds: 7));

      expect(socket.connectTokens, hasLength(opened));
      connection.disconnect(isLogout: true);
    });
  });

  // CONN-03. Mutation: drop `_reconnectManager.cancel()` before the socket
  // swap in `connect()`.
  test('the old socket dropping while a connect() is parked does not tear '
      'down the healthy session that connect then opens', () {
    fakeAsync((async) {
      var gate = Future<void>.value();
      final store = ContactStore(
        open: () async {
          await gate;
          return PrefsContentKv.open();
        },
        lock: <T>(_, action) => action(),
        accepts: (_) => true,
      );
      wire(contactStore: store);
      unawaited(connection.connect(1, 'a', _url));
      async.flushMicrotasks();
      socket
        ..transportConnect()
        ..serve('socketReady');

      final slow = Completer<void>();
      gate = slow.future;
      unawaited(connection.connect(2, 'b', _url, immediate: true));
      async.flushMicrotasks();
      // The old socket is still live while the store opens, and it dies.
      socket.drop();
      slow.complete();
      async.flushMicrotasks();
      socket
        ..transportConnect()
        ..serve('socketReady');
      expect(socket.connectTokens, ['a', 'b']);

      async.elapse(AppConstants.reconnectMaxDelay);

      expect(socket.connectTokens, ['a', 'b']);
      connection.disconnect(isLogout: true);
    });
  });

  // MC-09. Mutation: drop `_reconnectManager.resetAttempts()` from
  // `_onSocketReady`.
  test('a session that turned ready starts its reconnect count over: every '
      'drop schedules a reconnect, past the attempt cap', () {
    fakeAsync((async) {
      unawaited(connection.connect(1, 'token', _url));
      async.flushMicrotasks();

      for (
        var drop = 1;
        drop <= AppConstants.reconnectMaxAttempts + 1;
        drop++
      ) {
        socket
          ..transportConnect()
          ..serve('socketReady');
        final before = socket.connectTokens.length;

        socket.drop();
        async.elapse(
          AppConstants.reconnectMaxDelay +
              AppConstants.reconnectConnectCooldown,
        );

        expect(
          socket.connectTokens,
          hasLength(before + 1),
          reason: 'drop $drop reconnects',
        );
        expect(connection.errorMessage, isNull, reason: 'drop $drop');
      }
      connection.disconnect(isLogout: true);
    });
  });

  group('the socketReady watchdog', () {
    const pastWindow = Duration(seconds: 11);

    /// Connects and returns how often the provider had dropped the socket by
    /// then (connect() itself replaces the old one).
    int connectTransport(FakeAsync async) {
      unawaited(connection.connect(1, 'token', _url));
      async.flushMicrotasks();
      socket.transportConnect();
      return socket.disconnectCalls;
    }

    // MC-W5. Mutation: drop `_socketReadyWatchdog?.cancel()` from
    // `_onSocketReady`.
    test('leaves a link that turned ready alone', () {
      fakeAsync((async) {
        final dropped = connectTransport(async);
        socket.serve('socketReady');

        async.elapse(pastWindow);

        expect(socket.disconnectCalls, dropped);
        expect(connection.isConnected, isTrue);
        connection.disconnect(isLogout: true);
      });
    });

    // MC-W1. Mutation: drop the `_serverResponseCounter != armedAt` check.
    test('leaves a link alone that answered serverTime but is slow to turn '
        'ready', () {
      fakeAsync((async) {
        final dropped = connectTransport(async);
        socket.serve('serverTime', {'serverTime': '2026-11-23T10:00:00.000Z'});

        async.elapse(pastWindow);

        expect(socket.disconnectCalls, dropped);
        connection.disconnect(isLogout: true);
      });
    });

    // The control for the two above: the watchdog does fire in this harness.
    test('drops a link that said nothing for the whole window, once', () {
      fakeAsync((async) {
        final dropped = connectTransport(async);

        async.elapse(pastWindow);

        expect(socket.disconnectCalls, dropped + 1);
        connection.disconnect(isLogout: true);
      });
    });
  });

  // X3: an account deleted on another device. The server drops this device's
  // next handshake without a word (no `socketReady`, no event), so a socket
  // that goes away BEFORE it ever turned ready is the one moment the session
  // is worth asking the server about.
  group('a handshake that never turned ready asks the session probe', () {
    late int probes;

    setUp(() {
      probes = 0;
      connection.onSessionRejected = () async => probes++;
    });

    test('a drop before socketReady runs the probe once', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();
        socket
          ..transportConnect()
          ..drop();
        async.flushMicrotasks();

        expect(probes, 1);
        connection.disconnect(isLogout: true);
      });
    });

    test('a drop after socketReady is an ordinary drop: no probe', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();
        socket
          ..transportConnect()
          ..serve('socketReady')
          ..drop();
        async.flushMicrotasks();

        expect(probes, 0);
        connection.disconnect(isLogout: true);
      });
    });

    test('a drop this app asked for is not a rejection', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();
        socket.transportConnect();
        connection.disconnect();

        socket.drop();
        async.flushMicrotasks();

        expect(probes, 0);
        connection.disconnect(isLogout: true);
      });
    });

    test('a reconnect loop of rejected handshakes probes at most once per '
        'spacing', () {
      fakeAsync((async) {
        unawaited(connection.connect(1, 'token', _url));
        async.flushMicrotasks();
        socket
          ..transportConnect()
          ..drop();
        async.flushMicrotasks();
        expect(probes, 1);

        async.elapse(const Duration(seconds: 5));
        socket
          ..transportConnect()
          ..drop();
        async.flushMicrotasks();
        expect(probes, 1, reason: 'inside the spacing');

        async.elapse(ConnectionProvider.kSessionProbeSpacing);
        socket
          ..transportConnect()
          ..drop();
        async.flushMicrotasks();
        expect(probes, 2, reason: 'a later rejection asks again');
        connection.disconnect(isLogout: true);
      });
    });
  });
}
