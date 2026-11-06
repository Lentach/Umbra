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

Finder _scrollArrowIconFinder() => find.byWidgetPredicate(
  (widget) =>
      widget is Icon &&
      widget.icon == Icons.keyboard_arrow_down &&
      widget.size == 28,
);

/// A live arrival in the open chat: the loaded rows plus [json]'s.
void _arrive(MessagingProvider messaging, Map<String, dynamic> json) =>
    messaging.seedMessagesForTest(10, [
      ...messaging.messages,
      MessageModel.fromJson(json),
    ]);

Finder _scrollButtonFinder() => find.ancestor(
  of: _scrollArrowIconFinder(),
  matching: find.byType(Material),
);

Finder _scrollButtonBadgeText(String text) =>
    find.descendant(of: _scrollButtonFinder(), matching: find.text(text));

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

  // Prime ChatDetailScreen's internal message-count baseline while still at the
  // bottom. This mirrors the first live update after opening the chat and keeps
  // this test about away-from-bottom appends, not initial-snapshot bookkeeping.
  _arrive(
    messaging,
    _messageJson(
      id: 4000,
      senderId: 2,
      senderUsername: 'bob',
      content: 'baseline live row',
    ),
  );
  await tester.pumpAndSettle();

  await tester.drag(find.byType(ListView), const Offset(0, 360));
  await tester.pump();

  expect(_scrollArrowIconFinder(), findsOneWidget);
  expect(_scrollButtonBadgeText('1'), findsNothing);
  return messaging;
}

void main() {
  testWidgets(
    'own appended message while away from bottom does not show numeric badge',
    (tester) async {
      final messaging = await _pumpChatDetail(tester);

      _arrive(
        messaging,
        _messageJson(
          id: 5000,
          senderId: 1,
          senderUsername: 'alice',
          content: 'own appended row',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(_scrollArrowIconFinder(), findsOneWidget);
      expect(_scrollButtonBadgeText('1'), findsNothing);
    },
  );

  testWidgets(
    'peer appended message while away from bottom shows badge count one',
    (tester) async {
      final messaging = await _pumpChatDetail(tester);

      _arrive(
        messaging,
        _messageJson(
          id: 5001,
          senderId: 2,
          senderUsername: 'bob',
          content: 'peer appended row',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(_scrollArrowIconFinder(), findsOneWidget);
      expect(_scrollButtonBadgeText('1'), findsOneWidget);
    },
  );
}
