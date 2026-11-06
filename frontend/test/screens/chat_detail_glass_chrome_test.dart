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
import 'package:fireplace/widgets/glass/glass_top_bar.dart';
import 'package:fireplace/widgets/message/pinned_message_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';

/// Geometry proof for the Liquid Glass chat chrome (spec §5): with
/// `extendBodyBehindAppBar`, the pinned banner and the newest message must
/// clear the floating [GlassTopBar]; the wallpaper still runs behind it.
const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

Map<String, dynamic> _conversationJson({bool pinned = false}) => {
      'id': 10,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': '2026-01-01T00:00:00.000Z',
      'unreadCount': 0,
      'lastMessage': null,
      if (pinned) 'pinnedMessageId': 1001,
      if (pinned) 'pinnedMessage': _messageJson(1001),
    };

Map<String, dynamic> _messageJson(int id) => {
      'id': id,
      'content': 'note $id',
      'senderId': id.isEven ? 1 : 2,
      'senderUsername': id.isEven ? 'alice' : 'bob',
      'conversationId': 10,
      'deliveryStatus': 'DELIVERED',
      'messageType': 'TEXT',
      'createdAt': DateTime.utc(2026, 1, 1, 12, id % 60).toIso8601String(),
    };

Future<void> _pumpChat(
  WidgetTester tester, {
  bool pinned = false,
}) async {
  SharedPreferences.setMockInitialValues({});

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [_conversationJson(pinned: pinned)]);
  conversations.openConversation(10, notify: false);

  final messaging = MessagingProvider();
  messaging.setIncomingMessageSoundEnabledForTest(false);
  messaging.setConversationsProvider(conversations);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.setEmitCallback((event, data) {});
  messaging.onConnect(false);
  messaging.setActiveConversationIdForTest(10);
  messaging.seedCacheForTest(
    10,
    [for (var i = 0; i < 8; i++) MessageModel.fromJson(_messageJson(1000 + i))],
  );
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
}

void main() {
  testWidgets('newest message clears the floating GlassTopBar (unpinned)',
      (tester) async {
    await _pumpChat(tester);

    expect(find.byType(GlassTopBar), findsOneWidget);
    final barBottom = tester.getBottomLeft(find.byType(GlassTopBar)).dy;

    // reverse:true — the OLDEST visible message is nearest the top edge;
    // whatever is topmost must still clear the bar.
    final noteFinders = find.textContaining('note ', findRichText: true);
    expect(noteFinders, findsWidgets);
    var topMost = double.infinity;
    for (final e in noteFinders.evaluate()) {
      final dy = tester.getTopLeft(find.byWidget(e.widget)).dy;
      if (dy < topMost) topMost = dy;
    }
    // Scroll to the very top (oldest); the list padding must keep content
    // below the bar when fully scrolled.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    topMost = double.infinity;
    for (final e in find.textContaining('note ', findRichText: true).evaluate()) {
      final dy = tester.getTopLeft(find.byWidget(e.widget)).dy;
      if (dy < topMost) topMost = dy;
    }
    expect(topMost, greaterThanOrEqualTo(barBottom - 0.01),
        reason: 'scrolled-to-top content must not sit under the glass bar');
  });

  testWidgets('pinned banner sits fully below the floating GlassTopBar',
      (tester) async {
    await _pumpChat(tester, pinned: true);

    expect(find.byType(PinnedMessageBanner), findsOneWidget);
    final barBottom = tester.getBottomLeft(find.byType(GlassTopBar)).dy;
    final bannerTop =
        tester.getTopLeft(find.byType(PinnedMessageBanner)).dy;
    expect(bannerTop, greaterThanOrEqualTo(barBottom - 0.01),
        reason: 'pinned banner must clear the floating top chrome');
  });
}
