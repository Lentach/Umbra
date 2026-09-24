import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../emoji/fireplace_emoji_picker.dart';
import '../../models/message_model.dart';
import '../../utils/jumbo_emoji.dart';
import '../../utils/message_ids.dart';
import '../top_snackbar.dart';
import 'context_menu_bubble_anchor.dart';
import 'message_action_panel.dart';
import '../glass/glass_surface.dart';

OverlayEntry? _activeMessageContextMenu;

/// Consumes system back while the context menu is open (collapsed or
/// expanded): back closes the menu instead of popping the chat route.
/// Registered on the caller's [ModalRoute] — the same mechanism [PopScope]
/// uses — because a [WidgetsBindingObserver] would be consulted after
/// [WidgetsApp]'s own observer already popped the route.
class _ContextMenuPopEntry implements PopEntry<Object?> {
  final ValueNotifier<bool> _canPop = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) return;
    Future<void>.microtask(_dismissMessageContextMenu);
  }

  @override
  void onPopInvoked(bool didPop) {}

  void dispose() => _canPop.dispose();
}

_ContextMenuPopEntry? _contextMenuPopEntry;
ModalRoute<Object?>? _contextMenuPopRoute;

const _kReactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

/// Estimated height of [MessageActionPanel] (4 base rows × ~46dp; the Copy row
/// adds [kMessageActionPanelRowHeightEstimate]); used for overlay layout.
const kMessageActionPanelHeightEstimate = 184.0;

/// Height of one additional [MessageActionPanel] row (Copy); added to
/// [kMessageActionPanelHeightEstimate] when the row is shown.
const kMessageActionPanelRowHeightEstimate = 46.0;

/// Estimated height of the reaction emoji pill row; keep in sync with overlay UI.
const kMessageContextMenuEmojiRowHeight = 44.0;

/// Vertical gap between emoji row, bubble highlight, and action panel.
const kMessageContextMenuOverlayGap = 12.0;

const _kComposerClearance = 88.0;
const _kScrimBlurSigma = 12.0;
const _kElevatedBubbleScale = 1.02;

@visibleForTesting
double bubbleHighlightScaleOverflow(double bubbleHeight) =>
    bubbleHeight * (_kElevatedBubbleScale - 1) / 2;

/// Anchor [RenderBox] includes [kContextMenuAnchorBottomMargin]; layout uses the
/// painted bubble footprint only.
@visibleForTesting
Rect bubbleRectForContextMenuLayout(Rect globalAnchorRect) {
  return Rect.fromLTWH(
    globalAnchorRect.left,
    globalAnchorRect.top,
    globalAnchorRect.width,
    math.max(0, globalAnchorRect.height - kContextMenuAnchorBottomMargin),
  );
}

/// Visual top of the scaled highlight replica (global coordinates).
@visibleForTesting
double bubbleHighlightVisualTop({
  required double bubbleHighlightTop,
  required double layoutBubbleHeight,
}) => bubbleHighlightTop - bubbleHighlightScaleOverflow(layoutBubbleHeight);

/// Visual bottom of the scaled highlight replica (global coordinates).
@visibleForTesting
double bubbleHighlightVisualBottom({
  required double bubbleHighlightTop,
  required double layoutBubbleHeight,
}) =>
    bubbleHighlightTop +
    layoutBubbleHeight +
    bubbleHighlightScaleOverflow(layoutBubbleHeight);

/// Gap from scaled highlight bottom to action panel top.
@visibleForTesting
double messageContextMenuPanelTop({
  required double bubbleHighlightTop,
  required double layoutBubbleHeight,
}) =>
    bubbleHighlightVisualBottom(
      bubbleHighlightTop: bubbleHighlightTop,
      layoutBubbleHeight: layoutBubbleHeight,
    ) +
    kMessageContextMenuOverlayGap;

typedef _ContextMenuStackLayout = ({
  double emojiTop,
  double panelTop,
  double bubbleHighlightTop,
});

/// Telegram layout around the bubble: emoji row (top) → bubble → panel (bottom).
///
/// All three elements share one anchor rect ([bubbleRect]) with equal vertical
/// gaps. When the message sits near the composer, the whole stack shifts up so
/// the action panel stays fully visible. If there is still not enough room above
/// the bubble for the emoji row, the order becomes emoji → panel → bubble.
///
/// [panelAboveBubble] is a test/diagnostic flag only — production overlay code
/// does not branch on it.
@visibleForTesting
({
  double emojiTop,
  double panelTop,
  double bubbleHighlightTop,
  bool panelAboveBubble,
  double previewHeight,
})
computeMessageContextMenuLayout({
  required Rect bubbleRect,
  required EdgeInsets viewPadding,
  required Size viewSize,
  required double keyboardBottom,
  double composerClearance = _kComposerClearance,
  double panelHeight = kMessageActionPanelHeightEstimate,
}) {
  const emojiHeight = kMessageContextMenuEmojiRowHeight;
  const gap = kMessageContextMenuOverlayGap;
  final minTop = viewPadding.top;
  final maxContentBottom = viewSize.height - keyboardBottom - composerClearance;

  // Bubbles taller than the space left between emoji bar and panel can never
  // fit; the legacy flow would push the panel above the screen. Clamp the
  // preview height (the overlay crops the replica to it) and center the
  // emoji → preview → panel stack vertically instead.
  final availableForBubble =
      maxContentBottom - minTop - emojiHeight - panelHeight - 2 * gap;
  final maxPreviewHeight = math.max(
    48.0,
    availableForBubble / _kElevatedBubbleScale,
  );
  if (bubbleRect.height > maxPreviewHeight) {
    final previewHeight = maxPreviewHeight;
    final scalePad = bubbleHighlightScaleOverflow(previewHeight);
    final totalHeight =
        emojiHeight + gap + previewHeight + 2 * scalePad + gap + panelHeight;
    final emojiTop = math.max(
      minTop,
      minTop + (maxContentBottom - minTop - totalHeight) / 2,
    );
    final bubbleTop = emojiTop + emojiHeight + gap + scalePad;
    return (
      emojiTop: emojiTop,
      bubbleHighlightTop: bubbleTop,
      panelTop: bubbleTop + previewHeight + scalePad + gap,
      panelAboveBubble: false,
      previewHeight: previewHeight,
    );
  }

  final bubbleHeight = bubbleRect.height;
  final scaleOverflow = bubbleHighlightScaleOverflow(bubbleHeight);

  _ContextMenuStackLayout standardStack(double bubbleTop) {
    final panelTopValue = messageContextMenuPanelTop(
      bubbleHighlightTop: bubbleTop,
      layoutBubbleHeight: bubbleHeight,
    );
    return (
      bubbleHighlightTop: bubbleTop,
      emojiTop:
          bubbleHighlightVisualTop(
            bubbleHighlightTop: bubbleTop,
            layoutBubbleHeight: bubbleHeight,
          ) -
          emojiHeight -
          gap,
      panelTop: panelTopValue,
    );
  }

  _ContextMenuStackLayout invertedStack(double emojiTopValue) {
    final panelTopValue = emojiTopValue + emojiHeight + gap;
    return (
      emojiTop: emojiTopValue,
      panelTop: panelTopValue,
      bubbleHighlightTop: panelTopValue + panelHeight + gap,
    );
  }

  double bubbleVisualBottom(_ContextMenuStackLayout stack) =>
      stack.bubbleHighlightTop + bubbleHeight + scaleOverflow;

  var stack = standardStack(bubbleRect.top);
  var panelAboveBubble = false;

  final panelBottom = stack.panelTop + panelHeight;
  if (panelBottom > maxContentBottom) {
    stack = standardStack(bubbleRect.top - (panelBottom - maxContentBottom));
  }

  if (stack.emojiTop < minTop) {
    panelAboveBubble = true;
    stack = invertedStack(minTop);

    final overflow = bubbleVisualBottom(stack) - maxContentBottom;
    if (overflow > 0) {
      stack = invertedStack(minTop - overflow);
      if (stack.emojiTop < minTop) {
        final bubbleTop = maxContentBottom - bubbleHeight - scaleOverflow;
        final panelTopValue = bubbleTop - gap - panelHeight;
        final emojiTopValue = panelTopValue - gap - emojiHeight;
        stack = (
          emojiTop: emojiTopValue < minTop ? minTop : emojiTopValue,
          panelTop: panelTopValue,
          bubbleHighlightTop: bubbleTop,
        );
      }
    }
  }

  return (
    emojiTop: stack.emojiTop,
    panelTop: stack.panelTop,
    bubbleHighlightTop: stack.bubbleHighlightTop,
    panelAboveBubble: panelAboveBubble,
    previewHeight: bubbleHeight,
  );
}

@visibleForTesting
double computeEmojiBarLeft({
  required Rect bubbleRect,
  required EdgeInsets viewPadding,
  required Size viewSize,
  required bool isMine,
  required double emojiBarWidth,
}) {
  final rawLeft = isMine ? bubbleRect.right - emojiBarWidth : bubbleRect.left;
  return rawLeft.clamp(
    viewPadding.left,
    viewSize.width - viewPadding.right - emojiBarWidth,
  );
}

@visibleForTesting
double computePanelLeft({
  required Rect bubbleRect,
  required EdgeInsets viewPadding,
  required Size viewSize,
  required bool isMine,
  required double panelWidth,
}) {
  final rawLeft = isMine ? bubbleRect.right - panelWidth : bubbleRect.left;
  return rawLeft.clamp(
    viewPadding.left,
    viewSize.width - viewPadding.right - panelWidth,
  );
}

/// Max size and screen margin of the in-place expanded reaction picker.
const kExpandedReactionPickerMaxHeight = 420.0;
const kExpandedReactionPickerMaxWidth = 360.0;
const kExpandedReactionPickerMargin = 16.0;
const kExpandedReactionPickerMinHeight = 52.0;

/// Telegram-style in-place expansion: the panel replaces the emoji row and
/// action panel in the larger free region above or below the (possibly
/// clamped) bubble highlight. It never covers the bubble, never crosses the
/// 16px screen margins, and never sits under the keyboard or home indicator.
///
/// [bubbleHighlightTop] and [previewHeight] come from
/// [computeMessageContextMenuLayout] so huge-message clamped previews are
/// respected. [below] is also the entrance-animation anchor side.
@visibleForTesting
({double left, double top, double width, double height, bool below})
computeExpandedReactionPickerLayout({
  required Rect bubbleRect,
  required EdgeInsets viewPadding,
  required Size viewSize,
  required double keyboardBottom,
  required bool isMine,
  required double bubbleHighlightTop,
  required double previewHeight,
}) {
  const gap = kMessageContextMenuOverlayGap;
  const margin = kExpandedReactionPickerMargin;
  final minTop = viewPadding.top + 8;
  final maxBottom =
      viewSize.height - math.max(keyboardBottom, viewPadding.bottom) - margin;
  final highlightTop = bubbleHighlightVisualTop(
    bubbleHighlightTop: bubbleHighlightTop,
    layoutBubbleHeight: previewHeight,
  );
  final highlightBottom = bubbleHighlightVisualBottom(
    bubbleHighlightTop: bubbleHighlightTop,
    layoutBubbleHeight: previewHeight,
  );
  final above = highlightTop - gap - minTop;
  final below = maxBottom - (highlightBottom + gap);
  final placeBelow = below >= above;
  final region = math.max(placeBelow ? below : above, 0.0);
  final height = math.min(
    kExpandedReactionPickerMaxHeight,
    math.max(kExpandedReactionPickerMinHeight, region),
  );
  final top = placeBelow ? highlightBottom + gap : highlightTop - gap - height;
  final width = math.min(
    viewSize.width - 2 * margin,
    kExpandedReactionPickerMaxWidth,
  );
  final leftRaw = isMine ? bubbleRect.right - width : bubbleRect.left;
  final left = math.min(
    math.max(leftRaw, margin),
    viewSize.width - margin - width,
  );
  return (
    left: left,
    top: top,
    width: width,
    height: height,
    below: placeBelow,
  );
}

void _dismissMessageContextMenu() {
  final entry = _contextMenuPopEntry;
  if (entry != null) {
    _contextMenuPopRoute?.unregisterPopEntry(entry);
    entry.dispose();
    _contextMenuPopEntry = null;
    _contextMenuPopRoute = null;
  }
  _activeMessageContextMenu?.remove();
  _activeMessageContextMenu = null;
}

void dismissMessageContextMenu() => _dismissMessageContextMenu();

typedef MessageContextMenuBubbleBuilder =
    Widget Function(BuildContext overlayContext);

void openMessageContextMenu({
  required BuildContext context,
  required MessageModel message,
  required RenderBox bubbleRenderBox,
  required bool isMine,
  required int? currentUserId,
  required VoidCallback onReply,
  required VoidCallback onPin,
  required VoidCallback onDelete,
  VoidCallback? onCopy,
  VoidCallback? onEdit,
  required void Function(String emoji, bool alreadyReacted) onReaction,
  MessageContextMenuBubbleBuilder? bubblePreviewBuilder,
}) {
  _dismissMessageContextMenu();
  final overlay = Overlay.of(context);
  final l10n = AppLocalizations.of(context);
  final anchorRect =
      bubbleRenderBox.localToGlobal(Offset.zero) & bubbleRenderBox.size;
  final layoutRect = bubbleRectForContextMenuLayout(anchorRect);
  // Read MediaQuery from the overlay build context below, not here. Keyboard
  // and visual-viewport metrics can change while the overlay is open on iOS/PWA.
  final canPinOrDeleteForEveryone = isServerMessageId(message.id);
  final bubblePreview = bubblePreviewBuilder?.call(context);
  var pickerExpanded = false;

  _activeMessageContextMenu = OverlayEntry(
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setOverlayState) {
          final viewPadding = MediaQuery.paddingOf(ctx);
          final viewSize = MediaQuery.sizeOf(ctx);
          final keyboardBottom = MediaQuery.viewInsetsOf(ctx).bottom;
          final layout = computeMessageContextMenuLayout(
            bubbleRect: layoutRect,
            viewPadding: viewPadding,
            viewSize: viewSize,
            keyboardBottom: keyboardBottom,
            panelHeight:
                kMessageActionPanelHeightEstimate +
                (onCopy != null ? kMessageActionPanelRowHeightEstimate : 0),
          );
          final bubbleAlign = isMine
              ? Alignment.centerRight
              : Alignment.centerLeft;
          void selectPickerEmoji(String emoji) {
            final alreadyReacted =
                currentUserId != null &&
                (message.reactions[emoji]?.contains(currentUserId) ?? false);
            onReaction(emoji, alreadyReacted);
            dismissMessageContextMenu();
          }

          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: dismissMessageContextMenu,
                  behavior: HitTestBehavior.opaque,
                  child: ClipRect(
                    child: BackdropFilter(
                      key: const Key('context-menu-scrim'),
                      filter: ImageFilter.blur(
                        sigmaX: _kScrimBlurSigma,
                        sigmaY: _kScrimBlurSigma,
                      ),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ),
              if (bubblePreview != null)
                Positioned(
                  key: const Key('context-menu-bubble-highlight'),
                  left: layoutRect.left,
                  top: layout.bubbleHighlightTop,
                  width: layoutRect.width,
                  child: IgnorePointer(
                    child: Transform.scale(
                      scale: _kElevatedBubbleScale,
                      alignment: Alignment.center,
                      child: layout.previewHeight < layoutRect.height - 0.5
                          // Huge bubble: crop the replica top-aligned to the
                          // clamped height with a fade at the cut edge (the full
                          // message stays visible under the blur scrim).
                          ? SizedBox(
                              width: layoutRect.width,
                              height: layout.previewHeight,
                              child: ShaderMask(
                                shaderCallback: (rect) => const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white,
                                    Colors.white,
                                    Colors.transparent,
                                  ],
                                  stops: [0.0, 0.85, 1.0],
                                ).createShader(rect),
                                blendMode: BlendMode.dstIn,
                                child: ClipRect(
                                  child: OverflowBox(
                                    alignment: Alignment.topCenter,
                                    minHeight: layoutRect.height,
                                    maxHeight: layoutRect.height,
                                    child: SizedBox(
                                      width: layoutRect.width,
                                      height: layoutRect.height,
                                      child: bubblePreview,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : SizedBox(
                              width: layoutRect.width,
                              height: layoutRect.height,
                              child: bubblePreview,
                            ),
                    ),
                  ),
                ),
              if (!pickerExpanded)
                Positioned(
                  key: const Key('context-menu-emoji-bar'),
                  top: layout.emojiTop,
                  left: isMine ? null : layoutRect.left,
                  right: isMine ? viewSize.width - layoutRect.right : null,
                  child: _ContextMenuReactionEmojiBar(
                    message: message,
                    currentUserId: currentUserId,
                    onReaction: onReaction,
                    onExpand: () => setOverlayState(() {
                      pickerExpanded = true;
                    }),
                  ),
                ),
              if (!pickerExpanded)
                Positioned(
                  key: const Key('context-menu-action-panel'),
                  top: layout.panelTop,
                  left: layoutRect.left,
                  width: layoutRect.width,
                  child: Align(
                    alignment: bubbleAlign,
                    child: MessageActionPanel(
                      isMine: isMine,
                      canPinOrDeleteForEveryone: canPinOrDeleteForEveryone,
                      onReply: () {
                        dismissMessageContextMenu();
                        onReply();
                      },
                      onCopy: onCopy == null
                          ? null
                          : () {
                              dismissMessageContextMenu();
                              onCopy();
                            },
                      onEdit: onEdit == null
                          ? null
                          : () {
                              dismissMessageContextMenu();
                              onEdit();
                            },
                      onPin: () {
                        dismissMessageContextMenu();
                        if (!isServerMessageId(message.id)) {
                          showTopSnackBar(
                            context,
                            l10n.messagePinRequiresSentMessage,
                          );
                        } else {
                          onPin();
                        }
                      },
                      onDelete: () {
                        dismissMessageContextMenu();
                        onDelete();
                      },
                    ),
                  ),
                ),
              if (pickerExpanded)
                () {
                  final picker = computeExpandedReactionPickerLayout(
                    bubbleRect: layoutRect,
                    viewPadding: viewPadding,
                    viewSize: viewSize,
                    keyboardBottom: keyboardBottom,
                    isMine: isMine,
                    bubbleHighlightTop: layout.bubbleHighlightTop,
                    previewHeight: layout.previewHeight,
                  );
                  return Positioned(
                    key: const Key('context-menu-expanded-reaction-picker'),
                    left: picker.left,
                    top: picker.top,
                    width: picker.width,
                    height: picker.height,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      child: Material(
                        elevation: 16,
                        color: Theme.of(ctx).colorScheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: FireplaceEmojiPicker(
                          onEmojiSelected: selectPickerEmoji,
                          onBackspacePressed: null,
                          height: picker.height,
                        ),
                      ),
                      builder: (context, t, child) => Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: 0.95 + 0.05 * t,
                          alignment: picker.below
                              ? (isMine
                                    ? Alignment.topRight
                                    : Alignment.topLeft)
                              : (isMine
                                    ? Alignment.bottomRight
                                    : Alignment.bottomLeft),
                          child: child,
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          );
        },
      );
    },
  );
  overlay.insert(_activeMessageContextMenu!);
  final route = ModalRoute.of(context);
  if (route != null) {
    _contextMenuPopEntry = _ContextMenuPopEntry();
    _contextMenuPopRoute = route;
    route.registerPopEntry(_contextMenuPopEntry!);
  }
}

class _ContextMenuReactionEmojiBar extends StatelessWidget {
  const _ContextMenuReactionEmojiBar({
    required this.message,
    required this.currentUserId,
    required this.onReaction,
    required this.onExpand,
  });

  final MessageModel message;
  final int? currentUserId;
  final void Function(String emoji, bool alreadyReacted) onReaction;
  final VoidCallback onExpand;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(24),
      height: kMessageContextMenuEmojiRowHeight,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ..._kReactionEmojis.map((emoji) {
                  final alreadyReacted =
                      currentUserId != null &&
                      (message.reactions[emoji]?.contains(currentUserId) ??
                          false);
                  return Semantics(
                    button: true,
                    selected: alreadyReacted,
                    label: l10n.messageReactionSemantics(
                      emoji,
                      alreadyReacted
                          ? l10n.messageReactionSelected
                          : l10n.messageReactionNotSelected,
                    ),
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: () {
                        onReaction(emoji, alreadyReacted);
                        dismissMessageContextMenu();
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: alreadyReacted
                              ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.15)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          emoji,
                          style: const TextStyle(
                            fontSize: 22,
                            fontFamily: kEmojiFontFamily,
                            fontFamilyFallback: kEmojiFontFamilyFallback,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                Semantics(
                  button: true,
                  label: l10n.messageReactionMoreEmoji,
                  excludeSemantics: true,
                  child: Tooltip(
                    message: l10n.messageReactionMoreEmoji,
                    child: IconButton(
                      key: const ValueKey('context-menu-expand-reactions'),
                      onPressed: onExpand,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 22,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
