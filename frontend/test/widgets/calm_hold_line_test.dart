import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/calm_hold_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n.dart';

Future<void> _pump(
  WidgetTester tester,
  CalmHoldState state,
  VoidCallback onTap,
) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    theme: RpgTheme.themeDataDarkGray,
    home: Scaffold(
      body: CalmHoldLine(peerName: 'bob', state: state, onTap: onTap),
    ),
  ),
);

void main() {
  testWidgets('each state says its own thing', (tester) async {
    final lines = {
      CalmHoldState.waiting: l10n.calmHoldLine('bob'),
      CalmHoldState.checking: l10n.calmHoldChecking,
      CalmHoldState.failed: l10n.calmHoldFailed,
    };
    for (final MapEntry(key: state, value: text) in lines.entries) {
      await _pump(tester, state, () {});
      expect(find.text(text), findsOneWidget, reason: '$state');
    }
  });

  testWidgets('a tap calls back while waiting and after a failure, never '
      'while checking', (tester) async {
    var taps = 0;
    for (final (state, expected) in [
      (CalmHoldState.waiting, 1),
      (CalmHoldState.failed, 2),
      (CalmHoldState.checking, 2),
    ]) {
      await _pump(tester, state, () => taps++);
      await tester.tap(find.byKey(const ValueKey('calm-hold-line')));
      await tester.pump();
      expect(taps, expected, reason: '$state');
    }
  });

  testWidgets('it is one button for a screen reader, named by its line', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, CalmHoldState.waiting, () {});

    expect(
      tester.getSemantics(find.bySemanticsLabel(l10n.calmHoldLine('bob'))),
      matchesSemantics(
        label: l10n.calmHoldLine('bob'),
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('it is muted, not the error colour of the visible hold', (
    tester,
  ) async {
    await _pump(tester, CalmHoldState.waiting, () {});

    final style = tester.widget<Text>(find.text(l10n.calmHoldLine('bob'))).style;
    expect(style?.color, RpgTheme.mutedDark);
    expect(style?.color, isNot(RpgTheme.themeDataDarkGray.colorScheme.error));
  });
}
