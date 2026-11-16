import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/gif_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plan C2: the picker talks to Giphy directly, so GIF search is OFF until the
/// user says yes. Every Giphy request starts inside [GifPickerSheet]; it not
/// being built is what keeps the searches and the IP away from Giphy.
void main() {
  late SettingsProvider settings;
  final openPicker = find.byKey(const ValueKey('open-gif-picker'));
  final consent = find.text('Turn on GIFs from Giphy?');
  final picker = find.byType(GifPickerSheet);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider(initialThemePreference: 'light');
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open-gif-picker'),
                onPressed: () =>
                    GifPickerSheet.show(context, onGifSelected: (_) {}),
                child: const Text('GIF'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('off by default: the first tap asks, and Cancel opens nothing', (
    tester,
  ) async {
    await pumpHost(tester);
    expect(settings.gifSearch, isFalse);

    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    expect(consent, findsOneWidget);
    expect(picker, findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(consent, findsNothing);
    expect(picker, findsNothing);
    expect(settings.gifSearch, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gif_search'), isNot(isTrue));
  });

  testWidgets('dismissing the question (outside tap, back) is a no', (
    tester,
  ) async {
    await pumpHost(tester);

    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(consent, findsNothing);
    expect(picker, findsNothing);

    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    // The Android back button.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(consent, findsNothing);
    expect(picker, findsNothing);
    expect(settings.gifSearch, isFalse);
  });

  testWidgets('Turn on opens the picker and is remembered; off asks again', (
    tester,
  ) async {
    await pumpHost(tester);

    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    expect(settings.gifSearch, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gif_search'), isTrue);

    // Closed and opened again: straight to the picker, no second question.
    Navigator.of(tester.element(picker)).pop();
    await tester.pumpAndSettle();
    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    expect(consent, findsNothing);
    expect(picker, findsOneWidget);

    // Turned off again (Settings → Privacy & Safety): the next tap asks.
    Navigator.of(tester.element(picker)).pop();
    await tester.pumpAndSettle();
    await settings.setGifSearch(enabled: false);
    await tester.tap(openPicker);
    await tester.pumpAndSettle();
    expect(consent, findsOneWidget);
    expect(picker, findsNothing);
  });

  test('a yes survives a restart', () async {
    await settings.setGifSearch(enabled: true);

    final restarted = SettingsProvider(initialThemePreference: 'light');
    expect(restarted.gifSearch, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(restarted.gifSearch, isTrue);
  });
}
