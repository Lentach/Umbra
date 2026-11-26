import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

/// The 30-day local retention is intended (owner, 2026-11-26), so the screen
/// has to say it: once as a plain fact, and once where a backup is restored,
/// because a restored message keeps its original age.
void main() {
  final days = EncryptionService.retentionWindow.inDays;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => EncryptionProvider()),
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(initialThemePreference: 'dark'),
          ),
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PrivacySafetyScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says that messages on this device are deleted after the '
      'retention window', (tester) async {
    await pumpScreen(tester);

    expect(find.text(l10n.localRetentionNotice(days)), findsOneWidget);
  });

  testWidgets('the restore-from-backup row warns that old messages are '
      'deleted again', (tester) async {
    await pumpScreen(tester);

    expect(find.text(l10n.restoreRetentionWarning(days)), findsOneWidget);
  });
}
