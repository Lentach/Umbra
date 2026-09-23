// Amendment (lxxxi): rows that predate this device's link are not rendered as
// bubbles. The thread shows ONE muted pill at its oldest end instead — and
// still shows it when EVERY loaded row is pre-link, so the user learns why the
// chat looks empty rather than reading "no messages yet".
//
// Falsification contract: (F28) drop the filter in `MessagingProvider.messages`
// → the placeholder bubbles render and `findsNothing` below fails; (F29) count
// hidden rows without filtering → pill AND bubbles both render.

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

const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

class _QuietEncryption extends EncryptionProvider {
  @override
  Future<String?> getPeerIdentityFingerprint(int peerId) async => 'AAAA';
  @override
  Future<String?> getIdentityFingerprint() async => 'BBBB';
}

Map<String, dynamic> _conversationJson() => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

Map<String, dynamic> _messageJson(int id, {bool preLink = false}) => {
  'id': id,
  'content': preLink ? kNotLinkedYetMessageLabel : 'note $id',
  'senderId': 2,
  'senderUsername': 'bob',
  'conversationId': 10,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  if (preLink) 'envelopeStatus': 'none_for_device',
  'createdAt': DateTime.utc(2026, 1, 1, 12, id % 60).toIso8601String(),
};

Future<AppLocalizations> _pumpChat(
  WidgetTester tester, {
  required int preLinkRows,
  required int realRows,
}) async {
  SharedPreferences.setMockInitialValues({});
  final conversations = ConversationsProvider()..setCurrentUserId(1);
  conversations.onConversationsList([_conversationJson()]);
  conversations.openConversation(10, notify: false);

  final messaging = MessagingProvider();
  messaging.setIncomingMessageSoundEnabledForTest(false);
  messaging.setConversationsProvider(conversations);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.setEmitCallback((event, data) {});
  messaging.onConnect(false);
  messaging.setActiveConversationIdForTest(10);
  messaging.seedCacheForTest(10, [
    for (var i = 0; i < preLinkRows; i++)
      MessageModel.fromJson(_messageJson(1000 + i, preLink: true)),
    for (var i = 0; i < realRows; i++)
      MessageModel.fromJson(_messageJson(2000 + i)),
  ]);
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
        ChangeNotifierProvider<EncryptionProvider>.value(
          value: _QuietEncryption(),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'dark'),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('pl'),
        theme: RpgTheme.themeDataDarkGray,
        home: const ChatDetailScreen(conversationId: 10),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return AppLocalizations.delegate.load(const Locale('pl'));
}

void main() {
  const divider = Key('pre-link-history-divider');

  testWidgets('pre-link rows collapse to one pill above the real messages', (
    tester,
  ) async {
    final pl = await _pumpChat(tester, preLinkRows: 4, realRows: 2);

    expect(find.byKey(divider), findsOneWidget);
    expect(find.text(pl.historyNotOnThisDevice), findsOneWidget);
    expect(find.textContaining('note 2000', findRichText: true), findsOneWidget);
    expect(find.textContaining('note 2001', findRichText: true), findsOneWidget);
    expect(
      find.textContaining(kNotLinkedYetMessageLabel, findRichText: true),
      findsNothing,
      reason: 'the raw sentinel must never reach a bubble',
    );
    expect(find.textContaining('Wysłana przed', findRichText: true), findsNothing);
  });

  testWidgets('a thread that is ALL pre-link shows the pill, not "no messages"', (
    tester,
  ) async {
    final pl = await _pumpChat(tester, preLinkRows: 3, realRows: 0);

    expect(find.byKey(divider), findsOneWidget);
    expect(find.text(pl.noMessagesYet), findsNothing);
  });

  testWidgets('a thread with no pre-link rows has no pill', (tester) async {
    await _pumpChat(tester, preLinkRows: 0, realRows: 2);

    expect(find.byKey(divider), findsNothing);
  });

  testWidgets('a genuinely empty thread still says "no messages"', (
    tester,
  ) async {
    final pl = await _pumpChat(tester, preLinkRows: 0, realRows: 0);

    expect(find.byKey(divider), findsNothing);
    expect(find.text(pl.noMessagesYet), findsOneWidget);
  });
}
