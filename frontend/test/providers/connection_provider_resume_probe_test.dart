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

      expect(sock.getServerTimeCalls, 1); // resync issued
      expect(_logged('RESUME_RESYNC'), isTrue);
      expect(sock.connectCalls, 0); // no reconnect yet

      fake.elapse(const Duration(seconds: 7)); // probe window passes silently

      expect(_logged('RESUME_PROBE_TIMEOUT'), isTrue);
      expect(sock.connectCalls, 1); // forced fresh connect
    });
  });

  // `connect()` itself counts once; every count past it is a FORCED
  // reconnect. The provider's connect cooldown reads `package:clock`, so
  // the 6 s probe window is past it under fake_async: a forced connect runs
  // rather than being deferred by the debounce, unseen.
  test('silence in the probe window forces a fresh connect (control)', () {
    fakeAsync((fake) {
      final sock = _FakeSocketService();
      final provider = ConnectionProvider(socketService: sock);
      unawaited(provider.connect(1, 'tok', 'http://test'));
      fake.flushMicrotasks();
      expect(sock.connectCalls, 1);
      sock.connectedClaim = true;

      provider.ensureReconnectIfNeeded();
      fake
        ..elapse(const Duration(seconds: 7))
        ..flushMicrotasks();

      expect(sock.connectCalls, 2);
    });
  });

  // The resume probe asks for the server time and counts its answer as the
  // liveness evidence: a resume must stay a resume with no list to ask for.
  test('probe asks for the server time; its answer alone disarms it', () {
    fakeAsync((fake) {
      final sock = _FakeSocketService();
      final provider = ConnectionProvider(socketService: sock);
      unawaited(provider.connect(1, 'tok', 'http://test'));
      fake.flushMicrotasks();
      sock.connectedClaim = true;

      provider.ensureReconnectIfNeeded();
      expect(sock.getServerTimeCalls, 1);

      // Only the time answers; no list is ever listened for.
      expect(sock.handlers.containsKey('conversationsList'), isFalse);
      sock.handlers['serverTime']!.call({
        'serverTime': '2026-10-22T10:00:00.000Z',
      });
      fake
        ..elapse(const Duration(seconds: 7))
        ..flushMicrotasks();

      expect(sock.connectCalls, 1, reason: 'no forced reconnect');
    });
  });
}
