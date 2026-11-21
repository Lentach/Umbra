import 'dart:math' as math;

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:fireplace/widgets/message/gif_message_content.dart';
import 'package:fireplace/widgets/message/image_message_content.dart';
import 'package:fireplace/widgets/message/text_message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

MessageModel _gifMessage() => MessageModel(
  id: 1,
  content: '',
  senderId: 1,
  senderUsername: 'a',
  conversationId: 1,
  deliveryStatus: MessageDeliveryStatus.read,
  messageType: MessageType.gif,
  createdAt: DateTime(2026, 1, 1, 14, 30),
  mediaUrl: 'https://example.com/test.gif',
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
      ],
      child: child,
    ),
  ),
);

Widget _wrapBubble(Widget child) => MaterialApp(
  theme: RpgTheme.themeDataBlue,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider<MessagingProvider>(
          create: (_) => MessagingProvider(),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
      ],
      child: child,
    ),
  ),
);

void main() {
  group('GifMessageContent', () {
    testWidgets('renders SizedBox with height 220', (tester) async {
      await tester.pumpWidget(_wrap(GifMessageContent(message: _gifMessage())));
      final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
      expect(
        sizedBoxes.any((b) => b.height == 220.0),
        isTrue,
        reason: 'Loading placeholder must use height 220',
      );
    });

    testWidgets('does not render a ConstrainedBox with maxWidth 200', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(GifMessageContent(message: _gifMessage())));
      final boxes = tester.widgetList<ConstrainedBox>(
        find.byType(ConstrainedBox),
      );
      expect(
        boxes.any((b) => b.constraints.maxWidth == 200.0),
        isFalse,
        reason: 'GIF must not be capped at 200px',
      );
    });
  });

  group('ImageMessageContent', () {
    testWidgets('loading placeholder uses height 220', (tester) async {
      final msg = MessageModel(
        id: 2,
        content: '',
        senderId: 1,
        senderUsername: 'a',
        conversationId: 1,
        deliveryStatus: MessageDeliveryStatus.read,
        messageType: MessageType.image,
        createdAt: DateTime(2026, 1, 1, 14, 30),
        mediaUrl: 'https://example.com/test.jpg',
      );
      await tester.pumpWidget(_wrap(ImageMessageContent(message: msg)));
      final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
      expect(
        sizedBoxes.any((b) => b.height == 220.0),
        isTrue,
        reason: 'Loading placeholder must use height 220',
      );
    });

    testWidgets('does not render ConstrainedBox with maxWidth 200', (
      tester,
    ) async {
      final msg = MessageModel(
        id: 2,
        content: '',
        senderId: 1,
        senderUsername: 'a',
        conversationId: 1,
        deliveryStatus: MessageDeliveryStatus.read,
        messageType: MessageType.image,
        createdAt: DateTime(2026, 1, 1, 14, 30),
        mediaUrl: 'https://example.com/test.jpg',
      );
      await tester.pumpWidget(_wrap(ImageMessageContent(message: msg)));
      final boxes = tester.widgetList<ConstrainedBox>(
        find.byType(ConstrainedBox),
      );
      expect(boxes.any((b) => b.constraints.maxWidth == 200.0), isFalse);
    });
  });

  group('ImageMessageContent while sending', () {
    MessageModel image(MessageDeliveryStatus status) => MessageModel(
      id: -1,
      content: '',
      senderId: 1,
      senderUsername: 'a',
      conversationId: 1,
      deliveryStatus: status,
      messageType: MessageType.image,
      createdAt: DateTime(2026, 1, 1, 14, 30),
    );

    testWidgets('an own photo still uploading shows progress, not a failure', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapBubble(
          ImageMessageContent(message: image(MessageDeliveryStatus.sending)),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Image failed to load'), findsNothing);
    });

    testWidgets('a photo whose send failed says so', (tester) async {
      await tester.pumpWidget(
        _wrapBubble(
          ImageMessageContent(message: image(MessageDeliveryStatus.failed)),
        ),
      );
      await tester.pump();
      expect(find.text('Image failed to load'), findsOneWidget);
    });
  });

  group('TextMessageContent layout', () {
    testWidgets('renders text content without metadata overlay', (
      tester,
    ) async {
      final msg = MessageModel(
        id: 4,
        content: 'Hello',
        senderId: 1,
        senderUsername: 'a',
        conversationId: 1,
        deliveryStatus: MessageDeliveryStatus.read,
        messageType: MessageType.text,
        createdAt: DateTime(2026, 1, 1, 14, 30),
      );
      await tester.pumpWidget(
        _wrap(
          TextMessageContent(
            message: msg,
            isMine: true,
            textColor: Colors.white,
            isDark: true,
            maxWidth: 250,
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == 'Hello',
        ),
        findsOneWidget,
      );
    });
  });

  group('ChatMessageBubble routing', () {
    testWidgets('GIF bubble: Container has zero padding', (tester) async {
      final msg = MessageModel(
        id: 5,
        content: '',
        senderId: 1,
        senderUsername: 'a',
        conversationId: 1,
        deliveryStatus: MessageDeliveryStatus.read,
        messageType: MessageType.gif,
        createdAt: DateTime(2026, 1, 1, 14, 30),
        mediaUrl: 'https://example.com/test.gif',
      );
      await tester.pumpWidget(
        _wrapBubble(ChatMessageBubble(message: msg, isMine: true)),
      );
      final containers = tester.widgetList<Container>(find.byType(Container));
      expect(
        containers.any((c) => c.padding == EdgeInsets.zero),
        isTrue,
        reason: 'GIF bubble must have zero padding',
      );
      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('message-bubble-surface-5')),
      );
      final decoration = surface.foregroundDecoration! as BoxDecoration;
      final outline = decoration.border! as Border;
      expect(outline.top.width, 1.25);
      expect(outline.top.color, RpgTheme.themeDataBlue.colorScheme.primary);
    });

    testWidgets(
      'edited long text bubble lays metadata in flow instead of a positioned overlay',
      (tester) async {
        final msg = MessageModel(
          id: 6,
          content:
              'Edited wrapped text must keep its final line separate from the timestamp row.',
          senderId: 1,
          senderUsername: 'a',
          conversationId: 1,
          deliveryStatus: MessageDeliveryStatus.read,
          messageType: MessageType.text,
          createdAt: DateTime(2026, 1, 1, 14, 30),
          editedAt: DateTime(2026, 1, 1, 14, 35),
        );

        await tester.pumpWidget(
          _wrapBubble(
            SizedBox(
              width: 260,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        );

        final editedLabel = find.text('edited');
        expect(editedLabel, findsOneWidget);
        expect(
          find.ancestor(of: editedLabel, matching: find.byType(Positioned)),
          findsNothing,
          reason: 'Text metadata must not be absolutely positioned over text.',
        );
      },
    );

    testWidgets(
      'short text keeps full content width and reserves metadata only on final line',
      (tester) async {
        final msg = MessageModel(
          id: 7,
          content: 'widzimy sie za godzinke?',
          senderId: 2,
          senderUsername: 'a',
          conversationId: 1,
          deliveryStatus: MessageDeliveryStatus.sent,
          messageType: MessageType.text,
          createdAt: DateTime(2026, 1, 1, 14, 46),
        );

        await tester.pumpWidget(
          _wrapBubble(
            SizedBox(
              width: 360,
              child: ChatMessageBubble(message: msg, isMine: false),
            ),
          ),
        );

        final textFinder = find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().startsWith('widzimy sie za godzinke?'),
        );
        expect(textFinder, findsOneWidget);
        final textWidth = tester.getSize(textFinder).width;
        expect(
          textWidth,
          greaterThan(150),
          reason:
              'Short bubble text must measure as the text itself, not collapse from timestamp squeezing.',
        );
        final surfaceFinder = find.byKey(
          const ValueKey('message-bubble-surface-7'),
        );
        expect(surfaceFinder, findsOneWidget);
        final surfaceWidth = tester.getSize(surfaceFinder).width;
        // The text and its metadata share one Wrap: the time sits on the
        // text's line when it fits (it does in Inter), else on its own line.
        // Measure what the Wrap's children occupy, not the Wrap's own box: a
        // bubble forced wide stretches the Wrap with it, but not its children
        // (an incoming bubble aligns them at the start).
        final run = tester.renderObject<RenderWrap>(
          find.ancestor(of: textFinder, matching: find.byType(Wrap)).first,
        );
        var contentRight = 0.0;
        for (var child = run.firstChild; child != null;) {
          final data = child.parentData! as WrapParentData;
          contentRight = math.max(
            contentRight,
            data.offset.dx + child.size.width,
          );
          child = data.nextSibling;
        }
        expect(
          surfaceWidth,
          closeTo(contentRight + 32, 1),
          reason:
              'The painted bubble should shrink-wrap the text run and its metadata plus padding.',
        );
      },
    );

    testWidgets(
      'single emoji-only message renders large without a message bubble',
      (tester) async {
        final msg = MessageModel(
          id: 8,
          content: '🐶',
          senderId: 1,
          senderUsername: 'a',
          conversationId: 1,
          deliveryStatus: MessageDeliveryStatus.sent,
          messageType: MessageType.text,
          createdAt: DateTime(2026, 1, 1, 14, 56),
        );

        await tester.pumpWidget(
          _wrapBubble(
            SizedBox(
              width: 360,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        );

        final emojiFinder = find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().startsWith('🐶'),
        );
        expect(emojiFinder, findsOneWidget);
        final emojiLineWidth = tester.getSize(emojiFinder).width;
        expect(
          emojiLineWidth,
          greaterThan(80),
          reason: 'Single emoji-only message should be Telegram-large.',
        );
        final surfaceFinder = find.byKey(
          const ValueKey('message-bubble-surface-8'),
        );
        expect(
          surfaceFinder,
          findsNothing,
          reason: 'Emoji-only messages should not paint a message bubble.',
        );
      },
    );
  });
}
