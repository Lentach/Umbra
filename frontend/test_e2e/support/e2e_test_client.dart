// Support library for the full-stack two-account E2E wire harness.
//
// NOT part of the default `flutter test` suite (lives in `test_e2e/`, a
// sibling of `test/`). Requires a locally running backend:
//
//   docker-compose up            # repo root: backend :3000 + Postgres
//   cd frontend && flutter test test_e2e
//
// Register throttle is 10/hr per IP and the throttler store is in-memory —
// `docker compose restart backend` resets counters when iterating.
//
// Each E2eClient runs the app's REAL service stack: ApiService (REST auth),
// SocketService (Socket.IO wire), EncryptionService (real libsignal). Only
// the Signal key storage is mocked (in-memory, per-user `e2e_<id>_` prefixes),
// exactly like the existing encryption_service_roundtrip_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/socket_service.dart';
import 'package:fireplace/utils/e2e_envelope.dart';

/// Base URL of the backend under test. Override with the E2E_BASE_URL
/// environment variable when the backend is not on localhost:3000.
String e2eBaseUrl() =>
    Platform.environment['E2E_BASE_URL'] ?? 'http://localhost:3000';

/// The flutter_test binding installs a global HttpOverrides that answers
/// every real HttpClient request with HTTP 400 — including the WebSocket
/// upgrade socket_io_client performs. Call this once AFTER
/// `TestWidgetsFlutterBinding.ensureInitialized()` to restore real
/// networking. Global (not zone-local) on purpose: socket.io reconnect
/// timers can fire outside the test body's zone.
void enableRealNetwork() {
  HttpOverrides.global = null;
}

/// Runs one statement against the harness's own Postgres, out of band.
///
/// **This is the only sanctioned out-of-band write in the harness** (spec §12
/// (xxxvi)), and it exists for exactly one reason: §6.2's reset delay is 72 h,
/// or 1 h with a valid recovery phrase, and a test may not wait either out. It
/// AGES the deadline and then lets the real per-minute sweep complete the
/// ceremony — the production path — rather than forcing the end state.
///
/// Deliberately narrow. It is not a general fixture-loading back door: every
/// other precondition in this suite is built over the wire, because a
/// precondition built by SQL proves nothing about the code that normally
/// builds it.
///
/// Credentials match the harness's own docker-compose stack. The default
/// container is this checkout's (`docker compose up` from the repo root names
/// it `fireplace-db-1`); override with `E2E_DB_CONTAINER` for any other stack.
/// CI resolves it dynamically (`docker compose ps -q db`), so the default only
/// serves local runs — it previously named a sibling WORKTREE's container,
/// which made every SQL-backed test fail with "container is not running" on a
/// normal checkout. If `docker` is unreachable the caller gets a clear
/// StateError rather than a mystery timeout — a test that depends on this
/// channel must SKIP or FAIL loudly, never quietly pass.
Future<List<List<String>>> e2eSql(String statement) async {
  final container =
      Platform.environment['E2E_DB_CONTAINER'] ?? 'fireplace-db-1';
  final ProcessResult result;
  try {
    result = await Process.run('docker', [
      'exec',
      container,
      'psql',
      '-U',
      'postgres',
      '-d',
      'chatdb',
      '-At',
      '-F',
      '|',
      '-c',
      statement,
    ]);
  } on ProcessException catch (error) {
    throw StateError(
      'e2eSql: could not run docker ($error). The wire harness needs the '
      'compose stack it is testing against to be locally reachable.',
    );
  }
  if (result.exitCode != 0) {
    throw StateError(
      'e2eSql failed (exit ${result.exitCode}) for: $statement\n'
      '${result.stderr}',
    );
  }
  final out = (result.stdout as String).trim();
  if (out.isEmpty) return const [];
  return out
      .split(RegExp(r'\r?\n'))
      .map((line) => line.split('|'))
      .toList(growable: false);
}

/// Fails fast (clear message instead of a timeout soup) when the backend is
/// not reachable.
Future<void> requireBackendUp(String baseUrl) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$baseUrl/health'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    if (res.statusCode != 200) {
      throw StateError(
        'Backend /health returned ${res.statusCode} at $baseUrl',
      );
    }
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError(
      'Backend not reachable at $baseUrl ($e).\n'
      'Start it first: `docker-compose up` from the repo root, '
      'then re-run `flutter test test_e2e`.',
    );
  } finally {
    client.close(force: true);
  }
}

class _Waiter {
  _Waiter(this.event, this.where, this.completer);
  final String event;
  final bool Function(dynamic payload)? where;
  final Completer<dynamic> completer;
}

/// Records every tracked socket event and lets tests await one — including
/// events that arrived BEFORE the await (buffered, consumed in order).
class EventLog {
  final Map<String, List<dynamic>> _buffer = {};
  final List<_Waiter> _waiters = [];

  /// `error` events, kept separately so timeout messages can surface them.
  final List<dynamic> errors = [];

  void record(String event, dynamic payload) {
    if (event == 'error') {
      errors.add(payload);
    }
    for (var i = 0; i < _waiters.length; i++) {
      final w = _waiters[i];
      if (w.event == event && (w.where == null || w.where!(payload))) {
        _waiters.removeAt(i);
        w.completer.complete(payload);
        return;
      }
    }
    _buffer.putIfAbsent(event, () => []).add(payload);
  }

  /// Drops every buffered payload for [event].
  ///
  /// [next] scans the WHOLE buffer and takes the first payload satisfying
  /// `where`, with no cursor — so a payload that arrived long before the
  /// action under test can satisfy a later wait and make the assertion
  /// vacuous. Anything asserting a STATE TRANSITION (a list that must become
  /// empty, a count that must drop) has to discard immediately before
  /// triggering the action, or it proves nothing.
  void discard(String event) => _buffer.remove(event);

  /// Awaits an `error` payload whose text contains [marker] and takes it OFF
  /// [errors].
  ///
  /// A refusal the test ASKED for is not an unexpected server error, but
  /// `record` cannot tell the difference — so without this the end-of-run
  /// "no unexpected socket errors" assertion would fail on every deliberate
  /// refusal, and tests would be pushed into not asserting refusals at all.
  Future<dynamic> takeError(String marker, {String? reason}) async {
    final payload = await next(
      'error',
      where: (p) => p.toString().contains(marker),
      reason: reason ?? 'error containing "$marker"',
    );
    errors.remove(payload);
    return payload;
  }

  /// Waits for the next [event] payload (optionally matching [where]).
  /// Buffered payloads are consumed first, in arrival order.
  Future<dynamic> next(
    String event, {
    bool Function(dynamic payload)? where,
    Duration timeout = const Duration(seconds: 10),
    String? reason,
  }) {
    final buffered = _buffer[event];
    if (buffered != null) {
      for (var i = 0; i < buffered.length; i++) {
        if (where == null || where(buffered[i])) {
          final payload = buffered.removeAt(i);
          if (buffered.isEmpty) _buffer.remove(event);
          return Future.value(payload);
        }
      }
    }
    final completer = Completer<dynamic>();
    final waiter = _Waiter(event, where, completer);
    _waiters.add(waiter);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        final seen = _buffer.entries
            .map((e) => '${e.key} x${e.value.length}')
            .join(', ');
        throw TimeoutException(
          'Timed out waiting for "$event"'
          '${reason != null ? ' ($reason)' : ''}. '
          'Buffered events: [$seen]. '
          'Socket errors so far: $errors',
        );
      },
    );
  }

  /// Fails if [event] is already buffered or arrives within [within].
  ///
  /// This delegates matching and waiter cleanup to [next], so it observes the
  /// same whole buffer and future socket events as a positive assertion.
  /// [where] narrows it to one payload shape, so "no SECOND delivery of this
  /// message" does not trip over unrelated traffic on the same event.
  Future<void> none(
    String event, {
    required Duration within,
    bool Function(dynamic payload)? where,
    String? reason,
  }) async {
    try {
      final payload = await next(event, where: where, timeout: within);
      throw StateError(
        'Unexpected "$event" event'
        '${reason != null ? ' ($reason)' : ''}: $payload',
      );
    } on TimeoutException {
      // No matching event arrived during the requested window.
    }
  }
}

/// One headless account running the real client service stack.
class E2eClient {
  E2eClient(this.label, this.baseUrl) : api = ApiService(baseUrl: baseUrl);

  final String label;
  final String baseUrl;
  final ApiService api;
  final SocketService socketService = SocketService();
  final EncryptionService encryption = EncryptionService();
  final EventLog events = EventLog();

  late int userId;
  late String username;
  late String tag;
  late String accessToken;

  /// Satisfies backend policy: >=8 chars, upper + lower + digit.
  static const String password = 'E2eHarness1x';

  /// Every server emission the harness asserts on (or wants visible in
  /// timeout diagnostics). Anything not listed is simply not recorded.
  static const List<String> _trackedEvents = [
    'socketReady',
    'error',
    'keyBundleUploaded',
    'oneTimePreKeysUploaded',
    'preKeyBundleResponse',
    'preKeysLow',
    'sessionRebuildNeeded',
    'ownIdentityReplaced',
    'peerIdentityChanged',
    // Phase 0b: registration lock + reset ceremony.
    'registrationLockNonce',
    'identityResetStatus',
    'identityResetPending',
    'identityResetCancelled',
    'identityResetCancelResult',
    'recoveryKeySet',
    'ownKeyBundleStatus',
    // (lxxviii): the sealed identity backup answer. Unlisted events are
    // recorded nowhere, so without this every backup assert passes vacuously.
    'identityBackup',
    // Phase 2 T2: DAK enrollment + signed device list.
    'deviceAuthorityEnrolled',
    'deviceListUpdated',
    'deviceList',
    'deviceListChanged',
    // Phase 2 T3: §5.1 provisioning ceremony.
    'provisioningOpened',
    'provisioningHelloAck',
    'provisioningHello',
    'provisionDeviceAck',
    'provisioningBlob',
    'provisioningCompleted',
    'provisioningCancelled',
    // Phase 2 T6: §5.5 revocation. Unlisted events are recorded NOWHERE, so
    // without these two every revocation assert would pass vacuously.
    'deviceRevocationCompleted',
    'deviceRevoked',
    'newFriendRequest',
    'friendRequestSent',
    'friendRequestFailed',
    'invitationChatReady',
    'friendRequestAccepted',
    'friendsList',
    'conversationsList',
    'pendingRequestsCount',
    'sentRequestsList',
    'openConversation',
    'messageSent',
    'newMessage',
    'messageHistory',
    'messageEdited',
    'editMessageFailed',
    // T7 (§5.7): the delivery/read projection an edit must never regress.
    // Both statuses ride this ONE event. Unlisted events are recorded NOWHERE,
    // so without it the F8 stamp-preservation assert would pass vacuously.
    'messageDelivered',
    'reactionUpdated',
    'messageDeleted',
    'servedMessageIds',
    // T4 (§5.2 layer 1 + §12 (vi)/(x)): the refused-send answer. EventLog
    // records nothing that is not listed here, so a missing entry would make
    // every refusal assert pass vacuously.
    'deviceListStale',
    // Metadata-privacy PR3.2: first contact (a device publishes its request
    // queue; a stranger's search serves it with a bundle per device).
    'requestQueueSet',
    'searchUsersResult',
  ];

  /// Registers a brand-new account. Fresh every run BY DESIGN: reusing
  /// accounts with fresh client keys would get served a stale previous-run
  /// one-time pre-key (server keeps old unused OTPs, oldest-first) and fail
  /// with a phantom bad MAC.
  Future<void> registerFresh() async {
    final suffix = _randomHex(8);
    final name = 'e2e_${label}_$suffix'; // <=20 chars, [a-zA-Z0-9_]
    final data = await api.register(name, password);
    userId = data['id'] as int;
    username = data['username'] as String;
    tag = data['tag'] as String;
    final login = await api.login('$username#$tag', password);
    accessToken = login['access_token'] as String;
  }

  /// Reuses [other]'s authenticated server account with an independent
  /// client/service instance. Incident harnesses use this to model two app
  /// installations competing for one single-device account.
  void adoptAccountFrom(E2eClient other) {
    userId = other.userId;
    username = other.username;
    tag = other.tag;
    accessToken = other.accessToken;
  }

  /// Generates or loads this instance's Signal state and returns the exact
  /// public upload payload without touching the server.
  Future<Map<String, dynamic>> initializeKeys() async {
    await encryption.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final keys = encryption.getKeysForUpload();
    if (keys == null) {
      throw StateError(
        '$label: fresh EncryptionService produced no keys for upload',
      );
    }
    return keys;
  }

  /// The (lxxviii) backup payload for THIS instance's live identity, straight
  /// out of the production exporter: the `identity_record_v1` and
  /// `dak_record_v1_<uid>` strings verbatim as the stores hold them.
  ///
  /// Capture it BEFORE a test wipes the shared mock stores to model a wiped
  /// install — the wipe destroys the records it reads.
  Future<IdentityBackupPayload> exportIdentityBackup() =>
      encryption.exportIdentityForBackup();

  /// Runs the PRODUCTION restore adopt ((lxxviii) clause 3) over an unsealed
  /// backup and returns the exact public upload payload it staged.
  ///
  /// Deliberately the real `adoptRestoredIdentity` rather than a hand-rolled
  /// install: it is what proves the CLIENT half reinstalls a byte-identical
  /// identity + registrationId (a re-mint would upload a different key and
  /// the server would adjudicate an identity CHANGE, not a restore), and the
  /// fresh signed pre-key / one-time pre-keys it mints are exactly what the
  /// server's OTP purge has to make room for.
  Future<Map<String, dynamic>> adoptRestoredIdentityForUpload(
    IdentityBackupPayload payload,
  ) async {
    await encryption.adoptRestoredIdentity(userId: userId, payload: payload);
    final keys = encryption.getKeysForUpload();
    if (keys == null) {
      throw StateError('$label: restore adopt staged no keys for upload');
    }
    return keys;
  }

  /// Uploads a staged key bundle and waits for the server acknowledgement.
  Future<void> uploadKeyBundle(Map<String, dynamic> keys) async {
    socketService.uploadKeyBundle(
      (keys['keyBundle'] as Map).cast<String, dynamic>(),
    );
    await events.next('keyBundleUploaded', reason: '$label key bundle');
  }

  /// Uploads a bundle WITHOUT any registration-lock proof and returns the
  /// server's answer payload (success or refusal) instead of asserting.
  Future<Map<String, dynamic>> uploadKeyBundleRaw(
    Map<String, dynamic> keys, {
    String? identitySignature,
    String? restoreSignature,
    String? nonce,
  }) async {
    final bundle = (keys['keyBundle'] as Map).cast<String, dynamic>();
    events.discard('keyBundleUploaded');
    socketService.socket!.emit('uploadKeyBundle', {
      ...bundle,
      'identitySignature': ?identitySignature,
      'restoreSignature': ?restoreSignature,
      'nonce': ?nonce,
    });
    final answer = await events.next(
      'keyBundleUploaded',
      reason: '$label key bundle answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Asks the server for a registration-lock nonce (§6.1).
  Future<String> fetchRegistrationLockNonce() async {
    events.discard('registrationLockNonce');
    socketService.socket!.emit('getRegistrationLockNonce', <String, dynamic>{});
    final payload = await events.next(
      'registrationLockNonce',
      reason: '$label registration lock nonce',
    );
    return (payload as Map)['nonce'] as String;
  }

  /// Signs `newIdentityPublicKey ‖ userId ‖ nonce` with the identity key this
  /// instance currently holds — i.e. produces the proof a legitimate key
  /// rotation would carry (§6.1).
  ///
  /// Reads the key pair out of storage rather than widening the production
  /// API: nothing in the app has a reason to hand out a private key.
  ///
  /// Sound here specifically because this harness only ever runs on the VM:
  /// `DualStorage` branches on `kIsWeb || _debugForceSealedWeb`, and on the
  /// non-web side it reads and writes exactly `FlutterSecureStorage`
  /// (signal_stores.dart:151-157), whose test mock is a static map shared by
  /// every instance. On web this would read the wrong backend.
  /// Serialized identity key pair currently in this instance's storage.
  ///
  /// Capture this BEFORE any test wipes the shared mock stores to build a
  /// second installation — the wipe destroys the record, and signing with
  /// whatever replaced it produces a proof the server correctly refuses.
  Future<String> exportIdentityPair() async {
    const storage = FlutterSecureStorage();
    final raw = await storage.read(key: 'e2e_${userId}_identity_record_v1');
    if (raw == null) {
      throw StateError('$label: no identity record to export');
    }
    return (jsonDecode(raw) as Map)['pair'] as String;
  }

  Future<String> signIdentityChange({
    required String signerPairBase64,
    required String newIdentityPublicKeyBase64,
    required String nonceBase64,
  }) async {
    final pair = IdentityKeyPair.fromSerialized(base64Decode(signerPairBase64));
    final message = Uint8List.fromList([
      ...base64Decode(newIdentityPublicKeyBase64),
      ...utf8.encode(userId.toString()),
      ...base64Decode(nonceBase64),
    ]);
    // Curve.calculateSignature MUTATES its input — hand it a copy.
    final signature = Curve.calculateSignature(
      pair.getPrivateKey(),
      Uint8List.fromList(message),
    );
    return base64Encode(signature);
  }

  /// Starts a reset ceremony (§6.2) and returns the server's status answer.
  Future<Map<String, dynamic>> requestIdentityReset({
    String? recoveryPhrase,
  }) async {
    events.discard('identityResetStatus');
    socketService.socket!.emit('resetIdentityRequest', <String, dynamic>{
      'recoveryPhrase': ?recoveryPhrase,
    });
    final payload = await events.next(
      'identityResetStatus',
      reason: '$label reset request answer',
    );
    return (payload as Map).cast<String, dynamic>();
  }

  /// Cancels the pending ceremony and returns whether anything was cancelled.
  Future<bool> cancelIdentityReset() async {
    events.discard('identityResetCancelResult');
    socketService.socket!.emit('resetIdentityCancel', <String, dynamic>{});
    final payload = await events.next(
      'identityResetCancelResult',
      reason: '$label reset cancel answer',
    );
    return (payload as Map)['cancelled'] == true;
  }

  /// Enrols a recovery phrase (§6.2.1), optionally with the (lxxviii) sealed
  /// identity backup that turns the phrase into a real key backup.
  Future<bool> setRecoveryKey(
    String phrase, {
    Map<String, dynamic>? backup,
  }) async {
    events.discard('recoveryKeySet');
    socketService.socket!.emit('setRecoveryKey', {
      'phrase': phrase,
      'backup': ?backup,
    });
    final payload = await events.next(
      'recoveryKeySet',
      reason: '$label recovery key answer',
    );
    return (payload as Map)['success'] == true;
  }

  /// Fetches the (lxxviii) sealed identity backup. The blob is useless
  /// without the phrase, so the server serves it to any authenticated
  /// session of the account.
  Future<Map<String, dynamic>> getIdentityBackup() async {
    events.discard('identityBackup');
    socketService.socket!.emit('getIdentityBackup', <String, dynamic>{});
    final payload = await events.next(
      'identityBackup',
      reason: '$label identity backup answer',
    );
    return (payload as Map).cast<String, dynamic>();
  }

  /// Reads the server's view of this account's key/protection state.
  Future<Map<String, dynamic>> checkOwnKeyBundle() async {
    events.discard('ownKeyBundleStatus');
    socketService.socket!.emit('checkOwnKeyBundle', <String, dynamic>{});
    final payload = await events.next(
      'ownKeyBundleStatus',
      reason: '$label own bundle status',
    );
    return (payload as Map).cast<String, dynamic>();
  }

  /// Emits `enrollDeviceAuthority` (Phase 2 T2, spec §3) and returns the
  /// server's `deviceAuthorityEnrolled` answer — success or refusal.
  Future<Map<String, dynamic>> enrollDeviceAuthority(
    Map<String, dynamic> payload,
  ) async {
    events.discard('deviceAuthorityEnrolled');
    socketService.socket!.emit('enrollDeviceAuthority', payload);
    final answer = await events.next(
      'deviceAuthorityEnrolled',
      reason: '$label enrollment answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `updateDeviceList` (a DAK-signed list mutation, spec §3/§5.2) and
  /// returns the server's `deviceListUpdated` answer.
  Future<Map<String, dynamic>> updateDeviceList(
    Map<String, dynamic> payload,
  ) async {
    events.discard('deviceListUpdated');
    socketService.socket!.emit('updateDeviceList', payload);
    final answer = await events.next(
      'deviceListUpdated',
      reason: '$label list update answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `getDeviceList` for [targetUserId] and returns the `deviceList`
  /// answer: `{userId, authorization: {...} | null}`.
  Future<Map<String, dynamic>> fetchDeviceList(int targetUserId) async {
    events.discard('deviceList');
    socketService.socket!.emit('getDeviceList', {'userId': targetUserId});
    final answer = await events.next(
      'deviceList',
      where: (p) => p is Map && p['userId'] == targetUserId,
      reason: '$label device list for user $targetUserId',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `revokeDevice` (§5.5) and returns the `deviceRevocationCompleted`
  /// answer. The payload carries the DAK-signed list that ALREADY shows the
  /// device revoked — the server refuses the pair if they disagree.
  Future<Map<String, dynamic>> revokeDevice(
    Map<String, dynamic> payload,
  ) async {
    events.discard('deviceRevocationCompleted');
    socketService.socket!.emit('revokeDevice', payload);
    final answer = await events.next(
      'deviceRevocationCompleted',
      reason: '$label revokeDevice answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `openProvisioning` (§5.1 — the ceremony opener) and returns the
  /// `provisioningOpened` answer. The answer deliberately carries NO
  /// deviceId (spec §12 amendment (a)).
  ///
  /// [role] is (lxxvii) clause 1: `'new'` (default, byte-compatible with the
  /// pre-amendment payload) means the OPENER is the new device and the
  /// primary will send the hello; `'primary'` flips it, and then the
  /// opener's `provisioningHello` relay carries the assigned `deviceId`.
  Future<Map<String, dynamic>> openProvisioning({String? role}) async {
    events.discard('provisioningOpened');
    socketService.socket!.emit('openProvisioning', {'role': ?role});
    final answer = await events.next(
      'provisioningOpened',
      reason: '$label openProvisioning answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Awaits the `provisioningHello` RELAY (the opener's side of the other
  /// party's hello). Under (lxxvii) clause 1 a primary-opened ceremony
  /// relays `deviceId` with it; a new-device-opened one does not.
  Future<Map<String, dynamic>> awaitProvisioningHelloRelay() async {
    final payload = await events.next(
      'provisioningHello',
      reason: '$label provisioningHello relay',
    );
    return (payload as Map).cast<String, dynamic>();
  }

  /// Emits `provisioningHello` (the primary presents its ephemeral) and
  /// returns the `provisioningHelloAck` answer — the ack is how the primary
  /// learns the assigned deviceId (amendment (a)).
  Future<Map<String, dynamic>> provisioningHello({
    required String provisioningId,
    required String ephPubP,
  }) async {
    events.discard('provisioningHelloAck');
    socketService.socket!.emit('provisioningHello', {
      'provisioningId': provisioningId,
      'ephPubP': ephPubP,
    });
    final answer = await events.next(
      'provisioningHelloAck',
      reason: '$label provisioningHello answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `provisionDevice` (blob + signed v+1 mutation, staged not
  /// committed) and returns the `provisionDeviceAck` answer.
  Future<Map<String, dynamic>> provisionDevice(
    Map<String, dynamic> payload,
  ) async {
    events.discard('provisionDeviceAck');
    socketService.socket!.emit('provisionDevice', payload);
    final answer = await events.next(
      'provisionDeviceAck',
      reason: '$label provisionDevice answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `fetchProvisioningBlob` and returns the `provisioningBlob`
  /// answer — a blob re-fetch (falsification 18) or a refusal.
  Future<Map<String, dynamic>> fetchProvisioningBlobAnswer(
    String provisioningId,
  ) async {
    events.discard('provisioningBlob');
    socketService.socket!.emit('fetchProvisioningBlob', {
      'provisioningId': provisioningId,
    });
    final answer = await events.next(
      'provisioningBlob',
      reason: '$label fetchProvisioningBlob answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `provisioningComplete` (two-phase commit, phase two) and returns
  /// the `provisioningCompleted` answer — on success it carries the
  /// deviceId-bound token pair (spec §12 amendment (iii)).
  Future<Map<String, dynamic>> provisioningComplete(
    String provisioningId,
  ) async {
    events.discard('provisioningCompleted');
    socketService.socket!.emit('provisioningComplete', {
      'provisioningId': provisioningId,
    });
    final answer = await events.next(
      'provisioningCompleted',
      reason: '$label provisioningComplete answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Emits `cancelProvisioning` and returns the caller's ack.
  Future<Map<String, dynamic>> cancelProvisioning(String provisioningId) async {
    events.discard('provisioningCancelled');
    socketService.socket!.emit('cancelProvisioning', {
      'provisioningId': provisioningId,
    });
    final answer = await events.next(
      'provisioningCancelled',
      reason: '$label cancelProvisioning answer',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Uploads staged OTPs. [tagIdentityEpoch] selects the current client wire
  /// shape; false deliberately reproduces a pre-epoch legacy client.
  Future<void> uploadOneTimePreKeys(
    Map<String, dynamic> keys, {
    required bool tagIdentityEpoch,
    bool expectRejection = false,
  }) async {
    final preKeys = (keys['oneTimePreKeys'] as List)
        .cast<Map<String, dynamic>>();
    if (tagIdentityEpoch) {
      final bundle = (keys['keyBundle'] as Map).cast<String, dynamic>();
      socketService.socket!.emit('uploadOneTimePreKeys', {
        'keys': preKeys,
        'identityPublicKey': bundle['identityPublicKey'],
      });
    } else {
      socketService.uploadOneTimePreKeys(preKeys);
    }
    if (expectRejection) {
      final error = await events.next('error', reason: '$label OTP rejection');
      if (!error.toString().contains('identity_epoch_required')) {
        throw StateError('Unexpected OTP rejection: $error');
      }
      return;
    }
    await events.next('oneTimePreKeysUploaded', reason: '$label OTPs');
  }

  /// Connects the real Socket.IO client, waits for the server's
  /// `socketReady` (auth complete), and returns its payload.
  Future<dynamic> connectSocket() async {
    socketService.connect(baseUrl: baseUrl, token: accessToken);
    for (final event in _trackedEvents) {
      socketService.on(event, (payload) => events.record(event, payload));
    }
    // connect_error completes with a VALUE (never an error) so the losing
    // branch of Future.any can complete later without becoming an unhandled
    // async error; the listener is removed once auth resolves so transient
    // reconnect churn after socketReady stays silent.
    final connectError = Completer<dynamic>();
    socketService.socket!.on('connect_error', (e) {
      if (!connectError.isCompleted) connectError.complete(e);
    });
    dynamic socketReadyPayload;
    try {
      final firstError = await Future.any<dynamic>([
        events.next('socketReady', reason: '$label socket auth').then((
          payload,
        ) {
          socketReadyPayload = payload;
          return null;
        }),
        connectError.future,
      ]);
      if (firstError != null) {
        throw StateError('$label socket connect_error: $firstError');
      }
      return socketReadyPayload;
    } finally {
      socketService.off('connect_error');
    }
  }

  /// Connects expecting the §5.5 connect gate to REFUSE this session, and
  /// returns the `deviceRevoked` notice the server sends before closing it.
  ///
  /// Separate from [connectSocket] because that one waits for `socketReady`,
  /// which by contract never arrives here (amendment (xxii)): a revoked
  /// device's access JWT stays cryptographically valid, so refusing the
  /// session is the only thing standing between it and a live socket.
  Future<Map<String, dynamic>> connectExpectingRevoked() async {
    events.discard('socketReady');
    events.discard('deviceRevoked');
    socketService.connect(baseUrl: baseUrl, token: accessToken);
    for (final event in _trackedEvents) {
      socketService.on(event, (payload) => events.record(event, payload));
    }
    final notice = await events.next(
      'deviceRevoked',
      reason: '$label refused reconnect must say WHY',
    );
    await events.none(
      'socketReady',
      within: const Duration(seconds: 2),
      reason: 'a revoked device must never reach an authenticated session',
    );
    return (notice as Map).cast<String, dynamic>();
  }

  /// Initializes Signal keys (fresh mock storage → always generates) and
  /// uploads bundle + one-time pre-keys over WS, exactly like
  /// EncryptionProvider does on first run.
  Future<void> initializeAndUploadKeys() async {
    await encryption.initialize(
      userId,
      checkServerIdentity: () async => const ServerIdentityGuard(exists: false),
    );
    final keys = encryption.getKeysForUpload();
    if (keys == null) {
      throw StateError(
        '$label: fresh EncryptionService produced no keys for upload',
      );
    }
    socketService.uploadKeyBundle(
      (keys['keyBundle'] as Map).cast<String, dynamic>(),
    );
    await events.next('keyBundleUploaded', reason: '$label key bundle');
    socketService.socket!.emit('uploadOneTimePreKeys', {
      'keys': (keys['oneTimePreKeys'] as List).cast<Map<String, dynamic>>(),
      'identityPublicKey': (keys['keyBundle'] as Map)['identityPublicKey'],
    });
    await events.next('oneTimePreKeysUploaded', reason: '$label OTPs');
  }

  /// Server enforces a 750 ms per-(requester,target) gap between bundle
  /// fetches (PRE_KEY_FETCH_MIN_INTERVAL_MS); pace with margin so the
  /// harness never trips it into an `error` event.
  static const Duration _bundleFetchGap = Duration(milliseconds: 850);
  final Map<int, DateTime> _lastBundleFetch = {};

  /// Fetches the peer's pre-key bundle over WS. The response bundle is
  /// already flat — directly consumable by EncryptionService.buildSession.
  ///
  /// [deviceId] omitted reproduces a client that has never heard of devices;
  /// the server must answer for the account's default device (§8 rollout).
  Future<Map<String, dynamic>> fetchBundleFor(
    int peerUserId, {
    int? deviceId,
  }) async {
    final payload = await fetchBundleRawFor(peerUserId, deviceId: deviceId);
    final bundle = payload['bundle'];
    if (bundle is! Map) {
      throw StateError(
        '$label: no key bundle on server for user $peerUserId'
        '${deviceId == null ? '' : ' device $deviceId'}: $payload',
      );
    }
    return bundle.cast<String, dynamic>();
  }

  /// Same fetch, returning the whole `preKeyBundleResponse` payload so a test
  /// can assert on a MISSING bundle instead of throwing on it.
  Future<Map<String, dynamic>> fetchBundleRawFor(
    int peerUserId, {
    int? deviceId,
  }) async {
    final last = _lastBundleFetch[peerUserId];
    if (last != null) {
      final wait = _bundleFetchGap - DateTime.now().difference(last);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
    _lastBundleFetch[peerUserId] = DateTime.now();
    events.discard('preKeyBundleResponse');
    socketService.socket!.emit('fetchPreKeyBundle', <String, dynamic>{
      'userId': peerUserId,
      'deviceId': ?deviceId,
    });
    final payload =
        await events.next(
              'preKeyBundleResponse',
              where: (p) => p is Map && p['userId'] == peerUserId,
              reason: '$label fetching bundle for user $peerUserId',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Uploads a key bundle FOR a named device of this account, without going
  /// through the local Signal store: a second device's registration id and
  /// signed pre-key are just opaque strings to the server, and minting a real
  /// second installation would need Phase 2 provisioning.
  Future<Map<String, dynamic>> uploadDeviceKeyBundle({
    required int deviceId,
    required String identityPublicKey,
    required int registrationId,
  }) async {
    events.discard('keyBundleUploaded');
    socketService.socket!.emit('uploadKeyBundle', <String, dynamic>{
      'deviceId': deviceId,
      'registrationId': registrationId,
      'identityPublicKey': identityPublicKey,
      'signedPreKeyId': 0,
      'signedPreKeyPublic': 'dev$deviceId-spk-public',
      'signedPreKeySignature': 'dev$deviceId-spk-signature',
    });
    final answer = await events.next(
      'keyBundleUploaded',
      reason: '$label device $deviceId key bundle',
    );
    return (answer as Map).cast<String, dynamic>();
  }

  /// Uploads one-time pre-keys FOR a named device, reusing whatever keyIds the
  /// caller asks for — the point of falsification 1 is that two devices may
  /// both hold keyId 0.
  Future<void> uploadDeviceOneTimePreKeys({
    required int deviceId,
    required String identityPublicKey,
    required List<int> keyIds,
    required String publicKeyPrefix,
    String? expectRefusal,
  }) async {
    events.discard('oneTimePreKeysUploaded');
    socketService.socket!.emit('uploadOneTimePreKeys', <String, dynamic>{
      'deviceId': deviceId,
      'identityPublicKey': identityPublicKey,
      'keys': [
        for (final keyId in keyIds)
          {'keyId': keyId, 'publicKey': '$publicKeyPrefix$keyId'},
      ],
    });
    if (expectRefusal != null) {
      await events.takeError(
        expectRefusal,
        reason: '$label device $deviceId OTP refusal',
      );
      // A refusal must not also ack: the keys were not stored.
      await events.none(
        'oneTimePreKeysUploaded',
        within: const Duration(milliseconds: 750),
        reason: '$label device $deviceId OTPs were refused',
      );
      return;
    }
    await events.next(
      'oneTimePreKeysUploaded',
      reason: '$label device $deviceId OTPs',
    );
  }

  /// Encrypts [content] in the app's real E2E envelope wire format.
  Future<String> encryptText(int peerUserId, String content) {
    final envelopeJson = jsonEncode(E2eEnvelope.build(content));
    return encryption.encrypt(peerUserId, envelopeJson);
  }

  /// Decrypts a wire ciphertext and returns the envelope's text content.
  Future<String> decryptText(int peerUserId, String ciphertext) async {
    final envelopeJson = await encryption.decrypt(peerUserId, ciphertext);
    return E2eEnvelope.parse(envelopeJson).content;
  }

  /// Emits `sendMessage` with the app's real payload shape and returns the
  /// server's `messageSent` confirmation for [tempId].
  Future<Map<String, dynamic>> sendEncrypted(
    int recipientId,
    String ciphertext, {
    required String tempId,
  }) async {
    socketService.sendMessage(
      recipientId,
      '[encrypted]',
      tempId: tempId,
      encryptedContent: ciphertext,
    );
    final payload =
        await events.next(
              'messageSent',
              where: (p) => p is Map && p['tempId'] == tempId,
              reason: '$label sendMessage tempId=$tempId',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Emits `sendMessage` carrying a `sendToken` (Phase 1, spec §5.4) and
  /// returns the server's `messageSent` confirmation for [tempId].
  ///
  /// Raw emit rather than `SocketService.sendMessage`: the token is a wire
  /// field the app does not send yet, and the point is to exercise the
  /// SERVER's idempotency, not the client's send path.
  Future<Map<String, dynamic>> sendWithToken(
    int recipientId,
    String ciphertext, {
    required String tempId,
    required String sendToken,
  }) async {
    socketService.socket!.emit('sendMessage', <String, dynamic>{
      'recipientId': recipientId,
      'content': '[encrypted]',
      'encryptedContent': ciphertext,
      'tempId': tempId,
      'sendToken': sendToken,
    });
    final payload =
        await events.next(
              'messageSent',
              where: (p) => p is Map && p['tempId'] == tempId,
              reason: '$label sendMessage tempId=$tempId token=$sendToken',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Emits an ENVELOPE-shaped `sendMessage` (spec §5.2 + §12 amendment (v)):
  /// one ciphertext per (recipient user, device), with the device-list stamps
  /// the server cross-checks.
  ///
  /// Raw emit for the same reason as [sendWithToken]: this exercises the
  /// SERVER's fan-out ingest, independent of the app's send path.
  void emitEnvelopeSend(
    int recipientId, {
    required String tempId,
    required List<Map<String, dynamic>> envelopes,
    String? sendToken,
    int? recipientListVersion,
    int? senderListVersion,
  }) {
    socketService.socket!.emit('sendMessage', <String, dynamic>{
      'recipientId': recipientId,
      'content': '[encrypted]',
      'envelopes': envelopes,
      'tempId': tempId,
      'sendToken': ?sendToken,
      'recipientListVersion': ?recipientListVersion,
      'senderListVersion': ?senderListVersion,
    });
  }

  /// The `deviceListStale` refusal for [tempId] (spec §12 (vi)/(x)).
  Future<Map<String, dynamic>> awaitDeviceListStale(String tempId) async {
    final payload =
        await events.next(
              'deviceListStale',
              where: (p) => p is Map && p['tempId'] == tempId,
              reason: '$label deviceListStale tempId=$tempId',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Waits for an inbound `newMessage` matching [tempId] (the mapper echoes
  /// the sender's tempId to both sides).
  Future<Map<String, dynamic>> awaitNewMessage(String tempId) async {
    final payload =
        await events.next(
              'newMessage',
              where: (p) => p is Map && p['tempId'] == tempId,
              reason: '$label newMessage tempId=$tempId',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Emits `editMessage`. There is deliberately no SocketService emitter for
  /// this event — the app sends it through ConnectionProvider.emit's raw
  /// socket path, which this mirrors.
  void emitEditMessage(int messageId, String newCiphertext) {
    socketService.socket!.emit('editMessage', {
      'messageId': messageId,
      'content': '[encrypted]',
      'encryptedContent': newCiphertext,
    });
  }

  /// Emits an ENVELOPE-shaped `editMessage` (spec §5.7 + §12 amendment (xxxi)):
  /// one edited ciphertext per (user, device), with the device-list stamps the
  /// server cross-checks. Raw emit for the same reason as [emitEditMessage].
  void emitEnvelopeEdit(
    int messageId, {
    required List<Map<String, dynamic>> envelopes,
    int? recipientListVersion,
    int? senderListVersion,
  }) {
    socketService.socket!.emit('editMessage', <String, dynamic>{
      'messageId': messageId,
      'content': '[encrypted]',
      'envelopes': envelopes,
      'recipientListVersion': ?recipientListVersion,
      'senderListVersion': ?senderListVersion,
    });
  }

  /// Waits for a `messageEdited` for [messageId] on THIS device's socket.
  Future<Map<String, dynamic>> awaitMessageEdited(int messageId) async {
    final payload =
        await events.next(
              'messageEdited',
              where: (p) => p is Map && p['messageId'] == messageId,
              reason: '$label messageEdited messageId=$messageId',
            )
            as Map;
    return payload.cast<String, dynamic>();
  }

  /// Emits `deleteMessage`. Like `editMessage`, the app sends this through
  /// ConnectionProvider's raw socket path, which this mirrors.
  ///
  /// [forEveryone] false is delete-for-me (server keeps the row and adds the
  /// caller to `hiddenByUserIds`); true hard-deletes it for both sides.
  void emitDeleteMessage(int messageId, {required bool forEveryone}) {
    socketService.socket!.emit('deleteMessage', {
      'messageId': messageId,
      'mode': forEveryone ? 'for_everyone' : 'for_me',
    });
  }

  /// Emits `getServedMessageIds` and returns the ids the server says it still
  /// serves this account. Mirrors what `ConnectionProvider` does during
  /// local-plaintext reconciliation.
  Future<Set<int>> servedMessageIds(List<int> messageIds) async {
    final requestId = 'e2e-${_randomHex(6)}';
    events.discard('servedMessageIds');
    socketService.getServedMessageIds(requestId, messageIds);
    final payload =
        await events.next(
              'servedMessageIds',
              where: (p) => p is Map && p['requestId'] == requestId,
              reason: '$label servedMessageIds',
            )
            as Map;
    return {
      for (final id in payload['messageIds'] as List) (id as num).toInt(),
    };
  }

  void dispose() {
    socketService.disconnect();
  }

  static String _randomHex(int chars) {
    final rng = Random.secure();
    return List.generate(
      chars,
      (_) => rng.nextInt(16).toRadixString(16),
    ).join();
  }
}
