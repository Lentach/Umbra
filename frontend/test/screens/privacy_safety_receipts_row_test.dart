import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/services/box/box_friends.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only [onBox] is read by the screen; anything else is a test bug.
class _Link implements BoxFriendLink {
  bool on = false;

  @override
  bool get onBox => on;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The decision-62 receipts/typing switch does nothing until this device is on
/// the box, so the row shows only then (G5 owner call, 2026-09-29).
void main() {
  late _Link link;
  late MessagingProvider messaging;
  late SettingsProvider settings;
  final row = find.byKey(const ValueKey('privacy-receipts-and-typing-row'));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    link = _Link();
    messaging = MessagingProvider()..boxFriends = link;
    settings = SettingsProvider(initialThemePreference: 'dark');
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => EncryptionProvider()),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: messaging),
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

  testWidgets('no row while this device is not on the box', (tester) async {
    await pumpScreen(tester);

    expect(row, findsNothing);
  });

  testWidgets('no row without a box session at all', (tester) async {
    messaging.boxFriends = null;
    await pumpScreen(tester);

    expect(row, findsNothing);
  });

  testWidgets('the row appears once this device gets on the box, and toggles', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(row, findsNothing);

    // What `BoxSession` does when its request queue is first published.
    link.on = true;
    messaging.onBoxReady();
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);

    final toggle = find.descendant(of: row, matching: find.byType(Switch));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.receiptsAndTyping, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    // Out from under the glass top bar `ensureVisible` parked it behind.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(settings.receiptsAndTyping, isFalse);
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });
}
