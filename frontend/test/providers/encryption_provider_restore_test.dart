import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/device_list/device_list_canonical.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// The (lxxviii) clause-3 restore state machine, driven over a scripted
/// socket (the emit seam records every event and answers like the server).
///
/// The identity in the backup is REAL: a first EncryptionService mints it,
/// the payload is exported, the mock stores are wiped (the "lost device"),
/// and a second service + provider restore from the sealed blob. The restore
/// proof is verified with real XEdDSA — the exact §6.1 byte layout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 9;
  const phrase = 'abandon ability able about above absent '
      'absorb abstract absurd abuse access accident';
  const wrongPhrase = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';

  IdentityBackupCodec codec() =>
      IdentityBackupCodec(kdf: FakePasscodeKdf(), sealer: FakeContentSealer());

  /// Mints a real identity + DAK for [userId], exports the backup payload,
  /// seals it, then WIPES the stores — the state a restoring install is in.
  Future<SealedIdentityBackup> arrangeSealedBackup({bool withDak = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final original = EncryptionService();
    await original.initialize(
      userId,
      checkServerIdentity: () async =>
          const ServerIdentityGuard(exists: false),
    );
    var payload = await original.exportIdentityForBackup();
    if (withDak) {
      final dakPair = Curve.generateKeyPair();
      payload = IdentityBackupPayload(
        userId: payload.userId,
        identity: payload.identity,
        dak: jsonEncode({
          'userId': userId,
          'dakPub': base64Encode(dakPair.publicKey.serialize()),
          'dakPriv': base64Encode(dakPair.privateKey.serialize()),
          'createdAtMs': 1000,
        }),
      );
    }
    final sealed = await codec().seal(payload, phrase);
    // The lost device: nothing local survives.
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    return sealed;
  }

  /// Provider over a fresh service, `_currentUserId` seeded the way the gate
  /// seeds it (an init pass that could not ask the server).
  Future<EncryptionProvider> buildProvider() async {
    final provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: codec(),
    );
    await provider.initializeE2E(userId);
    return provider;
  }

  String oldListCanonicalB64() => base64Encode(
    encodeCanonicalDeviceList(
      const DeviceList(
        userId: userId,
        version: 3,
        devices: [
          DeviceListEntry(deviceId: 1, platform: 'web', addedAtMs: 100),
          DeviceListEntry(deviceId: 2, platform: 'android', addedAtMs: 200),
        ],
      ),
    ),
  );

  // Issue #208 (owner 11-04): a phrase restore starts fresh only for a device
  // the account unlinked; a live secondary that signed out and back in keeps
  // its history. Mutation: drop the `revokedAtMs == null` test.
  test('only a stamped device the served list revoked counts as unlinked',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'e2e_${userId}_material_device_v1': '2',
    });
    SharedPreferences.setMockInitialValues({});
    final provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: codec(),
    );
    Map<String, dynamic>? served;
    provider.setEmitCallback((event, _) {
      if (event != 'getDeviceList') return;
      scheduleMicrotask(
        () => provider.onDeviceList({
          'userId': userId,
          'authorization': served,
        }),
      );
    });
    String list({int? revokedAtMs}) => base64Encode(
      encodeCanonicalDeviceList(
        DeviceList(
          userId: userId,
          version: 3,
          devices: [
            const DeviceListEntry(deviceId: 1, platform: 'web', addedAtMs: 1),
            DeviceListEntry(
              deviceId: 2,
              platform: 'android',
              addedAtMs: 2,
              revokedAtMs: revokedAtMs,
            ),
          ],
        ),
      ),
    );

    served = {'listCanonical': list()};
    expect(await provider.stampedDeviceRevoked(userId), isFalse);
    served = {'listCanonical': list(revokedAtMs: 3)};
    expect(await provider.stampedDeviceRevoked(userId), isTrue);
    served = null;
    expect(
      await provider.stampedDeviceRevoked(userId),
      isTrue,
      reason: 'a never-enrolled account has no live secondary',
    );
  });

  // Issue #208 (owner 11-04): a restore on an install stamped for another
  // device id starts fresh only when the served list names that id revoked,
  // and fails, touching nothing, when the list does not answer. Mutations:
  // pass `freshDeviceLife: restoreMayStartFresh`; drop the `device_list`
  // failure.
  group('a phrase restore on a previous device life', () {
    Future<({EncryptionProvider provider, List<String> log, List<int> fresh})>
    staleRestore({
      required bool listAnswers,
      int? revokedAtMs = 3,
      bool mismatch = false,
      bool rebinds = false,
    }) async {
      final sealed = await arrangeSealedBackup();
      void answerKeyCheck(EncryptionProvider p) =>
          p.setEmitCallback((event, _) {
            if (event == 'checkOwnKeyBundle') {
              p.onOwnKeyBundleStatus({'exists': false});
            }
          });
      if (mismatch) {
        // The drive-3 shape: a previous life minted material as device 2.
        final life1 = EncryptionProvider(service: EncryptionService());
        answerKeyCheck(life1);
        life1.setOwnDeviceId(2);
        await life1.initializeE2E(userId);
        await pumpEventQueue(times: 200);
      } else {
        FlutterSecureStorage.setMockInitialValues({
          'e2e_${userId}_material_device_v1': '2',
        });
      }
      final provider = EncryptionProvider(
        service: EncryptionService(),
        backupCodec: codec(),
      )..storedSessionDeviceId = (() async => 7);
      if (mismatch) {
        answerKeyCheck(provider);
        provider.setOwnDeviceId(7);
      }
      await provider.initializeE2E(userId);
      await provider.checkPreviousDeviceLife(userId);
      if (mismatch) {
        await pumpEventQueue(times: 200);
        expect(provider.deviceMaterialMismatch, isTrue, reason: 'precondition');
      }
      final log = <String>[];
      final fresh = <int>[];
      provider.onFreshDeviceLife = () async => fresh.add(1);
      final served = base64Encode(
        encodeCanonicalDeviceList(
          DeviceList(
            userId: userId,
            version: 3,
            devices: [
              const DeviceListEntry(deviceId: 1, platform: 'web', addedAtMs: 1),
              DeviceListEntry(
                deviceId: 2,
                platform: 'web',
                addedAtMs: 2,
                revokedAtMs: revokedAtMs,
              ),
            ],
          ),
        ),
      );
      provider.setEmitCallback((event, data) {
        log.add(event);
        switch (event) {
          case 'getIdentityBackup':
            scheduleMicrotask(() => provider.onIdentityBackup({
                  'exists': true,
                  'blob': sealed.blob,
                  'salt': sealed.salt,
                  'iterations': sealed.iterations,
                }));
          case 'getDeviceList':
            scheduleMicrotask(
              listAnswers
                  ? () => provider.onDeviceList({
                        'userId': userId,
                        'authorization': {'listCanonical': served},
                      })
                  // The socket drops: every pending fetch fails at once.
                  : provider.onDisconnect,
            );
          case 'getRegistrationLockNonce':
            scheduleMicrotask(() => provider
                .onRegistrationLockNonce({'nonce': base64Encode([1, 2, 3])}));
          case 'uploadKeyBundle':
            scheduleMicrotask(() {
              if (!rebinds) {
                provider.onKeyBundleUploaded(
                    {'success': false, 'error': 'restore_refused'});
                return;
              }
              // The ConnectionProvider contract: adopt + reconnect FIRST.
              log.add('RECONNECTED');
              provider.onKeyBundleUploaded({
                'success': true,
                'identityChanged': false,
                'restored': true,
                'deviceId': 8,
                'nextListVersion': 4,
              });
            });
          case 'updateDeviceList':
            scheduleMicrotask(() => provider
                .onDeviceListUpdated({'success': true, 'listVersion': 4}));
        }
      });
      expect(provider.restoreMayStartFresh, isTrue, reason: 'precondition');
      await provider.restoreFromPhrase(phrase);
      return (provider: provider, log: log, fresh: fresh);
    }

    test('starts fresh when the list names the stamped device revoked',
        () async {
      final r = await staleRestore(listAnswers: true);
      expect(r.fresh, [1]);
      expect(r.log, contains('uploadKeyBundle'));
    });

    test('keeps its history when the list names the stamped device live',
        () async {
      final r = await staleRestore(listAnswers: true, revokedAtMs: null);
      expect(r.fresh, isEmpty);
      expect(r.log, contains('uploadKeyBundle'));
    });

    test('fails before adopting anything when the list does not answer',
        () async {
      final r = await staleRestore(listAnswers: false);
      expect(r.provider.restoreStage, IdentityRestoreStage.failed);
      expect(r.provider.restoreFailure, IdentityRestoreFailure.failed);
      expect(r.fresh, isEmpty);
      expect(r.log, isNot(contains('uploadKeyBundle')));
    });

    // Issue #208 drive 3: the (lxiv) mismatch flag outlived the rebind (the
    // restore's reconnect is a reconnect, so `onConnect` keeps it) and the
    // restore ack dropped the stashed one-time pre-keys; a kept-history
    // restore then had none at all. Mutation: drop the clear in
    // `_restoreObserveUploadAck`.
    for (final (shape, revokedAtMs) in [('fresh', 3), ('kept', null)]) {
      test('a mismatch-flagged $shape restore uploads its OTPs once, '
          'after the rebind', () async {
        final r = await staleRestore(
          listAnswers: true,
          revokedAtMs: revokedAtMs,
          mismatch: true,
          rebinds: true,
        );
        expect(r.provider.restoreStage, IdentityRestoreStage.done);
        expect(r.fresh, revokedAtMs == null ? isEmpty : [1]);
        final uploads = r.log.where((e) => e == 'uploadOneTimePreKeys');
        expect(uploads, hasLength(1));
        expect(
          r.log.indexOf('RECONNECTED'),
          lessThan(r.log.indexOf('uploadOneTimePreKeys')),
          reason: 'OTPs must ride the rebound device id',
        );
        expect(r.provider.deviceMaterialMismatch, isFalse);
      });
    }
  });

  test('happy path: nonce → proof upload → rebind → OTPs → list → rebuilds',
      () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();
    final nonce = base64Encode(List<int>.generate(24, (i) => i));

    final log = <String>[];
    final payloads = <String, dynamic>{};
    provider.sessionRebuildPeers = () => [11, 22];
    provider.setEmitCallback((event, data) {
      log.add(event);
      payloads[event] = data;
      switch (event) {
        case 'getIdentityBackup':
          scheduleMicrotask(() => provider.onIdentityBackup({
                'exists': true,
                'blob': sealed.blob,
                'salt': sealed.salt,
                'iterations': sealed.iterations,
              }));
        case 'getRegistrationLockNonce':
          scheduleMicrotask(
            () => provider.onRegistrationLockNonce({'nonce': nonce}),
          );
        case 'uploadKeyBundle':
          // The ConnectionProvider contract: adopt + reconnect FIRST, only
          // then deliver the ack (which flushes the OTP stash).
          scheduleMicrotask(() {
            log.add('RECONNECTED');
            provider.onKeyBundleUploaded({
              'success': true,
              'identityChanged': false,
              'restored': true,
              'deviceId': 7,
              'access_token': 'a',
              'refresh_token': 'r',
              'nextListVersion': 4,
            });
          });
        case 'getDeviceList':
          scheduleMicrotask(() => provider.onDeviceList({
                'userId': userId,
                'authorization': {'listCanonical': oldListCanonicalB64()},
              }));
        case 'updateDeviceList':
          scheduleMicrotask(() => provider
              .onDeviceListUpdated({'success': true, 'listVersion': 4}));
      }
    });

    await provider.restoreFromPhrase(phrase);

    expect(provider.restoreStage, IdentityRestoreStage.done);
    expect(provider.restoreFailure, isNull);

    // Order: every stage's wire step in the spec's sequence, and the OTP
    // upload strictly AFTER the reconnect.
    int at(String e) => log.indexOf(e);
    expect(at('getIdentityBackup'), lessThan(at('getRegistrationLockNonce')));
    expect(at('getRegistrationLockNonce'), lessThan(at('uploadKeyBundle')));
    expect(at('uploadKeyBundle'), lessThan(at('RECONNECTED')));
    expect(
      at('RECONNECTED'),
      lessThan(at('uploadOneTimePreKeys')),
      reason: 'OTPs must ride the rebound device id, never the revoked one',
    );
    expect(at('uploadOneTimePreKeys'), lessThan(at('updateDeviceList')));
    expect(at('getDeviceList'), lessThan(at('updateDeviceList')));
    expect(at('updateDeviceList'), lessThan(at('requestSessionRebuild')));
    expect(
      log.where((e) => e == 'requestSessionRebuild'),
      hasLength(2),
      reason: 'one rebuild request per conversation peer',
    );

    // The upload carries the restore proof: real XEdDSA over
    // identityPublicKey ‖ userId ‖ nonce by the RESTORED (unchanged) key.
    final upload = payloads['uploadKeyBundle'] as Map<String, dynamic>;
    expect(upload['nonce'], nonce);
    final identityB64 = upload['identityPublicKey'] as String;
    final identityBytes = base64Decode(identityB64);
    final ok = Curve.verifySignature(
      Curve.decodePoint(Uint8List.fromList(identityBytes), 0),
      Uint8List.fromList([
        ...identityBytes,
        ...utf8.encode('$userId'),
        ...base64Decode(nonce),
      ]),
      Uint8List.fromList(
        base64Decode(upload['restoreSignature'] as String),
      ),
    );
    expect(ok, isTrue, reason: 'F7: the proof must verify under the §6.1 layout');

    // The new list: server-named version, every OLD device tombstoned, the
    // rebound device present and live.
    final signed = payloads['updateDeviceList'] as Map<String, dynamic>;
    final list = parseCanonicalDeviceList(
      base64Decode(signed['listCanonical'] as String),
    );
    expect(list.version, 4);
    expect(list.userId, userId);
    final byId = {for (final d in list.devices) d.deviceId: d};
    expect(byId.keys, containsAll([1, 2, 7]));
    expect(byId[1]!.revokedAtMs, isNotNull);
    expect(byId[2]!.revokedAtMs, isNotNull);
    expect(byId[7]!.revokedAtMs, isNull);
  });

  test('F10: a wrong phrase emits NO nonce request and NO upload', () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();

    final log = <String>[];
    provider.setEmitCallback((event, data) {
      log.add(event);
      if (event == 'getIdentityBackup') {
        scheduleMicrotask(() => provider.onIdentityBackup({
              'exists': true,
              'blob': sealed.blob,
              'salt': sealed.salt,
              'iterations': sealed.iterations,
            }));
      }
    });

    await provider.restoreFromPhrase(wrongPhrase);

    expect(provider.restoreStage, IdentityRestoreStage.failed);
    expect(provider.restoreFailure, IdentityRestoreFailure.wrongPhrase);
    expect(log, isNot(contains('getRegistrationLockNonce')));
    expect(log, isNot(contains('uploadKeyBundle')));
  });

  test('exists:false without an error rider is noBackup', () async {
    await arrangeSealedBackup();
    final provider = await buildProvider();
    provider.setEmitCallback((event, data) {
      if (event == 'getIdentityBackup') {
        scheduleMicrotask(() => provider.onIdentityBackup({'exists': false}));
      }
    });
    await provider.restoreFromPhrase(phrase);
    expect(provider.restoreFailure, IdentityRestoreFailure.noBackup);
  });

  test('exists:false with the fail-closed error rider is failed, not noBackup',
      () async {
    await arrangeSealedBackup();
    final provider = await buildProvider();
    provider.setEmitCallback((event, data) {
      if (event == 'getIdentityBackup') {
        scheduleMicrotask(() => provider.onIdentityBackup(
            {'exists': false, 'error': 'backup_failed'}));
      }
    });
    await provider.restoreFromPhrase(phrase);
    expect(provider.restoreFailure, IdentityRestoreFailure.failed);
  });

  test('a restore_refused ack fails as refused, no list mutation', () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();
    final log = <String>[];
    provider.setEmitCallback((event, data) {
      log.add(event);
      switch (event) {
        case 'getIdentityBackup':
          scheduleMicrotask(() => provider.onIdentityBackup({
                'exists': true,
                'blob': sealed.blob,
                'salt': sealed.salt,
                'iterations': sealed.iterations,
              }));
        case 'getRegistrationLockNonce':
          scheduleMicrotask(() => provider
              .onRegistrationLockNonce({'nonce': base64Encode([1, 2, 3])}));
        case 'uploadKeyBundle':
          scheduleMicrotask(() => provider.onKeyBundleUploaded(
              {'success': false, 'error': 'restore_refused'}));
      }
    });
    await provider.restoreFromPhrase(phrase);
    expect(provider.restoreStage, IdentityRestoreStage.failed);
    expect(provider.restoreFailure, IdentityRestoreFailure.refused);
    expect(log, isNot(contains('updateDeviceList')));
    expect(log, isNot(contains('requestSessionRebuild')));
  });

  test('hasIdentityBackup parses only an explicit bool', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: codec(),
    );
    expect(provider.hasIdentityBackup, isNull);
    provider.onOwnKeyBundleStatus({'exists': true});
    expect(provider.hasIdentityBackup, isNull,
        reason: 'an older server must read as UNKNOWN, never false');
    provider.onOwnKeyBundleStatus({'exists': true, 'hasIdentityBackup': false});
    expect(provider.hasIdentityBackup, isFalse);
    provider.onOwnKeyBundleStatus({'exists': true, 'hasIdentityBackup': true});
    expect(provider.hasIdentityBackup, isTrue);
    provider.onOwnKeyBundleStatus({'exists': true});
    expect(provider.hasIdentityBackup, isTrue,
        reason: 'absence must not erase a known answer');
  });

  test('(lxxxiii) clause 4: hasRecoveryPhrase is its own explicit bool, both '
      'flags flip on a saved phrase, and both reset on account switch', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: codec(),
    );
    expect(provider.hasRecoveryPhrase, isNull);
    // goonboy's shape: a verifier-only phrase, no blob.
    provider.onOwnKeyBundleStatus({
      'exists': true,
      'hasRecoveryPhrase': true,
      'hasIdentityBackup': false,
    });
    expect(provider.hasRecoveryPhrase, isTrue);
    expect(provider.hasIdentityBackup, isFalse);
    // A 0.2.33 server sends no `hasRecoveryPhrase`: UNKNOWN, not false.
    provider.onOwnKeyBundleStatus({'exists': true, 'hasIdentityBackup': false});
    expect(provider.hasRecoveryPhrase, isTrue,
        reason: 'absence must not erase a known answer');

    provider.onOwnKeyBundleStatus({
      'exists': true,
      'hasRecoveryPhrase': false,
      'hasIdentityBackup': false,
    });
    provider.onRecoveryKeySet(const {'success': true});
    expect(provider.hasRecoveryPhrase, isTrue);
    expect(provider.hasIdentityBackup, isTrue);

    // A process singleton reused across logins: user A's answer must not
    // put the Chats line over user B's list until B's first status.
    provider.clearAll();
    expect(provider.hasRecoveryPhrase, isNull);
    expect(provider.hasIdentityBackup, isNull);
  });

  // The failure a code review caught, and the reason it was severe: the gate
  // that HOSTS this machine's progress and errors is mounted on
  // `needsDeviceLink`. Clearing `identityIncomplete` at adopt showed the shell
  // the instant the identity landed, so a failure in any later stage died on
  // an unmounted widget — invisible — while the freshly minted prekeys were
  // never published and peers kept fetching the stale server bundle.
  test('a failure AFTER adopt keeps the gate up, and the restore retries',
      () async {
    final sealed = await arrangeSealedBackup();
    final nonce = base64Encode(List<int>.generate(24, (i) => i));
    var failUpload = true;
    final log = <String>[];
    // Start from the REAL gated state, not the harness's deferred-init one:
    // no local identity + a server that says a bundle exists is what makes
    // the service refuse to mint, sets `identityIncomplete`, and mounts the
    // gate this machine's UI lives on. Asserting on a diag marker instead
    // would pin the marker, not the behaviour — a mutant that re-added the
    // early clear survived exactly that weaker assertion.
    final provider = EncryptionProvider(
      service: EncryptionService(),
      backupCodec: codec(),
    );
    addTearDown(provider.dispose);

    provider.setEmitCallback((event, data) {
      log.add(event);
      switch (event) {
        case 'checkOwnKeyBundle':
          scheduleMicrotask(() => provider.onOwnKeyBundleStatus(
              {'exists': true, 'linkingEnabled': true}));
        case 'getIdentityBackup':
          scheduleMicrotask(() => provider.onIdentityBackup({
                'exists': true,
                'blob': sealed.blob,
                'salt': sealed.salt,
                'iterations': sealed.iterations,
              }));
        case 'getRegistrationLockNonce':
          scheduleMicrotask(
            () => provider.onRegistrationLockNonce({'nonce': nonce}),
          );
        case 'uploadKeyBundle':
          scheduleMicrotask(() {
            if (failUpload) {
              // A refusal stands in for every post-adopt way this can die:
              // the nonce wait, the 45 s ack timeout, the roster re-sign.
              provider.onKeyBundleUploaded(
                  {'success': false, 'error': 'restore_refused'});
            } else {
              provider.onKeyBundleUploaded({
                'success': true,
                'identityChanged': false,
                'restored': true,
                'deviceId': 7,
                'access_token': 'a',
                'refresh_token': 'r',
                'nextListVersion': 4,
              });
            }
          });
        case 'getDeviceList':
          scheduleMicrotask(() => provider.onDeviceList({
                'userId': userId,
                'authorization': {'listCanonical': oldListCanonicalB64()},
              }));
        case 'updateDeviceList':
          scheduleMicrotask(() => provider
              .onDeviceListUpdated({'success': true, 'listVersion': 4}));
      }
    });

    await provider.initializeE2E(userId);
    expect(
      provider.needsDeviceLink,
      isTrue,
      reason: 'precondition: this is the gated, keyless install',
    );

    await provider.restoreFromPhrase(phrase);
    expect(provider.restoreStage, IdentityRestoreStage.failed);
    expect(
      provider.needsDeviceLink,
      isTrue,
      reason: 'a half-done restore must not drop the gate that shows it',
    );

    // The retry re-adopts the SAME identity this device now holds. Refusing
    // that was what made the stuck state permanent.
    failUpload = false;
    await provider.restoreFromPhrase(phrase);

    expect(provider.restoreStage, IdentityRestoreStage.done);
    expect(provider.restoreFailure, isNull);
    expect(
      provider.needsDeviceLink,
      isFalse,
      reason: 'only a finished restore may drop the gate',
    );
    expect(log.where((e) => e == 'uploadKeyBundle'), hasLength(2));
  });

  // The case the FIRST version of the clause-6 fix still got wrong. Stages
  // after the rebind (`listing`, the session rebuilds) run once the reconnect
  // has re-run E2E init, and the init success path clears `identityIncomplete`
  // (:1384) behind the machine's back — so that flag alone cannot be what
  // holds the gate. This drives the predicate directly: a provider whose init
  // SUCCEEDED (so `identityIncomplete` is false) must still be gated while an
  // ADOPTED restore sits unfinished.
  test('an adopted, unfinished restore holds the gate even when init cleared '
      'the flag', () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();
    expect(
      provider.needsDeviceLink,
      isFalse,
      reason: 'precondition: nothing else is holding the gate',
    );

    provider.setEmitCallback((event, data) {
      switch (event) {
        case 'getIdentityBackup':
          scheduleMicrotask(() => provider.onIdentityBackup({
                'exists': true,
                'blob': sealed.blob,
                'salt': sealed.salt,
                'iterations': sealed.iterations,
              }));
        case 'getRegistrationLockNonce':
          scheduleMicrotask(() => provider.onRegistrationLockNonce(
              {'nonce': base64Encode(List<int>.filled(24, 1))}));
        case 'uploadKeyBundle':
          // Adopted, then refused: the identity is held locally with
          // prekeys the server never saw.
          scheduleMicrotask(() => provider.onKeyBundleUploaded(
              {'success': false, 'error': 'restore_refused'}));
      }
    });
    await provider.restoreFromPhrase(phrase);

    expect(provider.restoreStage, IdentityRestoreStage.failed);
    expect(
      provider.needsDeviceLink,
      isTrue,
      reason: 'an adopted restore is itself a reason to keep the gate — the '
          'user has to see the failure and retry it',
    );
  });

  // (lxxx) clause 7: the hold above must NOT apply before anything was
  // adopted. A wrong phrase leaves the install exactly as it was; if the user
  // then takes another door (QR link, 72 h reset) the post-rebind init clears
  // `identityIncomplete` and the gate has to drop — a `failed` stage that
  // nobody ever resets would otherwise gate the install for the life of the
  // process, with nothing left to retry.
  test('a restore that failed BEFORE adopt does not hold the gate', () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();
    provider.setEmitCallback((event, data) {
      if (event == 'getIdentityBackup') {
        scheduleMicrotask(() => provider.onIdentityBackup({
              'exists': true,
              'blob': sealed.blob,
              'salt': sealed.salt,
              'iterations': sealed.iterations,
            }));
      }
    });

    await provider.restoreFromPhrase(wrongPhrase);
    expect(provider.restoreStage, IdentityRestoreStage.failed);
    expect(provider.restoreFailure, IdentityRestoreFailure.wrongPhrase);
    expect(
      provider.needsDeviceLink,
      isFalse,
      reason: 'nothing was adopted, so nothing is half-done: the gate is '
          'held only by whatever brought the user to it',
    );
  });

  // (lxxx) clause 7: the machine belongs to the account. The provider is a
  // process singleton reused across logins, so user A's failed restore must
  // not gate user B — `clearAll()` is the logout / account-switch teardown.
  test('clearAll returns a failed, adopted restore to idle', () async {
    final sealed = await arrangeSealedBackup();
    final provider = await buildProvider();
    provider.setEmitCallback((event, data) {
      switch (event) {
        case 'getIdentityBackup':
          scheduleMicrotask(() => provider.onIdentityBackup({
                'exists': true,
                'blob': sealed.blob,
                'salt': sealed.salt,
                'iterations': sealed.iterations,
              }));
        case 'getRegistrationLockNonce':
          scheduleMicrotask(() => provider.onRegistrationLockNonce(
              {'nonce': base64Encode(List<int>.filled(24, 1))}));
        case 'uploadKeyBundle':
          scheduleMicrotask(() => provider.onKeyBundleUploaded(
              {'success': false, 'error': 'restore_refused'}));
      }
    });
    await provider.restoreFromPhrase(phrase);
    expect(provider.needsDeviceLink, isTrue, reason: 'precondition');

    provider.clearAll();

    expect(provider.restoreStage, IdentityRestoreStage.idle);
    expect(provider.restoreFailure, isNull);
    expect(
      provider.needsDeviceLink,
      isFalse,
      reason: 'the next account must not inherit a gate it cannot clear',
    );
  });
}
