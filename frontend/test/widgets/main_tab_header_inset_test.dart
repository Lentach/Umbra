import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/main_tab_screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The status-bar inset is spent ONCE for the whole shell, and the header adds
/// none of its own. Native showed a phantom status-bar band above the title
/// capsule on the 0.2.44 APK (owner-reported 2026-09-14); web never did,
/// because `padding.top` is 0 there.
///
/// The mechanism is SIBLING SafeAreas, not nested ones — worth stating because
/// the obvious guess is wrong: a nested `SafeArea` adds nothing, since the
/// outer one strips the inset from its subtree (`MediaQuery.removePadding`).
/// But `MainShell` used to put a `SafeArea` around the (usually empty) banner
/// stack as a SIBLING of the tabs, so the tabs still saw the full
/// `padding.top`, and `MainTabScreenHeader`'s own `SafeArea` applied it a
/// second time — one inset as the banner wrapper's height, one inside the tab.
///
/// Scope: these pump the two ARRANGEMENTS around the real header, so they lock
/// the header's contract ("the caller owns the inset") and the doubling
/// mechanism. They do not pump `MainShell` itself — that needs the full
/// provider tree — so a regression re-added directly in `main_shell.dart`
/// would need the device check that accompanied this fix.
void main() {
  const inset = 40.0;

  Future<double> headerTop(WidgetTester tester, {required Widget body}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataDarkGray,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: inset)),
          child: Scaffold(body: body),
        ),
      ),
    );
    await tester.pump();
    return tester.getTopLeft(find.byType(MainTabScreenHeader)).dy;
  }

  testWidgets('one shell-level SafeArea spends the inset exactly once', (
    tester,
  ) async {
    // The shape after the fix: ONE SafeArea wrapping banner stack + tabs, and
    // a header that adds no inset of its own.
    final top = await headerTop(
      tester,
      body: const SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox.shrink(), // the banner stack, rendering nothing
            Expanded(
              child: Column(children: [MainTabScreenHeader(title: 'Chats')]),
            ),
          ],
        ),
      ),
    );

    expect(top, inset);
  });
}
