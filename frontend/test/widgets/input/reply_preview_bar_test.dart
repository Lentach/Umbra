import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/input/reply_preview_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/l10n.dart';

Widget _wrap(MessageModel message, {VoidCallback? onDismiss}) =>
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<EncryptionProvider>(
        create: (_) => EncryptionProvider(),
        child: Scaffold(
          body: ReplyPreviewBar(
            message: message,
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    );

MessageModel _encryptedMessage(MessageType type) => MessageModel(
      id: 1,
      content: '[encrypted]',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 1),
      messageType: type,
      encryptedContent: '3:AAAA',
    );

void main() {
  testWidgets('encrypted content shows Encrypted message l10n', (tester) async {
    await tester.pumpWidget(_wrap(MessageModel(
      id: 1,
      content: '[encrypted]',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 1),
    )));
    await tester.pumpAndSettle();

    expect(find.text(l10n.encryptedMessage), findsOneWidget);
    expect(find.text('[encrypted]'), findsNothing);
  });

  testWidgets('encrypted media replies show TYPE labels, never raw content',
      (tester) async {
    // CLAUDE.md §6: reply preview uses type labels for encrypted media.
    final cases = {
      MessageType.image: l10n.image,
      MessageType.voice: l10n.voiceMessage,
      MessageType.gif: l10n.actionTileGif,
      MessageType.file: l10n.attachmentOptionDocument,
    };
    for (final entry in cases.entries) {
      await tester.pumpWidget(_wrap(_encryptedMessage(entry.key)));
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsOneWidget,
          reason: '${entry.key} reply must show the "${entry.value}" label');
      expect(find.text('[encrypted]'), findsNothing,
          reason: 'raw E2E placeholder must never render for ${entry.key}');
      expect(find.text(l10n.encryptedMessage), findsNothing,
          reason: 'media replies use the TYPE label, not the generic one');
    }
  });

  testWidgets('tapping the close control fires onDismiss exactly once',
      (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(_wrap(
      _encryptedMessage(MessageType.text),
      onDismiss: () => dismissed++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, 1);
  });
}
