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

/// The status line under the chat title (`_getHeaderStatusText`): what a user
/// sees while the peer types, while either side records a voice note, and
/// that nothing shows otherwise.
const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

const _typingLine = 'typing…';
const _recordingLine = 'Recording voice…';

/// The peer's typing / recording state is box-fed and has no public setter, so
/// the screen reads it from here. The members are class members, so the
/// header's calls reach these overrides.
class _PeerStatusMessaging extends MessagingProvider {
  final Set<int> typingIn = {};
  final Set<int> recordingIn = {};

  @override
  bool isPartnerTyping(int conversationId) => typingIn.contains(conversationId);

  @override
  bool isPartnerRecordingVoice(int conversationId) =>
      recordingIn.contains(conversationId);

  void changePeer(void Function() change) {
    change();
    notifyListeners();
  }
}

Map<String, dynamic> _conversationJson() => {
      'id': 10,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': '2026-01-01T00:00:00.000Z',
      'unreadCount': 0,
      'lastMessage': null,
    };

Future<_PeerStatusMessaging> _pumpChat(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [_conversationJson()]);
  conversations.openConversation(10, notify: false);

  final messaging = _PeerStatusMessaging()
    ..setIncomingMessageSoundEnabledForTest(false)
    ..setConversationsProvider(conversations)
    ..setCurrentUserId(1)
    ..setToken('tok')
    ..setEmitCallback((event, data) {})
    ..onConnect(false)
    ..setActiveConversationIdForTest(10);
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
        home: const ChatDetailScreen(conversationId: 10),
      ),
    ),
  );
  await tester.pump();
  return messaging;
}

void main() {
  testWidgets('nothing is typed or recorded: the title has no status line',
      (tester) async {
    await _pumpChat(tester);

    expect(find.text('bob'), findsWidgets);
    expect(find.text(_typingLine), findsNothing);
    expect(find.text(_recordingLine), findsNothing);
  });

  testWidgets('the peer is typing: the title says "typing…"', (tester) async {
    final messaging = await _pumpChat(tester);

    messaging.changePeer(() => messaging.typingIn.add(10));
    await tester.pump();

    expect(find.text(_typingLine), findsOneWidget);
    expect(find.text(_recordingLine), findsNothing);
  });

  testWidgets('the peer typing stops: the line goes away again',
      (tester) async {
    final messaging = await _pumpChat(tester);
    messaging.changePeer(() => messaging.typingIn.add(10));
    await tester.pump();
    expect(find.text(_typingLine), findsOneWidget);

    messaging.changePeer(messaging.typingIn.clear);
    await tester.pump();

    expect(find.text(_typingLine), findsNothing);
  });

  testWidgets('the peer is recording a voice note: "Recording voice…"',
      (tester) async {
    final messaging = await _pumpChat(tester);

    messaging.changePeer(() => messaging.recordingIn.add(10));
    await tester.pump();

    expect(find.text(_recordingLine), findsOneWidget);
    expect(find.text(_typingLine), findsNothing);
  });

  testWidgets('I am recording a voice note: "Recording voice…"',
      (tester) async {
    final messaging = await _pumpChat(tester);

    messaging.setIsRecordingVoice(true);
    await tester.pump();

    expect(find.text(_recordingLine), findsOneWidget);
    expect(find.text(_typingLine), findsNothing);
  });

  testWidgets('recording wins over typing, from either side', (tester) async {
    final messaging = await _pumpChat(tester);

    messaging.changePeer(() {
      messaging.typingIn.add(10);
      messaging.recordingIn.add(10);
    });
    await tester.pump();
    expect(find.text(_recordingLine), findsOneWidget);
    expect(find.text(_typingLine), findsNothing);

    messaging
      ..changePeer(messaging.recordingIn.clear)
      ..setIsRecordingVoice(true);
    await tester.pump();
    expect(find.text(_recordingLine), findsOneWidget);
    expect(find.text(_typingLine), findsNothing);
  });

  testWidgets('a peer typing in ANOTHER chat shows nothing here',
      (tester) async {
    final messaging = await _pumpChat(tester);

    messaging.changePeer(() {
      messaging.typingIn.add(99);
      messaging.recordingIn.add(99);
    });
    await tester.pump();

    expect(find.text(_typingLine), findsNothing);
    expect(find.text(_recordingLine), findsNothing);
  });
}
