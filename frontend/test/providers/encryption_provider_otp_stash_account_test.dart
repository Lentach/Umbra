// The one-time pre-keys minted at init wait in the provider for the bundle's
// ack. The provider is a process singleton reused across logins, so a batch
// stashed for one account must never be released by the next account's ack:
// it would land in that account's pool on the server.

import 'package:fireplace/providers/encryption_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  int otpUploads() =>
      emitted.where((e) => e.$1 == 'uploadOneTimePreKeys').length;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    emitted = [];
  });

  test('control: the ack releases the batch minted at init', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(7);
    await pumpEventQueue(times: 200);
    expect(otpUploads(), 0);

    provider.onKeyBundleUploaded({'success': true});
    expect(otpUploads(), 1);
  });

  test('a batch stashed before logout is not released by a later ack', () async {
    final provider = buildProvider();
    provider.setOwnDeviceId(1);
    await provider.initializeE2E(7);
    await pumpEventQueue(times: 200);

    provider.clearAll(); // logout before the ack arrived
    provider.onKeyBundleUploaded({'success': true}); // the next session's ack

    expect(otpUploads(), 0);
  });
}
