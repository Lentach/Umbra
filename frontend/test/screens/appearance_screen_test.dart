import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/chat_background_preference.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/appearance_screen.dart';
import 'package:fireplace/widgets/appearance_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsProvider> pumpAppearance(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'chat_wallpaper_7': 'theme_default',
    });
    final settings = SettingsProvider(initialThemePreference: 'dark');
    await settings.loadChatBackground(7);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: Consumer<SettingsProvider>(
          builder: (context, current, _) => MaterialApp(
            theme: current.themeData,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AppearanceScreen(userId: 7),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('uses labeled real previews instead of generic theme icons', (
    tester,
  ) async {
    await pumpAppearance(tester);

    expect(find.text(l10n.appearanceColorTheme.toUpperCase()), findsOneWidget);
    expect(find.text(l10n.appearanceThemeLight), findsOneWidget);
    expect(find.text(l10n.appearanceThemeCosmic), findsOneWidget);
    expect(find.byType(AppearancePreview), findsWidgets);
    expect(find.byIcon(Icons.palette_outlined), findsNothing);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('theme default follows Cosmic while explicit glyphs persist', (
    tester,
  ) async {
    final settings = await pumpAppearance(tester);

    await tester.tap(find.byKey(const ValueKey('appearance-theme-cosmic')));
    await tester.pumpAndSettle();

    expect(settings.themePreference, 'cosmic');
    expect(settings.chatBackground, ChatBackgroundPreference.themeDefault);
    expect(settings.resolvedChatBackground, ChatBackgroundLayer.starfield);

    final glyphs = find.byKey(const ValueKey('appearance-background-glyphs'));
    await tester.scrollUntilVisible(
      glyphs,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(glyphs);
    await tester.pumpAndSettle();

    expect(settings.chatBackground, ChatBackgroundPreference.glyphs);
    expect(settings.resolvedChatBackground, ChatBackgroundLayer.glyphs);

    final blue = find.byKey(const ValueKey('appearance-theme-blue'));
    await tester.scrollUntilVisible(
      blue,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(blue);
    await tester.pumpAndSettle();

    expect(settings.themePreference, 'blue');
    expect(settings.chatBackground, ChatBackgroundPreference.glyphs);
    expect(settings.resolvedChatBackground, ChatBackgroundLayer.glyphs);
  });
}
