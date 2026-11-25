import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/message_context_menu_bubble_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

final _token = 'ab' * 16;
final _aesKey = base64Url.encode(List.filled(32, 7));
final _noteUrl =
    'https://fireplace.ignorelist.com/note/$_token#$_aesKey&e=4102444800000';

MessageModel _msg(String content) => MessageModel(
  id: 1,
  content: content,
  senderId: 1,
  senderUsername: 'alice',
  conversationId: 1,
  createdAt: DateTime(2026, 5, 23),
  deliveryStatus: MessageDeliveryStatus.sent,
  messageType: MessageType.text,
);

Widget _preview(String content) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: RpgTheme.themeDataLight,
  home: Scaffold(
    body: Center(
      child: MessageContextMenuBubbleHighlight(
        message: _msg(content),
        isMine: true,
        maxWidth: 280,
      ),
    ),
  ),
);

/// Every string drawn by the preview, joined.
String _drawnText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
].join('\n');

void main() {
  testWidgets('the long-press preview of a note link never prints its URL, '
      'token or key; it shows the card label', (tester) async {
    await tester.pumpWidget(_preview(_noteUrl));

    final drawn = _drawnText(tester);
    expect(drawn, isNot(contains(_token)));
    expect(drawn, isNot(contains(_aesKey)));
    expect(drawn, isNot(contains('http')));
    expect(find.text(l10n.antiQuantumNoteTitle), findsOneWidget);
  });

  testWidgets('an ordinary link still prints as typed', (tester) async {
    await tester.pumpWidget(_preview('see https://example.com/note/x'));

    expect(_drawnText(tester), contains('https://example.com/note/x'));
    expect(find.text(l10n.antiQuantumNoteTitle), findsNothing);
  });
}
