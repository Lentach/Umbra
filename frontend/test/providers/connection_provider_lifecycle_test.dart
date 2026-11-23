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
}
