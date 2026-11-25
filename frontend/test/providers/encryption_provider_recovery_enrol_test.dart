import 'package:fake_async/fake_async.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A2-ENC-C-3: the phrase wrap of the contact backup REPLACES the previous
/// one and is uploaded at once, so the phrase may be announced to
/// `onRecoveryPhraseEnrolled` only when the server confirmed it stored that
/// phrase. Announced early, a refused or unanswered `setRecoveryKey` leaves
/// the backup openable only by words the server never accepted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const first =
      'abandon ability able about above absent '
      'absorb abstract absurd abuse access accident';
  const second =
      'zoo zone zero youth young year '
      'wrong write wrap world work wood';
  const ok = {'success': true};

  late EncryptionProvider provider;
  late List<String> announced;
  late List<String> emitted;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    announced = [];
    emitted = [];
    provider = EncryptionProvider(service: EncryptionService())
      ..setEmitCallback((event, _) => emitted.add(event))
      ..onRecoveryPhraseEnrolled = announced.add;
  });

  test('the phrase is announced only once the server confirms it', () {
    provider.setRecoveryKey(first);
    expect(emitted, ['setRecoveryKey']);
    expect(
      announced,
      isEmpty,
      reason: 'the server has not answered; it may still refuse',
    );

    provider.onRecoveryKeySet(ok);
    expect(announced, [first]);

    provider.onRecoveryKeySet(ok);
    expect(announced, [first], reason: 'one enrolment, one announcement');
  });

  test('a refused phrase is never announced, not even by a later success', () {
    provider
      ..setRecoveryKey(first)
      ..onRecoveryKeySet(const {'success': false});
    expect(announced, isEmpty);

    provider.onRecoveryKeySet(ok);
    expect(announced, isEmpty, reason: 'the refused phrase was dropped');
  });

  test('logout drops a phrase the server has not confirmed', () {
    provider
      ..setRecoveryKey(first)
      ..clearAll()
      ..onRecoveryKeySet(ok);
    expect(announced, isEmpty);
  });

  test('a dropped socket drops a phrase the server has not confirmed', () {
    provider
      ..setRecoveryKey(first)
      ..onDisconnect()
      ..onRecoveryKeySet(ok);
    expect(announced, isEmpty);
  });

  test('a newer phrase replaces the pending one', () {
    provider
      ..setRecoveryKey(first)
      ..setRecoveryKey(second)
      ..onRecoveryKeySet(ok);
    expect(announced, [second]);
  });

  test('an answer that never came drops the phrase', () {
    fakeAsync((async) {
      provider.setRecoveryKey(first);
      async.elapse(const Duration(seconds: 7));
      provider.onRecoveryKeySet(ok);
      expect(
        announced,
        isEmpty,
        reason: 'the screen already told the user the phrase was not saved',
      );
    });
  });

  test("a newer phrase is not dropped by the older one's timeout", () {
    fakeAsync((async) {
      provider.setRecoveryKey(first);
      async.elapse(const Duration(seconds: 4));
      provider.setRecoveryKey(second);
      async.elapse(const Duration(seconds: 4));
      provider.onRecoveryKeySet(ok);
      expect(announced, [second]);
    });
  });

  test('an answer delivered inside the emit still counts, no timer left', () {
    fakeAsync((async) {
      provider
        ..setEmitCallback((event, _) => provider.onRecoveryKeySet(ok))
        ..setRecoveryKey(first);
      expect(announced, [first]);
      expect(async.nonPeriodicTimerCount, 0);
    });
  });
}
