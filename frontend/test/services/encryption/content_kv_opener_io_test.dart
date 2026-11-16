import 'package:fireplace/services/encryption/content_kv.dart';
import 'package:fireplace/services/encryption/content_kv_opener_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hardening plan A3: the Android opener fails CLOSED. Its plaintext
/// SharedPreferences fallback put whatever the session wrote into cleartext
/// XML; now a store that will not open is an error the app shows, and the
/// next touch tries again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await revokePlatformContentKv();
  });
  tearDown(revokePlatformContentKv);

  test(
    'an encrypted store that will not open throws instead of opening prefs',
    () async {
      // The test VM has no secure-storage plugin, so the DB key cannot be
      // read: the first stage of the real open chain fails.
      await expectLater(
        openEncryptedContentKv(),
        throwsA(
          isA<ContentStoreUnavailable>().having(
            (e) => e.stage,
            'stage',
            'db-key',
          ),
        ),
      );
    },
  );

  group('openMemoized', () {
    test('a failed open is not kept: the next call opens again', () async {
      var calls = 0;
      final kv = await PrefsContentKv.open();
      Future<ContentKv> open() async {
        calls++;
        if (calls == 1) throw const ContentStoreUnavailable('db-open');
        return kv;
      }

      await expectLater(
        openMemoized(open),
        throwsA(isA<ContentStoreUnavailable>()),
      );
      await expectLater(openMemoized(open), completion(same(kv)));
      expect(calls, 2);
    });

    test('concurrent first calls share one open, and a success is kept', () async {
      var calls = 0;
      final kv = await PrefsContentKv.open();
      Future<ContentKv> open() async {
        calls++;
        return kv;
      }

      final both = await Future.wait([openMemoized(open), openMemoized(open)]);
      await openMemoized(open);

      expect(both, everyElement(same(kv)));
      expect(calls, 1);
    });
  });
}
