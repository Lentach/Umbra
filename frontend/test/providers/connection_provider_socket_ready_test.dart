import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/device_link/link_ceremony_controller.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:fireplace/services/server_clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test double for [SocketService] — simulates connect / socketReady without I/O.
class FakeSocketService extends SocketService {
  final Map<String, List<void Function(dynamic)>> _handlers = {};
  void Function()? _onConnectCallback;
  void Function(dynamic)? _onDisconnectCallback;
  @override
  bool get isConnected => true;

  @override
  void connect({required String baseUrl, required String token}) {}

  @override
  void disconnect() {}

  @override
  void on(String event, void Function(dynamic) callback) {
    _handlers.putIfAbsent(event, () => []).add(callback);
  }

  @override
  void onConnect(void Function() callback) {
    _onConnectCallback = callback;
  }

  @override
  void onDisconnect(void Function(dynamic) callback) {
    _onDisconnectCallback = callback;
  }

  /// The transport dropped (the server or the network ended the socket).
  void simulateDisconnect() {
    _onDisconnectCallback?.call('transport close');
  }

  void simulateTransportConnect() {
    _onConnectCallback?.call();
  }

  /// [payload] mirrors the real `socketReady` body. The server sends
  /// `{serverTime: <ISO-8601>}`; null covers an older server that sends none.
  void simulateSocketReady({Object? payload}) {
    for (final handler in _handlers['socketReady'] ?? const []) {
      handler(payload);
    }
  }

  int getServerTimeCalls = 0;

  @override
  void getServerTime() {
    getServerTimeCalls++;
  }

  void simulateServerTime(Object? payload) {
    for (final handler in _handlers['serverTime'] ?? const []) {
      handler(payload);
    }
  }

  Iterable<String> get listenedEvents => _handlers.keys;
}

class RecordingConnectionProvider extends ConnectionProvider {
  RecordingConnectionProvider({required SocketService socketService})
      : super(socketService: socketService);

  final emitted = <MapEntry<String, dynamic>>[];

  @override
  void emit(String event, dynamic data) {
    emitted.add(MapEntry(event, data));
  }
}

/// Records the local-plaintext maintenance calls `_onSocketReady` fires.
class _RecordingEncryption extends EncryptionProvider {
  final calls = <String>[];

  @override
  Future<void> loadRetiredIds() async => calls.add('loadRetiredIds');

  @override
  Future<void> drainPurgeBacklog() async => calls.add('drainPurgeBacklog');

  @override
  Future<void> sweepDestroyablePlaintext() async =>
      calls.add('sweepDestroyablePlaintext');
}

class _NoIdentity implements LinkIdentityGateway {
  @override
  Future<String?> ownIdentityPublicKeyBase64() async => null;

  @override
  Future<dynamic> ownIdentityKeyPair() async =>
      throw StateError('not used here');

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) async {}

  @override
  Future<void> discardProvisionedIdentity(int userId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionProvider socketReady gating', () {
    late FakeSocketService fakeSocket;
    late RecordingConnectionProvider connection;

    setUp(() {
      fakeSocket = FakeSocketService();
      connection = RecordingConnectionProvider(socketService: fakeSocket);
    });

    tearDown(() {
      connection.disconnect();
    });

    test('socketReady emits none of the removed old-path events', () async {
      final conversations = ConversationsProvider();
      connection.setProviders(
        encryption: EncryptionProvider(),
        friends: FriendsProvider(),
        conversations: conversations,
        messaging: MessagingProvider()..setConversationsProvider(conversations),
      );
      await connection.connect(1, 'test-token', 'http://localhost:3000');
      conversations.openConversation(10);
      connection.emitted.clear();

      fakeSocket.simulateTransportConnect();
      fakeSocket.simulateSocketReady();
      await pumpEventQueue();

      // No chat list, friend list, block list, push-state, history or
      // served-ids request: the contact store is the only source (step 5).
      // (Other emits are the E2E layer's own.)
      for (final removed in const [
        'getConversations',
        'getFriends',
        'getFriendRequests',
        'getBlockedList',
        'pushClientState',
        'getMessages',
        'getServedMessageIds',
      ]) {
        expect(connection.emitted.map((e) => e.key), isNot(contains(removed)));
      }
      for (final removed in const [
        'friendsList',
        'friendRequestsList',
        'conversationsList',
        'messageHistory',
        'newMessage',
        'servedMessageIds',
      ]) {
        expect(fakeSocket.listenedEvents, isNot(contains(removed)));
      }
      expect(connection.isConnected, isTrue);
    });

    test('socketReady tells the provisioning sink the session is ready', () async {
      // (lxviii) clause 1: a devices screen open across a reconnect — above
      // all its own ceremony's rebind — must re-read the list on the socket
      // that can answer, and socketReady is the only moment that is true.
      final sinkEmits = <String>[];
      final sink = LinkCeremonyController(
        userId: 1,
        emit: (event, _) => sinkEmits.add(event),
        identity: _NoIdentity(),
        adoptSession: (_) async {},
        reconnect: (_) async {},
      );
      addTearDown(sink.dispose);
      connection.registerProvisioningSink(sink);
      await connection.connect(1, 'test-token', 'http://localhost:3000');
      fakeSocket.simulateTransportConnect();
      expect(sinkEmits, isNot(contains('getDeviceList')),
          reason: 'transport connect is not authenticated yet');

      fakeSocket.simulateSocketReady();

      expect(sinkEmits.where((e) => e == 'getDeviceList'), hasLength(1));
    });
  });

  group('ConnectionProvider local-plaintext maintenance', () {
    late FakeSocketService fakeSocket;
    late RecordingConnectionProvider connection;
    late _RecordingEncryption encryption;

    setUp(() {
      ServerClock.instance.resetForTest();
      fakeSocket = FakeSocketService();
      connection = RecordingConnectionProvider(socketService: fakeSocket);
      encryption = _RecordingEncryption();
      connection.setProviders(
        encryption: encryption,
        friends: FriendsProvider(),
        conversations: ConversationsProvider(),
        messaging: MessagingProvider(),
      );
    });

    tearDown(() {
      connection.disconnect();
      ServerClock.instance.resetForTest();
    });

    test('socketReady observes the server clock before sweeping', () async {
      await connection.connect(1, 'test-token', 'http://localhost:3000');
      final serverTime = DateTime.utc(2026, 7, 28, 12, 30);

      expect(ServerClock.instance.estimatedNow, isNull,
          reason: 'no observation yet, so the sweep must refuse to destroy');

      fakeSocket.simulateSocketReady(
        payload: {'serverTime': serverTime.toIso8601String()},
      );
      await pumpEventQueue();

      // Without this the expiry sweep silently never destroys anything, on the
      // one platform this feature exists for, with no error anywhere.
      final estimated = ServerClock.instance.estimatedNow;
      expect(estimated, isNotNull);
      expect(estimated!.isBefore(serverTime), isFalse);

      // Order is load-bearing: retired ids must be loaded before anything can
      // try to decrypt a row whose plaintext was already destroyed, and the
      // backlog must drain before the sweep adds more work.
      expect(encryption.calls, [
        'loadRetiredIds',
        'drainPurgeBacklog',
        'sweepDestroyablePlaintext',
      ]);
    });

    test('maintenance still runs when the server sends no clock', () async {
      await connection.connect(1, 'test-token', 'http://localhost:3000');

      fakeSocket.simulateSocketReady();
      await pumpEventQueue();

      // The sweep is internally a no-op with no clock, but the backlog drain
      // must NOT be skipped — it is what finishes a delete that was cut off by
      // a tab close, and it needs no clock at all.
      expect(encryption.calls, contains('drainPurgeBacklog'));
      expect(ServerClock.instance.estimatedNow, isNull);
    });

    test('a reconnect fails every lookup still waiting on the REPLACED socket',
        () async {
      // Its request left on the socket connect() tears down, so its answer
      // can never come; a later lookup that joins it would otherwise wait on
      // a dead request (a box send stuck "sending" forever, 0.2.66).
      await connection.connect(1, 'test-token', 'http://localhost:3000');
      final orphan = Completer<Map<String, dynamic>>();
      encryption.pendingPreKeyFetches[(5, 1)] = orphan;
      final failed = expectLater(orphan.future, throwsA('Disconnected'));

      await connection.connect(
        1,
        'test-token',
        'http://localhost:3000',
        immediate: true,
      );

      await failed;
      expect(encryption.pendingPreKeyFetches, isEmpty,
          reason: 'the next lookup must send a fresh request');
    });
  });

  group('ConnectionProvider in-session expiry sweep timer', () {
    // The timer exists because sweepDestroyablePlaintext otherwise runs ONLY
    // at socketReady: a message expiring while the app stays connected would
    // keep its plaintext on disk until the next reconnect — unbounded for a
    // long-lived PWA. These tests pin both halves: the tick sweeps, and a
    // stale clock asks the server for time instead of silently no-opping
    // forever (ServerClock refuses extrapolation past 30 minutes and its only
    // other feeder is socketReady).
    late FakeSocketService fakeSocket;
    late RecordingConnectionProvider connection;
    late _RecordingEncryption encryption;

    setUp(() {
      ServerClock.instance.resetForTest();
      fakeSocket = FakeSocketService();
      connection = RecordingConnectionProvider(socketService: fakeSocket);
      encryption = _RecordingEncryption();
      connection.setProviders(
        encryption: encryption,
        friends: FriendsProvider(),
        conversations: ConversationsProvider(),
        messaging: MessagingProvider(),
      );
    });

    tearDown(() {
      connection.disconnect();
      ServerClock.instance.resetForTest();
    });

    /// Connect and fire socketReady inside [fake]'s zone so the periodic
    /// timer is fake-controlled. [payload] mirrors the real socketReady body.
    void ready(FakeAsync fake, {Object? payload}) {
      connection.connect(1, 'test-token', 'http://localhost:3000');
      fake.flushMicrotasks();
      fakeSocket.simulateSocketReady(payload: payload);
      fake.flushMicrotasks();
      encryption.calls.clear();
    }

    test('a tick with a confirmed clock sweeps without a round trip', () {
      fakeAsync((fake) {
        ready(fake, payload: {
          'serverTime': DateTime.utc(2026, 7, 28, 12).toIso8601String(),
        });

        fake.elapse(const Duration(minutes: 1));
        fake.flushMicrotasks();

        // The real Stopwatch under ServerClock does not advance in fakeAsync,
        // so the socketReady observation is still fresh here by construction.
        expect(encryption.calls, contains('sweepDestroyablePlaintext'));
        expect(fakeSocket.getServerTimeCalls, 0,
            reason: 'a confirmable clock needs no round trip');
      });
    });

    test(
        'a tick with NO confirmable clock asks for server time instead of '
        'silently doing nothing', () {
      fakeAsync((fake) {
        // No serverTime in socketReady — same observable state as a clock
        // aged past maxExtrapolation.
        ready(fake);

        fake.elapse(const Duration(minutes: 1));
        fake.flushMicrotasks();

        expect(fakeSocket.getServerTimeCalls, 1);
        expect(encryption.calls, isNot(contains('sweepDestroyablePlaintext')),
            reason: 'nothing may be destroyed before the clock is confirmed');
      });
    });

    test('unanswered time requests are floor-limited, not once per tick', () {
      fakeAsync((fake) {
        ready(fake);

        // 4 ticks inside the 5-minute retry floor: exactly ONE request.
        fake.elapse(const Duration(minutes: 4));
        fake.flushMicrotasks();
        expect(fakeSocket.getServerTimeCalls, 1,
            reason: 'an older backend never answers; once per floor window');

        // Past the floor the request is retried.
        fake.elapse(const Duration(minutes: 2));
        fake.flushMicrotasks();
        expect(fakeSocket.getServerTimeCalls, 2);
      });
    });

    test('the serverTime reply observes the clock and sweeps immediately', () {
      fakeAsync((fake) {
        ready(fake);
        fake.elapse(const Duration(minutes: 1));
        fake.flushMicrotasks();
        expect(fakeSocket.getServerTimeCalls, 1);

        fakeSocket.simulateServerTime({
          'serverTime': DateTime.utc(2026, 7, 28, 12).toIso8601String(),
        });
        fake.flushMicrotasks();

        expect(ServerClock.instance.estimatedNow, isNotNull);
        expect(encryption.calls, contains('sweepDestroyablePlaintext'));
      });
    });

    test('a malformed serverTime reply neither observes nor sweeps', () {
      fakeAsync((fake) {
        ready(fake);
        fake.elapse(const Duration(minutes: 1));
        fake.flushMicrotasks();

        fakeSocket.simulateServerTime({'serverTime': 42});
        fake.flushMicrotasks();

        expect(ServerClock.instance.estimatedNow, isNull,
            reason: 'a malformed stamp must not become a confident clock');
        expect(encryption.calls, isNot(contains('sweepDestroyablePlaintext')));
      });
    });

    test('disconnect stops the timer', () {
      fakeAsync((fake) {
        ready(fake, payload: {
          'serverTime': DateTime.utc(2026, 7, 28, 12).toIso8601String(),
        });

        connection.disconnect();
        encryption.calls.clear();
        fake.elapse(const Duration(minutes: 10));
        fake.flushMicrotasks();

        expect(encryption.calls, isEmpty);
        expect(fakeSocket.getServerTimeCalls, 0);
      });
    });
  });
}
