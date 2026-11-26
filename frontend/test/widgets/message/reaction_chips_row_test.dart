import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/widgets/message/reaction_chips_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3-MSG-B-08: a screen reader reads the chips in the app's language.
Future<void> _pump(WidgetTester tester, Locale locale) => tester.pumpWidget(
  MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ReactionChipsRow(
        reactions: const {
          '👍': [1, 2],
          '🔥': [2],
        },
        currentUserId: 1,
        onTap: (_, _) {},
      ),
    ),
  ),
);

void main() {
  for (final code in ['en', 'pl']) {
    testWidgets('chip semantics are localized ($code)', (tester) async {
      await _pump(tester, Locale(code));
      final l10n = lookupAppLocalizations(Locale(code));
      expect(
        find.bySemanticsLabel(l10n.messageReactionChipRemove('👍', 2)),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(l10n.messageReactionChipAdd('🔥', 1)),
        findsOneWidget,
      );
    });
  }

  testWidgets('the Polish labels are not the English ones', (tester) async {
    await _pump(tester, const Locale('pl'));
    expect(find.bySemanticsLabel(RegExp('^Remove reaction')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^React with')), findsNothing);
  });
}
