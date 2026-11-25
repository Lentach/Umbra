import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/reply_quote_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

/// Who the quote card above a reply says the quoted message is from.
Widget _wrap(ReplyToPreview replyTo, {int? currentUserId}) => MaterialApp(
      theme: RpgTheme.themeDataLight,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ReplyQuoteCard(
          replyTo: replyTo,
          isDark: false,
          borderColor: Colors.orange,
          content: 'quoted words',
          currentUserId: currentUserId,
        ),
      ),
    );

ReplyToPreview _quote({required int? senderId, String senderUsername = ''}) =>
    ReplyToPreview(
      id: 5,
      content: 'quoted words',
      senderUsername: senderUsername,
      messageType: MessageType.text,
      wireId: 'wire-5',
      senderId: senderId,
    );

void main() {
  testWidgets(
      'a quote of your OWN message is labelled You, with or without a stored '
      'username', (tester) async {
    await tester.pumpWidget(_wrap(_quote(senderId: 1), currentUserId: 1));
    expect(find.text(l10n.senderYou), findsOneWidget);
    expect(find.text(l10n.unknown), findsNothing);

    await tester.pumpWidget(
      _wrap(_quote(senderId: 1, senderUsername: 'alice'), currentUserId: 1),
    );
    expect(find.text(l10n.senderYou), findsOneWidget);
    expect(find.text('alice'), findsNothing);
  });

  testWidgets("a quote of the peer's message keeps the peer's name",
      (tester) async {
    await tester.pumpWidget(
      _wrap(_quote(senderId: 2, senderUsername: 'bob'), currentUserId: 1),
    );
    expect(find.text('bob'), findsOneWidget);
    expect(find.text(l10n.senderYou), findsNothing);
  });

  testWidgets(
      'a quote with no sender id (a row older than wire ids) is never '
      'claimed as yours', (tester) async {
    await tester.pumpWidget(_wrap(_quote(senderId: null), currentUserId: 1));
    expect(find.text(l10n.unknown), findsOneWidget);
    expect(find.text(l10n.senderYou), findsNothing);
  });
}
