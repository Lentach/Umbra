part of '../connection_provider.dart';

// Extension methods on ConnectionProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// Socket event routing to the sub-providers and the provisioning sink.
extension ConnectionEvents on ConnectionProvider {
  void _registerEventListeners() {
    // --- Encryption events ---
    // A §6.2 recovery ack carries the device id the material now lives under
    // plus a session bound to it, and the client MUST adopt them BEFORE any
    // one-time pre-key upload (`chat-key-exchange.service.ts` says so at the
    // emit site). Delivering the ack first is what strands the pool: the
    // handler replenishes on `identityChanged`, and this socket is still
    // authenticated as the device the teardown just REVOKED — so the keys land
    // in the abandoned namespace, peers are served a bundle with no one-time
    // pre-key, and the next reconnect is refused by the §5.5 gate.
    _socketService.on('keyBundleUploaded', (data) {
      final rebind = _reboundSessionFrom(data);
      if (rebind != null) {
        unawaited(_adoptReboundSession(rebind, data));
        return;
      }
      _encryptionProvider?.onKeyBundleUploaded(data);
      // No rebind, but the server can still be telling us we owe it a
      // replacement enrollment ((xlv) clause 1): the recovery's own attempt
      // died with a dropped socket or a killed app, and the roster block that
      // started it runs only once, on the upload that consumed the ceremony.
      // The offer rides every authenticated upload until it is taken.
      // (lxxviii): same exemption as the rebind branch above — a RESTORED
      // upload preserved its DAK, and the restore machine re-signs the list
      // itself. A replacement enrollment would throw that authority away.
      if (data is Map && data['restored'] == true) return;
      final owedDeviceId = data is Map ? data['deviceId'] : null;
      final owedVersion = data is Map ? data['nextListVersion'] : null;
      final userId = _currentUserId;
      if (owedDeviceId is int && owedVersion is int && userId != null) {
        unawaited(
          _reenrollAfterReset(
            userId: userId,
            deviceId: owedDeviceId,
            version: owedVersion,
          ),
        );
      }
    });
    _socketService.on('oneTimePreKeysUploaded', (data) {
      _encryptionProvider?.onOneTimePreKeysUploaded(data);
    });
    _socketService.on('preKeyBundleResponse', (data) {
      _encryptionProvider?.onPreKeyBundleResponse(data);
    });
    _socketService.on('ownKeyBundleStatus', (data) {
      _encryptionProvider?.onOwnKeyBundleStatus(data);
    });
    _socketService.on('preKeysLow', (data) {
      _encryptionProvider?.onPreKeysLow(data);
    });
    _socketService.on('sessionRebuildNeeded', (data) {
      _encryptionProvider?.onSessionRebuildNeeded(data);
    });
    // Phase 0a takeover alarm (multi-device spec §6.0): another sign-in
    // replaced this account's key bundle.
    _socketService.on('ownIdentityReplaced', (data) {
      _encryptionProvider?.onOwnIdentityReplaced(data);
    });
    // Phase 0b reset ceremony (spec §6.2): every session of the account is
    // told, so any of them can cancel during the delay.
    _socketService.on('identityResetPending', (data) {
      _encryptionProvider?.onIdentityResetPending(data);
    });
    _socketService.on('identityResetCancelled', (data) {
      _encryptionProvider?.onIdentityResetCancelled(data);
    });
    _socketService.on('identityResetStatus', (data) {
      _encryptionProvider?.onIdentityResetStatus(data);
    });
    _socketService.on('identityResetCancelResult', (data) {
      _encryptionProvider?.onIdentityResetCancelResult(data);
    });
    _socketService.on('recoveryKeySet', (data) {
      _encryptionProvider?.onRecoveryKeySet(data);
    });
    // --- (lxxviii) phrase backup + restore ---
    _socketService.on('identityBackup', (data) {
      _encryptionProvider?.onIdentityBackup(data);
    });
    _socketService.on('registrationLockNonce', (data) {
      _encryptionProvider?.onRegistrationLockNonce(data);
    });
    _socketService.on('deviceListUpdated', (data) {
      _encryptionProvider?.onDeviceListUpdated(data);
      // (lxxx) clause 1: a device RENAME rides the same request, so the
      // ceremony controller hears the same answer. Each ignores one it has
      // nothing in flight for — the restore machine's completer is untouched.
      _provisioningSink?.onDeviceListUpdated(data);
    });

    // --- Device list + §5.1 provisioning ceremony (Phase 2 T3) ---
    // Forwarded to the screen-scoped ceremony controller (registered by
    // DevicesScreen for its lifetime). No controller = no listener work.
    _socketService.on('provisioningOpened', (data) {
      _provisioningSink?.onProvisioningOpened(data);
    });
    _socketService.on('provisioningHelloAck', (data) {
      _provisioningSink?.onProvisioningHelloAck(data);
    });
    _socketService.on('provisioningHello', (data) {
      _provisioningSink?.onProvisioningHelloRelay(data);
    });
    _socketService.on('provisionDeviceAck', (data) {
      _provisioningSink?.onProvisionDeviceAck(data);
    });
    _socketService.on('provisioningBlob', (data) {
      _provisioningSink?.onProvisioningBlob(data);
    });
    _socketService.on('provisioningCompleted', (data) {
      _provisioningSink?.onProvisioningCompleted(data);
    });
    _socketService.on('provisioningCancelled', (data) {
      _provisioningSink?.onProvisioningCancelled(data);
    });
    _socketService.on('deviceAuthorityEnrolled', (data) {
      // A recovery re-enrollment ((xlv) clause 1) owns its own answer: it runs
      // with no screen mounted, so there is no sink to route to. The two
      // cannot overlap — one needs DevicesScreen open, the other runs at
      // login — and the waiter is cleared as soon as it settles.
      final waiter = _resetEnrollAck;
      if (waiter != null && !waiter.isCompleted) {
        _resetEnrollAck = null;
        waiter.complete(
          data is Map
              ? data.cast<String, dynamic>()
              : const <String, dynamic>{'success': false, 'error': 'malformed'},
        );
        return;
      }
      _provisioningSink?.onDeviceAuthorityEnrolled(data);
    });
    _socketService.on('deviceList', (data) {
      _provisioningSink?.onDeviceList(data);
      // T4 C2: the send path's verified-list cache consumes the same answer;
      // each consumer keys on its own pending state, so double routing is
      // harmless.
      _encryptionProvider?.onDeviceList(data);
    });
    _socketService.on('deviceListChanged', (data) {
      _provisioningSink?.onDeviceListChanged(data);
      _encryptionProvider?.onDeviceListChanged(data);
    });
    _socketService.on('deviceRevocationCompleted', (data) {
      _provisioningSink?.onDeviceRevocationCompleted(data);
    });
    // THIS device was revoked (spec §5.5 + amendment (xxvi)). The server tells
    // us, then drops the socket; a later reconnect attempt is refused with the
    // same event before the socket closes, so this is the only place the app
    // ever learns WHY instead of showing the generic connection-lost banner.
    _socketService.on('deviceRevoked', (data) {
      _onOwnDeviceRevoked(data);
    });
    // --- Friend events ---
    _socketService.on('searchUsersResult', (data) {
      _friendsProvider?.onSearchUsersResult(data);
    });
    _socketService
      ..on('serverTime', _onServerTime)
      // PR3.1: the answer to the box request-queue publish (`BoxSession`).
      ..on('requestQueueSet', (data) => _box?.onRequestQueueSet(data))
      // Sibling queues: the answer to the own request-queue lookup.
      ..on('ownRequestQueues', (data) => _box?.onOwnRequestQueues(data));

    // --- Error event ---
    _socketService.on('error', (err) {
      final String msg = err is Map<String, dynamic> && err['message'] != null
          ? err['message'] as String
          : err.toString();
      _errorMessage = msg;
      notifyListeners();
    });
  }
}
