import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/widgets/dialogs/message_delete_dialog.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

void main() {
  Widget wrap({
    required bool isMine,
    required int messageId,
    String? wireId,
    VoidCallback? onDeleteForMe,
    VoidCallback? onDeleteForEveryone,
  }) {
    return MaterialApp(
      theme: RpgTheme.themeDataDarkGray,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showMessageDeleteDialog(
              context: ctx,
              isMine: isMine,
              messageId: messageId,
              wireId: wireId,
              onDeleteForMe: onDeleteForMe ?? () {},
              onDeleteForEveryone: onDeleteForEveryone ?? () {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }

  testWidgets('other user message hides delete for everyone', (tester) async {
    await tester.pumpWidget(wrap(isMine: false, messageId: 42));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageDeleteForMe), findsOneWidget);
    expect(find.text(l10n.messageDeleteForEveryone), findsNothing);
  });

  testWidgets('own persisted message shows both options', (tester) async {
    await tester.pumpWidget(wrap(isMine: true, messageId: 42));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageDeleteForMe), findsOneWidget);
    expect(find.text(l10n.messageDeleteForEveryone), findsOneWidget);
  });

  testWidgets('own optimistic temp id hides delete for everyone', (tester) async {
    await tester.pumpWidget(wrap(isMine: true, messageId: -1));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageDeleteForEveryone), findsNothing);
  });

  testWidgets(
    'own box message offers delete for everyone by its wire id, and not '
    'without one (item 4)',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          isMine: true,
          messageId: kFirstLocalMessageId + 1,
          wireId: 'wire-0000001',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.messageDeleteForEveryone), findsOneWidget);
      await tester.tap(find.text(l10n.messageDeleteForMe));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        wrap(isMine: true, messageId: kFirstLocalMessageId + 1),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.messageDeleteForEveryone), findsNothing);
    },
  );

  testWidgets('tapping delete for everyone fires callback and dismisses',
      (tester) async {
    var everyoneFired = false;
    var meFired = false;
    await tester.pumpWidget(wrap(
      isMine: true,
      messageId: 42,
      onDeleteForMe: () => meFired = true,
      onDeleteForEveryone: () => everyoneFired = true,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.messageDeleteForEveryone));
    await tester.pumpAndSettle();

    expect(everyoneFired, isTrue);
    expect(meFired, isFalse);
    // Dialog dismissed: its buttons are gone.
    expect(find.text(l10n.messageDeleteForMe), findsNothing);
    expect(find.text(l10n.messageDeleteForEveryone), findsNothing);
  });

  testWidgets('tapping delete for me fires callback and dismisses',
      (tester) async {
    var everyoneFired = false;
    var meFired = false;
    await tester.pumpWidget(wrap(
      isMine: true,
      messageId: 42,
      onDeleteForMe: () => meFired = true,
      onDeleteForEveryone: () => everyoneFired = true,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.messageDeleteForMe));
    await tester.pumpAndSettle();

    expect(meFired, isTrue);
    expect(everyoneFired, isFalse);
    expect(find.text(l10n.messageDeleteForMe), findsNothing);
    expect(find.text(l10n.messageDeleteForEveryone), findsNothing);
  });
}
