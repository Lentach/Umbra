// Amendment (lxxiii) clauses 2 and 4 — the opt-in registration lock, client
// half.
//
// Clause 2: `ownKeyBundleStatus` carries `linkingEnabled` (an
// `account_authorizations` row exists — the lock is ARMED). The guard's
// tri-state becomes a pair: `exists && linkingEnabled` gates as before;
// `exists && !linkingEnabled` means the server accepts an 'unlocked'
// replacement, so the client discards any residue (PROVEN) and mints —
// a routine PWA storage wipe on a never-linked account must not cost the
// §6.2 delay. An ABSENT field (older server) MUST read as `true`: fail
// closed to the gating behaviour, never to a mint the server would refuse.
//
// Clause 4: the §5.1 adopt path wipes whenever RESIDUE is present — not only
// when an identity is held. A residue install (prekeys, sessions,
// next_pre_key_id survive; identity gone) previously had the received
// identity installed OVER foreign prekeys and a stale prekey counter — the
// stranded-ratchet shape.
import 'dart:convert';

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secure = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    await E2ePersistentDiag.init();
  });

  group('(lxxiii) clause 2 — unlocked remint', () {
    test(
      'exists && !linkingEnabled with residue: residue rows gone, fresh '
      'identity minted, IDENTITY_GUARD_UNLOCKED_REMINT recorded',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'e2e_21_session_49_1': 'fake-record',
          'e2e_21_pre_key_777': 'fake-prekey',
          'e2e_21_next_pre_key_id': '778',
        });

        final svc = EncryptionService();
        await svc.initialize(
          21,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: true, linkingEnabled: false),
        );

        expect(svc.needsKeyUpload, isTrue);
        expect(await secure.read(key: 'e2e_21_identity_record_v1'), isNotNull);
        expect(
          await secure.read(key: 'e2e_21_session_49_1'),
          isNull,
          reason: 'no peer can follow a ratchet against unpublished material',
        );
        expect(await secure.read(key: 'e2e_21_pre_key_777'), isNull);
        expect(
          E2ePersistentDiag.entries.where(
            (e) => e.contains('IDENTITY_GUARD_UNLOCKED_REMINT'),
          ),
          hasLength(1),
        );
      },
    );

    test('exists && !linkingEnabled on a clean store mints without asking',
        () async {
      final svc = EncryptionService();
      await svc.initialize(
        22,
        checkServerIdentity: () async =>
            const ServerIdentityGuard(exists: true, linkingEnabled: false),
      );

      expect(svc.needsKeyUpload, isTrue);
      expect(await secure.read(key: 'e2e_22_identity_record_v1'), isNotNull);
      expect(
        E2ePersistentDiag.entries.where(
          (e) => e.contains('IDENTITY_GUARD_UNLOCKED_REMINT'),
        ),
        hasLength(1),
      );
    });

    test('exists && linkingEnabled still gates: no mint, no writes', () async {
      final svc = EncryptionService();
      await expectLater(
        svc.initialize(
          23,
          checkServerIdentity: () async =>
              const ServerIdentityGuard(exists: true, linkingEnabled: true),
        ),
        throwsA(isA<E2eIdentityIncompleteException>()),
      );
      expect(await secure.read(key: 'e2e_23_identity_record_v1'), isNull);
    });
  });

  group('(lxxiii) clause 2 — fail-closed payload parse', () {
    /// Drives the REAL provider parse (`onOwnKeyBundleStatus`) into the real
    /// guard, the way a connect does.
    Future<EncryptionProvider> initAgainst(
      int userId,
      Map<String, dynamic> payload,
    ) async {
      final provider = EncryptionProvider(service: EncryptionService());
      provider.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus(payload);
        }
      });
      await provider.initializeE2E(userId);
      return provider;
    }

    test('ABSENT linkingEnabled reads as armed: gate, never a mint', () async {
      final provider = await initAgainst(31, {'exists': true});

      expect(provider.identityIncomplete, isTrue);
      expect(provider.isE2EReady, isFalse);
      expect(await secure.read(key: 'e2e_31_identity_record_v1'), isNull);
    });

    test('non-bool linkingEnabled reads as armed', () async {
      final provider = await initAgainst(32, {
        'exists': true,
        'linkingEnabled': 'no',
      });

      expect(provider.identityIncomplete, isTrue);
      expect(provider.isE2EReady, isFalse);
    });

    test('explicit linkingEnabled: false remints and comes up ready',
        () async {
      final provider = await initAgainst(33, {
        'exists': true,
        'linkingEnabled': false,
      });

      expect(provider.identityIncomplete, isFalse);
      expect(provider.isE2EReady, isTrue);
      expect(await secure.read(key: 'e2e_33_identity_record_v1'), isNotNull);
    });
  });

  group('(lxxiii) clause 3 — the UNKNOWN outcome gets a flag', () {
    test(
      'a null guard answer sets identityCheckUnavailable and a disconnect '
      'does NOT clear it (offline must never show a keyless shell)',
      () async {
        final provider = EncryptionProvider(service: EncryptionService());
        // No emit callback wired: the check cannot even be sent — UNKNOWN.
        await provider.initializeE2E(41);

        expect(provider.isE2EReady, isFalse);
        expect(provider.identityCheckUnavailable, isTrue);
        expect(provider.identityIncomplete, isFalse);

        provider.onDisconnect();
        expect(provider.identityCheckUnavailable, isTrue);
      },
    );

    test('retryE2EInit re-runs the init and a decided answer clears the flag',
        () async {
      final provider = EncryptionProvider(service: EncryptionService());
      await provider.initializeE2E(42); // UNKNOWN — no socket
      expect(provider.identityCheckUnavailable, isTrue);

      provider.setEmitCallback((event, data) {
        if (event == 'checkOwnKeyBundle') {
          provider.onOwnKeyBundleStatus({'exists': false});
        }
      });
      await provider.retryE2EInit();

      expect(provider.identityCheckUnavailable, isFalse);
      expect(provider.isE2EReady, isTrue);
    });
  });

  group('(lxxiii) clause 4 — adopt over residue wipes first', () {
    ({String ikPub, String ikPriv, String dakPub}) mintBlobInputs() {
      final pair = generateIdentityKeyPair();
      return (
        ikPub: base64Encode(pair.getPublicKey().serialize()),
        ikPriv: base64Encode(pair.getPrivateKey().serialize()),
        dakPub: base64Encode(List<int>.filled(32, 3)),
      );
    }

    test(
      'a never-published residue (no identity) is wiped before the adopt '
      'writes — no consent flag needed',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'e2e_7_session_49_1': 'foreign-session',
          'e2e_7_pre_key_777': 'foreign-prekey',
          'e2e_7_next_pre_key_id': '778',
        });
        final blob = mintBlobInputs();

        final svc = EncryptionService();
        await svc.adoptProvisionedIdentity(
          userId: 7,
          ikPubBase64: blob.ikPub,
          ikPrivBase64: blob.ikPriv,
          dakPubBase64: blob.dakPub,
        );

        expect(
          E2ePersistentDiag.entries.where(
            (e) => e.contains('LINK_IDENTITY_ADOPTED'),
          ),
          hasLength(1),
        );
        final all = await secure.readAll();
        expect(
          all['e2e_7_session_49_1'],
          isNull,
          reason: 'foreign session must not survive LINK_IDENTITY_ADOPTED',
        );
        expect(
          all['e2e_7_pre_key_777'],
          isNull,
          reason: 'foreign prekey must not survive LINK_IDENTITY_ADOPTED',
        );
        // The stale counter was replaced by the adopt's own mint, not kept.
        expect(all['e2e_7_next_pre_key_id'], isNot('778'));
        // And the adopt actually installed the blob identity.
        expect(await svc.currentIdentityPublicKeyBase64(), blob.ikPub);
      },
    );

    test('a clean keyless store adopts without any wipe bookkeeping',
        () async {
      final blob = mintBlobInputs();
      final svc = EncryptionService();
      await svc.adoptProvisionedIdentity(
        userId: 8,
        ikPubBase64: blob.ikPub,
        ikPrivBase64: blob.ikPriv,
        dakPubBase64: blob.dakPub,
      );

      expect(await svc.currentIdentityPublicKeyBase64(), blob.ikPub);
      expect(
        E2ePersistentDiag.entries.where(
          (e) => e.contains('LINK_RESIDUE_DISPOSAL_DEFERRED'),
        ),
        isEmpty,
      );
    });
  });
}
