// Amendment (lxxviii) clauses 1-2 — WIRE LEVEL, against a real backend and a
// real Postgres.
//
// (lxxviii) turns the recovery phrase from a delay-shortener into a real key
// backup: the phrase seals IK + registrationId + DAK server-side, and a wiped
// install that knows the phrase re-uploads the SAME identity with a
// `restoreSignature` instead of serving a 72 h ceremony. That path deliberately
// bypasses the §6.0 takeover alarm and writes NO `identity_change_audit` row —
// which is precisely why it needs wire-level proof: if the branch predicate
// were wrong, the server would silently accept an identity CHANGE with no
// alarm and no audit trail, and every unit test would stay green.
//
// WHAT ONLY THIS FILE CAN PROVE. `key-bundles.service.spec.ts` mocks the
// authorization repo, so it proves the BRANCH but not the QUERY: it would stay
// green if the restore path read the wrong column, if `recovery_keys.backupBlob`
// were never persisted by `setRecoveryKey`, if the migration 0017 columns were
// missing from the DataSource, or if the OTP purge hit the wrong device. So
// this drives the real socket wire and then reads the server's own tables back.
// The client half is the PRODUCTION `adoptRestoredIdentity`, not a hand-rolled
// install: a restore that re-minted anything would upload a different
// `identityPublicKey`, and the server would then adjudicate an identity CHANGE
// instead of a restore — a divergence a server-only harness cannot see.
//
// THE CONTROLS ARE THE POINT:
//   * a restore proof signed by a DIFFERENT key must be refused
//     (`restore_refused`) and must change NOTHING — otherwise "accepted" only
//     means the server accepts everything;
//   * a restore of the UNCHANGED identity must be accepted — otherwise the
//     refusal above would pass with uploads simply broken;
//   * and the §6.1 identity CHANGE path must still work, so the refusal is
//     pinned to the proof rather than to a globally broken upload.
// All three run the IDENTICAL helper calls; only the signing key differs.
//
// THE CIPHER IS NOT THE CONTRACT HERE. The blob is opaque to the server, and
// this host has no webcrypto native (`flutter pub run webcrypto:setup` needs
// cmake), so the codec runs on injected deterministic primitives — exactly
// like `test/services/device_link/identity_backup_test.dart`, which owns the
// real codec contract. What stays production code is the payload SHAPE, the
// `toWire()` field set, and the seal→store→serve→unseal→adopt loop: the wire
// fields still have to satisfy the server's DTO bounds and the unsealed
// records still have to be the exact strings the stores hold.
//
// WHY IT IS OPT-IN, like the reset and enrolled-lock probes. `/auth/register`
// is 10 per HOUR per IP and every file in `test_e2e/` shares one bucket; the
// default run already spends it to the edge. This file registers TWO accounts,
// so it runs in an isolated pass against a fresh backend — never in the shared
// `test_e2e` run. The production cap is not raised to fit a test.
//
//   docker-compose up
//   cd frontend && flutter test test_e2e/identity_restore_test.dart \
//     --dart-define=RESTORE_PROBE=true

// Mock-store setup is legitimate here: this file is a test, but `test_e2e/` is
// a sibling of `test/` so the analyzer does not treat it as one.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption/content_sealer.dart';
import 'package:fireplace/services/passcode_kdf.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

/// Opt-in, for the register-bucket reason in the header.
const bool _enabled = bool.fromEnvironment('RESTORE_PROBE');

/// A real 12-word phrase shape; the server stores only its Argon2id verifier,
/// and the codec below derives the blob key from these exact bytes.
const String _phrase =
    'abandon ability able about above absent absorb abstract absurd abuse '
    'access accident';

/// Deterministic stand-in for PBKDF2 (no webcrypto native on this host).
class _HarnessKdf implements PasscodeKdf {
  const _HarnessKdf();

  @override
  Future<Uint8List> derive({
    required String passcode,
    required Uint8List salt,
    required int iterations,
    int lengthBytes = 32,
  }) async {
    final digest = sha256.convert(
      utf8.encode('$passcode|${base64Encode(salt)}|$iterations'),
    );
    return Uint8List.fromList(digest.bytes.sublist(0, lengthBytes));
  }
}

/// Keyed, AUTHENTICATED stand-in for AES-GCM: a wrong key must fail to open,
/// because `IdentityBackupCodec` keys its wrong-phrase verdict off exactly
/// that null.
class _HarnessSealer implements ContentSealer {
  static const int _tagLength = 32;

  Uint8List _stream(Uint8List key, Uint8List data) => Uint8List.fromList([
    for (var i = 0; i < data.length; i++) data[i] ^ key[i % key.length],
  ]);

  @override
  Future<Uint8List?> seal(Uint8List key, Uint8List plaintext) async {
    final ct = _stream(key, plaintext);
    return Uint8List.fromList([
      ...Hmac(sha256, key).convert(ct).bytes,
      ...ct,
    ]);
  }

  @override
  Future<Uint8List?> unseal(Uint8List key, Uint8List sealed) async {
    if (sealed.length < _tagLength) return null;
    final tag = sealed.sublist(0, _tagLength);
    final ct = sealed.sublist(_tagLength);
    final expected = Hmac(sha256, key).convert(ct).bytes;
    if (!constantTimeBytesEqual(
      Uint8List.fromList(tag),
      Uint8List.fromList(expected),
    )) {
      return null;
    }
    return _stream(key, ct);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();
  // The skip lives on the GROUP, not on the tests: a test-level `skip:` still
  // runs `setUpAll`, which would spend this probe's entire register-bucket cost
  // only to skip it (the lesson recorded in `identity_reset_teardown_test.dart`
  // and `enrolled_identity_lock_test.dart`).
  group(
    '(lxxviii) a phrase-sealed backup restores the SAME identity',
    () {
      final baseUrl = e2eBaseUrl();
      final codec = IdentityBackupCodec(
        kdf: const _HarnessKdf(),
        sealer: _HarnessSealer(),
      );
      late E2eClient subject;
      late E2eClient control;
      E2eClient? restored;
      E2eClient? impostor;
      E2eClient? controlSecond;
      // Captured while each account's identity record still exists: modelling
      // a wiped installation clears the shared mock stores and destroys it.
      late IdentityBackupPayload subjectBackup;
      late IdentityBackupPayload controlBackup;
      late String subjectPair;
      late String controlPair;
      late Map<String, dynamic> sealedBackup;

      Future<String?> scalar(String sql) async {
        final rows = await e2eSql(sql);
        if (rows.isEmpty || rows.first.isEmpty) return null;
        return rows.first.first;
      }

      /// The account's published identity, straight off the server's own
      /// bundle rows. DISTINCT because the (xxviii) teardown MOVES the row to
      /// a freshly allocated deviceId: the account holds one identity, and
      /// the number of rows carrying it is not what this file is about.
      Future<String?> publishedIdentity(int uid) => scalar(
        'SELECT DISTINCT "identityPublicKey" FROM key_bundles '
        'WHERE "userId" = $uid',
      );

      Future<void> bootAccount(E2eClient client) async {
        await client.registerFresh();
        await client.connectSocket();
        await client.initializeAndUploadKeys();
      }

      /// Models the wiped install: clear the shared mock stores, adopt the
      /// account's session, reinstall [install] through the PRODUCTION restore
      /// adopt, then re-upload with a restore proof.
      ///
      /// [signerPair] is what the test varies. Null means the proof is signed
      /// by the identity the adopt just reinstalled — i.e. the real client
      /// path, `EncryptionService.signRestoreProof`. A pair means a stranger
      /// signs, which is the refusal control.
      Future<Map<String, dynamic>> attemptRestore({
        required E2eClient account,
        required IdentityBackupPayload install,
        required String label,
        String? signerPair,
      }) async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        final wiped = E2eClient(label, baseUrl)..adoptAccountFrom(account);
        await wiped.connectSocket();
        final keys = await wiped.adoptRestoredIdentityForUpload(install);
        final identity =
            (keys['keyBundle'] as Map)['identityPublicKey'] as String;
        final nonce = await wiped.fetchRegistrationLockNonce();
        // The restore proof has the §6.1 byte layout exactly — identity ‖
        // userId ‖ nonce — whichever key signs it.
        final proof = signerPair == null
            ? await wiped.encryption.signRestoreProof(nonce)
            : await wiped.signIdentityChange(
                signerPairBase64: signerPair,
                newIdentityPublicKeyBase64: identity,
                nonceBase64: nonce,
              );
        final answer = await wiped.uploadKeyBundleRaw(
          keys,
          restoreSignature: proof,
          nonce: nonce,
        );
        return {'answer': answer, 'client': wiped, 'identity': identity};
      }

      setUpAll(() async {
        await requireBackendUp(baseUrl);
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});

        // ---- the subject: an account WITH a sealed backup ----
        subject = E2eClient('restsub', baseUrl);
        await bootAccount(subject);
        // Exported and sealed through the PRODUCTION exporter + codec, not a
        // hand-rolled blob: a shape the app cannot produce would prove nothing
        // about the real flow.
        subjectBackup = await subject.exportIdentityBackup();
        subjectPair = await subject.exportIdentityPair();
        sealedBackup = (await codec.seal(subjectBackup, _phrase)).toWire();
        expect(
          await subject.setRecoveryKey(_phrase, backup: sealedBackup),
          isTrue,
          reason: 'the whole file is about an account that HAS a backup',
        );

        // ---- the control: an account with NO backup ----
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        control = E2eClient('restctl', baseUrl);
        await bootAccount(control);
        controlBackup = await control.exportIdentityBackup();
        controlPair = await control.exportIdentityPair();
      });

      tearDownAll(() {
        subject.dispose();
        control.dispose();
        restored?.dispose();
        impostor?.dispose();
        controlSecond?.dispose();
      });

      test(
        'the sealed backup is stored and served back byte-identical, and the '
        'status flag flips',
        () async {
          final status = await subject.checkOwnKeyBundle();
          expect(
            status['hasIdentityBackup'],
            isTrue,
            reason: 'the client keys its restore door off this flag',
          );

          final served = await subject.getIdentityBackup();
          expect(served['exists'], isTrue);
          expect(served['blob'], sealedBackup['blob']);
          expect(served['salt'], sealedBackup['salt']);
          expect(served['iterations'], sealedBackup['iterations']);
          expect(served['version'], sealedBackup['version']);
          expect(served['version'], 2);

          // And it is really in Postgres, on the recovery row — not held in
          // some service-level cache that a restart would lose.
          final stored = await scalar(
            'SELECT "backupBlob" FROM recovery_keys '
            'WHERE "userId" = ${subject.userId}',
          );
          expect(stored, sealedBackup['blob']);

          // The control has no backup at all, so the flag is not a constant.
          final controlStatus = await control.checkOwnKeyBundle();
          expect(controlStatus['hasIdentityBackup'], isFalse);
          final controlServed = await control.getIdentityBackup();
          expect(controlServed['exists'], isFalse);
          expect(controlServed['blob'], isNull);
        },
      );

      test(
        'a wiped install restores the SAME identity: rebound session, no audit '
        'row, one-time pre-keys purged',
        () async {
          final identityBefore = await publishedIdentity(subject.userId);
          final auditBefore = await scalar(
            'SELECT COUNT(*) FROM identity_change_audit '
            'WHERE "userId" = ${subject.userId}',
          );
          final otpBefore = await scalar(
            'SELECT COUNT(*) FROM one_time_pre_keys '
            'WHERE "userId" = ${subject.userId}',
          );
          expect(identityBefore, isNotNull);
          expect(
            otpBefore,
            isNot('0'),
            reason: 'the purge assert below would be vacuous with no keys',
          );

          // The install starts from the blob the SERVER served, unsealed with
          // the phrase — the whole loop, not a local copy of the payload.
          final served = await subject.getIdentityBackup();
          final unsealed = await codec.unseal(
            blob: served['blob'] as String,
            salt: served['salt'] as String,
            iterations: served['iterations'] as int,
            version: served['version'] as int,
            phrase: _phrase,
          );
          expect(
            unsealed.identity,
            subjectBackup.identity,
            reason: 'the server must round-trip the sealed record verbatim',
          );

          final attempt = await attemptRestore(
            account: subject,
            install: unsealed,
            label: 'restnew',
          );
          restored = attempt['client'] as E2eClient;
          final answer = attempt['answer'] as Map<String, dynamic>;

          expect(answer['success'], isTrue, reason: 'answer: $answer');
          expect(answer['restored'], isTrue);
          expect(
            answer['identityChanged'],
            isFalse,
            reason: 'a restore reinstalls the SAME key — nothing changed',
          );
          // The client half really reinstalled, never re-minted.
          expect(
            attempt['identity'],
            identityBefore,
            reason: 'adoptRestoredIdentity must reinstall the backed-up IK',
          );
          // The rebound session: the client MUST adopt this before uploading
          // one-time pre-keys, or they land on the abandoned device id.
          expect(answer['access_token'], isA<String>());
          expect(answer['refresh_token'], isA<String>());
          expect(answer['deviceId'], isA<int>());
          expect(
            answer['nextListVersion'],
            isA<int>(),
            reason: 'the client re-signs the list at exactly this version',
          );

          // The identity is byte-identical: this is the entire point of the
          // amendment. A restore that rotated the key would leave every peer
          // with a "security number changed" alarm.
          expect(
            await publishedIdentity(subject.userId),
            identityBefore,
          );
          // And no audit row, so no §6.0 alarm is armed for the next connect.
          expect(
            await scalar(
              'SELECT COUNT(*) FROM identity_change_audit '
              'WHERE "userId" = ${subject.userId}',
            ),
            auditBefore,
          );
          // The pre-wipe one-time pre-keys are gone: their private halves died
          // with the wipe, and the teardown re-homes this device's rows onto
          // the fresh id, which would otherwise carry unanswerable X3DH offers.
          expect(
            await scalar(
              'SELECT COUNT(*) FROM one_time_pre_keys '
              'WHERE "userId" = ${subject.userId}',
            ),
            '0',
          );
        },
      );

      test(
        'a restore proof signed by a STRANGER is refused and changes nothing',
        () async {
          final identityBefore = await publishedIdentity(control.userId);
          final otpBefore = await scalar(
            'SELECT COUNT(*) FROM one_time_pre_keys '
            'WHERE "userId" = ${control.userId}',
          );

          // The install is control's OWN identity, so the upload is NOT an
          // identity change and the server reaches the restore branch — the
          // only thing wrong is the signature. `subjectPair` is a perfectly
          // valid identity key, just not this account's.
          final attempt = await attemptRestore(
            account: control,
            install: controlBackup,
            label: 'restimp',
            signerPair: subjectPair,
          );
          impostor = attempt['client'] as E2eClient;
          final answer = attempt['answer'] as Map<String, dynamic>;

          expect(answer['success'], isFalse, reason: 'answer: $answer');
          expect(answer['error'], 'restore_refused');
          expect(answer['restored'], isNull);
          expect(answer['access_token'], isNull);
          expect(
            await publishedIdentity(control.userId),
            identityBefore,
            reason: 'a refused restore must not touch the stored identity',
          );
          // Nothing written means nothing torn down either: the refusal is
          // adjudicated before the teardown that purges these rows.
          expect(
            await scalar(
              'SELECT COUNT(*) FROM one_time_pre_keys '
              'WHERE "userId" = ${control.userId}',
            ),
            otpBefore,
          );
        },
      );

      test(
        'positive control: the §6.1 identity CHANGE path still works, so the '
        'refusal above is pinned to the proof',
        () async {
          FlutterSecureStorage.setMockInitialValues({});
          SharedPreferences.setMockInitialValues({});
          final second = E2eClient('restchg', baseUrl)
            ..adoptAccountFrom(control);
          controlSecond = second;
          await second.connectSocket();
          final keys = await second.initializeKeys();
          final newIdentity =
              (keys['keyBundle'] as Map)['identityPublicKey'] as String;
          final nonce = await second.fetchRegistrationLockNonce();
          final proof = await second.signIdentityChange(
            signerPairBase64: controlPair,
            newIdentityPublicKeyBase64: newIdentity,
            nonceBase64: nonce,
          );
          // IDENTICAL helper calls to the refused attempt — only the rider
          // name and the signing key differ.
          final answer = await second.uploadKeyBundleRaw(
            keys,
            identitySignature: proof,
            nonce: nonce,
          );

          expect(answer['success'], isTrue, reason: 'answer: $answer');
          expect(answer['identityChanged'], isTrue);
          expect(
            answer['restored'],
            isNull,
            reason: 'a §6.1 rotation is not a restore',
          );
          expect(
            await publishedIdentity(control.userId),
            newIdentity,
          );
        },
      );
    },
    skip: _enabled
        ? false
        : 'opt-in: registers 2 accounts against the 10/hour bucket — run with '
              '--dart-define=RESTORE_PROBE=true',
  );
}
