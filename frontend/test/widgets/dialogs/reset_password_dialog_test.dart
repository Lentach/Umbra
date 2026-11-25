import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/dialogs/reset_password_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

/// One typo in the only new-password field sets a password nobody knows, so
/// the dialog must hand back a password only when it was typed twice alike.
void main() {
  Map<String, String>? result;

  Widget wrap() => MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (ctx) => Scaffold(
        body: ElevatedButton(
          onPressed: () async => result = await showDialog<Map<String, String>>(
            context: ctx,
            builder: (_) => const ResetPasswordDialog(),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> fill(WidgetTester tester, String repeat) async {
    result = null;
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'OldPass1');
    await tester.enterText(fields.at(1), 'NewPass12');
    await tester.enterText(fields.at(2), repeat);
    await tester.tap(find.text(l10n.resetButton));
    await tester.pumpAndSettle();
  }

  testWidgets('a repeat that differs keeps the dialog open with a message', (
    tester,
  ) async {
    await fill(tester, 'NewPass13');

    expect(find.text(l10n.passwordsDoNotMatch), findsOneWidget);
    expect(find.byType(ResetPasswordDialog), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('submits both passwords when the repeat matches', (tester) async {
    await fill(tester, 'NewPass12');

    expect(find.byType(ResetPasswordDialog), findsNothing);
    expect(result, {'oldPassword': 'OldPass1', 'newPassword': 'NewPass12'});
  });
}
