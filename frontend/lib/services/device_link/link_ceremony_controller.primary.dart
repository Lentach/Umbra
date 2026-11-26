part of 'link_ceremony_controller.dart';

/// The primary side of the ceremony: paste or show a code, SAS, approve,
/// cancel, and the stage of the signed v+1 list and blob.
extension LinkCeremonyPrimary on LinkCeremonyController {
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
    // Both devices scanned each other (A2-DEV-04): leaving the displayed `p`
    // code for this paste closes our own stage first, as
    // [startNewDeviceFromCode] does — else the new device's hello would be
    // acked on a stage nobody approves, until it expires.
    final ownStage = _primaryProvisioningId;
    if (primaryStep == PrimaryLinkStep.showCode &&
        ownStage != null &&
        ownStage != code.provisioningId) {
      _emit('cancelProvisioning', {'provisioningId': ownStage});
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
      if (_resignRetries < LinkCeremonyController._kResignRetryCap) {
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
    // The identity read parks this stage: a cancel, a restart or a dispose may
    // land meanwhile, and what it answers belongs to the ceremony that asked.
    bool over() =>
        _disposed ||
        primaryStep != PrimaryLinkStep.staging ||
        _primaryProvisioningId != provisioningId ||
        !identical(_ephP, eph);
    try {
      final identity = await _identity.ownIdentityKeyPair();
      if (over()) return;
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
      _awaitingAnswer.add('stage');
    } catch (e) {
      if (over()) return;
      primaryError = 'stage_failed';
      primaryStep = PrimaryLinkStep.failed;
      notifyListeners();
    }
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
    _awaitingAnswer.remove('stage');
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
}
