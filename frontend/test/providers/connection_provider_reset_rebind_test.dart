import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fireplace/constants/app_constants.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// The §6.2 recovery ack re-homes this account onto a NEWLY allocated device
/// and hands back the session bound to it. The server states the contract at
/// its own emit site: *the client MUST adopt these before uploading one-time
/// pre-keys, or those keys land in the namespace the teardown just abandoned.*
///
/// That upload is triggered BY the ack — `onKeyBundleUploaded` replenishes on
/// `identityChanged` — so the whole contract is an ORDERING one, and ordering
/// is what these tests pin. A test that only checked "the token was persisted"
/// would pass with the adoption running after the ack and the pre-keys still
/// landing on the revoked device.
class _FakeSocket extends SocketService {
  final Map<String, List<void Function(dynamic)>> handlers = {};
  int connects = 0;
  int disconnects = 0;

  @override
  bool get isConnected => true;

  /// Faithful to the real [SocketService], which DISPOSES `_socket` and builds
  /// a fresh one — so every previously registered listener goes with it. A fake
  /// that kept them would accumulate handlers across the rebind's reconnect and
  /// report duplicate deliveries that production cannot produce.
  @override
  void connect({required String baseUrl, required String token}) {
    handlers.clear();
    connects++;
  }

  @override
  void disconnect() {
    handlers.clear();
    disconnects++;
  }

  /// Replacement enrollments this recovery emitted ((xlv) clause 1).
  final List<Map<String, dynamic>> enrollments = [];

  @override
  void enrollDeviceAuthority(Map<String, dynamic> payload) {
    enrollments.add(payload);
  }

  @override
  void on(String event, void Function(dynamic) callback) {
    handlers.putIfAbsent(event, () => []).add(callback);
  }

  @override
  void onConnect(void Function() callback) {}

  @override
  void onDisconnect(void Function(dynamic) callback) {}

  void emitServer(String event, dynamic payload) {
    for (final h in List.of(handlers[event] ?? const [])) {
      h(payload);
    }
  }
}

/// Supplies the account identity the replacement enrollment is signed with.
/// The real service reads it from a keystore this test has no business
/// standing up.
class _FakeEncryptionService extends EncryptionService {
  _FakeEncryptionService(this.pair);
  final IdentityKeyPair pair;

  @override
  Future<IdentityKeyPair> identityKeyPairForLinking() async => pair;
}

/// Records WHEN the ack reached the encryption layer, relative to the rebind.
class _RecordingEncryption extends EncryptionProvider {
  _RecordingEncryption(this.order, EncryptionService service)
    : super(service: service);
  final List<String> order;

  @override
  void onKeyBundleUploaded(dynamic data) => order.add('ack');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSocket socket;
  late List<String> order;
  late ConnectionProvider conn;

  Future<void> connectOnce() =>
      conn.connect(7, 'old-token', 'http://127.0.0.1:3000');

  setUp(() async {
    // The armed DAK write of (xlv) clause 1 goes through secure storage, and
    // `persistArmed` only counts a write it can read back.
    FlutterSecureStorage.setMockInitialValues({});
    socket = _FakeSocket();
    order = <String>[];
    conn = ConnectionProvider(socketService: socket);
    conn.setProviders(
      encryption: _RecordingEncryption(
        order,
        _FakeEncryptionService(generateIdentityKeyPair()),
      ),
      friends: FriendsProvider(),
      conversations: ConversationsProvider(),
      messaging: MessagingProvider(),
    );
    await connectOnce();
  });

  tearDown(() => conn.dispose());

  Map<String, dynamic> recoveryAck() => {
    'success': true,
    'identityChanged': true,
    'deviceId': 3,
    'access_token': 'new-access',
    'refresh_token': 'new-refresh',
  };

  test('adopts the session and reconnects BEFORE delivering the ack', () async {
    final adopted = <Map<String, dynamic>>[];
    conn.onSessionRebound = (tokens) async {
      order.add('adopt');
      adopted.add(tokens);
    };
    final connectsBefore = socket.connects;

    socket.emitServer('keyBundleUploaded', recoveryAck());
    await Future<void>.delayed(Duration.zero);

    expect(
      order,
      ['adopt', 'ack'],
      reason:
          'the ack is what triggers the pre-key upload, so adopting after it '
          'publishes those keys under the device the teardown revoked',
    );
    expect(adopted.single, {
      'access_token': 'new-access',
      'refresh_token': 'new-refresh',
    });
    expect(
      socket.connects,
      greaterThan(connectsBefore),
      reason: 'persisting the token is not enough — the SOCKET must rebind',
    );
  });

  test('an ordinary ack is passed straight through, untouched', () async {
    var adoptCalls = 0;
    conn.onSessionRebound = (_) async => adoptCalls++;
    final connectsBefore = socket.connects;

    socket.emitServer('keyBundleUploaded', {
      'success': true,
      'identityChanged': false,
    });
    await Future<void>.delayed(Duration.zero);

    expect(order, ['ack']);
    expect(adoptCalls, 0, reason: 'no reset happened; nothing to adopt');
    expect(socket.connects, connectsBefore);
  });

  test('a refusal never rebinds, even carrying a token-shaped body', () async {
    var adoptCalls = 0;
    conn.onSessionRebound = (_) async => adoptCalls++;

    socket.emitServer('keyBundleUploaded', {
      'success': false,
      'error': 'identity_locked',
      'access_token': 'attacker-supplied',
      'refresh_token': 'attacker-supplied',
    });
    await Future<void>.delayed(Duration.zero);

    expect(adoptCalls, 0);
    expect(order, ['ack']);
  });

  test('a HALF payload is ignored rather than half-adopted', () async {
    var adoptCalls = 0;
    conn.onSessionRebound = (_) async => adoptCalls++;

    // An access token with no refresh token would leave a session that cannot
    // be renewed — worse than not adopting at all.
    socket.emitServer('keyBundleUploaded', {
      'success': true,
      'identityChanged': true,
      'access_token': 'only-access',
    });
    await Future<void>.delayed(Duration.zero);

    expect(adoptCalls, 0);
    expect(order, ['ack']);
  });

  test('the ack still reaches the client when the rebind THROWS', () async {
    conn.onSessionRebound = (_) async {
      order.add('adopt');
      throw StateError('storage unavailable');
    };

    socket.emitServer('keyBundleUploaded', recoveryAck());
    await Future<void>.delayed(Duration.zero);

    expect(
      order,
      ['adopt', 'ack'],
      reason:
          'dropping the ack strands the stashed pre-keys forever, which is '
          'worse than publishing them somewhere a later rebind can replace',
    );
  });

  test('a SECOND recovery LATER in the same session still rebinds', () async {
    var adoptCalls = 0;
    conn.onSessionRebound = (_) async => adoptCalls++;

    socket.emitServer('keyBundleUploaded', recoveryAck());
    await Future<void>.delayed(Duration.zero);

    // Past the floor: a later ceremony is a legitimate second recovery, and the
    // latch must not have closed for the lifetime of the provider.
    await withClock(
      Clock.fixed(
        DateTime.now().add(AppConstants.reconnectConnectCooldown * 2),
      ),
      () async {
        socket.emitServer('keyBundleUploaded', recoveryAck());
        await Future<void>.delayed(Duration.zero);
      },
    );

    expect(
      adoptCalls,
      2,
      reason:
          'the in-flight latch guards concurrency, not the lifetime of the '
          'provider — a later ceremony is a legitimate second rebind',
    );
  });

  test('a REPEATED ack inside the floor is throttled, not re-adopted', () async {
    var adoptCalls = 0;
    conn.onSessionRebound = (_) async => adoptCalls++;

    // This ack is entirely server-driven and its rebind bypasses the reconnect
    // cooldown, so a flapping or hostile server must not be able to drive
    // unbounded socket churn and token rewrites by repeating it.
    for (var i = 0; i < 5; i++) {
      socket.emitServer('keyBundleUploaded', recoveryAck());
      await Future<void>.delayed(Duration.zero);
    }

    expect(adoptCalls, 1);
    expect(
      order.where((e) => e == 'ack').length,
      5,
      reason: 'every ack is still delivered — throttling must not swallow it',
    );
  });

  // --- (xlv) clause 1: the recovery re-enrolls the device authority --------
  // The teardown revoked every device the surviving list names and allocated
  // an id it does not name, so without this the account is addressable by
  // nobody. It cannot live on LinkCeremonyController: that is registered by
  // DevicesScreen, and a recovery runs at login with no screen mounted.

  test('a recovery re-enrolls at the server-named version and device', () async {
    conn.onSessionRebound = (_) async {};

    socket.emitServer('keyBundleUploaded', {
      ...recoveryAck(),
      'nextListVersion': 4,
    });
    // Let the rebind + mint + armed DAK persist run, then answer the enroll.
    await pumpEventQueue();
    socket.emitServer('deviceAuthorityEnrolled', {'success': true});
    await pumpEventQueue();

    expect(
      socket.enrollments,
      hasLength(1),
      reason: 'a completed recovery owes exactly one replacement enrollment',
    );
    final list = parseCanonicalDeviceList(
      base64Decode(socket.enrollments.single['listCanonical'] as String),
    );
    expect(
      list.version,
      4,
      reason:
          'the replacement must carry the version the server named — the '
          'client cannot read a row whose enrollment signature is orphaned',
    );
    expect(
      list.devices.map((d) => d.deviceId),
      [3],
      reason:
          'it must name the freshly allocated id, never device 1: ids are '
          'never reused ((a)) and device 1 is what the teardown revoked',
    );
  });

  test('a repeated offer with NO rebind still re-enrolls (the retry path)', () async {
    conn.onSessionRebound = (_) async {};

    // The recovery's own attempt died — dropped socket, killed app. The
    // teardown runs only on the upload that consumed the ceremony, so nothing
    // re-fires on its own; the server re-offers the terms on every
    // authenticated upload instead. No tokens here, so the rebind path must
    // NOT run.
    socket.emitServer('keyBundleUploaded', {
      'success': true,
      'identityChanged': false,
      'deviceId': 5,
      'nextListVersion': 2,
    });
    await pumpEventQueue();
    socket.emitServer('deviceAuthorityEnrolled', {'success': true});
    await pumpEventQueue();

    expect(socket.connects, 1, reason: 'a retry offer must not rebind');
    expect(socket.enrollments, hasLength(1));
    final retried = parseCanonicalDeviceList(
      base64Decode(socket.enrollments.single['listCanonical'] as String),
    );
    expect(retried.version, 2);
    expect(retried.devices.map((d) => d.deviceId), [5]);
  });

  test('an IMPLAUSIBLE server-named version is refused, not signed', () async {
    conn.onSessionRebound = (_) async {};

    // Every later DAK-signed mutation must strictly exceed the stored version,
    // so signing a number near the ceiling would freeze this account's device
    // list permanently — and it would stay frozen after the server turned
    // honest again. The client cannot authenticate the number, so it bounds it.
    socket.emitServer('keyBundleUploaded', {
      ...recoveryAck(),
      'nextListVersion': 2147483000,
    });
    await pumpEventQueue();

    expect(socket.enrollments, isEmpty);
  });

  test('an ack that names no version enrolls NOTHING', () async {
    conn.onSessionRebound = (_) async {};

    // An older server that reissues a session without naming the version.
    // Guessing 1 against a surviving row reads as a rollback attempt, so the
    // client must decline to guess rather than mint something refusable.
    socket.emitServer('keyBundleUploaded', recoveryAck());
    await pumpEventQueue();

    expect(socket.enrollments, isEmpty);
  });

  test('an ORDINARY ack never re-enrolls', () async {
    conn.onSessionRebound = (_) async {};

    // No rebind, so no teardown happened and the device list is untouched.
    // Re-enrolling here would replace a live DAK the account still holds.
    socket.emitServer('keyBundleUploaded', {
      'success': true,
      'identityChanged': false,
      'nextListVersion': 4,
    });
    await pumpEventQueue();

    expect(socket.enrollments, isEmpty);
  });

  test('a RESTORED rebind adopts + reconnects but NEVER re-enrolls', () async {
    // (lxxviii): the restore kept its DAK and its enrollment — E still
    // verifies under the unchanged identity, and the restore machine
    // re-signs the list via `updateDeviceList`. Minting a replacement
    // enrollment here would discard the very authority the backup preserved.
    var adopted = 0;
    conn.onSessionRebound = (_) async => adopted++;
    final connectsBefore = socket.connects;

    socket.emitServer('keyBundleUploaded', {
      ...recoveryAck(),
      'identityChanged': false,
      'restored': true,
      'nextListVersion': 4,
    });
    await pumpEventQueue();

    expect(adopted, 1, reason: 'the rebind itself must still run');
    expect(socket.connects, greaterThan(connectsBefore));
    expect(order, contains('ack'));
    expect(socket.enrollments, isEmpty,
        reason: 'a restored account keeps its DAK — updateDeviceList, not enroll');
  });

  test('a RESTORED offer with NO rebind never re-enrolls either', () async {
    conn.onSessionRebound = (_) async {};

    // The (lxxviii) restore ack rides every later authenticated upload, and
    // this one carries no session — the restore already rebound, or the ack
    // arrived on a socket that needs no rebind. The no-rebind branch must
    // honour the same exemption as the rebind branch: the restore PRESERVED
    // the DAK and its enrollment (E still verifies under the unchanged
    // identity), so minting a replacement enrollment here would discard the
    // very authority the phrase backup exists to keep, and every peer holding
    // the old E would be re-anchored onto a DAK the account never needed.
    socket.emitServer('keyBundleUploaded', {
      'success': true,
      'restored': true,
      'deviceId': 5,
      'nextListVersion': 3,
    });
    await pumpEventQueue();

    expect(socket.connects, 1, reason: 'no tokens — nothing to rebind');
    expect(
      socket.enrollments,
      isEmpty,
      reason: 'a restored account re-signs via updateDeviceList, not enroll',
    );
    expect(
      order,
      ['ack'],
      reason: 'the exemption must skip the enrollment, never swallow the ack',
    );
  });

  test('a second offer INSIDE the ack window enrolls ONCE, and the answer still lands', () async {
    conn.onSessionRebound = (_) async {};

    Map<String, dynamic> offer(int version) => {
      'success': true,
      'identityChanged': false,
      'deviceId': 5,
      'nextListVersion': version,
    };

    // The offer rides EVERY authenticated upload and the listener fires the
    // pass unawaited, so a second upload arriving before
    // `deviceAuthorityEnrolled` used to start an entire second pass: two DAKs
    // minted, the pending slot AND the ack completer overwritten, and then the
    // first pass's `finally` cleared the survivor's completer — so the server's
    // answer had nowhere to land, both passes timed out on the 20 s ceiling,
    // and the account stayed addressable by nobody ((lxxxv)).
    socket.emitServer('keyBundleUploaded', offer(2));
    await pumpEventQueue();
    socket.emitServer('keyBundleUploaded', offer(2));
    await pumpEventQueue();

    expect(
      socket.enrollments,
      hasLength(1),
      reason: 'the duplicate offer must cost nothing — one pass is already it',
    );

    socket.emitServer('deviceAuthorityEnrolled', {'success': true});
    await pumpEventQueue();

    // This second enrollment is the load-bearing half: it can only happen if
    // the answer above reached the pass that was waiting (which releases the
    // latch). A clobbered completer leaves the pass stuck until its timeout,
    // so a still-held latch would swallow this offer and leave the count at 1.
    socket.emitServer('keyBundleUploaded', offer(3));
    await pumpEventQueue();

    expect(
      socket.enrollments,
      hasLength(2),
      reason:
          'the latch guards CONCURRENCY, not the session — and the answer '
          'must have landed for it to have cleared at all',
    );
  });
}
