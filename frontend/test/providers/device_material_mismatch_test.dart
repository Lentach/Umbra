// Amendment (lxiv) clause 2 — GATE2-REVOKED-DEVICE-RELOGIN-CLOBBER.
//
// A revoked linked device that signs back in with the password is resolved by
// the server onto the LIVE PRIMARY's device id, still holds the shared account
// identity plus its OWN locally minted material, and re-uploads its bundle on
// every connect — silently clobbering the primary's published keys and making
// peers' first messages permanently undecryptable by every device.
//
// The client half of the fix: the install stamps which device id its material
// was provisioned for (TOFU on the first server-confirmed id; cleared by every
// authorized re-homing), and refuses E2E duty when the session's confirmed id
// contradicts the stamp. These tests drive the REAL EncryptionService and the
// REAL EncryptionProvider over mock storage — no fake provider state.
//
// Falsification contract: disarming `_verifyMaterialDeviceStamp` (or the init
// gate) must turn the mismatch tests RED; the positive controls must stay
// green so the gate cannot block ordinary single-device operation.

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;

  late List<(String, dynamic)> emitted;

  EncryptionProvider buildProvider() {
    final provider = EncryptionProvider();
    provider.setEmitCallback((event, data) {
      emitted.add((event, data));
      if (event == 'checkOwnKeyBundle') {
        provider.onOwnKeyBundleStatus({'exists': false});
      }
    });
    return provider;
  }

  List<(String, dynamic)> emitsOf(String event) =>
      emitted.where((e) => e.$1 == event).toList();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = [];
  });

  test('positive control: TOFU stamp + matching confirm keeps E2E ready', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);

    expect(provider.isE2EReady, isTrue);
    expect(provider.deviceMaterialMismatch, isFalse);
    expect(emitsOf('uploadKeyBundle'), hasLength(1),
        reason: 'a healthy install must keep publishing');

    // The stamp is real: the same engine confirming the SAME id stays clean.
    provider.setOwnDeviceId(1);
    await pumpEventQueue(times: 200);
    expect(provider.deviceMaterialMismatch, isFalse);
  });

  test(
      'the revoked-relogin shape: material stamped for device 2, session '
      'confirmed as device 1 -> E2E duty refused, nothing published', () async {
    // Life 1: the install is device 2 (a linked laptop). Init mints material
    // and the confirmed id TOFU-stamps 2.
    final life1 = buildProvider();
    life1.setOwnDeviceId(2);
    await life1.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    expect(life1.isE2EReady, isTrue);
    expect(life1.deviceMaterialMismatch, isFalse);

    // Life 2: the device was revoked and signs back in. Same storage (Signal
    // material survives logout by design), but the server resolves the login
    // onto the PRIMARY's id. A fresh provider models the fresh app session.
    emitted = [];
    final life2 = buildProvider();
    var notified = 0;
    life2.addListener(() => notified++);
    life2.setOwnDeviceId(1);
    await life2.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);

    expect(life2.deviceMaterialMismatch, isTrue,
        reason: 'the stamp (2) contradicts the session id (1)');
    expect(life2.isE2EReady, isFalse,
        reason: 'a mismatched install must not join E2E flows');
    expect(notified, greaterThan(0),
        reason: 'the banner cannot appear without a notify');
    expect(emitsOf('uploadKeyBundle'), isEmpty,
        reason: 'the clobbering re-upload is exactly the write this gate exists to stop');
    expect(emitsOf('uploadOneTimePreKeys'), isEmpty);

    // The preKeysLow replenishment path is also refused while mismatched.
    life2.onPreKeysLow(null);
    await pumpEventQueue(times: 200);
    expect(emitsOf('uploadOneTimePreKeys'), isEmpty,
        reason: 'a mismatched install must not deposit OTPs into a foreign pool');
  });

  test('reconnect path: a contradicting confirm AFTER init flips the gate', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(2);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    expect(provider.isE2EReady, isTrue);

    // The reconnect path skips _initializeE2EInner, so setOwnDeviceId's own
    // verification is what must catch a contradicting confirm.
    provider.setOwnDeviceId(1);
    await pumpEventQueue(times: 200);

    expect(provider.deviceMaterialMismatch, isTrue);
    expect(provider.isE2EReady, isFalse);
  });

  test('positive control: an authorized re-homing (rebind clear) re-stamps', () async {
    final life1 = buildProvider();
    life1.setOwnDeviceId(1);
    await life1.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    expect(life1.isE2EReady, isTrue);

    // The §6.2 rebind adoption clears the stamp before reconnecting under the
    // freshly allocated id — the recovering device must NOT trip the gate.
    await life1.encryptionService.clearMaterialDeviceStamp();

    emitted = [];
    final life2 = buildProvider();
    life2.setOwnDeviceId(9);
    await life2.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);

    expect(life2.deviceMaterialMismatch, isFalse);
    expect(life2.isE2EReady, isTrue);
    expect(emitsOf('uploadKeyBundle'), hasLength(1),
        reason: 'the recovering device must keep publishing under its new id');
  });

  test(
      'positive control: a re-homing RECONNECT on the live provider must not '
      'strand the device (final-review P1)', () async {
    // The real §6.2 rebind and §5.1 link reconnect reuse the SAME provider
    // singleton: connect() sees isReconnect=true, clearAll does NOT run, and
    // the `socketReady` handler confirms the freshly allocated id and THEN
    // starts initializeE2E. The previously confirmed OLD id must not
    // TOFU-stamp the just-cleared slot, or the recovered/linked device is
    // stranded out of E2E by its own gate.
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    expect(provider.isE2EReady, isTrue);

    // Authorized re-homing: stamp cleared, then the reconnect sequence.
    await provider.encryptionService.clearMaterialDeviceStamp();
    provider
      ..onConnect(true) // isReconnect — state deliberately preserved
      ..setOwnDeviceId(2); // socketReady with the fresh id ...
    await provider.initializeE2E(ownUserId); // ... then the init it starts
    await pumpEventQueue(times: 200);

    expect(provider.deviceMaterialMismatch, isFalse,
        reason: 'the stale pre-rebind id must not TOFU-stamp the fresh slot');
    expect(provider.isE2EReady, isTrue,
        reason: 'a stranded recovery defeats the §6.2 ceremony it rode in on');
  });

  test('the OTP replenishment carries the (lxiv) registrationId install proof', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);

    provider.onPreKeysLow(null);
    await pumpEventQueue(times: 200);

    final uploads = emitsOf('uploadOneTimePreKeys');
    expect(uploads, hasLength(1));
    final payload = (uploads.single.$2 as Map).cast<String, dynamic>();
    final expected = await provider.encryptionService.currentRegistrationId();
    expect(expected, isNotNull);
    expect(payload['registrationId'], expected,
        reason: 'without the proof the server cannot tell this install from a '
            'foreign one sharing the account identity');
  });

  // Amendment (lxvii) clause 2 — the link predicates are OWNED by the provider,
  // so the devices screen's CTA gate and the ceremony's disposal authorization
  // read one truth. Three shapes admit the device-side flow; two of them
  // authorize disposing the existing identity.
  test('(lxvii): a lock-refused identity admits the link AND its disposal', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);

    expect(provider.needsDeviceLink, isFalse, reason: 'healthy: no link door');
    expect(provider.linkDisposesStaleMaterial, isFalse);

    // The server refuses the upload: the identity this install holds will
    // never serve this session.
    provider.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});

    expect(provider.identityUploadLocked, isTrue);
    expect(provider.linkDisposesStaleMaterial, isTrue,
        reason: 'a refused identity is stale material, exactly like (lxiv)');
    expect(provider.needsDeviceLink, isTrue,
        reason: 'the CTA must not vanish behind a cleared identityIncomplete');

    // The lock clears where it always did: a successful re-upload.
    provider.onKeyBundleUploaded({'success': true});
    expect(provider.linkDisposesStaleMaterial, isFalse);
    expect(provider.needsDeviceLink, isFalse);
  });

  test('(lxvii): the (lxiv) mismatch shape reads through the same predicates', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(2);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    provider.setOwnDeviceId(1);
    await pumpEventQueue(times: 200);

    expect(provider.deviceMaterialMismatch, isTrue);
    expect(provider.linkDisposesStaleMaterial, isTrue);
    expect(provider.needsDeviceLink, isTrue);
  });

  // (lxvii) made the lock flag a DISPOSAL authorization, so its lifetime is
  // now load-bearing: this provider is a process singleton reused across
  // logins, and a refusal answered for account A must not authorize wiping
  // account B's healthy identity in B's ceremony.
  test('(lxvii): the lock does not outlive the session it was answered for', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    provider.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});
    expect(provider.linkDisposesStaleMaterial, isTrue);

    provider.clearAll(); // logout
    expect(provider.linkDisposesStaleMaterial, isFalse,
        reason: 'a stale lock would authorize wiping the next account\'s identity');
    expect(provider.needsDeviceLink, isFalse);

    provider.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});
    expect(provider.linkDisposesStaleMaterial, isTrue);
    provider.onConnect(false); // fresh connect, possibly another account
    expect(provider.linkDisposesStaleMaterial, isFalse);
    provider.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});
    provider.onConnect(true); // a reconnect of the SAME session keeps it
    expect(provider.linkDisposesStaleMaterial, isTrue);
  });
}
