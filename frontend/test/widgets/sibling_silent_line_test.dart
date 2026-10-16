import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/sibling_silent_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decision 101 B's line: it names the device, and its dialog is the only
/// way to remove or keep it; dismissing the dialog does neither.
void main() {
  late List<String> calls;

  Future<void> pump(WidgetTester tester) async {
    calls = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SiblingSilentLine(
            name: 'Pixel 7',
            onKeep: () => calls.add('keep'),
            onRemove: () => calls.add('remove'),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sibling-silent-alert')));
    await tester.pumpAndSettle();
  }

  testWidgets('names the device the Devices screen names', (tester) async {
    await pump(tester);
    expect(find.textContaining('“Pixel 7” has not been used'), findsOneWidget);
  });

  testWidgets('Keep keeps, Remove removes, each once', (tester) async {
    await pump(tester);

    await openDialog(tester);
    expect(find.text('Remove “Pixel 7”?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sibling-silent-keep')));
    await tester.pumpAndSettle();
    expect(calls, ['keep']);

    await openDialog(tester);
    await tester.tap(find.byKey(const Key('sibling-silent-remove')));
    await tester.pumpAndSettle();
    expect(calls, ['keep', 'remove']);
  });

  testWidgets('a dismissed dialog neither keeps nor removes', (tester) async {
    await pump(tester);

    await openDialog(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Remove “Pixel 7”?'), findsNothing);
    expect(calls, isEmpty);
  });
}
