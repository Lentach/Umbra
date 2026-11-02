// Issue #207 — a §6.2 reset started from the link gate must be SPENT once the
// server completes it.
//
// The server spends a completed ceremony on the first upload of a DIFFERENT
// identity (`consumeCompletedReset`). The two gate shapes that offer
// "Rozpocznij reset" hold no identity they could upload: a keyless install
// ((lxxi)/(lxxiii): the guard refuses to mint while the account has a bundle)
// and an install whose material is stamped for another device id ((lxiv):
// init returns before any publish). So unless a completed ceremony itself
// authorizes the mint, the user waits out the delay and nothing happens.
//
// REAL EncryptionService and EncryptionProvider over mock storage.

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ownUserId = 7;

  late List<(String, dynamic)> emitted;

  /// [status] is what `ownKeyBundleStatus` answers on every check; the
  /// session is confirmed as [deviceId].
  EncryptionProvider buildProvider(
    Map<String, dynamic> Function() status, {
    int deviceId = 1,
  }) {
    final provider = EncryptionProvider();
    return provider
      ..setEmitCallback((event, data) {
        emitted.add((event, data));
        if (event == 'checkOwnKeyBundle') provider.onOwnKeyBundleStatus(status());
      })
      ..setOwnDeviceId(deviceId);
  }

  Map<String, dynamic> enrolled({String? reset}) => {
    'exists': true,
    'linkingEnabled': true,
    'identityReset': reset == null
        ? null
        : {'status': reset, 'deadlineAt': DateTime.now().toUtc().toIso8601String()},
  };

  List<String> uploadedIdentities() => [
    for (final (event, data) in emitted)
      if (event == 'uploadKeyBundle') (data as Map)['identityPublicKey'] as String,
  ];

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = [];
  });

  group('keyless install on the gate', () {
    test('a merely PENDING ceremony mints nothing', () async {
      final provider = buildProvider(() => enrolled(reset: 'pending'));
      await provider.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);

      expect(provider.identityIncomplete, isTrue);
      expect(uploadedIdentities(), isEmpty,
          reason: 'the delay exists so the owner can cancel; pending authorizes nothing');
    });

    test('a COMPLETED ceremony mints and uploads a fresh identity', () async {
      final provider = buildProvider(() => enrolled(reset: 'completed'));
      await provider.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);

      expect(uploadedIdentities(), hasLength(1),
          reason: 'the upload is what spends the ceremony on the server');
      expect(provider.identityIncomplete, isFalse);
      expect(provider.needsDeviceLink, isFalse);
    });

    test('the ceremony completing while the gate is up spends it without a reload',
        () async {
      var reset = 'pending';
      final provider = buildProvider(() => enrolled(reset: reset));
      await provider.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);
      expect(uploadedIdentities(), isEmpty);

      // The countdown's re-read is how a gated session learns of completion.
      reset = 'completed';
      provider.onOwnKeyBundleStatus(enrolled(reset: reset));
      await pumpEventQueue(times: 400);

      expect(uploadedIdentities(), hasLength(1));
      expect(provider.needsDeviceLink, isFalse);
    });
  });

  group('stale-material install on the gate ((lxiv) mismatch)', () {
    Future<String> provisionAsDevice2() async {
      final life1 = buildProvider(() => {'exists': false}, deviceId: 2);
      await life1.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);
      expect(life1.isE2EReady, isTrue);
      final old = uploadedIdentities().single;
      emitted = [];
      return old;
    }

    test('a merely PENDING ceremony publishes nothing', () async {
      await provisionAsDevice2();
      final life2 = buildProvider(() => enrolled(reset: 'pending'));
      await life2.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);

      expect(life2.deviceMaterialMismatch, isTrue);
      expect(uploadedIdentities(), isEmpty);
    });

    test('a COMPLETED ceremony disposes the stale identity and uploads a new one',
        () async {
      final old = await provisionAsDevice2();
      final life2 = buildProvider(() => enrolled(reset: 'completed'));
      await life2.initializeE2E(ownUserId);
      await pumpEventQueue(times: 200);
      expect(life2.deviceMaterialMismatch, isTrue, reason: 'precondition');
      // A loaded store asks the server nothing at init; the connect-time
      // account-status read (ConnectionProvider) is how it hears of the reset.
      life2.refreshOwnAccountStatus();
      await pumpEventQueue(times: 400);

      final uploads = uploadedIdentities();
      expect(uploads, hasLength(1));
      expect(uploads.single, isNot(old),
          reason: 'the stale identity is what the account published; re-sending '
              'it would change nothing and spend nothing');
      expect(life2.needsDeviceLink, isFalse);
    });
  });

  test('a lock-refused install re-sends its identity at once, not on the next connect',
      () async {
    var reset = 'pending';
    final provider = buildProvider(() => {...enrolled(reset: reset), 'exists': false});
    await provider.initializeE2E(ownUserId);
    await pumpEventQueue(times: 200);
    provider.onKeyBundleUploaded({'success': false, 'error': 'identity_locked'});
    final minted = uploadedIdentities().single;
    emitted = [];

    reset = 'completed';
    provider.refreshOwnAccountStatus();
    await pumpEventQueue(times: 200);

    expect(uploadedIdentities(), [minted]);
  });

  test('a sibling tab that minted while this one waited for the lock is loaded, '
      'never minted over', () async {
    const completed = ServerIdentityGuard(exists: true, resetCompleted: true);
    final sibling = EncryptionService();
    String? siblingIdentity;
    final tab = EncryptionService(
      sessionCrossContextLock: <T>(name, action) async {
        if (name.startsWith('fireplace-e2e-reset-mint-') && siblingIdentity == null) {
          // The other tab held the lock first and spent its turn minting.
          await sibling.initialize(ownUserId, checkServerIdentity: () async => completed);
          siblingIdentity =
              (await sibling.getKeyBundleForReupload())!['identityPublicKey'] as String;
        }
        return action();
      },
    );

    await tab.initialize(ownUserId, checkServerIdentity: () async => completed);

    expect(
      (await tab.getKeyBundleForReupload())!['identityPublicKey'],
      siblingIdentity,
      reason: 'a second mint would leave the store holding an identity other '
          'than the one the spending upload published',
    );
    expect(tab.needsKeyUpload, isFalse);
  });
}
