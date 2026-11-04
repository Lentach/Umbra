// Phase 0a takeover alarm (multi-device spec §6.0), wire-level.
//
// The server branch under test: `upsertKeyBundle` with a DIFFERENT
// identityPublicKey than stored must alert the account's OTHER live sessions
// via `ownIdentityReplaced` — excluding the uploading socket, which caused the
// event. The same-identity re-upload (the client's normal every-connect path)
// must stay silent.
//
// The peer half of the alarm (`peerIdentityChanged` to conversation peers) is
// gone with the server's conversation table (Phase 4 step 5): a peer learns of
// an identity change from the next bundle or device list it fetches, which the
// registration-lock and reset probes cover.
//
// PHASE 0b INTERACTION: the registration lock (§6.1) now REFUSES an
// unauthorized identity replacement outright, writing nothing — so there is no
// longer any such thing as an unannounced replacement to alarm about. The
// alarm therefore fires for AUTHORIZED replacements, and this test carries the
// proof the lock demands (old key signs the new one against a session nonce).
// Refusal itself is covered by registration_lock_test.dart.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  enableRealNetwork();

  group('takeover alarm (Phase 0a)', () {
    final baseUrl = e2eBaseUrl();
    late E2eClient victim;
    late E2eClient victimTab;
    E2eClient? replacement;
    // Captured before the storage wipe below destroys the record: the 0b lock
    // requires the PREVIOUS identity key to authorize the replacement.
    late String victimPair;

    setUpAll(() async {
      await requireBackendUp(baseUrl);
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({});
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});

      victim = E2eClient('vic', baseUrl);
      await victim.registerFresh();
      await victim.connectSocket();
      await victim.initializeAndUploadKeys();
      victimPair = await victim.exportIdentityPair();

      // A second live session of the victim's account (another tab/device).
      victimTab = E2eClient('victab', baseUrl)..adoptAccountFrom(victim);
      await victimTab.connectSocket();

      // Reinstall/takeover model, same seam as the incident regression test:
      // reset the shared mock stores so a replacement instance on the SAME
      // account mints a genuinely different Signal identity.
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({});
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      replacement = E2eClient('repl', baseUrl)..adoptAccountFrom(victim);
      await replacement!.connectSocket();
    });

    tearDownAll(() {
      victim.dispose();
      victimTab.dispose();
      replacement?.dispose();
    });

    test(
      'identity replacement alerts the account\'s other sessions; '
      'same-identity re-upload stays silent',
      () async {
        final replacementKeys = await replacement!.initializeKeys();
        final replacementIdentity =
            (replacementKeys['keyBundle'] as Map)['identityPublicKey']
                as String;

        victim.events.discard('ownIdentityReplaced');
        victimTab.events.discard('ownIdentityReplaced');

        // Authorized under the 0b lock: the previous identity key signs the
        // new one against a nonce issued to the uploading session.
        final nonce = await replacement!.fetchRegistrationLockNonce();
        final proof = await replacement!.signIdentityChange(
          signerPairBase64: victimPair,
          newIdentityPublicKeyBase64: replacementIdentity,
          nonceBase64: nonce,
        );
        final answer = await replacement!.uploadKeyBundleRaw(
          replacementKeys,
          identitySignature: proof,
          nonce: nonce,
        );
        expect(answer['success'], isTrue);

        // Both of the account's OTHER live sessions are alerted.
        final tabAlarm = await victimTab.events.next(
          'ownIdentityReplaced',
          reason: 'second session must learn its identity was replaced',
        ) as Map;
        expect(tabAlarm['occurredAt'], isA<String>());
        await victim.events.next(
          'ownIdentityReplaced',
          reason: 'original session must learn its identity was replaced',
        );
        // The uploading socket caused the event — it must NOT be alarmed.
        await replacement!.events.none(
          'ownIdentityReplaced',
          within: const Duration(seconds: 3),
          reason: 'the replacing session must not alarm itself',
        );

        // Same-identity re-upload — the client's normal every-connect path —
        // must raise NO alarm anywhere.
        victim.events.discard('ownIdentityReplaced');
        victimTab.events.discard('ownIdentityReplaced');
        await replacement!.uploadKeyBundle(replacementKeys);
        await victimTab.events.none(
          'ownIdentityReplaced',
          within: const Duration(seconds: 3),
          reason: 'same-identity re-upload must stay silent (sessions)',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
