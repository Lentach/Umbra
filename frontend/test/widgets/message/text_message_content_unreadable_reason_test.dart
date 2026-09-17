// "This message can't be read on this device" names the symptom and hides the
// cause, which reads as a crash. The bubble now adds one quiet line saying WHY
// the row is dead. These tests pin the two cases that get a reason and, more
// importantly, the rows that must NOT get one — a reason attached to a row
// that renders fine is worse than no reason at all.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart'
    show kDecryptionFailedLabel, kEncryptedPlaceholderLabel;
import 'package:fireplace/widgets/message/text_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _msg(String content) => MessageModel(
  id: 1,
  content: content,
  senderId: 2,
  senderUsername: 'bob',
  conversationId: 10,
  createdAt: DateTime.utc(2026, 1, 1),
);

Widget _host(
  MessageModel m, {
  bool isMine = false,
  bool decryptInProgress = false,
}) => MaterialApp(
  locale: const Locale('pl'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: TextMessageContent(
      message: m,
      isMine: isMine,
      textColor: Colors.black,
      isDark: false,
      maxWidth: 300,
      decryptInProgress: decryptInProgress,
    ),
  ),
);

Future<AppLocalizations> _pl() =>
    AppLocalizations.delegate.load(const Locale('pl'));

void main() {
  testWidgets('a peer row that failed to decrypt says why', (tester) async {
    final pl = await _pl();
    await tester.pumpWidget(_host(_msg(kDecryptionFailedLabel)));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(pl.messageUnreadableOnThisDevice, findRichText: true),
      findsOneWidget,
      reason: 'the symptom line stays',
    );
    expect(
      find.text(pl.messageUnreadableReasonKeysGone),
      findsOneWidget,
      reason: 'and the cause is now stated under it',
    );
  });

  testWidgets('an own row whose local copy is gone gets the OTHER reason', (
    tester,
  ) async {
    final pl = await _pl();
    await tester.pumpWidget(
      _host(_msg(kEncryptedPlaceholderLabel), isMine: true),
    );
    await tester.pumpAndSettle();

    expect(find.text(pl.messageUnreadableReasonOwnCopyGone), findsOneWidget);
    expect(
      find.text(pl.messageUnreadableReasonKeysGone),
      findsNothing,
      reason: 'a sender never failed a Signal decrypt — wrong cause',
    );
  });

  testWidgets('a readable message gets no reason line', (tester) async {
    final pl = await _pl();
    await tester.pumpWidget(_host(_msg('hello there')));
    await tester.pumpAndSettle();

    expect(find.textContaining('hello there', findRichText: true),
        findsOneWidget);
    expect(find.text(pl.messageUnreadableReasonKeysGone), findsNothing);
    expect(find.text(pl.messageUnreadableReasonOwnCopyGone), findsNothing);
  });

  testWidgets('a row still being decrypted is not declared dead', (
    tester,
  ) async {
    final pl = await _pl();
    await tester.pumpWidget(
      _host(
        _msg(kEncryptedPlaceholderLabel),
        isMine: true,
        decryptInProgress: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(pl.messageUnreadableReasonOwnCopyGone),
      findsNothing,
      reason: 'the pass may still resolve it; claiming the keys are gone '
          'mid-pass is the false alarm this guard exists for',
    );
  });
}
