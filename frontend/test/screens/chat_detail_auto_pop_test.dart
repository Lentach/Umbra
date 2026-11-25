import 'package:fireplace/l10n/app_localizations.dart';
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
import '../support/l10n.dart';

/// A friend is removed or blocked while their chat is open. The chat must
/// close and say why, whether or not other chats remain in the list.
const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

Map<String, dynamic> _conversationJson(int id, int peerId, String peer) => {
  'id': id,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': peerId, 'username': peer, 'tag': '000$peerId'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

Future<ConversationsProvider> _pumpChat(
  WidgetTester tester, {
  required bool otherChatRemains,
}) async {
  SharedPreferences.setMockInitialValues({});

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [
    _conversationJson(10, 2, 'bob'),
    if (otherChatRemains) _conversationJson(11, 3, 'carol'),
  ]);

  final messaging = MessagingProvider()
    ..setIncomingMessageSoundEnabledForTest(false)
    ..setConversationsProvider(conversations)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setEmitCallback((event, data) {})
    ..onConnect(false);
  addTearDown(messaging.dispose);

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
          create: (_) => SettingsProvider(initialThemePreference: 'dark'),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: RpgTheme.themeDataDarkGray,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ChatDetailScreen(conversationId: 10),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  conversations.openConversation(10, notify: false);
  expect(find.byType(ChatDetailScreen), findsOneWidget);
  return conversations;
}

Future<void> _unfriendBob(
  WidgetTester tester,
  ConversationsProvider conversations,
) async {
  conversations.removeConversationsForUser(2);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('another chat remains: the open chat closes with the notice', (
    tester,
  ) async {
    final conversations = await _pumpChat(tester, otherChatRemains: true);

    await _unfriendBob(tester, conversations);

    expect(find.byType(ChatDetailScreen), findsNothing);
    expect(find.text(l10n.cantMessageThisUser), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // the notice's own timer
  });

  testWidgets('it was the ONLY chat: the open chat closes with the notice', (
    tester,
  ) async {
    final conversations = await _pumpChat(tester, otherChatRemains: false);

    await _unfriendBob(tester, conversations);

    expect(find.byType(ChatDetailScreen), findsNothing);
    expect(find.text(l10n.cantMessageThisUser), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // the notice's own timer
  });
}
