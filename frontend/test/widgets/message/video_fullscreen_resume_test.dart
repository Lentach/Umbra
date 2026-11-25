import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/utils/chat_resume_reassert.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:fireplace/widgets/message/video_fullscreen_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/box_send_harness.dart';

const Key _kOpen = ValueKey('open_video');
const Key _kClose = ValueKey('video_fullscreen_close');

/// Real waits alternated with pumps: the send's continuations run in the test
/// zone (the same loop the voice retry test uses).
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  int turns = 100,
}) async {
  for (var i = 0; i < turns && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Coming back to the app re-opens the chat from its RAM cache
/// (`reassertOpenConversationOnResume`). A clip the user sent this session
/// is in the chat, and its player must survive that.
void main() {
  late BoxSendHarness h;

  setUp(() async => h = await BoxSendHarness.create());
  tearDown(() => h.dispose());

  testWidgets('the player of a clip sent this session stays open across an '
      'app resume', (tester) async {
    h.bob([1]);
    final earlier = MessageModel(
      id: kFirstLocalMessageId + 1,
      content: 'hello',
      senderId: 2,
      senderUsername: 'bob',
      conversationId: 10,
      createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    // A chat that was opened: its cache holds what it showed then.
    h.provider.seedMessagesForTest(10, [earlier]);
    expect(h.provider.hasCachedMessages(10), isTrue);

    final clip = List<int>.generate(3000, (i) => i % 251);
    var done = false;
    h.provider
        .sendVideoMessage(clip, 2, duration: 4)
        .whenComplete(() => done = true)
        .ignore();
    await _until(tester, () => done);
    final sent = h.provider.messages.lastWhere(
      (m) => m.messageType == MessageType.video,
    );
    expect(sent.deliveryStatus, MessageDeliveryStatus.sent);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: AuthProvider()..setAccessTokenForTest('tok'),
          ),
          ChangeNotifierProvider<MessagingProvider>.value(value: h.provider),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: _kOpen,
                onPressed: () => showVideoFullscreen(context, sent),
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_kOpen));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(_kClose), findsOneWidget);

    // What the chat screen does on resume.
    reassertOpenConversationOnResume(h.conversations, h.provider, 10);
    await _until(tester, () => false, turns: 15);

    expect(find.byKey(_kClose), findsOneWidget);
  });
}
