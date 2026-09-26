import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:fireplace/widgets/message/context_menu_bubble_anchor.dart';
import 'package:fireplace/widgets/message/voice_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

MessageModel _reacted() => MessageModel(
  id: 42,
  content: 'hello there',
  senderId: 2,
  senderUsername: 'bob',
  conversationId: 1,
  deliveryStatus: MessageDeliveryStatus.read,
  createdAt: DateTime(2026, 1, 1, 14, 30),
  reactions: const {
    '👍': [2],
  },
);

Widget _wrap(Widget child) => MaterialApp(
  theme: RpgTheme.themeDataBlue,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider<MessagingProvider>(
          create: (_) => MessagingProvider(),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
      ],
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 360, child: child),
      ),
    ),
  ),
);

void main() {
  for (final isMine in [false, true]) {
    testWidgets(
      'a tap on the MIDDLE of a reaction chip reaches it (isMine: $isMine) — '
      'the chip above the bubble must sit inside the Stack it is painted in, '
      'or Flutter never hit-tests its upper part',
      (tester) async {
        await tester.pumpWidget(
          _wrap(ChatMessageBubble(message: _reacted(), isMine: isMine)),
        );
        await tester.pumpAndSettle();

        final chip = find.byType(ReactionChipsRow);
        final chipBox = tester.getRect(chip);
        final bubbleBox = tester.getRect(find.byType(ContextMenuBubbleAnchor));
        // The chip's upper half sits above the bubble: the part that used to
        // be dead.
        final upper = Offset(chipBox.center.dx, chipBox.top + 3);
        expect(upper.dy, lessThan(bubbleBox.top));

        await tester.tapAt(upper);
        await tester.pump();

        // No socket in a widget test, so the reaction cannot be sent and the
        // user is told: the snackbar proves the tap reached the chip.
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(find.text(l10n.snackbarReactionUnavailable), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      },
    );
  }

  for (final isMine in [false, true]) {
    testWidgets(
      'the chip keeps its place (isMine: $isMine): 14 px above the bubble '
      'top, 8 px in from its leading edge',
      (tester) async {
        await tester.pumpWidget(
          _wrap(ChatMessageBubble(message: _reacted(), isMine: isMine)),
        );
        await tester.pumpAndSettle();

        final chip = tester.getRect(find.byType(ReactionChipsRow));
        final bubble = tester.getRect(find.byType(ContextMenuBubbleAnchor));
        expect(bubble.top - chip.top, 14);
        if (isMine) {
          expect(bubble.right - chip.right, 8);
        } else {
          expect(chip.left - bubble.left, 8);
        }
      },
    );
  }

  testWidgets('the same holds for a voice note bubble', (tester) async {
    final voice = _reacted().copyWith(
      messageType: MessageType.voice,
      mediaUrl: 'https://example.com/v.m4a',
      mediaDuration: 3,
    );
    await tester.pumpWidget(
      _wrap(VoiceMessageContent(message: voice, isMine: false)),
    );
    await tester.pump();

    final chipBox = tester.getRect(find.byType(ReactionChipsRow));
    final bubbleBox = tester.getRect(find.byType(ContextMenuBubbleAnchor));
    expect(bubbleBox.top - chipBox.top, 14);
    await tester.tapAt(Offset(chipBox.center.dx, chipBox.top + 3));
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.snackbarReactionUnavailable), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
