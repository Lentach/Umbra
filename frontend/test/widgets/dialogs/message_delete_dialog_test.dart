import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/widgets/dialogs/message_delete_dialog.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(find.text('Delete for me'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsNothing);
  });

  testWidgets('own persisted message shows both options', (tester) async {
    await tester.pumpWidget(wrap(isMine: true, messageId: 42));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete for me'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
  });

  testWidgets('own optimistic temp id hides delete for everyone', (tester) async {
    await tester.pumpWidget(wrap(isMine: true, messageId: -1));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete for everyone'), findsNothing);
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
      expect(find.text('Delete for everyone'), findsOneWidget);
      await tester.tap(find.text('Delete for me'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        wrap(isMine: true, messageId: kFirstLocalMessageId + 1),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for everyone'), findsNothing);
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

    await tester.tap(find.text('Delete for everyone'));
    await tester.pumpAndSettle();

    expect(everyoneFired, isTrue);
    expect(meFired, isFalse);
    // Dialog dismissed: its buttons are gone.
    expect(find.text('Delete for me'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
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

    await tester.tap(find.text('Delete for me'));
    await tester.pumpAndSettle();

    expect(meFired, isTrue);
    expect(everyoneFired, isFalse);
    expect(find.text('Delete for me'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
  });
}
