import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';

void main() {
  testWidgets('diagnostic panel exposes filters and safe clear wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => EncryptionProvider()),
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(initialThemePreference: 'dark'),
          ),
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
    await tester.longPress(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

    expect(find.text('E2E Diagnostic Log'), findsOneWidget);
    expect(find.text('Current session'), findsOneWidget);
    final dropdown = find.byType(DropdownButton<String>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    expect(find.text('Since current build'), findsOneWidget);
    expect(find.text('Last 24 hours'), findsOneWidget);
    expect(find.text('Historical'), findsOneWidget);
    expect(find.text('Full raw log'), findsOneWidget);
    expect(
      find.text(
        'Clears diagnostic logs only. Does not clear messages, encryption keys, sessions, or browser storage.',
      ),
      findsOneWidget,
    );
  });
}
