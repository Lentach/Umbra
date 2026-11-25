// A2-AUTH-04: Enter pressed twice during a slow sign-in must send ONE request.
//
// The button is disabled while a submit is in flight, but the keyboard's
// submit action on either field reaches the same handler. Two calls are two
// server sessions (the first refresh token orphaned) and two attempts on the
// login throttle.

import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/l10n.dart';

void main() {
  /// Pumps the form; [calls] collects every credential pair handed up while
  /// [inFlight] keeps each of them pending, like a slow server.
  Future<void> pumpForm(
    WidgetTester tester, {
    required AuthFormMode mode,
    required List<(String, String)> calls,
    required Completer<void> inFlight,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AuthForm(
            mode: mode,
            onSubmit: (username, password) {
              calls.add((username, password));
              return inFlight.future;
            },
            onRecover: (_, _, _) async {},
          ),
        ),
      ),
    ),
  );

  Future<void> pressEnterIn(WidgetTester tester, Finder field) async {
    await tester.showKeyboard(field);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  for (final (mode, passwordHint) in [
    (AuthFormMode.login, l10n.authPasswordHint),
    (AuthFormMode.register, l10n.authPasswordHintRegister),
  ]) {
    testWidgets('Enter pressed twice while the ${mode.name} is in flight sends '
        'one request, and the form answers again once it settles', (
      tester,
    ) async {
      final calls = <(String, String)>[];
      final inFlight = Completer<void>();
      await pumpForm(tester, mode: mode, calls: calls, inFlight: inFlight);

      final username = find.widgetWithText(
        TextFormField,
        l10n.authUsernameHint,
      );
      final password = find.widgetWithText(TextFormField, passwordHint);
      await tester.enterText(username, 'alice');
      await tester.enterText(password, 'Passw0rdOk');

      await pressEnterIn(tester, password);
      await pressEnterIn(tester, password);
      await pressEnterIn(tester, username);

      expect(calls, [('alice', 'Passw0rdOk')]);

      // The attempt is over (a wrong password, say): the form is live again.
      inFlight.complete();
      await tester.pump();
      await pressEnterIn(tester, password);
      expect(calls, hasLength(2));
    });
  }
}
