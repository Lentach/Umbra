import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls; base SocketService methods are `_socket?.emit` null-safe
/// no-ops, so only the observed members need overriding.
class _FakeSocketService extends SocketService {
  bool connectedClaim = false;
  int connectCalls = 0;
  int getConversationsCalls = 0;
  int getServerTimeCalls = 0;
  final Map<String, void Function(dynamic)> handlers = {};

  @override
  bool get isConnected => connectedClaim;

  @override
  void connect({required String baseUrl, required String token}) {
    connectCalls++;
  }

  @override
  void on(String event, void Function(dynamic) callback) {
    handlers[event] = callback;
  }

  @override
  void onConnect(void Function() callback) {}

  @override
  void onDisconnect(void Function(dynamic) callback) {}

  @override
  void disconnect() {}

  @override
  void getConversations() {
    getConversationsCalls++;
  }

  @override
  void getServerTime() {
    getServerTimeCalls++;
  }
}

bool _logged(String step) =>
    E2eDiagLog.entries.any((e) => e.contains(step));

void main() {
  setUp(E2eDiagLog.clear);

  test('resume with dead socket reconnects immediately', () {
    final sock = _FakeSocketService();
    final provider = ConnectionProvider(socketService: sock);
    provider.setIdentityForTest(1, 'tok');
    sock.connectedClaim = false;

    provider.ensureReconnectIfNeeded();

    expect(sock.connectCalls, 1);
    expect(_logged('RESUME_CHECK'), isTrue);
  });

  test('zombie socket: resync, then forced reconnect after probe window', () {
    fakeAsync((fake) {
      final sock = _FakeSocketService();
      final provider = ConnectionProvider(socketService: sock);
      provider.setIdentityForTest(1, 'tok');
      sock.connectedClaim = true; // socket CLAIMS connected (iOS zombie)

      provider.ensureReconnectIfNeeded();

      expect(sock.getConversationsCalls, 1); // resync issued
      expect(_logged('RESUME_RESYNC'), isTrue);
      expect(sock.connectCalls, 0); // no reconnect yet

      fake.elapse(const Duration(seconds: 7)); // probe window passes silently

      expect(_logged('RESUME_PROBE_TIMEOUT'), isTrue);
      expect(sock.connectCalls, 1); // forced fresh connect
    });
  });

  test('probe is disarmed when a server response arrives in the window', () {
    fakeAsync((fake) {
      final sock = _FakeSocketService();
      final provider = ConnectionProvider(socketService: sock);
      // Full connect() registers the event handlers that bump the
      // liveness counter.
      provider.connect(1, 'tok', 'http://test');
      fake.flushMicrotasks();
      sock.connectedClaim = true;

      provider.ensureReconnectIfNeeded();
      expect(_logged('RESUME_RESYNC'), isTrue);

      // Server responds within the window → socket is alive.
      sock.handlers['conversationsList']!.call(<dynamic>[]);
      fake.elapse(const Duration(seconds: 7));

      expect(_logged('RESUME_PROBE_TIMEOUT'), isFalse);
    });
  });

  // Phase 4 step 4: the server stops answering `getConversations` for good
  // (silence, never `[]`), and `conversationsList` was the one reply the
  // probe counted. A resume must stay a resume: its liveness evidence is the
  // answer to a request that outlives the old tables.
  test('probe asks for the server time; its answer alone disarms it', () {
    fakeAsync((fake) {
      final sock = _FakeSocketService();
      final provider = ConnectionProvider(socketService: sock);
      unawaited(provider.connect(1, 'tok', 'http://test'));
      fake.flushMicrotasks();
      sock.connectedClaim = true;

      provider.ensureReconnectIfNeeded();
      expect(sock.getServerTimeCalls, 1);

      // `conversationsList` never arrives; only the time does.
      sock.handlers['serverTime']!.call({
        'serverTime': '2026-10-22T10:00:00.000Z',
      });
      fake.elapse(const Duration(seconds: 7));

      expect(_logged('RESUME_PROBE_TIMEOUT'), isFalse);
    });
  });
}
