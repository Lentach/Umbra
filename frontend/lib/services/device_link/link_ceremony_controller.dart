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

part 'link_ceremony_controller.abort.dart';
part 'link_ceremony_controller.blob.dart';
part 'link_ceremony_controller.devices.dart';
part 'link_ceremony_controller.new_device.dart';
part 'link_ceremony_controller.primary.dart';
part 'link_ceremony_controller.types.dart';

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

  /// Requests this controller EMITTED and has no answer to yet: `enroll`,
  /// `stage`, `revoke`, `rename`. A marker (`enrolling`, the `staging` step,
  /// `revokingDeviceId`, `renamingDeviceId`) that is set while its request is
  /// still being built is not in it, so [onSessionLost] never frees a marker
  /// whose own handler is still running.
  final Set<String> _awaitingAnswer = <String>{};

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

  /// A ceremony epoch, bumped by every start and every abort. A
  /// [_handleBlob] parked in its awaits compares it afterwards: a changed
  /// epoch means the ceremony it belongs to is over.
  int _ceremonyEpoch = 0;

  /// The epoch a [_handleBlob] is running for, or null. A blob that arrives
  /// while one is running for the SAME epoch is dropped — the step only
  /// leaves `showSas` after the adopt and the passcode wrap return, so a
  /// second delivery would run a second adopt beside the first (each one
  /// wipes the account namespace). A legitimate `stale_version` re-stage
  /// cannot arrive in that window: it answers our `provisioningComplete`,
  /// which is the last thing a run does.
  int? _blobRunEpoch;

  /// Blob handlers run strictly one after another, across epochs too: an
  /// abort-and-restart must not start the new ceremony's adopt while the old
  /// run is still inside its own.
  Future<void> _blobRuns = Future<void>.value();

  /// Issue #208: whether the current socket is authenticated, and whether
  /// the new-device `openProvisioning` may have reached no server handler —
  /// sent before `socketReady`, or still unanswered when the socket was
  /// lost. Only such an open is asked again at [onSessionReady].
  bool _sessionReady = false;
  bool _openOwed = false;

  /// The same debt for the flipped flow's `provisioningHello` (A2-DEV-01): a
  /// hello sent before `socketReady` is dropped by the server WITHOUT an
  /// answer, and the step it leaves behind has no timer. Owed from the send
  /// on a session that is not ready, or when the socket is lost while the
  /// ack is still out; paid, with the same ephemeral, at [onSessionReady].
  bool _helloOwed = false;

  // ---------- Devices list ----------

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
    final resendHello =
        _helloOwed &&
        newDeviceStep == NewDeviceLinkStep.awaitingHelloAck &&
        _openProvisioningId != null;
    _sessionReady = true;
    _openOwed = false;
    _helloOwed = false;
    if (resend) _emit('openProvisioning', {'role': 'new'});
    if (resendHello) _sendHello();
  }

  @override
  void onSessionLost() {
    _sessionReady = false;
    if (newDeviceStep == NewDeviceLinkStep.opening &&
        _openProvisioningId == null) {
      _openOwed = true;
    }
    if (newDeviceStep == NewDeviceLinkStep.awaitingHelloAck) {
      _helloOwed = true;
    }
    // A request sent on the socket that just went has no answer coming, and
    // these markers are cleared only by one. Fail them with the code the
    // server's own refusal would have carried, so the screen offers a retry.
    var changed = false;
    if (_awaitingAnswer.remove('enroll') && enrolling) {
      enrolling = false;
      enrollError = 'enroll_failed';
      changed = true;
    }
    if (_awaitingAnswer.remove('stage') &&
        primaryStep == PrimaryLinkStep.staging) {
      primaryError = 'stage_failed';
      primaryStep = PrimaryLinkStep.failed;
      changed = true;
    }
    if (_awaitingAnswer.remove('revoke') && revokingDeviceId != null) {
      revokingDeviceId = null;
      revokeError = 'revoke_failed';
      changed = true;
    }
    if (_awaitingAnswer.remove('rename') && renamingDeviceId != null) {
      renamingDeviceId = null;
      renameError = 'rename_failed';
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // ---------- Enable linking (primary enrollment) ----------

  @override
  void onDeviceAuthorityEnrolled(dynamic data) {
    enrolling = false;
    _awaitingAnswer.remove('enroll');
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

  // ---------- Revocation (spec §5.5, T6) ----------

  /// Device id whose revocation is in flight, or null.
  int? revokingDeviceId;

  /// Stable refusal code from the last attempt, or null.
  String? revokeError;

  @override
  void onDeviceRevocationCompleted(dynamic data) {
    if (revokingDeviceId == null) return;
    revokingDeviceId = null;
    _awaitingAnswer.remove('revoke');
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

  @override
  void onDeviceListUpdated(dynamic data) {
    // The restore machine ((lxxviii)) emits the same request from
    // EncryptionProvider and awaits its own completer; an answer that
    // belongs to it finds nothing in flight here and is left alone.
    if (renamingDeviceId == null) return;
    renamingDeviceId = null;
    _awaitingAnswer.remove('rename');
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
    _awaitingAnswer.remove('stage');
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

  // ---------- New-device flow ----------
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
    if (_blobRunEpoch == _ceremonyEpoch) return;
    _blobRunEpoch = _ceremonyEpoch;
    final epoch = _ceremonyEpoch;
    _blobRuns = _blobRuns
        .then((_) => _handleBlob(blobB64, ephPubP, epoch))
        .catchError((Object _) {});
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

  @override
  void dispose() {
    _disposed = true;
    _cancelLivePrimaryStage();
    _expiryTimer?.cancel();
    // A controller torn down mid-flow (screen disposed) must not leave the
    // passcode exemption raised: no further notify will ever run.
    linkCeremonyActive.value = false;
    super.dispose();
  }
}
