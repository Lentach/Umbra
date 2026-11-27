import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/conversation_tile.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:fireplace/widgets/message/image_message_content.dart';
import 'package:fireplace/widgets/message/message_context_menu_bubble_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/box_send_harness.dart';
import '../../support/l10n.dart';

/// Invariant slice 3b: a message waiting to be sent (`waitingToSend`, status
/// still `failed`) is drawn CALM: a clock, grey words by the reason, no Retry,
/// nothing red. An ordinary failed row stays exactly as it was.
void main() {
  late BoxSendHarness h;
  final pl = lookupAppLocalizations(const Locale('pl'));

  setUp(() async {
    final harness = await BoxSendHarness.create();
    h = harness..bob([1]);
  });
  tearDown(() => h.dispose());

  Widget app({required Widget child, Locale locale = const Locale('en')}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
          ChangeNotifierProvider<MessagingProvider>.value(value: h.provider),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(),
          ),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataBlue,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      );

  Future<void> pumpRow(
    WidgetTester tester,
    MessageModel message, {
    Locale locale = const Locale('en'),
    double width = 360,
  }) => tester.pumpWidget(
    app(
      locale: locale,
      child: SizedBox(
        width: width,
        child: ChatMessageBubble(
          message: message,
          isMine: true,
          peerRefusedIdentity: true,
        ),
      ),
    ),
  );

  /// A real waiting row: written while the friend's calm line is untapped.
  Future<MessageModel> waitingRow(WidgetTester tester) async {
    h.provider.seedCalmHoldForTest(2, CalmHoldState.waiting);
    await tester.runAsync(() async {
      h.provider.sendMessage('hello');
      await h.pump();
    });
    final row = h.provider.messages.single;
    expect(row.deliveryStatus, MessageDeliveryStatus.failed);
    expect(row.waitingToSend, isTrue);
    return row;
  }

  MessageModel voiceOf(MessageModel row) => row.copyWith(
    messageType: MessageType.voice,
    content: '',
    mediaDuration: 7,
  );

  final failedDot = find.byIcon(Icons.error);
  final retry = find.text(l10n.messageRetrySend);

  /// Anything painted in the theme's error colour on screen.
  Finder redThings(BuildContext context) => find.byWidgetPredicate((w) {
    final error = Theme.of(context).colorScheme.error;
    return (w is Icon && w.color == error) ||
        (w is Text && w.style?.color == error);
  });

  testWidgets('calm line untapped: clock, the calm text, no Retry, no red', (
    tester,
  ) async {
    final row = await waitingRow(tester);

    await pumpRow(tester, row);

    expect(find.text(l10n.messageWaitingTapCalmLine), findsOneWidget);
    expect(l10n.messageWaitingTapCalmLine,
        'Waiting: tap the line about the new device');
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(retry, findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(failedDot, findsNothing);
    expect(redThings(tester.element(find.byType(ChatMessageBubble))),
        findsNothing);
  });

  testWidgets('the same in Polish', (tester) async {
    final row = await waitingRow(tester);

    await pumpRow(tester, row, locale: const Locale('pl'));

    expect(find.text(pl.messageWaitingTapCalmLine), findsOneWidget);
    expect(pl.messageWaitingTapCalmLine,
        'Czeka: dotknij linii o nowym urządzeniu');
    expect(find.text(pl.messageRetrySend), findsNothing);
  });

  testWidgets('any other reason: "Waiting to send" / "Czeka na wysłanie"', (
    tester,
  ) async {
    final row = await waitingRow(tester);
    h.provider.clearCalmHoldForTest(2);

    await pumpRow(tester, row);
    expect(find.text(l10n.messageWaitingToSend), findsOneWidget);
    expect(l10n.messageWaitingToSend, 'Waiting to send');
    expect(find.text(l10n.messageWaitingTapCalmLine), findsNothing);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(retry, findsNothing);
    expect(failedDot, findsNothing);

    await pumpRow(tester, row, locale: const Locale('pl'));
    expect(find.text(pl.messageWaitingToSend), findsOneWidget);
    expect(pl.messageWaitingToSend, 'Czeka na wysłanie');
  });

  testWidgets('the text follows the reason while the row is on screen', (
    tester,
  ) async {
    final row = await waitingRow(tester);
    await pumpRow(tester, row);
    expect(find.text(l10n.messageWaitingTapCalmLine), findsOneWidget);

    h.provider.clearCalmHoldForTest(2);
    await tester.pump();

    expect(find.text(l10n.messageWaitingToSend), findsOneWidget);
    expect(find.text(l10n.messageWaitingTapCalmLine), findsNothing);
  });

  testWidgets('the semantics label is the visible text', (tester) async {
    final handle = tester.ensureSemantics();
    final row = await waitingRow(tester);

    await pumpRow(tester, row);
    // The line may merge into the bubble's node: the label it reads out holds
    // the visible text once (the Text's own semantics are excluded).
    final label = tester.getSemantics(find.byIcon(Icons.schedule)).label;
    expect(label, contains(l10n.messageWaitingTapCalmLine));
    expect(
      l10n.messageWaitingTapCalmLine.allMatches(label),
      hasLength(1),
    );
    handle.dispose();
  });

  testWidgets('an ordinary failed row is unchanged: Retry and the red dot', (
    tester,
  ) async {
    final row = (await waitingRow(tester)).copyWith(waitingToSend: false);

    await pumpRow(tester, row);

    expect(retry, findsOneWidget);
    expect(failedDot, findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsNothing);
    expect(find.text(l10n.messageWaitingTapCalmLine), findsNothing);
    expect(find.text(l10n.messageWaitingToSend), findsNothing);
  });

  testWidgets('320 px wide, Polish: the text wraps, no overflow, no ellipsis', (
    tester,
  ) async {
    final row = await waitingRow(tester);

    await pumpRow(tester, row, locale: const Locale('pl'), width: 320);

    final finder = find.text(pl.messageWaitingTapCalmLine);
    expect(finder, findsOneWidget);
    final text = tester.widget<Text>(finder);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(text.maxLines, isNull);
    expect(tester.renderObject<RenderParagraph>(finder).didExceedMaxLines,
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a waiting row can be deleted from the long-press menu', (
    tester,
  ) async {
    final row = await waitingRow(tester);
    await pumpRow(tester, row);

    await tester.longPress(find.byType(ChatMessageBubble));
    await tester.pumpAndSettle();

    expect(find.text(l10n.messageActionDelete), findsOneWidget);
  });

  testWidgets('a waiting VOICE note is calm too: no red, no Retry', (
    tester,
  ) async {
    final row = voiceOf(await waitingRow(tester));

    await pumpRow(tester, row);

    expect(find.text(l10n.messageWaitingTapCalmLine), findsOneWidget);
    expect(retry, findsNothing);
    expect(failedDot, findsNothing);
    expect(redThings(tester.element(find.byType(ChatMessageBubble))),
        findsNothing);
  });

  testWidgets('a failed VOICE note still shows Retry and the red dot', (
    tester,
  ) async {
    final row = voiceOf(
      (await waitingRow(tester)).copyWith(waitingToSend: false),
    );

    await pumpRow(tester, row);

    expect(retry, findsOneWidget);
    expect(failedDot, findsOneWidget);
  });

  testWidgets('the context-menu replica of a waiting row is not red', (
    tester,
  ) async {
    final row = await waitingRow(tester);
    await tester.pumpWidget(
      app(
        child: MessageContextMenuBubbleHighlight(
          message: row,
          isMine: true,
          maxWidth: 200,
        ),
      ),
    );

    expect(failedDot, findsNothing);
    expect(redThings(tester.element(find.byType(Scaffold))), findsNothing);
  });

  testWidgets('the context-menu replica of an ordinary failed row IS red', (
    tester,
  ) async {
    final row = (await waitingRow(tester)).copyWith(waitingToSend: false);
    await tester.pumpWidget(
      app(
        child: MessageContextMenuBubbleHighlight(
          message: row,
          isMine: true,
          maxWidth: 200,
        ),
      ),
    );

    expect(failedDot, findsOneWidget);
  });

  testWidgets('the chat-list tile of a chat whose last row waits shows no '
      'failed marker', (tester) async {
    final row = await waitingRow(tester);
    await tester.pumpWidget(
      app(
        child: SizedBox(
          width: 390,
          child: ConversationTile(
            conversationId: 10,
            displayName: 'Bob',
            lastMessage: row,
            onTap: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(failedDot, findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.text(row.content), findsOneWidget);
  });

  testWidgets('a waiting photo not uploaded yet is "on its way", never the '
      'red "failed to load"', (tester) async {
    final row = (await waitingRow(tester)).copyWith(
      messageType: MessageType.image,
      content: '',
      mediaUrl: '',
    );
    await tester.pumpWidget(
      app(
        child: SizedBox(width: 300, child: ImageMessageContent(message: row)),
      ),
    );
    await tester.pump();

    expect(find.text(l10n.imageFailedToLoad), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
