part of '../connection_provider.dart';

/// The §6.2 recovery ack: adopting the rebound session and re-enrolling the
/// device authority.
extension ConnectionResetRebind on ConnectionProvider {
  // ---------- Event Routing ----------

  /// The deviceId-bound session a §6.2 recovery ack carries, or null when this
  /// is an ordinary key-bundle ack.
  ///
  /// The server includes the triple ONLY when a reset teardown re-homed the
  /// account, so `access_token` is the discriminator. A partial payload is
  /// treated as absent rather than half-adopted: persisting an access token
  /// with no refresh token would leave a session that cannot be renewed.
  Map<String, dynamic>? _reboundSessionFrom(dynamic data) {
    if (data is! Map) return null;
    if (data['success'] == false) return null;
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    return {'access_token': access, 'refresh_token': refresh};
  }

  /// Plausibility ceiling for a server-named replacement list version
  /// ((xlv) clause 1). A list version advances once per device mutation, so
  /// no real account comes near this; the bound exists only to deny a hostile
  /// server the "freeze the list at the integer ceiling" move.
  static const int _maxPlausibleListVersion = 1000000;

  /// Adopts the recovery session, reconnects under it, and only THEN delivers
  /// the ack — so the pre-key upload it triggers rides the new device id.
  ///
  /// The ack is delivered even when the rebind fails. Dropping it would strand
  /// the stashed pre-keys forever, which is strictly worse than publishing them
  /// to a namespace a later successful rebind can re-publish over; the failure
  /// is recorded so it is visible rather than inferred.
  Future<void> _adoptReboundSession(
    Map<String, dynamic> tokens,
    dynamic data,
  ) async {
    // clock.now() (package:clock), not DateTime.now(): fake_async patches the
    // former, so the rebind floor is deterministic under test.
    final now = clock.now();
    final since = _lastReboundAt == null
        ? null
        : now.difference(_lastReboundAt!);
    if (_reboundInFlight ||
        (since != null && since < AppConstants.reconnectConnectCooldown)) {
      _encryptionProvider?.onKeyBundleUploaded(data);
      return;
    }
    _reboundInFlight = true;
    _lastReboundAt = now;
    final userId = _currentUserId;
    var rebound = false;
    try {
      if (onSessionRebound == null) {
        // Only the auth layer may write the session, so an unwired app cannot
        // complete a recovery. Loud, because the symptom otherwise looks like
        // "recovered account has no pre-keys" three subsystems away.
        E2ePersistentDiag.record('RESET_REBIND_UNWIRED', {});
      } else {
        // (lxiv): the teardown re-homes this install's material onto the
        // freshly allocated device id — drop the old stamp BEFORE the
        // reconnect below, so the new session's confirm re-stamps instead of
        // tripping the material-device gate on the recovering device.
        await _encryptionProvider?.encryptionService.clearMaterialDeviceStamp();
        await onSessionRebound!(tokens);
        if (userId != null) {
          // `immediate` takes exactly one generation; connect() returns
          // quietly when a newer connect or a disconnect took another, and
          // then no socket was opened by this call.
          final ownGeneration = _connectGeneration + 1;
          await connect(
            userId,
            tokens['access_token'] as String,
            AppConfig.baseUrl,
            immediate: true,
          );
          if (_connectGeneration == ownGeneration) {
            rebound = true;
          } else {
            E2ePersistentDiag.record('RESET_REBIND_SUPERSEDED', {});
          }
        } else {
          // Adopted but NOT reconnected: the replenish this ack triggers would
          // ride whatever socket exists, which is a weaker form of the very
          // defect this path closes. Unreachable in a real recovery (the
          // ceremony completes on a connected session), so it is recorded
          // rather than handled — invisible is what would make it dangerous.
          E2ePersistentDiag.record('RESET_REBIND_NO_SESSION', {});
        }
      }
    } catch (error) {
      E2ePersistentDiag.record('RESET_REBIND_FAILED', {
        'error': error.runtimeType.toString(),
      });
    } finally {
      _reboundInFlight = false;
    }
    _encryptionProvider?.onKeyBundleUploaded(data);
    // Amendment (xlv) clause 1, and it runs on the REBOUND socket — the
    // enrollment must be attributed to the freshly allocated device id, and
    // the pre-reset socket is authenticated as a device this teardown just
    // revoked. Strictly after the ack for the same reason the ack is delivered
    // late: the one-time pre-key upload it triggers is the more urgent of the
    // two, and a re-enrollment that fails must not strand it.
    // (lxxviii): a RESTORED rebind keeps its DAK and E — the restore machine
    // re-signs the list via `updateDeviceList`; minting a replacement
    // enrollment here would discard the very authority the backup preserved.
    if (data is Map && data['restored'] == true) return;
    if (rebound && userId != null) {
      final deviceId = data is Map ? data['deviceId'] : null;
      final version = data is Map ? data['nextListVersion'] : null;
      if (deviceId is int && version is int) {
        await _reenrollAfterReset(
          userId: userId,
          deviceId: deviceId,
          version: version,
        );
      } else {
        // An older server that reissues a session without naming the version.
        // Recorded rather than guessed: minting at the wrong version is
        // refused as `stale_version`, and guessing 1 against a surviving row
        // would look like a rollback attempt.
        E2ePersistentDiag.record('RESET_REENROLL_NO_VERSION', {
          'deviceId': '$deviceId',
        });
      }
    }
  }

  /// Re-enrolls the device authority after a §6.2 recovery (amendment (xlv)
  /// clause 1).
  ///
  /// The teardown revoked every device the surviving list names and allocated
  /// an id it does NOT name, so peers hold a list that cannot address this
  /// account — and for an account that never enrolled they synthesize a
  /// device 1 that no longer exists. Neither is repairable with
  /// `updateDeviceList`: that needs the old DAK, whose private half died with
  /// the lost devices. Only a REPLACEMENT enrollment under a fresh DAK, signed
  /// by the new identity, restores addressability.
  ///
  /// Rider order is T3's, unchanged: mint → persist the DAK armed → ONLY THEN
  /// emit. A DAK that signed a list the server accepted but that this device
  /// failed to persist would be unrecoverable authority.
  Future<void> _reenrollAfterReset({
    required int userId,
    required int deviceId,
    required int version,
  }) async {
    final encryption = _encryptionProvider;
    if (encryption == null) {
      E2ePersistentDiag.record('RESET_REENROLL_UNWIRED', {});
      return;
    }
    // The server names this version, and an honest one names `stored + 1`.
    // Signing it unbounded would let a hostile one name a number near the
    // integer ceiling: every later DAK-signed mutation must strictly exceed
    // the stored version, so the account's device list would be frozen for
    // good — a state that survives the server becoming honest again. The
    // client cannot authenticate the number (the row it would check against is
    // the orphaned one), so the only honest defence is a plausibility ceiling:
    // list versions advance once per device mutation, so a real account never
    // approaches this.
    if (version < 1 || version > _maxPlausibleListVersion) {
      E2ePersistentDiag.record('RESET_REENROLL_IMPLAUSIBLE_VERSION', {
        'version': '$version',
      });
      return;
    }
    // Single-flight ((lxxxv)). Taken BEFORE the mint, not at the ack: two
    // concurrent passes each minted a DAK and armed a pending record, so even
    // the winner's promote was no longer bound to the enrollment the server
    // accepted. A duplicate offer must cost nothing — the one in flight is
    // already the attempt, and the offer rides every later upload anyway.
    if (_reenrollInFlight) {
      E2ePersistentDiag.record('RESET_REENROLL_INFLIGHT', {
        'deviceId': '$deviceId',
        'version': '$version',
      });
      return;
    }
    _reenrollInFlight = true;
    try {
      // Throws when the service holds no identity (RESET_REENROLL_FAILED).
      final identity = await encryption.encryptionService
          .identityKeyPairForLinking();
      final engine = DeviceAuthorityEngine();
      final payload = engine.mintEnrollment(
        userId: userId,
        identity: identity,
        createdAtMs: clock.now().millisecondsSinceEpoch,
        platform: linkPlatformLabel(),
        deviceId: deviceId,
        version: version,
      );
      final exported = engine.exportDakForPersistence();
      // Amendment (liii). The candidate goes to a PENDING slot, never over the
      // live record. This offer cannot be authenticated by us — the enrollment
      // row we would check it against is the orphaned one, which is why the
      // server-named `version` above gets a plausibility ceiling rather than a
      // signature check — so a spurious offer must cost us nothing. Overwriting
      // in place meant one crafted event destroyed the account's real DAK
      // private half, and every later revoke/provision died on
      // `invalid_list_signature` with a 72 h reset as the only exit.
      //
      // Still ARMED before the emit, so an enrollment the server accepts can
      // never be one we failed to persist.
      final store = DakStore();
      await store.persistPendingArmed(
        DakRecord(
          userId: userId,
          dakPub: exported['dakPub']!,
          dakPriv: exported['dakPriv']!,
          createdAtMs: payload['createdAt'] as int,
        ),
      );
      final ack = Completer<Map<String, dynamic>>();
      _resetEnrollAck = ack;
      _socketService.enrollDeviceAuthority(payload);
      final answer = await ack.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => const {'success': false, 'error': 'timeout'},
      );
      if (answer['success'] == true) {
        await store.promotePending(userId: userId);
        E2ePersistentDiag.record('RESET_REENROLL_PROMOTED', {
          'deviceId': '$deviceId',
          'version': '$version',
        });
      } else {
        // Left visible rather than retried here: the account is still
        // reachable-by-nobody, and (xlv) clause 2 keeps peers failing CLOSED
        // meanwhile instead of silently addressing a device that cannot
        // receive.
        E2ePersistentDiag.record('RESET_REENROLL_REFUSED', {
          'error': '${answer['error']}',
          'deviceId': '$deviceId',
          'version': '$version',
        });
        // An EXPLICIT refusal means this candidate authorizes nothing, so drop
        // it. A timeout is ambiguous and deliberately leaves it: the live
        // record is intact either way, and the offer rides every later upload.
        if (answer['error'] != 'timeout') {
          await store.clearPending(userId: userId);
        }
      }
    } catch (error) {
      E2ePersistentDiag.record('RESET_REENROLL_FAILED', {
        'error': error.runtimeType.toString(),
      });
    } finally {
      _resetEnrollAck = null;
      _reenrollInFlight = false;
    }
  }
}
