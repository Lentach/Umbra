// §5.1 provisioning ceremony state machine (Phase 2 T3).
//
// Screen-scoped ChangeNotifier, deliberately NOT an 8th top-level provider
// (frontend/CLAUDE.md §2 pins exactly 7): DevicesScreen constructs one,
// registers it as ConnectionProvider's provisioning sink for its lifetime,
// and both link-flow screens drive the same instance.
//
// Two flows, one controller:
//  - PRIMARY (this device enrolled, DAK persisted): paste code → hello →
//    SAS → human approve → blob + signed v+1 list → wait for commit.
//  - NEW DEVICE (this device keyless): open → show OOB code → relayed hello
//    → SAS → blob → MAC-verify/decrypt → adopt identity → complete →
//    rebind session under the assigned deviceId → the EXISTING upload path
//    publishes the minted bundle/OTPs (amendment (b), option A).
//
// Abort hygiene (I1, falsification 18): every failure path of the new-device
// flow runs [_discardNewDeviceState], which deletes the adopted identity and
// every minted key through EncryptionService.discardProvisionedIdentity — N
// ends exactly as unkeyed as it started. The discard is a real enumerated
// delete, never a comment.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../device_list/device_authority_engine.dart';
import '../device_list/device_list_canonical.dart';
import '../encryption_service.dart';
import '../passcode_wrap_hook.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../../widgets/input/composer_keyboard_signals.dart';
import 'dak_store.dart';
import 'link_crypto.dart';

/// This device's self-reported platform label for the signed list entry
/// (spec §12 item (i) — informational metadata, ≤32 chars, never a name).
///
/// Lives here rather than on a screen because the §6.2 recovery
/// re-enrollment ((xlv) clause 1) runs from ConnectionProvider, at login,
/// with no screen mounted — and a provider must not import one.
String linkPlatformLabel() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name.toLowerCase();
}

/// Server events ConnectionProvider forwards to the registered ceremony
/// controller. One interface so the provider stays a dumb router.
abstract class ProvisioningEventSink {
  void onProvisioningOpened(dynamic data);
  void onProvisioningHelloAck(dynamic data);
  void onProvisioningHelloRelay(dynamic data);
  void onProvisionDeviceAck(dynamic data);
  void onProvisioningBlob(dynamic data);
  void onProvisioningCompleted(dynamic data);
  void onProvisioningCancelled(dynamic data);
  void onDeviceAuthorityEnrolled(dynamic data);
  void onDeviceList(dynamic data);
  void onDeviceListChanged(dynamic data);
  void onDeviceRevocationCompleted(dynamic data);

  /// Answer to `updateDeviceList` — the event a device RENAME rides
  /// ((lxxx) clause 1 reuses the existing mutating request rather than
  /// growing a wire). The restore machine in EncryptionProvider awaits the
  /// same event through its own completer; both hear every answer, and each
  /// ignores one it has nothing in flight for.
  void onDeviceListUpdated(dynamic data);

  /// The session's socket just became authenticated (`socketReady`). The
  /// only moment an emit is guaranteed to reach the CURRENT socket — a
  /// rebind's reconnect returns before its transport exists, and an
  /// account-room broadcast that landed between sockets is gone.
  void onSessionReady();

  /// The session's socket dropped or was replaced: an emit still waiting
  /// for its answer may never get one.
  void onSessionLost();
}

/// The narrow identity surface the ceremony needs. Production wraps
/// [EncryptionService]; tests fake it.
abstract class LinkIdentityGateway {
  /// base64 of the own serialized identity public key, or null when this
  /// device holds no identity.
  Future<String?> ownIdentityPublicKeyBase64();

  /// The full identity pair (primary side, blob building). READ ONLY.
  Future<dynamic> ownIdentityKeyPair();

  /// [disposeStaleMaterial] is the (lxv) authorization: wipe an existing
  /// (lxiv)-mismatched identity before adopting. Only the ceremony passes it.
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  });

  Future<void> discardProvisionedIdentity(int userId);
}

/// Production gateway over the app's one EncryptionService instance.
class EncryptionServiceLinkGateway implements LinkIdentityGateway {
  EncryptionServiceLinkGateway(this._service, {this.beforeWipe});

  final EncryptionService _service;

  /// Issue #208: runs inside the adopt once the blob has parsed, right
  /// before it wipes this install's account namespace —
  /// `EncryptionProvider.prepareFreshDeviceLife` stops the old life's box,
  /// deletes its queues and closes the contact store.
  final Future<void> Function()? beforeWipe;

  @override
  Future<String?> ownIdentityPublicKeyBase64() =>
      _service.currentIdentityPublicKeyBase64();

  @override
  Future<dynamic> ownIdentityKeyPair() => _service.identityKeyPairForLinking();

  @override
  Future<void> adoptProvisionedIdentity({
    required int userId,
    required String ikPubBase64,
    required String ikPrivBase64,
    required String dakPubBase64,
    bool disposeStaleMaterial = false,
  }) => _service.adoptProvisionedIdentity(
    userId: userId,
    ikPubBase64: ikPubBase64,
    ikPrivBase64: ikPrivBase64,
    dakPubBase64: dakPubBase64,
    disposeStaleMaterial: disposeStaleMaterial,
    beforeWipe: beforeWipe,
  );

  @override
  Future<void> discardProvisionedIdentity(int userId) =>
      _service.discardProvisionedIdentity(userId);
}

/// Where the devices surface stands for THIS device/account.
enum DeviceListState { loading, notEnrolled, enrolled, chainInvalid }

/// Primary-flow steps, in ceremony order. `opening`/`showCode` belong to the
/// FLIPPED flow (amendment (lxxvii): the primary opens with role 'primary'
/// and displays a `p` code); the classic paste flow enters at
/// [awaitingHelloAck].
enum PrimaryLinkStep {
  idle,
  opening,
  showCode,
  awaitingHelloAck,
  showSas,
  staging,
  waitingForDevice,
  done,
  failed,
}

/// New-device-flow steps, in ceremony order. `awaitingHelloAck` belongs to
/// the FLIPPED flow (this device scanned the primary's `p` code and said
/// hello); the classic flow goes opening → showCode.
enum NewDeviceLinkStep {
  idle,
  opening,
  showCode,
  awaitingHelloAck,
  showSas,
  completing,
  rebinding,
  done,
  aborted,
}

class LinkCeremonyController extends ChangeNotifier
    implements ProvisioningEventSink {
  LinkCeremonyController({
    required this.userId,
    required void Function(String event, dynamic data) emit,
    required LinkIdentityGateway identity,
    required Future<void> Function(Map<String, dynamic> tokens) adoptSession,
    required Future<void> Function(String accessToken) reconnect,
    bool Function()? staleDisposalAuthorized,
    DakStore? dakStore,
    DeviceAuthorityEngine? engine,
  }) : _emit = emit,
       _identity = identity,
       _adoptSession = adoptSession,
       _reconnect = reconnect,
       _staleDisposalAuthorized = staleDisposalAuthorized,
       _dakStore = dakStore ?? DakStore(),
       _engine = engine ?? DeviceAuthorityEngine();

  final int userId;
  final void Function(String event, dynamic data) _emit;
  final LinkIdentityGateway _identity;
  final Future<void> Function(Map<String, dynamic> tokens) _adoptSession;
  final Future<void> Function(String accessToken) _reconnect;

  /// Live (lxiv) mismatch state, read at blob time (amendment (lxv)). Null —
  /// the historical ctor shape — means "never authorized".
  final bool Function()? _staleDisposalAuthorized;
  final DakStore _dakStore;
  final DeviceAuthorityEngine _engine;

  static const int _kResignRetryCap = 3;

  // ---------- Devices surface ----------

  DeviceListState listState = DeviceListState.loading;
  DeviceList? verifiedList;
  String? listFailureReason;

  /// Whether THIS install holds the account's DAK — the one fact that makes
  /// it the primary (§5.5: the primary is the only DAK holder; amendment
  /// (lxviii) clause 2). `null` until the first refresh has resolved it. The
  /// screen offers the primary-side flow only when this is true; a linked
  /// device would otherwise be invited into a flow that fails closed with
  /// `linkNoDak` after the user typed a code.
  bool? holdsDak;

  /// The raw authorization fields of the last VERIFIED own-list answer —
  /// the primary flow signs against these.
  Map<String, dynamic>? _authorization;

  /// Enable-linking outcome the UI renders (`already_enrolled` is a DISTINCT
  /// state: another install of this account beat us to the authority).
  String? enrollError;
  bool enrolling = false;

  // ---------- Primary flow ----------

  PrimaryLinkStep primaryStep = PrimaryLinkStep.idle;
  String? primaryError;
  String? primarySas;
  int? assignedDeviceId;
  LinkOobCode? _parsedCode;
  dynamic _ephP; // ECKeyPair — dynamic to keep the gateway seam narrow
  Uint8List? _ephPubP;
  String? _primaryProvisioningId;

  /// The `p` code this primary DISPLAYS in the flipped flow ((lxxvii)
  /// clause 2), or null outside it.
  String? primaryOobCode;

  /// The hello party's ephemeral relayed to this flipped-flow primary (the
  /// N slot of the fixed N-then-P transcript).
  Uint8List? _relayedEphPubN;

  /// The new device's self-reported platform label from the hello relay
  /// ((lxxx) clause 3), or null when the hello carried none (an older
  /// client) — the staged entry then falls back to `unknown`.
  String? _relayedPlatform;
  int _resignRetries = 0;
  bool _resignPending = false;

  // ---------- New-device flow ----------

  NewDeviceLinkStep newDeviceStep = NewDeviceLinkStep.idle;
  String? newDeviceError;
  String? newDeviceSas;
  String? oobCode;
  String? _openProvisioningId;
  Uint8List? _ephPubNBytes;
  dynamic _ephN;
  Uint8List? _relayedEphPubP;
  String _platform = 'web';
  Timer? _expiryTimer;
  bool _identityAdopted = false;

  /// Issue #208: whether the current socket is authenticated, and whether
  /// the new-device `openProvisioning` may have reached no server handler —
  /// sent before `socketReady`, or still unanswered when the socket was
  /// lost. Only such an open is asked again at [onSessionReady].
  bool _sessionReady = false;
  bool _openOwed = false;

  // ---------- Devices list ----------

  void refreshDeviceList() {
    _emit('getDeviceList', {'userId': userId});
    unawaited(_resolveDakPresence());
  }

  Future<void> _resolveDakPresence() async {
    final present = await _readDak() != null;
    // The screen may have popped during the Keystore read.
    if (_disposed || holdsDak == present) return;
    holdsDak = present;
    notifyListeners();
  }

  bool _disposed = false;

  /// (lxxvi) clause 2: `linkCeremonyActive` is raised from the first emit of
  /// either flow (or an enrolment) until the terminal state. Every mutation
  /// funnels through [notifyListeners], so syncing there is the ONE setter —
  /// a new step or failure path cannot forget to lower it.
  void _syncCeremonyActive() {
    linkCeremonyActive.value =
        enrolling ||
        (primaryStep != PrimaryLinkStep.idle &&
            primaryStep != PrimaryLinkStep.done &&
            primaryStep != PrimaryLinkStep.failed) ||
        (newDeviceStep != NewDeviceLinkStep.idle &&
            newDeviceStep != NewDeviceLinkStep.done &&
            newDeviceStep != NewDeviceLinkStep.aborted);
  }

  @override
  void notifyListeners() {
    _syncCeremonyActive();
    super.notifyListeners();
  }

  /// A staging that waited for the list ((lxx) clause 3) cannot proceed
  /// without one: every exit of the list answer that does not end in a
  /// VERIFIED list — absent, malformed, keyless, chain-invalid — fails the
  /// ceremony with a reason rather than leaving it in `staging` forever.
  /// One place, so a new exit cannot forget it.
  void _failWaitingStage() {
    if (!_resignPending) return;
    _resignPending = false;
    primaryError = 'list_unavailable';
    primaryStep = PrimaryLinkStep.failed;
  }

  @override
  void onDeviceList(dynamic data) {
    if (data is! Map || data['userId'] != userId) return;
    final authorization = data['authorization'];
    if (authorization == null) {
      listState = DeviceListState.notEnrolled;
      verifiedList = null;
      _authorization = null;
      _failWaitingStage();
      notifyListeners();
      return;
    }
    if (authorization is! Map) {
      _failWaitingStage();
      notifyListeners();
      return;
    }
    _verifyOwnList(authorization.cast<String, dynamic>());
  }

  Future<void> _verifyOwnList(Map<String, dynamic> authorization) async {
    // The own list is verified with the SAME I7 chain semantics a peer uses,
    // against this device's own TOFU'd identity — the server's word alone is
    // never trusted for list content.
    final tofu = await _identity.ownIdentityPublicKeyBase64();
    // A `deviceList` answer can land as the screen pops.
    if (_disposed) return;
    if (tofu == null) {
      // Keyless device (new-device flow candidate): render the list fields
      // unverified is NOT an option — mark the chain unverifiable.
      listState = DeviceListState.chainInvalid;
      listFailureReason = 'no_local_identity';
      _authorization = null;
      _failWaitingStage();
      notifyListeners();
      return;
    }
    final result = DeviceAuthorityEngine.verifyPeerDeviceList(
      authorization: authorization,
      tofuIdentityKeyBase64: tofu,
      expectedUserId: userId,
    );
    if (!result.ok) {
      listState = DeviceListState.chainInvalid;
      listFailureReason = result.reason;
      _authorization = null;
      // The screen shows one generic line for every reason; the reason
      // itself is what a field report needs (first seen on a cold-boot
      // deep link, 2026-09-03).
      E2ePersistentDiag.record('OWN_DEVICE_LIST_UNVERIFIED', {
        'userId': userId,
        'reason': result.reason,
      });
      _failWaitingStage();
    } else {
      listState = DeviceListState.enrolled;
      verifiedList = result.deviceList;
      listFailureReason = null;
      _authorization = authorization;
      if (primaryStep == PrimaryLinkStep.waitingForDevice &&
          assignedDeviceId != null &&
          result.deviceList!.devices.any(
            (d) => d.deviceId == assignedDeviceId,
          )) {
        primaryStep = PrimaryLinkStep.done;
      }
      if (_resignPending) {
        _resignPending = false;
        unawaited(_stageProvisionDevice());
      }
    }
    notifyListeners();
  }

  @override
  void onDeviceListChanged(dynamic data) {
    if (data is! Map || data['userId'] != userId) return;
    refreshDeviceList();
  }

  @override
  void onSessionReady() {
    // (lxviii) clause 1: every authenticated (re)connect re-reads the list.
    // Covers the rebind reconnect of this install's own ceremony and any
    // `deviceListChanged` broadcast that landed while it was between sockets.
    refreshDeviceList();
    // Issue #208: the gate now mounts from the first frame, before the
    // socket is authenticated, and an `openProvisioning` sent then reaches no
    // server handler — the gate spun forever with no code. Only an owed open
    // ([onSessionLost]) is asked again; an answer to both is folded in
    // [onProvisioningOpened].
    final resend =
        _openOwed &&
        newDeviceStep == NewDeviceLinkStep.opening &&
        _openProvisioningId == null;
    _sessionReady = true;
    _openOwed = false;
    if (resend) _emit('openProvisioning', {'role': 'new'});
  }

  @override
  void onSessionLost() {
    _sessionReady = false;
    if (newDeviceStep == NewDeviceLinkStep.opening &&
        _openProvisioningId == null) {
      _openOwed = true;
    }
  }

  // ---------- Enable linking (primary enrollment) ----------

  /// (lxxviii) clause 4: the DAK must exist BEFORE the recovery backup blob
  /// is sealed (the blob carries it) and BEFORE any enrolment. Mint + armed
  /// persist only — NO server call. Idempotent: a persisted DAK is restored
  /// into the engine and kept, never re-minted (re-minting would orphan a
  /// blob already sealed over the old pair).
  Future<void> mintDak() async {
    if (await _readDak() != null) return;
    try {
      _engine.mintDak();
      final exported = _engine.exportDakForPersistence();
      await _dakStore.persistArmed(
        DakRecord(
          userId: userId,
          dakPub: exported['dakPub']!,
          dakPriv: exported['dakPriv']!,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {
      // The caller aborts, so without this the user taps "enable" and sees
      // NOTHING happen — the pre-(lxxviii) order at least rendered the enroll
      // error. Rethrown: an unpersisted DAK must not reach the phrase screen.
      enrollError = 'enroll_failed';
      enrolling = false;
      notifyListeners();
      rethrow;
    }
  }

  /// Rider order (T3 + (lxxviii) clause 4): mint → persist DAK armed → ONLY
  /// THEN emit enroll, over the SAME held pair ([mintDak] is a no-op when
  /// the backup flow already minted one).
  Future<void> enableLinking({required String platform}) async {
    if (enrolling) return;
    enrolling = true;
    enrollError = null;
    notifyListeners();
    try {
      await mintDak();
      final identity = await _identity.ownIdentityKeyPair();
      final payload = _engine.mintEnrollment(
        userId: userId,
        // The gateway returns the service's IdentityKeyPair; the engine's
        // parameter type enforces it.
        identity: identity,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        platform: platform,
        reuseHeldDak: true,
      );
      _emit('enrollDeviceAuthority', payload);
    } catch (e) {
      enrollError = 'enroll_failed';
      enrolling = false;
      notifyListeners();
    }
  }

  @override
  void onDeviceAuthorityEnrolled(dynamic data) {
    enrolling = false;
    if (data is Map && data['success'] == true) {
      enrollError = null;
      refreshDeviceList();
    } else {
      enrollError = data is Map && data['error'] is String
          ? data['error'] as String
          : 'enroll_failed';
      if (enrollError == 'already_enrolled') {
        // Another install already holds the authority — the persisted DAK
        // here authorizes nothing and keeping it invites signing lists the
        // server never pinned an E for.
        unawaited(_dakStore.clear(userId: userId));
      }
      notifyListeners();
    }
  }

  // ---------- Primary flow ----------

  /// Manual paste is the REQUIRED OOB path (spec item (i)).
  Future<void> startPrimaryFlow(String rawCode) async {
    final code = LinkOobCode.tryParse(rawCode.trim());
    if (code == null) {
      primaryError = 'invalid_code';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    if (code.role != LinkRole.newDevice) {
      // (lxxvii) F5: a `p` code names the PRIMARY's ephemeral — feeding it
      // into the N slot would derive a SAS the other side can never match.
      primaryError = 'wrong_code_role';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    final dak = await _readDak();
    if (dak == null) {
      primaryError = 'no_dak';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    _parsedCode = code;
    _primaryProvisioningId = code.provisioningId;
    final eph = generateLinkEphemeral();
    _ephP = eph;
    _ephPubP = linkEphemeralPublicBytes(eph);
    primaryError = null;
    primarySas = null;
    assignedDeviceId = null;
    _resignRetries = 0;
    primaryStep = PrimaryLinkStep.awaitingHelloAck;
    notifyListeners();
    _emit('provisioningHello', {
      'provisioningId': code.provisioningId,
      'ephPubP': base64Encode(_ephPubP!),
    });
  }

  /// FLIPPED primary flow ((lxxvii) clauses 1–2): this enrolled device opens
  /// the stage with `role: 'primary'` and DISPLAYS a `p` code; the new
  /// device scans it and says hello. [platform] labels the displayed code
  /// (the displaying device's own platform, informational).
  Future<void> startPrimaryShowFlow({required String platform}) async {
    final dak = await _readDak();
    if (dak == null) {
      primaryError = 'no_dak';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    _platform = platform;
    final eph = generateLinkEphemeral();
    _ephP = eph;
    _ephPubP = linkEphemeralPublicBytes(eph);
    _parsedCode = null;
    primaryError = null;
    primarySas = null;
    primaryOobCode = null;
    assignedDeviceId = null;
    _relayedEphPubN = null;
    _relayedPlatform = null;
    _resignRetries = 0;
    primaryStep = PrimaryLinkStep.opening;
    notifyListeners();
    _emit('openProvisioning', {'role': 'primary'});
  }

  Future<DakRecord?> _readDak() async {
    try {
      final record = await _dakStore.read(userId: userId);
      if (record != null) {
        _engine.restoreDak(
          dakPubBase64: record.dakPub,
          dakPrivBase64: record.dakPriv,
        );
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  @override
  void onProvisioningHelloAck(dynamic data) {
    // FLIPPED flow: this device is the hello CALLER (it scanned a `p`
    // code) — the ack confirms the pin and carries the assigned deviceId
    // (informational here; the blob stays authoritative for N's id).
    if (newDeviceStep == NewDeviceLinkStep.awaitingHelloAck) {
      _onNewDeviceHelloAck(data);
      return;
    }
    if (primaryStep != PrimaryLinkStep.awaitingHelloAck) return;
    if (data is! Map || data['success'] != true || data['deviceId'] is! int) {
      primaryError = data is Map && data['error'] is String
          ? data['error'] as String
          : 'hello_failed';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    final code = _parsedCode;
    final eph = _ephP;
    if (code == null || eph == null) return;
    assignedDeviceId = data['deviceId'] as int;
    final transcript = linkTranscript(
      provisioningId: code.provisioningId,
      ephPubN: code.ephPub,
      ephPubP: _ephPubP!,
    );
    final sharedSecret = linkSharedSecret(
      theirEphPub: code.ephPub,
      // ignore: avoid_dynamic_calls
      ownEphPriv: eph.privateKey,
    );
    primarySas = deriveLinkSas(
      sharedSecret: sharedSecret,
      transcript: transcript,
    );
    primaryStep = PrimaryLinkStep.showSas;
    notifyListeners();
  }

  void _onNewDeviceHelloAck(dynamic data) {
    if (data is! Map || data['success'] != true) {
      unawaited(
        abortNewDevice(
          data is Map && data['error'] is String
              ? data['error'] as String
              : 'hello_failed',
        ),
      );
      return;
    }
    final ephPubP = _relayedEphPubP;
    final eph = _ephN;
    if (ephPubP == null || eph == null || _ephPubNBytes == null) return;
    final transcript = linkTranscript(
      provisioningId: _openProvisioningId!,
      ephPubN: _ephPubNBytes!,
      ephPubP: ephPubP,
    );
    final sharedSecret = linkSharedSecret(
      theirEphPub: ephPubP,
      // ignore: avoid_dynamic_calls
      ownEphPriv: eph.privateKey,
    );
    newDeviceSas = deriveLinkSas(
      sharedSecret: sharedSecret,
      transcript: transcript,
    );
    newDeviceStep = NewDeviceLinkStep.showSas;
    notifyListeners();
  }

  /// The human compared both screens and approved: NOW (and only now —
  /// secrets-last, I3) the IK-bearing blob is built and staged.
  Future<void> approvePrimary() async {
    if (primaryStep != PrimaryLinkStep.showSas) return;
    primaryStep = PrimaryLinkStep.staging;
    notifyListeners();
    await _stageProvisionDevice();
  }

  Future<void> _stageProvisionDevice() async {
    final code = _parsedCode;
    final eph = _ephP;
    final deviceId = assignedDeviceId;
    final provisioningId = _primaryProvisioningId;
    final authorization = _authorization;
    final list = verifiedList;
    // Classic flow: N's ephemeral came in the pasted code. Flipped flow:
    // it arrived on the hello relay. Same slot either way (fixed N-then-P).
    final ephPubN = code?.ephPub ?? _relayedEphPubN;
    if (provisioningId == null ||
        eph == null ||
        deviceId == null ||
        ephPubN == null) {
      return;
    }
    if (authorization == null || list == null) {
      // The list is not in hand — on a cold boot the Keystore read can win
      // the race against the list fetch, and a deep-linked code starts the
      // flow the moment the screen mounts (observed live 2026-09-03 as
      // `list_unavailable` at Approve). The stage is still valid: fetch the
      // list and re-stage when it verifies, on the same retry budget the
      // stale-version path uses. Only a list that never verifies fails.
      if (_resignRetries < _kResignRetryCap) {
        _resignRetries++;
        _resignPending = true;
        refreshDeviceList();
        return;
      }
      primaryError = 'list_unavailable';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    try {
      final identity = await _identity.ownIdentityKeyPair();
      final transcript = linkTranscript(
        provisioningId: provisioningId,
        ephPubN: ephPubN,
        ephPubP: _ephPubP!,
      );
      final sharedSecret = linkSharedSecret(
        theirEphPub: ephPubN,
        // ignore: avoid_dynamic_calls
        ownEphPriv: eph.privateKey,
      );
      final keys = deriveLinkBlobKeys(
        sharedSecret: sharedSecret,
        transcript: transcript,
      );
      final blob = sealLinkBlob(
        keys: keys,
        payload: LinkBlobPayload(
          userId: userId,
          deviceId: deviceId,
          // ignore: avoid_dynamic_calls
          ikPub: base64Encode(identity.getPublicKey().serialize() as List<int>),
          // ignore: avoid_dynamic_calls
          ikPriv: base64Encode(
            identity.getPrivateKey().serialize() as List<int>,
          ),
          dakPub: _authorization!['dakPub'] as String,
          enrollmentCreatedAt: _authorization!['enrollmentCreatedAt'] as int,
          enrollmentSig: _authorization!['enrollmentSig'] as String,
        ),
      );
      // The staged v+1 list: current entries + EXACTLY the assigned device,
      // NO name (amendment (i)). The platform label comes from the pasted
      // code in the classic flow and from the hello relay in the flipped one
      // ((lxxx) clause 3); an older client that sends neither is labelled
      // 'unknown' (informational metadata only).
      final staged = DeviceList(
        userId: userId,
        version: list.version + 1,
        devices: [
          ...list.devices,
          DeviceListEntry(
            deviceId: deviceId,
            platform: code?.platform ?? _relayedPlatform ?? 'unknown',
            addedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );
      final signed = _engine.signList(staged);
      _emit('provisionDevice', {
        'provisioningId': provisioningId,
        'blob': base64Encode(blob),
        'listCanonical': signed['listCanonical'],
        'listSignature': signed['listSignature'],
      });
    } catch (e) {
      primaryError = 'stage_failed';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
    }
  }

  // ---------- Revocation (spec §5.5, T6) ----------

  /// Device id whose revocation is in flight, or null.
  int? revokingDeviceId;

  /// Stable refusal code from the last attempt, or null.
  String? revokeError;

  /// Revokes one of this account's OTHER devices (spec §5.5).
  ///
  /// The client signs the mutation because only the primary holds the DAK: the
  /// staged list is the current one with `revokedAt` stamped on that entry and
  /// the version advanced, and the server refuses the request outright unless
  /// those signed bytes really do revoke the device named in it (amendment
  /// (xxi), `list_device_mismatch`).
  ///
  /// Revoked entries STAY on the list — they are what tells every peer to stop
  /// addressing envelopes to that device, and what lets a receiver refuse its
  /// ciphertext at decrypt time (amendment (e)).
  Future<void> revokeDevice(int deviceId) async {
    final list = verifiedList;
    if (list == null || revokingDeviceId != null) return;
    final target = list.devices
        .where((d) => d.deviceId == deviceId)
        .firstOrNull;
    if (target == null || target.revokedAtMs != null) return;
    revokingDeviceId = deviceId;
    revokeError = null;
    notifyListeners();
    // Arm the engine from the Keystore FIRST. The controller is rebuilt every
    // time the devices screen opens, so its engine holds no DAK until this
    // runs — signing without it throws and the request never leaves the
    // device. `startPrimaryFlow` does the same thing for the same reason; the
    // app-proof caught this path missing it.
    if (await _readDak() == null) {
      revokingDeviceId = null;
      revokeError = 'no_dak';
      notifyListeners();
      return;
    }
    try {
      final staged = DeviceList(
        userId: userId,
        version: list.version + 1,
        devices: [
          for (final d in list.devices)
            if (d.deviceId == deviceId)
              DeviceListEntry(
                deviceId: d.deviceId,
                platform: d.platform,
                addedAtMs: d.addedAtMs,
                name: d.name,
                revokedAtMs: DateTime.now().millisecondsSinceEpoch,
              )
            else
              d,
        ],
      );
      final signed = _engine.signList(staged);
      _emit('revokeDevice', {
        'deviceId': deviceId,
        'listCanonical': signed['listCanonical'],
        'listSignature': signed['listSignature'],
      });
    } catch (e) {
      revokingDeviceId = null;
      revokeError = 'sign_failed';
      notifyListeners();
    }
  }

  @override
  void onDeviceRevocationCompleted(dynamic data) {
    if (revokingDeviceId == null) return;
    revokingDeviceId = null;
    if (data is Map && data['success'] == true) {
      revokeError = null;
      // The server broadcasts `deviceListChanged` to the account, which lands
      // as a refresh — but ask directly too, so the row updates even if this
      // session somehow missed the broadcast.
      refreshDeviceList();
    } else {
      revokeError = data is Map && data['error'] is String
          ? data['error'] as String
          : 'revoke_failed';
    }
    notifyListeners();
  }

  // ---------- Rename (spec §12 (lxxx) clause 1) ----------

  /// Device id whose rename is in flight, or null.
  int? renamingDeviceId;

  /// Stable refusal code from the last rename attempt, or null.
  String? renameError;

  /// Gives one row of the account's signed list a human [name] — or CLEARS
  /// it when [name] is empty/whitespace only.
  ///
  /// Exactly the [revokeDevice] shape with `name` set instead of
  /// `revokedAt`: only a DAK holder may sign a list version, so the engine is
  /// armed from the Keystore FIRST, and the mutation rides the EXISTING
  /// `updateDeviceList` request — the server constrains only the userId, the
  /// signature and version monotonicity, so no new wire and no server change
  /// is needed.
  ///
  /// A REVOKED row is refused: it is a tombstone, and mutating it would spend
  /// a list version to no effect. Clearing passes `null` rather than `""`, so
  /// the canonical bytes match a list that was never named (the encoder omits
  /// an absent name).
  Future<void> renameDevice(int deviceId, String name) async {
    final list = verifiedList;
    if (list == null || renamingDeviceId != null || revokingDeviceId != null) {
      return;
    }
    final target = list.devices
        .where((d) => d.deviceId == deviceId)
        .firstOrNull;
    if (target == null || target.revokedAtMs != null) return;
    final trimmed = name.trim();
    final String? nextName = trimmed.isEmpty
        ? null
        : (trimmed.length > kDeviceNameMaxLength
              ? trimmed.substring(0, kDeviceNameMaxLength)
              : trimmed);
    // (lxxx) clause 1: refuse a name the STORAGE GATE would reject for NFC
    // reasons BEFORE spending a list version on it. Signing first burns
    // version+1, comes back as `invalid_canonical`, and tells the user only
    // "could not rename".
    if (nextName != null && !isSignableDeviceName(nextName)) {
      renameError = 'not_storable';
      notifyListeners();
      return;
    }
    renamingDeviceId = deviceId;
    renameError = null;
    notifyListeners();
    // Arm the engine from the Keystore FIRST — same reason as
    // [revokeDevice]: a controller rebuilt with the screen holds no DAK, and
    // signing without one throws so nothing ever leaves the device.
    if (await _readDak() == null) {
      renamingDeviceId = null;
      renameError = 'no_dak';
      notifyListeners();
      return;
    }
    try {
      final staged = DeviceList(
        userId: userId,
        version: list.version + 1,
        devices: [
          for (final d in list.devices)
            if (d.deviceId == deviceId)
              DeviceListEntry(
                deviceId: d.deviceId,
                platform: d.platform,
                addedAtMs: d.addedAtMs,
                name: nextName,
                revokedAtMs: d.revokedAtMs,
              )
            else
              d,
        ],
      );
      final signed = _engine.signList(staged);
      _emit('updateDeviceList', {
        'listCanonical': signed['listCanonical'],
        'listSignature': signed['listSignature'],
      });
    } catch (e) {
      renamingDeviceId = null;
      renameError = 'sign_failed';
      notifyListeners();
    }
  }

  @override
  void onDeviceListUpdated(dynamic data) {
    // The restore machine ((lxxviii)) emits the same request from
    // EncryptionProvider and awaits its own completer; an answer that
    // belongs to it finds nothing in flight here and is left alone.
    if (renamingDeviceId == null) return;
    renamingDeviceId = null;
    if (data is Map && data['success'] == true) {
      renameError = null;
      refreshDeviceList();
    } else {
      renameError = 'rename_failed';
    }
    notifyListeners();
  }

  @override
  void onProvisionDeviceAck(dynamic data) {
    if (primaryStep != PrimaryLinkStep.staging) return;
    if (data is Map && data['success'] == true) {
      primaryStep = PrimaryLinkStep.waitingForDevice;
      notifyListeners();
      return;
    }
    final error = data is Map && data['error'] is String
        ? data['error'] as String
        : 'stage_failed';
    if (error == 'stale_version' && _resignRetries < _kResignRetryCap) {
      // Falsification 20: a concurrent ceremony took the version slot —
      // refetch the committed list and re-sign v+2 against the SAME stage.
      _resignRetries++;
      _resignPending = true;
      refreshDeviceList();
      return;
    }
    primaryError = error;
    primaryStep = PrimaryLinkStep.failed;
    notifyListeners();
  }

  void cancelPrimary() {
    final id = _primaryProvisioningId;
    if (id != null &&
        primaryStep != PrimaryLinkStep.idle &&
        primaryStep != PrimaryLinkStep.done) {
      _emit('cancelProvisioning', {'provisioningId': id});
    }
    _resetPrimary();
    notifyListeners();
  }

  void _resetPrimary() {
    primaryStep = PrimaryLinkStep.idle;
    primaryError = null;
    primarySas = null;
    primaryOobCode = null;
    assignedDeviceId = null;
    _parsedCode = null;
    _ephP = null;
    _ephPubP = null;
    _relayedEphPubN = null;
    _relayedPlatform = null;
    _primaryProvisioningId = null;
    _resignRetries = 0;
    _resignPending = false;
  }

  // ---------- New-device flow ----------
  Future<void> startNewDeviceFlow({required String platform}) async {
    _platform = platform;
    final eph = generateLinkEphemeral();
    _ephN = eph;
    _ephPubNBytes = linkEphemeralPublicBytes(eph);
    newDeviceError = null;
    newDeviceSas = null;
    oobCode = null;
    _relayedEphPubP = null;
    _identityAdopted = false;
    newDeviceStep = NewDeviceLinkStep.opening;
    notifyListeners();
    _openOwed = !_sessionReady;
    _emit('openProvisioning', {'role': 'new'});
  }

  /// FLIPPED new-device flow ((lxxvii) clause 3): this keyless device
  /// scanned the primary's `p` code. Refusals return a stable code WITHOUT
  /// touching a flow already in progress (the gate keeps showing its own
  /// `n` code after a bad scan); a valid `p` code cancels this device's own
  /// open stage and runs the hello side.
  Future<String?> startNewDeviceFromCode(
    String rawCode, {
    required String platform,
  }) async {
    final code = LinkOobCode.tryParse(rawCode.trim());
    if (code == null) return 'invalid_code';
    if (code.role != LinkRole.primary) {
      // (lxxvii) F5's mirror: an `n` code names a NEW device's ephemeral —
      // this device IS the new device, so the code belongs in
      // [startNewDeviceFlow]'s display, never fed back in here.
      return 'wrong_code_role';
    }
    final ownStage = _openProvisioningId;
    if (ownStage != null && ownStage != code.provisioningId) {
      _emit('cancelProvisioning', {'provisioningId': ownStage});
    }
    _expiryTimer?.cancel();
    _platform = platform;
    final eph = generateLinkEphemeral();
    _ephN = eph;
    _ephPubNBytes = linkEphemeralPublicBytes(eph);
    _relayedEphPubP = Uint8List.fromList(code.ephPub);
    _openProvisioningId = code.provisioningId;
    oobCode = null;
    newDeviceSas = null;
    newDeviceError = null;
    _identityAdopted = false;
    newDeviceStep = NewDeviceLinkStep.awaitingHelloAck;
    notifyListeners();
    // The wire field stays `ephPubP` for v1 compatibility — it is simply
    // "the hello party's ephemeral", filling the N slot in this flow.
    // `platform` is (lxxx) clause 3: in the FLIPPED direction this hello is
    // the only channel that carries this device's label to the primary, and
    // without it every device linked that way landed as `unknown`.
    _emit('provisioningHello', {
      'provisioningId': code.provisioningId,
      'ephPubP': base64Encode(_ephPubNBytes!),
      'platform': _platform,
    });
    return null;
  }

  @override
  void onProvisioningOpened(dynamic data) {
    if (primaryStep == PrimaryLinkStep.opening) {
      _onPrimaryShowOpened(data);
      return;
    }
    if (newDeviceStep != NewDeviceLinkStep.opening) {
      // Issue #208: the answer to an open re-sent at `socketReady` while the
      // first one was in fact handled — the server made a second stage, which
      // nothing will ever use. Freed at once instead of left to expire.
      final extra = data is Map ? data['provisioningId'] : null;
      if (extra is String &&
          _openProvisioningId != null &&
          extra != _openProvisioningId) {
        _emit('cancelProvisioning', {'provisioningId': extra});
      }
      return;
    }
    if (data is! Map || data['success'] != true) {
      newDeviceError = data is Map && data['error'] is String
          ? data['error'] as String
          : 'open_failed';
      newDeviceStep = NewDeviceLinkStep.aborted;
      notifyListeners();
      return;
    }
    final id = data['provisioningId'];
    final expiresAt = data['expiresAt'];
    if (id is! String || _ephPubNBytes == null) return;
    _openProvisioningId = id;
    oobCode = LinkOobCode(
      provisioningId: id,
      ephPub: _ephPubNBytes!,
      platform: _platform,
    ).encode();
    newDeviceStep = NewDeviceLinkStep.showCode;
    if (expiresAt is int) {
      final remaining = DateTime.fromMillisecondsSinceEpoch(
        expiresAt,
      ).difference(DateTime.now());
      _expiryTimer?.cancel();
      if (remaining > Duration.zero) {
        _expiryTimer = Timer(remaining, () {
          // TTL expiry: the server forgot the stage (falsification 18's
          // boundary) — discard everything and end as unkeyed as we began.
          unawaited(abortNewDevice('expired'));
        });
      }
    }
    notifyListeners();
  }

  /// FLIPPED flow, primary side: the stage is open — display the `p` code.
  void _onPrimaryShowOpened(dynamic data) {
    if (data is! Map || data['success'] != true) {
      primaryError = data is Map && data['error'] is String
          ? data['error'] as String
          : 'open_failed';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    final id = data['provisioningId'];
    final expiresAt = data['expiresAt'];
    if (id is! String || _ephPubP == null) return;
    _primaryProvisioningId = id;
    primaryOobCode = LinkOobCode(
      provisioningId: id,
      ephPub: _ephPubP!,
      platform: _platform,
      role: LinkRole.primary,
    ).encode();
    primaryStep = PrimaryLinkStep.showCode;
    if (expiresAt is int) {
      final remaining = DateTime.fromMillisecondsSinceEpoch(
        expiresAt,
      ).difference(DateTime.now());
      _expiryTimer?.cancel();
      if (remaining > Duration.zero) {
        _expiryTimer = Timer(remaining, () {
          // TTL expiry: the server forgot the stage. Nothing secret was
          // handed out — fail with a reason, no cancel emit needed.
          if (primaryStep == PrimaryLinkStep.showCode) {
            primaryError = 'expired';
            primaryStep = PrimaryLinkStep.failed;
            notifyListeners();
          }
        });
      }
    }
    notifyListeners();
  }

  @override
  void onProvisioningHelloRelay(dynamic data) {
    if (data is! Map || data['ephPubP'] is! String) return;
    // FLIPPED flow, primary side: the relay carries the hello party's
    // ephemeral (N slot) plus the deviceId this primary must sign for.
    if (primaryStep == PrimaryLinkStep.showCode &&
        data['provisioningId'] == _primaryProvisioningId) {
      _onPrimaryHelloRelay(data);
      return;
    }
    if (data['provisioningId'] != _openProvisioningId) return;
    if (newDeviceStep != NewDeviceLinkStep.showCode &&
        newDeviceStep != NewDeviceLinkStep.showSas) {
      return;
    }
    final Uint8List ephPubP;
    try {
      ephPubP = base64Decode(data['ephPubP'] as String);
    } catch (_) {
      return;
    }
    if (ephPubP.length != kLinkEphemeralPublicKeyLength) return;
    _relayedEphPubP = ephPubP;
    final transcript = linkTranscript(
      provisioningId: _openProvisioningId!,
      ephPubN: _ephPubNBytes!,
      ephPubP: ephPubP,
    );
    final sharedSecret = linkSharedSecret(
      theirEphPub: ephPubP,
      // ignore: avoid_dynamic_calls
      ownEphPriv: _ephN.privateKey,
    );
    newDeviceSas = deriveLinkSas(
      sharedSecret: sharedSecret,
      transcript: transcript,
    );
    newDeviceStep = NewDeviceLinkStep.showSas;
    notifyListeners();
  }

  void _onPrimaryHelloRelay(dynamic data) {
    if (data['deviceId'] is! int) return;
    final Uint8List ephPubN;
    try {
      ephPubN = base64Decode(data['ephPubP'] as String);
    } catch (_) {
      return;
    }
    if (ephPubN.length != kLinkEphemeralPublicKeyLength) return;
    final eph = _ephP;
    if (eph == null) return;
    _relayedEphPubN = ephPubN;
    // (lxxx) clause 3: OPTIONAL on the wire; an older new device sends none
    // and the entry stays 'unknown' rather than crashing the ceremony.
    final platform = data['platform'];
    _relayedPlatform = platform is String && platform.isNotEmpty
        ? platform
        : null;
    assignedDeviceId = data['deviceId'] as int;
    final transcript = linkTranscript(
      provisioningId: _primaryProvisioningId!,
      ephPubN: ephPubN,
      ephPubP: _ephPubP!,
    );
    final sharedSecret = linkSharedSecret(
      theirEphPub: ephPubN,
      // ignore: avoid_dynamic_calls
      ownEphPriv: eph.privateKey,
    );
    primarySas = deriveLinkSas(
      sharedSecret: sharedSecret,
      transcript: transcript,
    );
    primaryStep = PrimaryLinkStep.showSas;
    notifyListeners();
  }

  @override
  void onProvisioningBlob(dynamic data) {
    if (data is! Map || data['provisioningId'] != _openProvisioningId) return;
    final blobB64 = data['blob'];
    if (blobB64 is! String) return;
    final ephPubP = _relayedEphPubP;
    if (ephPubP == null ||
        (newDeviceStep != NewDeviceLinkStep.showSas &&
            newDeviceStep != NewDeviceLinkStep.completing)) {
      return;
    }
    unawaited(_handleBlob(blobB64, ephPubP));
  }

  Future<void> _handleBlob(String blobB64, Uint8List ephPubP) async {
    try {
      final transcript = linkTranscript(
        provisioningId: _openProvisioningId!,
        ephPubN: _ephPubNBytes!,
        ephPubP: ephPubP,
      );
      final sharedSecret = linkSharedSecret(
        theirEphPub: ephPubP,
        // ignore: avoid_dynamic_calls
        ownEphPriv: _ephN.privateKey,
      );
      final keys = deriveLinkBlobKeys(
        sharedSecret: sharedSecret,
        transcript: transcript,
      );
      // MAC verified constant-time BEFORE decrypt inside openLinkBlob.
      final payload = openLinkBlob(keys: keys, blob: base64Decode(blobB64));
      if (payload.userId != userId) {
        await abortNewDevice('blob_user_mismatch');
        return;
      }
      await _identity.adoptProvisionedIdentity(
        userId: userId,
        ikPubBase64: payload.ikPub,
        ikPrivBase64: payload.ikPriv,
        dakPubBase64: payload.dakPub,
        // (lxv): blob authenticated (MAC before decrypt) and user-matched;
        // if this install carries (lxiv)-mismatched material, the ceremony
        // is its authorized disposal.
        disposeStaleMaterial: _staleDisposalAuthorized?.call() ?? false,
      );
      // (lxxvi) clause 3: the adopt just landed RAW key material — with
      // wrapping ON a crash before the next unlock would leave it raw on a
      // "protected" device, so wrap it NOW (idempotent; no-op unwired).
      await PasscodeWrapHook.run();
      _identityAdopted = true;
      newDeviceStep = NewDeviceLinkStep.completing;
      notifyListeners();
      _emit('provisioningComplete', {'provisioningId': _openProvisioningId});
    } on LinkBlobException catch (e) {
      await abortNewDevice(e.reason);
    } catch (_) {
      await abortNewDevice('adopt_failed');
    }
  }

  @override
  void onProvisioningCompleted(dynamic data) {
    if (newDeviceStep != NewDeviceLinkStep.completing) return;
    if (data is! Map) return;
    if (data['success'] == true) {
      unawaited(_finishRebind(data.cast<String, dynamic>()));
      return;
    }
    final error = data['error'];
    if (error == 'stale_version') {
      // The primary lost a concurrent version race and will re-sign and
      // re-stage against this SAME stage; the next provisioningBlob re-runs
      // the adopt (same identity bytes) and re-emits complete.
      return;
    }
    unawaited(abortNewDevice(error is String ? error : 'complete_failed'));
  }

  Future<void> _finishRebind(Map<String, dynamic> data) async {
    _expiryTimer?.cancel();
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || refresh is! String) {
      await abortNewDevice('complete_failed');
      return;
    }
    newDeviceStep = NewDeviceLinkStep.rebinding;
    notifyListeners();
    try {
      // Amendment (iii): persist the deviceId-bound session, then disconnect/
      // reconnect under it. Only THEN does the existing OTP-gated upload path
      // publish the minted bundle+OTPs (amendment (b): a bundle uploaded
      // before rebind would land on device 1 and overwrite the primary's).
      await _adoptSession({'access_token': access, 'refresh_token': refresh});
      await _reconnect(access);
      newDeviceStep = NewDeviceLinkStep.done;
      notifyListeners();
      // (lxviii) clause 1: the devices screen beneath this route still holds
      // the pre-ceremony answer. The list is re-read from [onSessionReady] —
      // NOT here: `_reconnect` returns before the new transport exists, so an
      // emit at this point lands in the gap between sockets (observed live:
      // the screen kept the pre-ceremony version).
    } catch (_) {
      // Session adoption failed AFTER the server committed the device. The
      // identity is real and committed — discarding it now would orphan the
      // devices row; surface the failure instead.
      newDeviceError = 'rebind_failed';
      newDeviceStep = NewDeviceLinkStep.aborted;
      notifyListeners();
    }
  }

  @override
  void onProvisioningCancelled(dynamic data) {
    if (data is! Map) return;
    // The caller-ack shape carries `success`; the opener notification is the
    // bare `{provisioningId}` push — only the latter aborts a flow.
    if (data['success'] != null) return;
    // FLIPPED flow, primary side: this primary is the OPENER — the new
    // device walking away lands here. Nothing secret was handed out before
    // Approve; past staging the cancel can no longer reach the stage.
    if (data['provisioningId'] == _primaryProvisioningId &&
        (primaryStep == PrimaryLinkStep.showCode ||
            primaryStep == PrimaryLinkStep.showSas ||
            primaryStep == PrimaryLinkStep.staging)) {
      _expiryTimer?.cancel();
      primaryError = 'cancelled';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
      return;
    }
    if (data['provisioningId'] != _openProvisioningId) return;
    if (newDeviceStep == NewDeviceLinkStep.idle ||
        newDeviceStep == NewDeviceLinkStep.done) {
      return;
    }
    unawaited(abortNewDevice('cancelled'));
  }

  /// I1 abort hygiene: discard the adopted identity, every minted key, the
  /// stored dakPub and the assigned id — then reset the flow.
  Future<void> abortNewDevice(String reason) async {
    _expiryTimer?.cancel();
    final id = _openProvisioningId;
    if (reason != 'expired' && reason != 'cancelled' && id != null) {
      _emit('cancelProvisioning', {'provisioningId': id});
    }
    if (_identityAdopted) {
      try {
        await _identity.discardProvisionedIdentity(userId);
      } catch (_) {
        // The discard failing must not mask the abort itself; the adopt
        // path re-runs it before any retry.
      }
      _identityAdopted = false;
    }
    _openProvisioningId = null;
    _ephN = null;
    _ephPubNBytes = null;
    _relayedEphPubP = null;
    oobCode = null;
    newDeviceSas = null;
    newDeviceError = reason;
    newDeviceStep = NewDeviceLinkStep.aborted;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    // A controller torn down mid-flow (screen disposed) must not leave the
    // passcode exemption raised: no further notify will ever run.
    linkCeremonyActive.value = false;
    super.dispose();
  }
}
