import 'package:fireplace/providers/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Decision 62 / E61c: receipts and typing on box chats are OFF until this
// device's user turns them on, and the choice survives a restart (a fresh
// provider over the same prefs).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh install has receipts and typing OFF', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider(initialThemePreference: 'light');
    await Future<void>.delayed(Duration.zero);
    expect(settings.receiptsAndTyping, isFalse);
  });

  test('turning it on persists and a fresh provider loads it', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider(initialThemePreference: 'light');
    await settings.setReceiptsAndTyping(enabled: true);
    expect(settings.receiptsAndTyping, isTrue);

    final relaunched = SettingsProvider(initialThemePreference: 'light');
    await Future<void>.delayed(Duration.zero);
    expect(relaunched.receiptsAndTyping, isTrue);

    await relaunched.setReceiptsAndTyping(enabled: false);
    final again = SettingsProvider(initialThemePreference: 'light');
    await Future<void>.delayed(Duration.zero);
    expect(again.receiptsAndTyping, isFalse);
  });
}
