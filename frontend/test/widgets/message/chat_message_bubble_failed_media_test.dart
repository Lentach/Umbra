import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:fireplace/widgets/message/message_metadata_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// A3-MSG-A-08: the time/error pill floats over the media at the bubble's
/// bottom right; the red Retry row of a failed own send must not sit under it.
void main() {
  for (final type in [MessageType.image, MessageType.video]) {
    testWidgets('a failed own $type keeps Retry clear of the time pill', (
      tester,
    ) async {
      final message = MessageModel(
        id: -1,
        content: '',
        senderId: 1,
        senderUsername: '',
        conversationId: 10,
        deliveryStatus: MessageDeliveryStatus.failed,
        messageType: type,
        createdAt: DateTime(2026, 1, 1, 14, 30),
        tempId: 't1',
        encryptedContent: 'c',
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
            ChangeNotifierProvider<MessagingProvider>(
              create: (_) => MessagingProvider(),
            ),
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(),
            ),
            ChangeNotifierProvider<EncryptionProvider>(
              create: (_) => EncryptionProvider(),
            ),
          ],
          child: MaterialApp(
            theme: RpgTheme.themeDataBlue,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  child: ChatMessageBubble(message: message, isMine: true),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final retry = tester.getRect(find.byType(TextButton));
      final pill = tester.getRect(find.byType(MessageMetadataRow));
      expect(retry.overlaps(pill), isFalse);
    });
  }
}
