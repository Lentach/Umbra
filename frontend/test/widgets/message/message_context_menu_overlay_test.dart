import 'dart:math' as math;

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/message/chat_message_bubble.dart';
import 'package:fireplace/widgets/message/message_context_menu_bubble_highlight.dart';
import 'package:fireplace/widgets/message/context_menu_bubble_anchor.dart';
import 'package:fireplace/widgets/message/message_context_menu_overlay.dart';
import 'package:fireplace/widgets/message/message_bubble_inline_time.dart';
import 'package:fireplace/widgets/message_swipe_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/l10n.dart';

MessageModel _msg({
  required int id,
  required int senderId,
  DateTime? createdAt,
}) => MessageModel(
  id: id,
  content: 'hello',
  senderId: senderId,
  senderUsername: 'alice',
  conversationId: 1,
  createdAt: createdAt ?? DateTime(2026, 5, 23),
  deliveryStatus: MessageDeliveryStatus.sent,
  messageType: MessageType.text,
);

MessageModel _imageMsg({required int id, required int senderId}) =>
    MessageModel(
      id: id,
      content: '',
      senderId: senderId,
      senderUsername: 'alice',
      conversationId: 1,
      createdAt: DateTime(2026, 5, 23),
      deliveryStatus: MessageDeliveryStatus.sent,
      messageType: MessageType.image,
    );

void main() {
  group('messageBubbleUsesInlineTime', () {
    test('short text without reply uses inline time', () {
      final msg = _msg(id: 1, senderId: 1);
      expect(
        messageBubbleUsesInlineTime(message: msg, displayContent: 'hello'),
        isTrue,
      );
    });

    test('long text stays inline; newline uses stacked time', () {
      final msg = _msg(id: 1, senderId: 1);
      expect(
        messageBubbleUsesInlineTime(
          message: msg,
          displayContent: 'this message is definitely too long',
        ),
        isTrue,
      );
      expect(
        messageBubbleUsesInlineTime(
          message: msg,
          displayContent: 'line\nbreak',
        ),
        isFalse,
      );
    });

    test('reply or link preview disables inline time', () {
      final msg = _msg(id: 1, senderId: 1).copyWith(
        replyTo: const ReplyToPreview(
          id: 2,
          content: 'quoted',
          senderUsername: 'bob',
          messageType: MessageType.text,
        ),
      );
      expect(
        messageBubbleUsesInlineTime(message: msg, displayContent: 'hi'),
        isFalse,
      );

      final withPreview = _msg(
        id: 1,
        senderId: 1,
      ).copyWith(linkPreviewUrl: 'https://example.com');
      expect(
        messageBubbleUsesInlineTime(message: withPreview, displayContent: 'hi'),
        isFalse,
      );
    });

    test('ping uses inline time; image and file do not', () {
      final ping = _msg(
        id: 1,
        senderId: 1,
      ).copyWith(messageType: MessageType.ping, content: 'Ping!');
      expect(
        messageBubbleUsesInlineTime(message: ping, displayContent: 'Ping!'),
        isTrue,
      );

      final image = _imageMsg(id: 1, senderId: 1);
      expect(
        messageBubbleUsesInlineTime(message: image, displayContent: ''),
        isFalse,
      );

      final file = _msg(
        id: 1,
        senderId: 1,
      ).copyWith(messageType: MessageType.file, content: 'doc.pdf');
      expect(
        messageBubbleUsesInlineTime(message: file, displayContent: 'doc.pdf'),
        isFalse,
      );
    });
  });

  group('computeMessageContextMenuLayout', () {
    const viewPadding = EdgeInsets.only(top: 48, left: 0, right: 0, bottom: 34);
    const viewSize = Size(390, 844);
    const panelHeight = kMessageActionPanelHeightEstimate;
    const emojiHeight = kMessageContextMenuEmojiRowHeight;
    const gap = kMessageContextMenuOverlayGap;

    double scaleOverflow(double bubbleHeight) =>
        bubbleHighlightScaleOverflow(bubbleHeight);

    test('layout rect subtracts anchor bottom margin from render box', () {
      const anchorRect = Rect.fromLTWH(80, 300, 200, 58);
      final layoutRect = bubbleRectForContextMenuLayout(anchorRect);
      expect(layoutRect.height, 48);
      expect(layoutRect.top, anchorRect.top);
      expect(layoutRect.left, anchorRect.left);
      expect(layoutRect.width, anchorRect.width);
    });

    test('standard layout keeps equal gaps around bubble highlight', () {
      const bubbleRect = Rect.fromLTWH(120, 400, 200, 40);
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );
      final scalePad = scaleOverflow(bubbleRect.height);

      expect(layout.panelAboveBubble, isFalse);
      expect(
        layout.emojiTop + emojiHeight + gap,
        closeTo(layout.bubbleHighlightTop - scalePad, 0.001),
      );
      expect(
        layout.bubbleHighlightTop + bubbleRect.height + scalePad + gap,
        closeTo(layout.panelTop, 0.001),
      );
      expect(
        layout.panelTop + panelHeight,
        lessThanOrEqualTo(viewSize.height - 88),
      );
    });

    test('standard layout keeps equal gaps for tall media bubble (220dp)', () {
      const bubbleRect = Rect.fromLTWH(
        120,
        400,
        200,
        kMessageMediaBubbleHeight,
      );
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );
      final scalePad = scaleOverflow(bubbleRect.height);

      expect(layout.panelAboveBubble, isFalse);
      expect(
        layout.emojiTop + emojiHeight + gap,
        closeTo(layout.bubbleHighlightTop - scalePad, 0.001),
      );
      expect(
        layout.bubbleHighlightTop + bubbleRect.height + scalePad + gap,
        closeTo(layout.panelTop, 0.001),
      );
      expect(
        layout.panelTop + panelHeight,
        lessThanOrEqualTo(viewSize.height - 88),
      );
    });

    test('near bottom shifts stack so full panel fits above composer', () {
      const bubbleRect = Rect.fromLTWH(16, 680, 200, 40);
      final maxContentBottom = viewSize.height - 88;
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );
      final scalePad = scaleOverflow(bubbleRect.height);

      expect(
        layout.panelTop + panelHeight,
        lessThanOrEqualTo(maxContentBottom),
      );
      expect(layout.bubbleHighlightTop, lessThan(bubbleRect.top));
      expect(
        layout.emojiTop + emojiHeight + gap,
        closeTo(layout.bubbleHighlightTop - scalePad, 0.001),
      );
      expect(
        layout.bubbleHighlightTop + bubbleRect.height + scalePad + gap,
        closeTo(layout.panelTop, 0.001),
      );
    });

    test(
      'bottom message at y ~720 keeps all four action rows within bounds',
      () {
        const bubbleRect = Rect.fromLTWH(16, 720, 200, 40);
        final maxContentBottom = viewSize.height - 88;
        final layout = computeMessageContextMenuLayout(
          bubbleRect: bubbleRect,
          viewPadding: viewPadding,
          viewSize: viewSize,
          keyboardBottom: 0,
        );

        expect(
          layout.panelTop + panelHeight,
          lessThanOrEqualTo(maxContentBottom),
        );
        expect(layout.panelTop, greaterThanOrEqualTo(viewPadding.top));
        // The whole stack — not just the panel — must stay on-screen: the
        // emoji row sits at/below the safe-area top and the bubble highlight
        // sits strictly below the emoji row.
        expect(layout.emojiTop, greaterThanOrEqualTo(viewPadding.top));
        expect(layout.bubbleHighlightTop, greaterThan(layout.emojiTop));
      },
    );

    test(
      'Telegram order: emoji top < bubble top < panel top when centered',
      () {
        const bubbleRect = Rect.fromLTWH(80, 300, 220, 56);
        final layout = computeMessageContextMenuLayout(
          bubbleRect: bubbleRect,
          viewPadding: viewPadding,
          viewSize: viewSize,
          keyboardBottom: 0,
        );
        final scalePad = scaleOverflow(bubbleRect.height);

        expect(layout.emojiTop, lessThan(layout.bubbleHighlightTop));
        expect(
          layout.panelTop,
          greaterThan(layout.bubbleHighlightTop + bubbleRect.height + scalePad),
        );
      },
    );

    test('larger panelHeight shifts bottom-anchored stack further up', () {
      const bubbleRect = Rect.fromLTWH(16, 680, 200, 40);
      const fiveRowHeight =
          kMessageActionPanelHeightEstimate +
          kMessageActionPanelRowHeightEstimate;
      final maxContentBottom = viewSize.height - 88;

      final fourRows = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );
      final fiveRows = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
        panelHeight: fiveRowHeight,
      );

      expect(
        fiveRows.panelTop + fiveRowHeight,
        lessThanOrEqualTo(maxContentBottom),
      );
      expect(
        fiveRows.bubbleHighlightTop,
        lessThan(fourRows.bubbleHighlightTop),
      );
    });

    test('huge bubble clamps preview and keeps the whole menu on-screen', () {
      // Taller than the screen and partially scrolled off the top.
      const bubbleRect = Rect.fromLTWH(16, -400, 200, 2000);
      final maxContentBottom = viewSize.height - 88;
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );

      expect(layout.previewHeight, lessThan(bubbleRect.height));
      expect(layout.previewHeight, greaterThan(0));
      expect(layout.emojiTop, greaterThanOrEqualTo(viewPadding.top));
      expect(
        layout.panelTop + panelHeight,
        lessThanOrEqualTo(maxContentBottom),
      );
      expect(layout.panelTop, greaterThan(layout.emojiTop));

      // Stack geometry (equal gaps) holds for the CLAMPED height.
      final scalePad = scaleOverflow(layout.previewHeight);
      expect(
        layout.emojiTop + emojiHeight + gap,
        closeTo(layout.bubbleHighlightTop - scalePad, 0.001),
      );
      expect(
        layout.bubbleHighlightTop + layout.previewHeight + scalePad + gap,
        closeTo(layout.panelTop, 0.001),
      );
    });

    test('huge bubble with five-row panel also fits on-screen', () {
      const bubbleRect = Rect.fromLTWH(16, 100, 200, 2000);
      const fiveRowHeight =
          kMessageActionPanelHeightEstimate +
          kMessageActionPanelRowHeightEstimate;
      final maxContentBottom = viewSize.height - 88;
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
        panelHeight: fiveRowHeight,
      );

      expect(layout.emojiTop, greaterThanOrEqualTo(viewPadding.top));
      expect(
        layout.panelTop + fiveRowHeight,
        lessThanOrEqualTo(maxContentBottom),
      );
      expect(layout.previewHeight, lessThan(bubbleRect.height));
    });

    test('normal bubble keeps previewHeight equal to its own height', () {
      const bubbleRect = Rect.fromLTWH(120, 400, 200, 40);
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );
      expect(layout.previewHeight, bubbleRect.height);
    });

    test('inverted layout preserves gaps between emoji panel and bubble', () {
      const bubbleRect = Rect.fromLTWH(16, 52, 200, 40);
      final layout = computeMessageContextMenuLayout(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        keyboardBottom: 0,
      );

      expect(layout.panelAboveBubble, isTrue);
      expect(layout.emojiTop, viewPadding.top);
      expect(layout.panelTop, layout.emojiTop + emojiHeight + gap);
      expect(layout.bubbleHighlightTop, layout.panelTop + panelHeight + gap);
    });
  });

  group('computeExpandedReactionPickerLayout', () {
    const viewSize = Size(400, 800);
    const wideViewSize = Size(800, 800);
    const viewPadding = EdgeInsets.only(top: 40, bottom: 20);
    const gap = kMessageContextMenuOverlayGap;

    ({double left, double top, double width, double height, bool below})
    layoutFor({
      Rect bubbleRect = const Rect.fromLTWH(120, 200, 240, 48),
      Size size = viewSize,
      double keyboardBottom = 0,
      bool isMine = true,
      double? bubbleHighlightTop,
      double? previewHeight,
    }) => computeExpandedReactionPickerLayout(
      bubbleRect: bubbleRect,
      viewPadding: viewPadding,
      viewSize: size,
      keyboardBottom: keyboardBottom,
      isMine: isMine,
      bubbleHighlightTop: bubbleHighlightTop ?? bubbleRect.top,
      previewHeight: previewHeight ?? bubbleRect.height,
    );

    test('prefers the larger region below a high bubble and caps at 420', () {
      final l = layoutFor();
      expect(l.below, isTrue);
      final highlightBottom = bubbleHighlightVisualBottom(
        bubbleHighlightTop: 200,
        layoutBubbleHeight: 48,
      );
      expect(l.top, closeTo(highlightBottom + gap, 0.001));
      expect(l.height, kExpandedReactionPickerMaxHeight);
      expect(
        l.top + l.height,
        lessThanOrEqualTo(800 - 20 - kExpandedReactionPickerMargin),
      );
    });

    test('places above when the bubble sits near the screen bottom', () {
      final l = layoutFor(bubbleRect: const Rect.fromLTWH(120, 680, 240, 48));
      expect(l.below, isFalse);
      final highlightTop = bubbleHighlightVisualTop(
        bubbleHighlightTop: 680,
        layoutBubbleHeight: 48,
      );
      expect(l.top + l.height, closeTo(highlightTop - gap, 0.001));
      expect(l.top, greaterThanOrEqualTo(viewPadding.top + 8));
    });

    test('keyboard inset shrinks the below region', () {
      final noKb = layoutFor();
      final withKb = layoutFor(keyboardBottom: 300);
      expect(withKb.height, lessThan(noKb.height));
      expect(
        withKb.top + withKb.height,
        lessThanOrEqualTo(800 - 300 - kExpandedReactionPickerMargin),
      );
    });

    test('never returns a height below the suggested-row minimum', () {
      final l = layoutFor(
        size: const Size(400, 220),
        keyboardBottom: 118,
        bubbleRect: const Rect.fromLTWH(120, 78, 160, 48),
      );

      expect(l.height, greaterThanOrEqualTo(52));
    });

    test('width caps at 360 and respects 16px margins on narrow screens', () {
      final l = layoutFor();
      expect(l.width, math.min(400 - 32, kExpandedReactionPickerMaxWidth));
      expect(l.left, greaterThanOrEqualTo(kExpandedReactionPickerMargin));
      expect(
        l.left + l.width,
        lessThanOrEqualTo(400 - kExpandedReactionPickerMargin),
      );
    });

    test('own message right-aligns panel to the bubble right edge', () {
      final l = layoutFor(
        size: wideViewSize,
        bubbleRect: const Rect.fromLTWH(300, 200, 240, 48),
      );
      expect(l.width, kExpandedReactionPickerMaxWidth);
      expect(l.left + l.width, closeTo(540, 0.001)); // bubbleRect.right
    });

    test('received message left-aligns panel to the bubble left edge', () {
      final l = layoutFor(
        size: wideViewSize,
        isMine: false,
        bubbleRect: const Rect.fromLTWH(300, 200, 240, 48),
      );
      expect(l.left, closeTo(300, 0.001)); // bubbleRect.left
    });

    test('huge-message clamped previewHeight drives the free regions', () {
      // Raw bubble is 700px tall but the overlay shows a clamped 400px preview
      // starting at highlight top 150; free space is measured from the preview.
      final l = layoutFor(
        bubbleRect: const Rect.fromLTWH(20, 100, 300, 700),
        bubbleHighlightTop: 150,
        previewHeight: 400,
      );
      final highlightBottom = bubbleHighlightVisualBottom(
        bubbleHighlightTop: 150,
        layoutBubbleHeight: 400,
      );
      expect(l.below, isTrue);
      expect(l.top, closeTo(highlightBottom + gap, 0.001));
    });
  });

  group('horizontal alignment helpers', () {
    const viewPadding = EdgeInsets.only(
      top: 48,
      left: 16,
      right: 16,
      bottom: 34,
    );
    const viewSize = Size(390, 844);

    test('received panel aligns to bubble left edge', () {
      const bubbleRect = Rect.fromLTWH(16, 400, 220, 40);
      final left = computePanelLeft(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        isMine: false,
        panelWidth: 180,
      );
      expect(left, bubbleRect.left);
    });

    test('sent panel aligns to bubble right edge', () {
      const bubbleRect = Rect.fromLTWH(194, 400, 180, 40);
      final left = computePanelLeft(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        isMine: true,
        panelWidth: 180,
      );
      expect(left, bubbleRect.right - 180);
    });

    test('received emoji bar aligns to bubble left edge', () {
      const bubbleRect = Rect.fromLTWH(16, 400, 220, 40);
      const emojiBarWidth = 248.0;
      final left = computeEmojiBarLeft(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        isMine: false,
        emojiBarWidth: emojiBarWidth,
      );
      expect(left, bubbleRect.left);
    });

    test('sent emoji bar aligns to bubble right edge', () {
      const bubbleRect = Rect.fromLTWH(126, 400, 248, 40);
      const emojiBarWidth = 248.0;
      final left = computeEmojiBarLeft(
        bubbleRect: bubbleRect,
        viewPadding: viewPadding,
        viewSize: viewSize,
        isMine: true,
        emojiBarWidth: emojiBarWidth,
      );
      expect(left, bubbleRect.right - emojiBarWidth);
    });
  });

  testWidgets('ChatMessageBubble short text has equal top and bottom gaps', (
    tester,
  ) async {
    final msg = _msg(id: 10, senderId: 1);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(),
              ),
              ChangeNotifierProvider<MessagingProvider>(
                create: (_) => MessagingProvider(),
              ),
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: SizedBox(
              width: 390,
              height: 600,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();

    final highlight =
        tester.renderObject(
              find.byKey(const Key('context-menu-bubble-highlight')),
            )
            as RenderBox;
    final emoji =
        tester.renderObject(find.byKey(const Key('context-menu-emoji-bar')))
            as RenderBox;
    final panel =
        tester.renderObject(find.byKey(const Key('context-menu-action-panel')))
            as RenderBox;

    final highlightTop = highlight.localToGlobal(Offset.zero).dy;
    final layoutHeight = highlight.size.height;
    final highlightVisualTop = bubbleHighlightVisualTop(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final highlightVisualBottom = bubbleHighlightVisualBottom(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final emojiBottom = emoji.localToGlobal(Offset.zero).dy + emoji.size.height;
    final panelTop = panel.localToGlobal(Offset.zero).dy;

    final topGap = highlightVisualTop - emojiBottom;
    final bottomGap = panelTop - highlightVisualBottom;

    expect(topGap, closeTo(kMessageContextMenuOverlayGap, 1.0));
    expect(bottomGap, closeTo(kMessageContextMenuOverlayGap, 1.0));
    expect(topGap, closeTo(bottomGap, 1.0));
  });

  testWidgets('ChatMessageBubble image message has equal top and bottom gaps', (
    tester,
  ) async {
    final msg = _imageMsg(id: 11, senderId: 1);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(),
              ),
              ChangeNotifierProvider<MessagingProvider>(
                create: (_) => MessagingProvider(),
              ),
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: SizedBox(
              width: 390,
              height: 700,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();

    final highlight =
        tester.renderObject(
              find.byKey(const Key('context-menu-bubble-highlight')),
            )
            as RenderBox;
    final emoji =
        tester.renderObject(find.byKey(const Key('context-menu-emoji-bar')))
            as RenderBox;
    final panel =
        tester.renderObject(find.byKey(const Key('context-menu-action-panel')))
            as RenderBox;

    final highlightTop = highlight.localToGlobal(Offset.zero).dy;
    final layoutHeight = highlight.size.height;
    expect(layoutHeight, closeTo(kMessageMediaBubbleHeight, 1.0));

    final highlightVisualTop = bubbleHighlightVisualTop(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final highlightVisualBottom = bubbleHighlightVisualBottom(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final emojiBottom = emoji.localToGlobal(Offset.zero).dy + emoji.size.height;
    final panelTop = panel.localToGlobal(Offset.zero).dy;

    final topGap = highlightVisualTop - emojiBottom;
    final bottomGap = panelTop - highlightVisualBottom;

    expect(topGap, closeTo(kMessageContextMenuOverlayGap, 2.0));
    expect(bottomGap, closeTo(kMessageContextMenuOverlayGap, 2.0));
    expect(topGap, closeTo(bottomGap, 2.0));
    expect(panelTop, greaterThan(highlightVisualBottom));
  });

  testWidgets('ChatMessageBubble long-press opens context menu overlay', (
    tester,
  ) async {
    final msg = _msg(id: 10, senderId: 1, createdAt: DateTime.now());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(),
              ),
              ChangeNotifierProvider<MessagingProvider>(
                create: (_) => MessagingProvider(),
              ),
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: SizedBox(
              width: 390,
              height: 600,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();

    expect(find.text(l10n.messageActionReply), findsOneWidget);
    expect(find.text(l10n.messageActionEdit), findsOneWidget);
    expect(find.text(l10n.messageActionPin), findsOneWidget);
    expect(find.text(l10n.messageActionDelete), findsOneWidget);
    expect(find.byKey(const Key('context-menu-scrim')), findsOneWidget);
    expect(find.byType(MessageContextMenuBubbleHighlight), findsOneWidget);
  });

  testWidgets('long-press entry shows four action labels and blur scrim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: _msg(id: 10, senderId: 1),
                      bubbleRenderBox: box,
                      isMine: true,
                      currentUserId: 1,
                      onReply: () {},
                      onEdit: () {},
                      onPin: () {},
                      onDelete: () {},
                      onReaction: (emoji, alreadyReacted) {},
                      bubblePreviewBuilder: (_) =>
                          MessageContextMenuBubbleHighlight(
                            message: _msg(id: 10, senderId: 1),
                            isMine: true,
                            maxWidth: 120,
                          ),
                    );
                  },
                  child: const Text('bubble'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('bubble'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionReply), findsOneWidget);
    expect(find.text(l10n.messageActionEdit), findsOneWidget);
    expect(find.text(l10n.messageActionPin), findsOneWidget);
    expect(find.text(l10n.messageActionDelete), findsOneWidget);
    expect(find.byKey(const Key('context-menu-scrim')), findsOneWidget);
  });

  Future<void> pumpBubble(WidgetTester tester, MessageModel msg) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(),
              ),
              ChangeNotifierProvider<MessagingProvider>(
                create: (_) => MessagingProvider(),
              ),
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: SizedBox(
              width: 390,
              height: 600,
              child: ChatMessageBubble(message: msg, isMine: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDirectContextMenu(
    WidgetTester tester, {
    MessageModel? message,
    int currentUserId = 1,
    bool isMine = true,
    GlobalKey? bubbleKey,
    Size bubbleSize = const Size(160, 48),
    MessageContextMenuBubbleBuilder? bubblePreviewBuilder,
    void Function(String emoji, bool alreadyReacted)? onReaction,
  }) async {
    final effectiveBubbleKey = bubbleKey ?? GlobalKey();
    final menuMessage = message ?? _msg(id: 10, senderId: 1);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box =
                        effectiveBubbleKey.currentContext!.findRenderObject()
                            as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: menuMessage,
                      bubbleRenderBox: box,
                      isMine: isMine,
                      currentUserId: currentUserId,
                      onReply: () {},
                      onPin: () {},
                      onDelete: () {},
                      onReaction: onReaction ?? (emoji, alreadyReacted) {},
                      bubblePreviewBuilder: bubblePreviewBuilder,
                    );
                  },
                  child: SizedBox(
                    key: effectiveBubbleKey,
                    width: bubbleSize.width,
                    height: bubbleSize.height,
                    child: const Center(child: Text('bubble')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('bubble'));
    await tester.pumpAndSettle();
  }

  testWidgets('chevron expands picker in place, hiding row and action panel', (
    tester,
  ) async {
    await pumpDirectContextMenu(tester);

    final expand = find.byKey(const ValueKey('context-menu-expand-reactions'));
    expect(expand, findsOneWidget);
    expect(find.text(l10n.messageActionReply), findsOneWidget);

    await tester.tap(expand);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('context-menu-expanded-reaction-picker')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(l10n.emojiPickerSemantics), findsOneWidget);
    // Telegram parity: row and action panel unmount while expanded.
    expect(find.byKey(const Key('context-menu-emoji-bar')), findsNothing);
    expect(find.text(l10n.messageActionReply), findsNothing);
    // Scrim (and the bubble underneath) stay.
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('expanded picker geometry matches the layout function', (
    tester,
  ) async {
    await pumpDirectContextMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('context-menu-expand-reactions')),
    );
    await tester.pumpAndSettle();

    final panel = find.byKey(
      const Key('context-menu-expanded-reaction-picker'),
    );
    final positioned = tester.widget<Positioned>(panel);
    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(positioned.width, math.min(screenWidth - 32, 360));
    expect(positioned.height, lessThanOrEqualTo(420));
    expect(
      positioned.left,
      greaterThanOrEqualTo(kExpandedReactionPickerMargin),
    );
  });

  testWidgets('expanded picker recomputes geometry from live keyboard insets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);

    final bubbleKey = GlobalKey();
    await pumpDirectContextMenu(tester, bubbleKey: bubbleKey);
    await tester.tap(
      find.byKey(const ValueKey('context-menu-expand-reactions')),
    );
    await tester.pumpAndSettle();

    Positioned positioned() => tester.widget<Positioned>(
      find.byKey(const Key('context-menu-expanded-reaction-picker')),
    );

    final bubbleRect = bubbleRectForContextMenuLayout(
      tester.getRect(find.byKey(bubbleKey)),
    );
    final viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    final viewPadding = MediaQuery.paddingOf(
      tester.element(find.byType(Scaffold)),
    );
    final baseMenuLayout = computeMessageContextMenuLayout(
      bubbleRect: bubbleRect,
      viewPadding: viewPadding,
      viewSize: viewSize,
      keyboardBottom: 0,
      panelHeight: kMessageActionPanelHeightEstimate,
    );
    final basePickerLayout = computeExpandedReactionPickerLayout(
      bubbleRect: bubbleRect,
      viewPadding: viewPadding,
      viewSize: viewSize,
      keyboardBottom: 0,
      isMine: true,
      bubbleHighlightTop: baseMenuLayout.bubbleHighlightTop,
      previewHeight: baseMenuLayout.previewHeight,
    );

    expect(positioned().top, closeTo(basePickerLayout.top, 0.001));
    expect(positioned().height, closeTo(basePickerLayout.height, 0.001));

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    final insetMenuLayout = computeMessageContextMenuLayout(
      bubbleRect: bubbleRect,
      viewPadding: viewPadding,
      viewSize: viewSize,
      keyboardBottom: 320,
      panelHeight: kMessageActionPanelHeightEstimate,
    );
    final insetPickerLayout = computeExpandedReactionPickerLayout(
      bubbleRect: bubbleRect,
      viewPadding: viewPadding,
      viewSize: viewSize,
      keyboardBottom: 320,
      isMine: true,
      bubbleHighlightTop: insetMenuLayout.bubbleHighlightTop,
      previewHeight: insetMenuLayout.previewHeight,
    );
    final insetPositioned = positioned();

    expect(insetPositioned.top, closeTo(insetPickerLayout.top, 0.001));
    expect(insetPositioned.height, closeTo(insetPickerLayout.height, 0.001));
    expect(
      insetPositioned.top! + insetPositioned.height!,
      lessThanOrEqualTo(800 - 320),
    );

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();

    expect(positioned().top, closeTo(basePickerLayout.top, 0.001));
    expect(positioned().height, closeTo(basePickerLayout.height, 0.001));

    // Every inset change feeds EmojiPicker a new Config (the picker height is
    // derived from the keyboard inset), so didUpdateWidget reloads the recent
    // emojis. emoji_picker_flutter 4.5.3 memoizes that read behind
    // `Future(() async {...})`, and a bare `Future(...)` schedules a real
    // zero-duration Timer where 4.4.0's plain `async` body only queued
    // microtasks. The last inset pump above leaves that timer unfired and the
    // binding asserts `!timersPending` at teardown; settling drains the timer
    // and the setState frame that follows it. A single extra `pump()` is NOT
    // enough — verified. Nothing product-side changed: the read is memoized
    // (4.4.0 hit SharedPreferences on every config change, 4.5.3 hits it once).
    await tester.pumpAndSettle();
  });

  testWidgets(
    'expanded picker keeps bubble highlight while hiding quick row and actions',
    (tester) async {
      final message = _msg(id: 10, senderId: 1);
      await pumpDirectContextMenu(
        tester,
        message: message,
        bubblePreviewBuilder: (_) => MessageContextMenuBubbleHighlight(
          message: message,
          isMine: true,
          maxWidth: 160,
        ),
      );

      expect(
        find.byKey(const Key('context-menu-bubble-highlight')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('context-menu-emoji-bar')), findsOneWidget);
      expect(
        find.byKey(const Key('context-menu-action-panel')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('context-menu-expand-reactions')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('context-menu-expanded-reaction-picker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('context-menu-bubble-highlight')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('context-menu-emoji-bar')), findsNothing);
      expect(find.byKey(const Key('context-menu-action-panel')), findsNothing);
    },
  );

  testWidgets('outside tap dismisses the expanded picker overlay', (
    tester,
  ) async {
    await pumpDirectContextMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('context-menu-expand-reactions')),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('context-menu-expanded-reaction-picker')),
      findsNothing,
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets(
    'emoji picker selection invokes reaction callback and dismisses menu',
    (tester) async {
      final calls = <({String emoji, bool alreadyReacted})>[];
      final message = _msg(id: 10, senderId: 1).copyWith(
        reactions: const {
          '🔥': [1],
        },
      );

      await pumpDirectContextMenu(
        tester,
        message: message,
        currentUserId: 1,
        onReaction: (emoji, alreadyReacted) =>
            calls.add((emoji: emoji, alreadyReacted: alreadyReacted)),
      );

      await tester.tap(
        find.byKey(const ValueKey('context-menu-expand-reactions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-picker-option-🔥')));
      await tester.pumpAndSettle();

      expect(calls, [(emoji: '🔥', alreadyReacted: true)]);
      expect(find.bySemanticsLabel(l10n.emojiPickerSemantics), findsNothing);
    },
  );

  testWidgets('system back closes the context menu instead of the route', (
    tester,
  ) async {
    await pumpDirectContextMenu(tester);
    expect(find.text(l10n.messageActionReply), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final handled = await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(handled, isTrue); // consumed by the overlay's PopEntry
    expect(find.text(l10n.messageActionReply), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('bubble'), findsOneWidget); // chat screen intact
  });

  testWidgets('system back closes the expanded picker overlay too', (
    tester,
  ) async {
    await pumpDirectContextMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('context-menu-expand-reactions')),
    );
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('context-menu-expanded-reaction-picker')),
      findsNothing,
    );
    expect(find.text('bubble'), findsOneWidget);
  });

  testWidgets(
    'selected quick reaction is announced as selected for current user',
    (tester) async {
      final message = _msg(id: 10, senderId: 1).copyWith(
        reactions: const {
          '🔥': [1],
        },
      );

      await pumpDirectContextMenu(tester, message: message, currentUserId: 1);

      expect(
        find.bySemanticsLabel(
          l10n.messageReactionSemantics('🔥', l10n.messageReactionSelected),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          l10n.messageReactionSemantics('👍', l10n.messageReactionNotSelected),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Copy on text bubble writes clipboard, dismisses menu, confirms', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpBubble(tester, _msg(id: 10, senderId: 1));
    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionCopy), findsOneWidget);

    await tester.tap(find.text(l10n.messageActionCopy));
    await tester.pump();

    final setData = calls
        .where((c) => c.method == 'Clipboard.setData')
        .toList();
    expect(setData, hasLength(1));
    expect((setData.single.arguments as Map)['text'], 'hello');
    expect(find.text(l10n.messageActionReply), findsNothing); // menu dismissed
    expect(find.text(l10n.snackbarMessageCopied), findsOneWidget); // top snackbar
    // Flush showTopSnackBar's 2500ms removal future so no pending timers leak.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('image bubble context menu has no Copy row', (tester) async {
    await pumpBubble(tester, _imageMsg(id: 11, senderId: 1));
    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionReply), findsOneWidget);
    expect(find.text(l10n.messageActionCopy), findsNothing);
  });

  testWidgets('decryption-failed text bubble has no Copy row', (tester) async {
    await pumpBubble(
      tester,
      _msg(id: 12, senderId: 1).copyWith(content: '[Decryption failed]'),
    );
    await tester.longPress(find.byType(MessageSwipeWrapper));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionReply), findsOneWidget);
    expect(find.text(l10n.messageActionCopy), findsNothing);
  });

  testWidgets('copy row appears when onCopy is provided', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: _msg(id: 10, senderId: 1),
                      bubbleRenderBox: box,
                      isMine: true,
                      currentUserId: 1,
                      onReply: () {},
                      onPin: () {},
                      onDelete: () {},
                      onCopy: () {},
                      onReaction: (emoji, alreadyReacted) {},
                    );
                  },
                  child: const Text('bubble'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('bubble'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionCopy), findsOneWidget);
    expect(find.text(l10n.messageActionReply), findsOneWidget);
  });

  testWidgets('copy row absent when onCopy is omitted', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: _msg(id: 10, senderId: 1),
                      bubbleRenderBox: box,
                      isMine: true,
                      currentUserId: 1,
                      onReply: () {},
                      onPin: () {},
                      onDelete: () {},
                      onReaction: (emoji, alreadyReacted) {},
                    );
                  },
                  child: const Text('bubble'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('bubble'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messageActionCopy), findsNothing);
    expect(find.text(l10n.messageActionReply), findsOneWidget);
  });

  testWidgets('huge message: menu fully on-screen and Copy tappable', (
    tester,
  ) async {
    final bubbleKey = GlobalKey();
    var copied = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box =
                        bubbleKey.currentContext!.findRenderObject()
                            as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: _msg(id: 10, senderId: 1),
                      bubbleRenderBox: box,
                      isMine: false,
                      currentUserId: 1,
                      onReply: () {},
                      onPin: () {},
                      onDelete: () {},
                      onCopy: () => copied = true,
                      onReaction: (emoji, alreadyReacted) {},
                    );
                  },
                  // Far taller than the 600px test viewport.
                  child: SizedBox(
                    key: bubbleKey,
                    width: 200,
                    height: 2000,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Center positions the 2000px box from y=-700; press a visible point.
    await tester.longPressAt(const Offset(400, 100));
    await tester.pumpAndSettle();

    final viewHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final panel =
        tester.renderObject(find.byKey(const Key('context-menu-action-panel')))
            as RenderBox;
    final emoji =
        tester.renderObject(find.byKey(const Key('context-menu-emoji-bar')))
            as RenderBox;

    final panelTop = panel.localToGlobal(Offset.zero).dy;
    expect(panelTop, greaterThanOrEqualTo(0));
    expect(panelTop + panel.size.height, lessThanOrEqualTo(viewHeight));
    expect(emoji.localToGlobal(Offset.zero).dy, greaterThanOrEqualTo(0));

    await tester.tap(find.text(l10n.messageActionCopy));
    await tester.pumpAndSettle();
    expect(copied, isTrue);
    expect(find.text(l10n.messageActionReply), findsNothing); // menu dismissed
  });

  testWidgets('rendered gaps match overlay constant with scale overflow', (
    tester,
  ) async {
    final bubbleKey = GlobalKey();
    final msg = _msg(id: 10, senderId: 1);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: GestureDetector(
                onLongPress: () {
                  final box =
                      bubbleKey.currentContext!.findRenderObject() as RenderBox;
                  openMessageContextMenu(
                    context: ctx,
                    message: msg,
                    bubbleRenderBox: box,
                    isMine: true,
                    currentUserId: 1,
                    onReply: () {},
                    onPin: () {},
                    onDelete: () {},
                    onReaction: (_, _) {},
                    bubblePreviewBuilder: (_) =>
                        MessageContextMenuBubbleHighlight(
                          message: msg,
                          isMine: true,
                          maxWidth: 200,
                        ),
                  );
                },
                child: SizedBox(
                  key: bubbleKey,
                  width: 200,
                  height: 58,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byKey(bubbleKey));
    await tester.pumpAndSettle();

    final highlight =
        tester.renderObject(
              find.byKey(const Key('context-menu-bubble-highlight')),
            )
            as RenderBox;
    final emoji =
        tester.renderObject(find.byKey(const Key('context-menu-emoji-bar')))
            as RenderBox;
    final panel =
        tester.renderObject(find.byKey(const Key('context-menu-action-panel')))
            as RenderBox;

    final layoutHeight = 58 - kContextMenuAnchorBottomMargin;
    final highlightTop = highlight.localToGlobal(Offset.zero).dy;
    final highlightVisualBottom = bubbleHighlightVisualBottom(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final emojiBottom = emoji.localToGlobal(Offset.zero).dy + emoji.size.height;
    final panelTop = panel.localToGlobal(Offset.zero).dy;

    final highlightVisualTop = bubbleHighlightVisualTop(
      bubbleHighlightTop: highlightTop,
      layoutBubbleHeight: layoutHeight,
    );
    final topGap = highlightVisualTop - emojiBottom;
    final bottomGap = panelTop - highlightVisualBottom;

    expect(topGap, closeTo(kMessageContextMenuOverlayGap, 1.0));
    expect(bottomGap, closeTo(kMessageContextMenuOverlayGap, 1.0));
    expect(topGap, closeTo(bottomGap, 1.0));
    expect(emoji.size.height, kMessageContextMenuEmojiRowHeight);

    final emojiGlobal = emoji.localToGlobal(Offset.zero);
    final emojiTrailing = emojiGlobal.dx + emoji.size.width;
    final highlightTrailing =
        highlight.localToGlobal(Offset.zero).dx + highlight.size.width;
    expect(emojiTrailing, closeTo(highlightTrailing, 1.0));
  });

  // A3-MSG-B-06: a message that expires or is deleted while its menu is open
  // must not stay readable (or copyable) behind the scrim.
  testWidgets('the menu closes when its message leaves the list', (
    tester,
  ) async {
    final listRows = ValueNotifier<bool>(false);
    addTearDown(listRows.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: RpgTheme.themeDataLight,
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsProvider>(
                create: (_) => SettingsProvider(),
              ),
            ],
            child: Builder(
              builder: (ctx) => Center(
                child: GestureDetector(
                  onLongPress: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    openMessageContextMenu(
                      context: ctx,
                      message: _msg(id: 10, senderId: 1),
                      bubbleRenderBox: box,
                      isMine: true,
                      currentUserId: 1,
                      onReply: () {},
                      onPin: () {},
                      onDelete: () {},
                      onReaction: (emoji, alreadyReacted) {},
                      goneWatch: (
                        changes: listRows,
                        isGone: () => listRows.value,
                      ),
                    );
                  },
                  child: const Text('bubble'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('bubble'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-menu-scrim')), findsOneWidget);

    listRows.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-menu-scrim')), findsNothing);
  });
}
