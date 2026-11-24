part of 'link_ceremony_controller.dart';

/// Ending a new-device ceremony: the epoch test, the orphaned-adopt discard
/// and the I1 abort.
extension LinkCeremonyAbort on LinkCeremonyController {
  bool _ceremonyOver(int epoch) => _disposed || epoch != _ceremonyEpoch;

  /// The ceremony ended (abort, restart or dispose) while an adopt was
  /// parked, so the abort saw nothing adopted and skipped its discard. What
  /// the adopt landed since is removed here. Handlers are serialised, so no
  /// newer ceremony has adopted anything yet.
  Future<void> _discardOrphanedAdopt() async {
    try {
      await _identity.discardProvisionedIdentity(userId);
    } on Object catch (_) {
      // Same as the abort path: the discard failing must not mask the abort.
    }
  }

  /// I1 abort hygiene: discard the adopted identity, every minted key, the
  /// stored dakPub and the assigned id — then reset the flow.
  Future<void> abortNewDevice(String reason) async {
    _ceremonyEpoch++;
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
}
