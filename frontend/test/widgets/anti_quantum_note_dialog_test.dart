import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/anti_quantum_note_dialog.dart';

import '../support/l10n.dart';

// The dialog reads FireplaceColors.of(context), so the wrapper needs a real
// RpgTheme ThemeData (bare MaterialApp has no FireplaceColors extension).
Widget _wrap(Widget child) => MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('shows title and TTL chips', (tester) async {
    await tester.pumpWidget(_wrap(AntiQuantumNoteDialog(onSend: (_, _) async {})));
    await tester.pumpAndSettle();

    expect(find.byType(AntiQuantumNoteDialog), findsOneWidget);
    expect(find.text(l10n.antiQuantumNoteTtl1h), findsOneWidget);
    expect(find.text(l10n.antiQuantumNoteTtl6h), findsOneWidget);
    expect(find.text(l10n.antiQuantumNoteTtl12h), findsOneWidget);
    expect(find.text(l10n.antiQuantumNoteTtl24h), findsOneWidget);
    expect(find.text('2h'), findsNothing);
    expect(find.byType(ElevatedButton), findsOneWidget);
  });

  testWidgets('Generate & Send disabled when text is empty', (tester) async {
    await tester.pumpWidget(_wrap(AntiQuantumNoteDialog(onSend: (_, _) async {})));
    await tester.pumpAndSettle();

    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('Generate & Send enabled when text is non-empty', (tester) async {
    await tester.pumpWidget(_wrap(AntiQuantumNoteDialog(onSend: (_, _) async {})));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('calls onSend with content and selected TTL', (tester) async {
    String? capturedContent;
    int? capturedTtl;

    await tester.pumpWidget(_wrap(AntiQuantumNoteDialog(
      onSend: (content, ttl) async {
        capturedContent = content;
        capturedTtl = ttl;
      },
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'secret text');
    await tester.pump();

    await tester.tap(find.text(l10n.antiQuantumNoteTtl12h));
    await tester.pump();

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();

    expect(capturedContent, 'secret text');
    expect(capturedTtl, 43200);
  });
}
