// A3-SVC-A-2: the server reports "another session replaced your keys" on
// every socketReady, but E2E init waits for the passcode unlock. On a locked
// cold start the report reaches a service that has no user yet; the unlock
// then loaded the (empty) persisted state over it and the warning was lost
// until the next reconnect.
import 'dart:async';

import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 21;
  const replacedAt = '2026-08-18T00:00:00.000Z';
  const noBundle = ServerIdentityGuard(exists: false, linkingEnabled: false);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.clear();
    await E2ePersistentDiag.init();
  });

  test('a replacement reported while locked survives the unlock', () async {
    final svc = EncryptionService();
    var notified = 0;
    svc.onOwnIdentityReplaced = () => notified++;

    // Locked cold start: the socket is up, `initialize` has not run.
    await svc.recordOwnIdentityReplacedFromServer(replacedAt);
    // Held, not raised: the key it would be judged against is not loaded.

    await svc.initialize(userId, checkServerIdentity: () async => noBundle);

    expect(
      svc.ownIdentityReplacedAt,
      replacedAt,
      reason: 'the unlock must not throw the pending warning away',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('e2e_${userId}_own_identity_replaced_v1'),
      replacedAt,
      reason: 'and it must now be saved, so a restart keeps it too',
    );
    expect(notified, greaterThan(0));
  });

  /// An opener that parks the first open of the content store: `initialize`
  /// has bound its user and waits for the persisted state, the window in
  /// which the connect-time status answer can arrive (A3-SVC-A-2, S3).
  Future<(EncryptionService, Completer<void>)> serviceParkedAtOpen() async {
    final real = await EncryptionService().contentKv;
    final gate = Completer<void>();
    final svc = EncryptionService()
      ..debugSetContentKvOpener(() async {
        await gate.future;
        return real;
      });
    return (svc, gate);
  }

  test('a report arriving after the user is bound but before the saved '
      'state loads does not re-raise a dismissed replacement', () async {
    SharedPreferences.setMockInitialValues({
      'e2e_${userId}_own_identity_replaced_seen_v1': replacedAt,
    });
    final (svc, gate) = await serviceParkedAtOpen();

    final init = svc.initialize(userId, checkServerIdentity: () async => noBundle);
    await pumpEventQueue();
    final report = svc.recordOwnIdentityReplacedFromServer(replacedAt);
    await pumpEventQueue();
    gate.complete();
    await init;
    await report;

    expect(svc.ownIdentityReplacedAt, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('e2e_${userId}_own_identity_replaced_v1'), isNull);
  });

  test('a genuine report arriving in that same window is shown', () async {
    final (svc, gate) = await serviceParkedAtOpen();

    final init = svc.initialize(userId, checkServerIdentity: () async => noBundle);
    await pumpEventQueue();
    final report = svc.recordOwnIdentityReplacedFromServer(replacedAt);
    await pumpEventQueue();
    gate.complete();
    await init;
    await report;

    expect(svc.ownIdentityReplacedAt, replacedAt);
  });

  test('a report held across the unlock for our own re-publish '
      'spends the one-shot flag and raises nothing', () async {
    SharedPreferences.setMockInitialValues({
      'e2e_${userId}_own_publish_unacked_v1': 1,
    });
    final svc = EncryptionService();

    await svc.recordOwnIdentityReplacedFromServer(replacedAt);
    await svc.initialize(userId, checkServerIdentity: () async => noBundle);

    expect(svc.ownIdentityReplacedAt, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('e2e_${userId}_own_publish_unacked_v1'), isNull);
  });

  test('a report for a newer instant than the saved alarm wins', () async {
    SharedPreferences.setMockInitialValues({
      'e2e_${userId}_own_identity_replaced_v1': '2026-08-01T00:00:00.000Z',
    });
    final svc = EncryptionService();

    await svc.recordOwnIdentityReplacedFromServer(replacedAt);
    await svc.initialize(userId, checkServerIdentity: () async => noBundle);

    expect(svc.ownIdentityReplacedAt, replacedAt);
  });
}
