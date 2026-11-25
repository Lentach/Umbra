// EncryptionProvider is one object per process, reused across logins. State
// and unfinished work of the account that just signed out must never reach
// the account that signs in next.
//
// REAL EncryptionService and EncryptionProvider over mock storage.

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userA = 7;
  const userB = 9;

  late List<(String, dynamic)> emitted;

  /// What `ownKeyBundleStatus` answers per check; null leaves the check
  /// unanswered (the init stays waiting on the server).
  late Map<String, dynamic>? Function() status;

  EncryptionProvider buildProvider() {
    final provider = EncryptionProvider();
    return provider
      ..setEmitCallback((event, data) {
        emitted.add((event, data));
        if (event == 'checkOwnKeyBundle') {
          final answer = status();
          if (answer != null) provider.onOwnKeyBundleStatus(answer);
        }
      })
      ..setOwnDeviceId(1);
  }

  /// An account that already published an identity this install does not hold.
  Map<String, dynamic> enrolled() => {
    'exists': true,
    'linkingEnabled': true,
    'identityReset': null,
  };

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = [];
  });

  group('the link gate of the account that signed out', () {
    Future<EncryptionProvider> gatedAsA() async {
      status = enrolled;
      final provider = buildProvider();
      await provider.initializeE2E(userA);
      await pumpEventQueue(times: 200);
      expect(provider.needsDeviceLink, isTrue, reason: 'precondition: A is gated');
      return provider;
    }

    test("is gone after logout, before the next account's init answers", () async {
      final provider = await gatedAsA();

      provider.clearAll(); // A taps logout on the gate
      expect(provider.needsDeviceLink, isFalse);

      // B signs in; the server has not answered B's bundle check yet.
      status = () => null;
      final initB = provider.initializeE2E(userB);
      await pumpEventQueue(times: 200);
      expect(provider.needsDeviceLink, isFalse,
          reason: 'B must not see the gate A was stuck on');

      provider.onOwnKeyBundleStatus({'exists': false});
      await initB;
      expect(provider.needsDeviceLink, isFalse);
      expect(provider.isE2EReady, isTrue);
    });

    test('is gone on a fresh (non-reconnect) connect', () async {
      final provider = await gatedAsA();

      provider.onConnect(false);

      expect(provider.needsDeviceLink, isFalse);
    });
  });
}
