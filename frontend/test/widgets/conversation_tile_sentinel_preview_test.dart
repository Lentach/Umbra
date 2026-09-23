import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/conversation_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: RpgTheme.themeDataDarkGray,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: SizedBox(width: 390, child: child),
      ),
    ),
  );
}

MessageModel _row(
  String content, {
  String? encryptedContent,
  MessageType type = MessageType.text,
  String? mediaKey,
}) => MessageModel(
  id: 1,
  content: content,
  senderId: 2,
  senderUsername: 'alice',
  conversationId: 10,
  createdAt: DateTime.now(),
  messageType: type,
  encryptedContent: encryptedContent,
  mediaKey: mediaKey,
);

Future<AppLocalizations> _pumpTile(
  WidgetTester tester,
  MessageModel last,
) async {
  await tester.pumpWidget(
    _wrap(
      ConversationTile(
        conversationId: 10,
        displayName: 'Alice',
        lastMessage: last,
        onTap: () {},
        onDelete: () {},
      ),
    ),
  );
  await tester.pump();
  return AppLocalizations.of(tester.element(find.byType(ConversationTile)));
}

void main() {
  // A conversation-list row is served by `getLastMessagesBatch`, which resolves
  // no per-device envelope: a new-model row therefore arrives with content
  // '[encrypted]' and a NULL legacy ciphertext, so the old
  // `displayAsEncryptedPlaceholder` predicate missed it and the raw sentinel
  // reached the screen. Measured on a freshly linked phone (2026-09-13): the
  // whole chat list read '[encrypted]'.
  //
  // (lxxxviii) A1: such a row has simply not been opened yet, so the list says
  // "New message" — never "Encrypted message", which read as a fault.
  testWidgets('a no-ciphertext [encrypted] row previews as a new message', (
    tester,
  ) async {
    final l10n = await _pumpTile(tester, _row(kEncryptedPlaceholderLabel));

    expect(find.text(l10n.newMessagePreview, findRichText: true), findsOneWidget);
    expect(find.text(l10n.encryptedMessage, findRichText: true), findsNothing);
    expect(
      find.textContaining(kEncryptedPlaceholderLabel, findRichText: true),
      findsNothing,
    );
  });

  testWidgets('a terminally failed row says so instead of leaking the label', (
    tester,
  ) async {
    await _pumpTile(tester, _row(kDecryptionFailedLabel));

    expect(
      find.textContaining("can't be read", findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(kDecryptionFailedLabel, findRichText: true),
      findsNothing,
    );
  });

  testWidgets('a pre-link row previews as pre-link history', (tester) async {
    final l10n = await _pumpTile(tester, _row(kNotLinkedYetMessageLabel));

    expect(
      find.text(l10n.historyNotOnThisDevice, findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(kNotLinkedYetMessageLabel, findRichText: true),
      findsNothing,
    );
  });

  testWidgets('a retired row previews as no longer stored', (tester) async {
    await _pumpTile(tester, _row(kRetiredMessageLabel));

    expect(
      find.textContaining('no longer stored', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(kRetiredMessageLabel, findRichText: true),
      findsNothing,
    );
  });

  // The mapping must stay BELOW the media branches: a keyed media row keeps
  // content == '[encrypted]' for its whole life because its payload is the
  // mediaKey, and it must read as an attachment, never as an unreadable row.
  testWidgets('a keyed image row still previews as an attachment', (
    tester,
  ) async {
    final l10n = await _pumpTile(
      tester,
      _row(
        kEncryptedPlaceholderLabel,
        type: MessageType.image,
        mediaKey: 'k',
        encryptedContent: '3:cipher',
      ),
    );

    expect(find.text('Attachment', findRichText: true), findsOneWidget);
    expect(find.text(l10n.newMessagePreview, findRichText: true), findsNothing);
  });

  testWidgets('real plaintext is never relabelled', (tester) async {
    await _pumpTile(tester, _row('see you tomorrow'));

    expect(find.text('see you tomorrow', findRichText: true), findsOneWidget);
  });
}
