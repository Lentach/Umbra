import 'dart:async';
import 'dart:convert';

import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/utils/message_ids.dart';
import 'package:fireplace/widgets/message/message_context_menu_overlay.dart'
    show messageGoneWatch;
import 'package:fireplace/widgets/user_card/shared_media_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3-MSG-B-11: the user card's fullscreen photo must not outlive its message.
void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  testWidgets('the fullscreen photo closes when its message is gone', (
    tester,
  ) async {
    final gone = ValueNotifier<bool>(false);
    addTearDown(gone.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSharedMediaFullscreen(
              context,
              png,
              goneWatch: (changes: gone, isGone: () => gone.value),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    gone.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('a change that keeps the message leaves it open', (tester) async {
    final changes = ValueNotifier<int>(0);
    addTearDown(changes.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSharedMediaFullscreen(
              context,
              png,
              goneWatch: (changes: changes, isGone: () => false),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('a route above the photo is not popped in its place', (
    tester,
  ) async {
    final gone = ValueNotifier<bool>(false);
    addTearDown(gone.dispose);
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            home = context;
            return TextButton(
              onPressed: () => showSharedMediaFullscreen(
                context,
                png,
                goneWatch: (changes: gone, isGone: () => gone.value),
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: home,
        builder: (_) => const AlertDialog(content: Text('above')),
      ),
    );
    await tester.pumpAndSettle();

    gone.value = true;
    await tester.pumpAndSettle();

    expect(find.text('above'), findsOneWidget);
  });

  // The watch must also see the REAL provider's delete paths: they notify
  // before the RAM cache the watch reads is updated, so a check made inside
  // the notify still finds the row.
  const chat = 10;
  MessageModel row(int n, {MessageType type = MessageType.text}) =>
      MessageModel(
        id: kFirstLocalMessageId + n,
        content: 'row $n',
        senderId: 2,
        senderUsername: 'bob',
        conversationId: chat,
        createdAt: DateTime.utc(2026, 1, 1, 0, n),
        messageType: type,
        mediaUrl: type == MessageType.image ? 'https://example.com/p.bin' : null,
      );

  Future<MessagingProvider> openOverProvider(
    WidgetTester tester,
    MessageModel watched,
  ) async {
    final messaging = MessagingProvider()
      ..seedMessagesForTest(chat, [row(1), watched, row(3)]);
    addTearDown(messaging.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSharedMediaFullscreen(
              context,
              png,
              goneWatch: messageGoneWatch(
                messaging,
                () => messaging.cachedMessagesFor(chat),
                watched,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    return messaging;
  }

  testWidgets('deleting the message through the provider closes the photo', (
    tester,
  ) async {
    final watched = row(2, type: MessageType.image);
    final messaging = await openOverProvider(tester, watched);

    messaging.deleteMessage(watched.id, forEveryone: false);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('clearing the chat through the provider closes the photo', (
    tester,
  ) async {
    final watched = row(2, type: MessageType.image);
    final messaging = await openOverProvider(tester, watched);

    messaging.clearChatHistory(chat);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
