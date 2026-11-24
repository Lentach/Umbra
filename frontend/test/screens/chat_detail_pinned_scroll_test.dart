import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/chat_detail_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/pinned_message_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';

const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

Map<String, dynamic> _conversationJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
  // The oldest row is pinned: the banner's tap scrolls to the far end.
  'pinnedMessageId': 1000,
  'pinnedMessage': _messageJson(
    id: 1000,
    senderId: 2,
    senderUsername: 'bob',
    content: 'pinned preview text',
  ),
};

Map<String, dynamic> _messageJson({
  required int id,
  required int senderId,
  required String senderUsername,
  required String content,
}) => {
  'id': id,
  'content': content,
  'senderId': senderId,
  'senderUsername': senderUsername,
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': DateTime.utc(2026, 1, 1, 12, id % 60).toIso8601String(),
};

List<MessageModel> _initialMessages() => List.generate(36, (index) {
  final mine = index.isEven;
  return MessageModel.fromJson(
    _messageJson(
      id: 1000 + index,
      senderId: mine ? 1 : 2,
      senderUsername: mine ? 'alice' : 'bob',
      content: mine
          ? 'sent note ${index + 100}'
          : 'received note ${index + 100}',
    ),
  );
});

Future<MessagingProvider> _pumpChatDetail(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [_conversationJson()]);
  conversations.openConversation(10, notify: false);

  final messaging = MessagingProvider();
  messaging.setIncomingMessageSoundEnabledForTest(false);
  messaging.setConversationsProvider(conversations);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.setEmitCallback((event, data) {});
  messaging.onConnect(false);
  messaging.setActiveConversationIdForTest(10);
  messaging.seedCacheForTest(10, _initialMessages());
  messaging.loadCachedMessages(10);

  final auth = AuthProvider()..setAccessTokenForTest(_currentUserJwt);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationsProvider>.value(
          value: conversations,
        ),
        ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider.value(value: EncryptionProvider()),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'light'),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: RpgTheme.themeDataLight,
        home: const Scaffold(
          body: SizedBox(
            width: 360,
            height: 520,
            child: ChatDetailScreen(conversationId: 10, isEmbedded: true),
          ),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
  return messaging;
}

void main() {
  testWidgets(
    'a second tap on the pinned banner during the first scroll still reaches it',
    (tester) async {
      await _pumpChatDetail(tester);
      expect(find.byType(PinnedMessageBanner), findsOneWidget);
      // The oldest row is far off screen.
      expect(find.byKey(const ValueKey(1000)), findsNothing);

      await tester.tap(find.byType(PinnedMessageBanner));
      await tester.pump();
      // 400 ms in, the first scroll is still revealing the row (the pump
      // clock is fake, so this instant is the same on every run).
      for (var t = 0; t < 400; t += 50) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byType(PinnedMessageBanner));

      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Message is no longer available'), findsNothing);
      expect(find.byKey(const ValueKey(1000)), findsOneWidget);
      final row = tester.getRect(find.byKey(const ValueKey(1000)));
      expect(row.top, greaterThanOrEqualTo(0));
      expect(row.bottom, lessThanOrEqualTo(520));

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );
}
