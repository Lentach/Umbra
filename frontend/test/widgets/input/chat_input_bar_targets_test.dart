import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:fireplace/widgets/input/chat_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/chat_seed.dart';

Map<String, dynamic> _conversation(int id, int peer, String name) => {
  'id': id,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': peer, 'username': name, 'tag': '000$peer'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': null,
};

/// The desktop split view keeps ONE composer mounted while the chat beside
/// it changes: what the composer shows and sends there must follow the chat.
void main() {
  late ConversationsProvider conversations;
  late MessagingProvider messaging;
  late ChatInputBarState bar;

  MessageModel ours(int n, int conversationId, String content) => MessageModel(
    id: kFirstLocalMessageId + n,
    content: content,
    senderId: 1,
    senderUsername: 'alice',
    conversationId: conversationId,
    createdAt: DateTime.now(),
    wireId: 'wire-0000000$n',
  );

  Future<void> pumpComposer(WidgetTester tester) async {
    conversations = ConversationsProvider()..setCurrentUserId(1);
    seedConversations(conversations, [
      _conversation(10, 2, 'bob'),
      _conversation(11, 3, 'carol'),
    ]);
    conversations.openConversation(10);
    messaging = MessagingProvider()
      ..setConversationsProvider(conversations)
      ..setCurrentUserId(1)
      ..setIncomingMessageSoundEnabledForTest(false)
      ..seedMessagesForTest(10, [ours(1, 10, 'typo')]);
    final key = GlobalKey<ChatInputBarState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: conversations),
              ChangeNotifierProvider.value(value: messaging),
              ChangeNotifierProvider(
                create: (_) => SettingsProvider(initialThemePreference: 'light'),
              ),
            ],
            child: ChatInputBar(key: key),
          ),
        ),
      ),
    );
    await tester.pump();
    bar = key.currentState!;
  }

  /// What the chat screen does when [id] becomes the chat beside the
  /// composer.
  Future<void> switchTo(WidgetTester tester, int id) async {
    conversations.openConversation(id);
    messaging.seedMessagesForTest(id, const []);
    await tester.pump();
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('editing in one chat: the field is pre-filled and a send edits '
      'the message', (tester) async {
    await pumpComposer(tester);
    messaging.beginEditMessage(messaging.messages.single);
    await tester.pump();
    expect(fieldText(tester), 'typo');

    await tester.enterText(find.byType(TextField), 'fixed');
    await bar.sendForTest();
    await tester.pump();

    expect(messaging.editingMessage, isNull);
    expect(messaging.messages.single.id, kFirstLocalMessageId + 1);
    expect(fieldText(tester), isEmpty);
  });

  testWidgets('switching chats while editing: the other chat starts with an '
      'empty field, and what is typed there is sent as a normal message', (
    tester,
  ) async {
    await pumpComposer(tester);
    messaging.beginEditMessage(messaging.messages.single);
    await tester.pump();
    expect(fieldText(tester), 'typo');

    await switchTo(tester, 11);

    expect(fieldText(tester), isEmpty);
    expect(messaging.editingMessage, isNull);

    await tester.enterText(find.byType(TextField), 'hello Carol');
    await bar.sendForTest();
    await tester.pump();

    final sent = messaging.messages.where((m) => m.content == 'hello Carol');
    expect(sent, hasLength(1));
    expect(sent.single.conversationId, 11);
    expect(fieldText(tester), isEmpty);
  });
}
