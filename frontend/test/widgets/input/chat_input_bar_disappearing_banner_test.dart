import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/widgets/hearth_fade_hex.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/input/chat_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

ConversationsProvider _providerWithConversation({
  required int conversationId,
  int? disappearingTimer,
}) {
  final userA = UserModel(id: 1, username: 'alice', tag: '0001');
  final userB = UserModel(id: 2, username: 'bob', tag: '0002');
  final provider = ConversationsProvider();
  provider.onConversationsList([
    {
      'id': conversationId,
      'userOne': {
        'id': userA.id,
        'username': userA.username,
        'tag': userA.tag,
      },
      'userTwo': {
        'id': userB.id,
        'username': userB.username,
        'tag': userB.tag,
      },
      'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      'disappearingTimer': disappearingTimer,
      'unreadCount': 0,
    },
  ]);
  provider.openConversation(conversationId);
  return provider;
}

void main() {
  group('ChatInputBar disappearing banner', () {
    testWidgets('updates duration when timer changes without sending a message',
        (tester) async {
      const conversationId = 10;
      final convs = _providerWithConversation(
        conversationId: conversationId,
        disappearingTimer: 300,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(
                  create: (_) => SettingsProvider(initialThemePreference: 'light'),
                ),
              ],
              child: const ChatInputBar(),
            ),
          ),
        ),
      );

      expect(find.textContaining('5 minutes'), findsOneWidget);

      convs.setDisappearingTimer(conversationId, 86400);
      await tester.pump();

      expect(find.textContaining('1 day'), findsOneWidget);
      expect(find.textContaining('5 minutes'), findsNothing);
    });

    testWidgets('hides banner when timer is turned off', (tester) async {
      const conversationId = 10;
      final convs = _providerWithConversation(
        conversationId: conversationId,
        disappearingTimer: 86400,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: RpgTheme.themeDataLight,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(
                  create: (_) => SettingsProvider(initialThemePreference: 'light'),
                ),
              ],
              child: const ChatInputBar(),
            ),
          ),
        ),
      );

      expect(find.textContaining('1 day'), findsOneWidget);

      convs.setDisappearingTimer(conversationId, null);
      await tester.pump();

      expect(find.textContaining('Disappearing'), findsNothing);
    });

    testWidgets('teal theme uses teal accent on banner hex', (tester) async {
      const conversationId = 10;
      final convs = _providerWithConversation(
        conversationId: conversationId,
        disappearingTimer: 300,
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: RpgTheme.themeDataTealStone,
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
                ChangeNotifierProvider(create: (_) => MessagingProvider()),
                ChangeNotifierProvider(
                  create: (_) => SettingsProvider(initialThemePreference: 'teal'),
                ),
              ],
              child: const ChatInputBar(),
            ),
          ),
        ),
      );

      expect(find.textContaining('5 minutes'), findsOneWidget);

      final hexPaint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((p) => p.painter is HearthFadeHexPainter);
      final painter = hexPaint.painter! as HearthFadeHexPainter;
      expect(painter.color, RpgTheme.primaryTealStone);
      expect(painter.color, isNot(RpgTheme.primaryLight));
    });
  });
}
