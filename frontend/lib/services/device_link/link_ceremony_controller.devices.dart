part of 'link_ceremony_controller.dart';

/// The devices surface: the verified own list, DAK presence, enabling
/// linking, revoking and renaming a device.
extension LinkCeremonyDevices on LinkCeremonyController {
  void refreshDeviceList() {
    _emit('getDeviceList', {'userId': userId});
    unawaited(_resolveDakPresence());
  }

  Future<void> _resolveDakPresence() async {
    DakRecord? record;
    var readFailed = false;
    try {
      record = await _readDakOrThrow();
    } on Object catch (_) {
      readFailed = true;
    }
    // The screen may have popped during the Keystore read.
    if (_disposed) return;
    if (readFailed) {
      // A glitch is not an answer: leave `holdsDak` as it was and say so, so
      // the screen keeps the actions and a later refresh can settle it.
      if (dakReadFailed) return;
      dakReadFailed = true;
      notifyListeners();
      return;
    }
    final present = record != null;
    if (holdsDak == present && !dakReadFailed) return;
    holdsDak = present;
    dakReadFailed = false;
    notifyListeners();
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
      _awaitingAnswer.add('enroll');
    } catch (e) {
      enrollError = 'enroll_failed';
      enrolling = false;
      notifyListeners();
    }
  }

  /// The stored DAK, or null when none is held. A read that THROWS is treated
  /// as null by the action paths (a revoke or rename then fails closed with
  /// `no_dak`); the presence check uses [_readDakOrThrow] so it can tell the
  /// two apart.
  Future<DakRecord?> _readDak() async {
    try {
      return await _readDakOrThrow();
    } on Object catch (_) {
      return null;
    }
  }

  Future<DakRecord?> _readDakOrThrow() async {
    final record = await _dakStore.read(userId: userId);
    if (record != null) {
      _engine.restoreDak(
        dakPubBase64: record.dakPub,
        dakPrivBase64: record.dakPriv,
      );
    }
    return record;
  }

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
      _awaitingAnswer.add('revoke');
    } catch (e) {
      revokingDeviceId = null;
      revokeError = 'sign_failed';
      notifyListeners();
    }
  }

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
      _awaitingAnswer.add('rename');
    } catch (e) {
      renamingDeviceId = null;
      renameError = 'sign_failed';
      notifyListeners();
    }
  }
}
