// The About field limits what the user sees: 80 characters (grapheme
// clusters), plus 640 code points as a backstop. The server enforces the same
// two limits (`MaxGraphemes(80)` + `MaxCodePoints(640)`, migration 0032), so an
// 80-heart About saves and nothing the field allows is refused with a 400.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/edit_about_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _heart = '\u2764\uFE0F';
const String _flag = '\u{1F1F5}\u{1F1F1}';
const String _family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}';

void main() {
  Future<TextField> pumpField(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const EditAboutScreen(),
      ),
    );
    await tester.pump();
    return tester.widget<TextField>(find.byType(TextField));
  }

  for (final (name, unit) in [
    ('hearts', _heart),
    ('flags', _flag),
    ('families', _family),
    ('letters', 'x'),
  ]) {
    testWidgets('80 $name are accepted whole; the 81st is cut away', (
      tester,
    ) async {
      final field = await pumpField(tester);

      await tester.enterText(find.byType(TextField), unit * 80);
      expect(field.controller!.text, unit * 80);

      // A paste into an empty field: cut at the last whole character.
      await tester.enterText(find.byType(TextField), '');
      await tester.enterText(find.byType(TextField), unit * 90);
      expect(field.controller!.text, unit * 80);
    });
  }

  testWidgets('a shorter value is untouched', (tester) async {
    final field = await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'short about');
    expect(field.controller!.text, 'short about');
  });

  testWidgets('typing into a full field is refused, not a dropped last '
      'character', (tester) async {
    final field = await pumpField(tester);
    final full = '${'a' * 79}z';
    await tester.enterText(find.byType(TextField), full);
    expect(field.controller!.text, full);

    // A letter typed at the start: 81 long. A cut would keep the first 80 and
    // silently lose the final 'z'.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: 'y$full',
        selection: const TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();

    expect(field.controller!.text, full);
  });

  // A cluster of 80 code points (a letter and 79 combining marks).
  final heavy = 'a${'\u0301' * 79}';

  testWidgets('the code-point backstop cuts at 640, on a whole character', (
    tester,
  ) async {
    final field = await pumpField(tester);

    await tester.enterText(find.byType(TextField), heavy * 9);

    expect(field.controller!.text, heavy * 8);
    expect(field.controller!.text.runes.length, 640);
  });

  testWidgets('one cluster larger than the backstop is refused outright', (
    tester,
  ) async {
    final field = await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'a${'\u0301' * 700}');

    expect(field.controller!.text, '');
  });

  testWidgets('the counter shows the limit that is closer to binding', (
    tester,
  ) async {
    await pumpField(tester);

    await tester.enterText(find.byType(TextField), _heart * 12);
    await tester.pump();
    expect(find.text('12/80'), findsOneWidget);

    await tester.enterText(find.byType(TextField), heavy * 8);
    await tester.pump();
    expect(find.text('640/640'), findsOneWidget);
  });
}
