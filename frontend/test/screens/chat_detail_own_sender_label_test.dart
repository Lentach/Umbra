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
import 'package:fireplace/widgets/input/reply_preview_bar.dart';
import 'package:fireplace/widgets/message/pinned_message_banner.dart';
import 'package:fireplace/widgets/message/reply_quote_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';
import '../support/l10n.dart';

/// The open chat names the reader's OWN message "You" wherever it quotes one:
/// the composer's reply preview, the quote above a sent reply and the pinned
/// banner. An own row carries no username, so these read "Unknown" (reply) or
/// the PEER's name (pin) before.
const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

MessageModel _own({required int id, required String content}) => MessageModel(
      id: id,
      content: content,
      senderId: 1,
      senderUsername: '',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 2),
    );

Future<MessagingProvider> _pumpChat(
  WidgetTester tester, {
  Map<String, dynamic>? pinned,
  List<MessageModel> rows = const [],
}) async {
  SharedPreferences.setMockInitialValues({});

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [
    {
      'id': 10,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': '2026-01-01T00:00:00.000Z',
      'unreadCount': 0,
      'lastMessage': null,
      if (pinned != null) ...{
        'pinnedMessageId': pinned['id'],
        'pinnedMessage': pinned,
      },
    },
  ]);
  conversations.openConversation(10, notify: false);

  final messaging = MessagingProvider()
    ..setIncomingMessageSoundEnabledForTest(false)
    ..setConversationsProvider(conversations)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setEmitCallback((event, data) {})
    ..onConnect(false)
    ..setActiveConversationIdForTest(10);
  addTearDown(messaging.dispose);
  if (rows.isNotEmpty) messaging.seedMessagesForTest(10, rows);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationsProvider>.value(
          value: conversations,
        ),
        ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
        ChangeNotifierProvider<AuthProvider>.value(
          value: AuthProvider()..setAccessTokenForTest(_currentUserJwt),
        ),
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
        home: const ChatDetailScreen(conversationId: 10),
      ),
    ),
  );
  await tester.pump();
  return messaging;
}

Finder _within(Type widget, String text) =>
    find.descendant(of: find.byType(widget), matching: find.text(text));

void main() {
  testWidgets("the composer's reply preview names your own message You",
      (tester) async {
    final own = _own(id: 5, content: 'my words');
    final messaging = await _pumpChat(tester, rows: [own]);

    messaging.setReplyingTo(own);
    await tester.pump();
    await tester.pump();

    expect(_within(ReplyPreviewBar, l10n.senderYou), findsOneWidget);
    expect(_within(ReplyPreviewBar, l10n.unknown), findsNothing);
  });

  testWidgets('the quote above a reply to your own message says You',
      (tester) async {
    final own = _own(id: 5, content: 'my words');
    final reply = MessageModel(
      id: 6,
      content: 'and more',
      senderId: 1,
      senderUsername: '',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 3),
      replyTo: const ReplyToPreview(
        id: 5,
        content: 'my words',
        senderUsername: '',
        messageType: MessageType.text,
        wireId: 'wire-5',
        senderId: 1,
      ),
    );
    await _pumpChat(tester, rows: [own, reply]);
    await tester.pump();

    expect(_within(ReplyQuoteCard, l10n.senderYou), findsOneWidget);
    expect(_within(ReplyQuoteCard, l10n.unknown), findsNothing);
  });

  testWidgets(
      'the pinned banner names your own pinned message You, not the peer',
      (tester) async {
    await _pumpChat(
      tester,
      pinned: {
        'id': 5,
        'content': 'my pinned words',
        'senderId': 1,
        'senderUsername': '',
        'conversationId': 10,
        'createdAt': '2026-01-02T00:00:00.000Z',
      },
    );

    expect(_within(PinnedMessageBanner, l10n.senderYou), findsOneWidget);
    expect(_within(PinnedMessageBanner, 'bob'), findsNothing);
  });

  testWidgets("the pinned banner keeps the peer's name on the peer's message",
      (tester) async {
    await _pumpChat(
      tester,
      pinned: {
        'id': 5,
        'content': 'their pinned words',
        'senderId': 2,
        'senderUsername': '',
        'conversationId': 10,
        'createdAt': '2026-01-02T00:00:00.000Z',
      },
    );

    expect(_within(PinnedMessageBanner, 'bob'), findsOneWidget);
    expect(_within(PinnedMessageBanner, l10n.senderYou), findsNothing);
  });
}
