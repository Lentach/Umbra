part of 'link_ceremony_controller.dart';

/// The new-device side up to the SAS: open, show or scan a code, hello.
extension LinkCeremonyNewDevice on LinkCeremonyController {
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
    _ceremonyEpoch++;
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
    _ceremonyEpoch++;
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
}
