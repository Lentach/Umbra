part of 'link_ceremony_controller.dart';

/// The new device's blob run and the session rebind that finishes it. The
/// `_blobRuns` chain that serialises the runs stays in `onProvisioningBlob`.
extension LinkCeremonyBlob on LinkCeremonyController {
  Future<void> _handleBlob(
    String blobB64,
    Uint8List ephPubP,
    int epoch,
  ) async {
    // Queued behind an older run; its ceremony may be over by now.
    if (_ceremonyOver(epoch)) {
      if (_blobRunEpoch == epoch) _blobRunEpoch = null;
      return;
    }
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
      if (_ceremonyOver(epoch)) {
        await _discardOrphanedAdopt();
        return;
      }
      // (lxxvi) clause 3: the adopt just landed RAW key material — with
      // wrapping ON a crash before the next unlock would leave it raw on a
      // "protected" device, so wrap it NOW (idempotent; no-op unwired).
      await PasscodeWrapHook.run();
      if (_ceremonyOver(epoch)) {
        await _discardOrphanedAdopt();
        return;
      }
      _identityAdopted = true;
      newDeviceStep = NewDeviceLinkStep.completing;
      notifyListeners();
      _emit('provisioningComplete', {'provisioningId': _openProvisioningId});
    } on LinkBlobException catch (e) {
      if (!_ceremonyOver(epoch)) await abortNewDevice(e.reason);
    } catch (_) {
      if (_ceremonyOver(epoch)) {
        await _discardOrphanedAdopt();
      } else {
        await abortNewDevice('adopt_failed');
      }
    } finally {
      if (_blobRunEpoch == epoch) _blobRunEpoch = null;
    }
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
}
