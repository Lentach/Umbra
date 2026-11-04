import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/hex_avatar.dart';
import 'package:fireplace/widgets/invitations/invitation_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _peer = UserModel(id: 2, username: 'Ada', tag: '0002');

Widget _host(InvitationRowState state, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: InvitationRow(
          key: const ValueKey(2),
          peer: _peer,
          state: state,
          onAccept: () {},
          onDecline: () {},
          onOpenChat: () {},
          onDone: () {},
        ),
      ),
    ),
  );
}

Finder _forgeOverlay() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is DashedHexPainter,
);

void main() {
  testWidgets('accepting forges the avatar: dashed accent overlay plays once '
      'and ends', (tester) async {
    await tester.pumpWidget(_host(InvitationRowState.inbound));
    expect(_forgeOverlay(), findsNothing);

    await tester.pumpWidget(_host(InvitationRowState.acceptedReady));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      _forgeOverlay(),
      findsOneWidget,
      reason: 'the forge overlay must be visible mid-animation',
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(
      _forgeOverlay(),
      findsNothing,
      reason: 'the forge is one-shot; nothing lingers after ~280ms',
    );
  });

  testWidgets('reduce motion skips the forge entirely', (tester) async {
    await tester.pumpWidget(
      _host(InvitationRowState.inbound, disableAnimations: true),
    );
    await tester.pumpWidget(
      _host(InvitationRowState.acceptedReady, disableAnimations: true),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_forgeOverlay(), findsNothing);
  });

  testWidgets('mounting directly in an accepted state never forges', (
    tester,
  ) async {
    await tester.pumpWidget(_host(InvitationRowState.acceptedReady));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_forgeOverlay(), findsNothing);
  });
}
