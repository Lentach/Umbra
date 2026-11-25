import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:fireplace/widgets/message/video_fullscreen_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _kChat = 10;
const Key _kOpen = ValueKey('open_video');
const Key _kClose = ValueKey('video_fullscreen_close');

MessageModel _video({DateTime? expiresAt, String? tempId}) => MessageModel(
  id: kFirstLocalMessageId + 7,
  tempId: tempId,
  content: '',
  senderId: 2,
  senderUsername: 'bob',
  conversationId: _kChat,
  deliveryStatus: MessageDeliveryStatus.read,
  messageType: MessageType.video,
  createdAt: DateTime.now(),
  mediaUrl: 'https://example.com/media/msgs/v.bin',
  mediaDuration: 12,
  expiresAt: expiresAt,
);

MessageModel _text(int n) => MessageModel(
  id: kFirstLocalMessageId + n,
  content: 'hello',
  senderId: 2,
  senderUsername: 'bob',
  conversationId: _kChat,
  createdAt: DateTime.now(),
);

/// Opens the fullscreen player for [message] over a chat page that holds
/// [rows]. Providers sit ABOVE MaterialApp: the player is a dialog on the
/// root navigator.
Future<MessagingProvider> _open(
  WidgetTester tester,
  MessageModel message,
  List<MessageModel> rows,
) async {
  final messaging = MessagingProvider()..seedMessagesForTest(_kChat, rows);
  addTearDown(messaging.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(
          value: AuthProvider()..setAccessTokenForTest('tok'),
        ),
        ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _kOpen,
              onPressed: () => showVideoFullscreen(context, message),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_kOpen));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(_kClose), findsOneWidget);
  return messaging;
}

void main() {
  testWidgets('the fullscreen video closes when its disappearing timer runs '
      'out', (tester) async {
    final message = _video(
      expiresAt: DateTime.now().add(const Duration(milliseconds: 600)),
    );
    final messaging = await _open(tester, message, [message]);

    // The expiry rule reads the real clock; this is the chat screen's own
    // once-a-second sweep, run after the deadline.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    messaging.removeExpiredMessages();
    await tester.pumpAndSettle();

    expect(find.byKey(_kClose), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    // Only the player went: the chat page under it is still there.
    expect(find.byKey(_kOpen), findsOneWidget);
  });

  testWidgets('the fullscreen video closes when its message is deleted', (
    tester,
  ) async {
    final message = _video();
    final messaging = await _open(tester, message, [message]);

    messaging.deleteMessage(message.id, forEveryone: false);
    await tester.pumpAndSettle();

    expect(find.byKey(_kClose), findsNothing);
    expect(find.byKey(_kOpen), findsOneWidget);
  });

  testWidgets('another message arriving or going leaves the player open', (
    tester,
  ) async {
    final message = _video();
    final other = _text(8);
    final messaging = await _open(tester, message, [message, other]);

    messaging.deleteMessage(other.id, forEveryone: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_kClose), findsOneWidget);

    messaging.seedMessagesForTest(_kChat, [message, _text(9)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_kClose), findsOneWidget);
  });

  testWidgets('an own clip keeps its player when the sent row replaces the '
      'optimistic one', (tester) async {
    final optimistic = MessageModel(
      id: -3,
      tempId: 'temp_1_1_2',
      content: '',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: _kChat,
      messageType: MessageType.video,
      createdAt: DateTime.now(),
      mediaUrl: 'https://example.com/media/msgs/v.bin',
    );
    final messaging = await _open(tester, optimistic, [optimistic]);

    messaging.seedMessagesForTest(_kChat, [
      _video(tempId: 'temp_1_1_2'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(_kClose), findsOneWidget);
  });
}
