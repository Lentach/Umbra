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

void main() {
  // A3-MISC-8: the desktop pane keeps ONE ChatDetailScreen and swaps its
  // conversation id, so a card in the tray for the newly opened chat must be
  // closed on that swap too, not only on the first mount.
  testWidgets("switching the open chat closes the new chat's tray card", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final conversations = ConversationsProvider()..setCurrentUserId(1);
    seedConversations(conversations, [
      _conversationJson(10, 2, 'bob'),
      _conversationJson(11, 3, 'carol'),
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
    final closed = <int>[];
    final shown = ValueNotifier<int>(10);
    addTearDown(shown.dispose);

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
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: shown,
              builder: (_, id, _) => ChatDetailScreen(
                conversationId: id,
                isEmbedded: true,
                closeNotification:
                    (conversationId, {required newUnreadTotal}) async =>
                        closed.add(conversationId),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, [10]);

    shown.value = 11;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(closed, [10, 11]);
  });
}
