// A2-SET-6: the About field counted user-visible characters, the server
// (`@MaxLength(80)`, validator's `isLength`) counts UTF-16 units minus
// surrogate pairs and presentation selectors. 41 flags passed the field and
// were refused by the server with raw exception text on the card.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/screens/edit_about_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profileAboutLength counts the way the server validator does', () {
    expect(profileAboutLength('abc'), 3);
    // A flag is two regional indicators: two units each, counted as pairs.
    expect(profileAboutLength('\u{1F1F5}\u{1F1F1}'), 2);
    // Family of three: three emoji and two joiners.
    expect(
      profileAboutLength('\u{1F468}\u200D\u{1F469}\u200D\u{1F467}'),
      5,
    );
    // A base letter plus a combining accent is two; a presentation selector
    // after a character adds nothing.
    expect(profileAboutLength('a\u0301'), 2);
    expect(profileAboutLength('\u2764\uFE0F'), 1);
  });

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

  testWidgets('41 flags are cut to the 40 the server accepts', (tester) async {
    final field = await pumpField(tester);
    const flag = '\u{1F1F5}\u{1F1F1}';

    await tester.enterText(find.byType(TextField), flag * 41);

    expect(field.controller!.text, flag * 40);
    expect(profileAboutLength(field.controller!.text), 80);
  });

  testWidgets('plain text stops at 80 and a shorter value is untouched', (
    tester,
  ) async {
    final field = await pumpField(tester);

    await tester.enterText(find.byType(TextField), 'x' * 90);
    expect(field.controller!.text, 'x' * 80);

    await tester.enterText(find.byType(TextField), 'short about');
    expect(field.controller!.text, 'short about');
  });

  testWidgets('typing into a full field is refused, not a dropped last '
      'character', (tester) async {
    final field = await pumpField(tester);
    final full = '${'a' * 79}z';
    await tester.enterText(find.byType(TextField), full);
    expect(field.controller!.text, full);

    // A letter typed at the start: 81 long. The old cut kept the first 80 and
    // silently lost the final 'z'.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: 'y$full',
        selection: const TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();

    expect(field.controller!.text, full);
  });
}
