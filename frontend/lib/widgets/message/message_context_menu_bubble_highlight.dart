import 'package:flutter/material.dart';
import '../../utils/message_display_text.dart';
import '../../models/message_model.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/jumbo_emoji.dart';
import 'message_bubble_inline_time.dart';

/// Sharp bubble replica shown above the blurred scrim during long-press menu.
///
/// Intentionally self-contained (no Provider reads) so it can mount in [Overlay]
/// without inheriting chat providers.
class MessageContextMenuBubbleHighlight extends StatelessWidget {
  const MessageContextMenuBubbleHighlight({
    super.key,
    required this.message,
    required this.isMine,
    required this.maxWidth,
    this.themePreference = 'light',
  });

  final MessageModel message;
  final bool isMine;
  final double maxWidth;
  final String themePreference;

  // `isMine` matters too: an own `[encrypted]` row is permanently unreadable
  // and says so, and the overlay must not contradict the bubble.
  String _displayContent(BuildContext context) => messageDisplayContent(
    context,
    message,
    isMine: isMine,
  );

  Widget _metadataRow(BuildContext context, Color timeColor) {
    IconData? deliveryIcon;
    if (isMine) {
      switch (message.deliveryStatus) {
        case MessageDeliveryStatus.sending:
          deliveryIcon = Icons.access_time;
          break;
        case MessageDeliveryStatus.sent:
        case MessageDeliveryStatus.delivered:
          deliveryIcon = Icons.check;
          break;
        case MessageDeliveryStatus.read:
          deliveryIcon = Icons.done_all;
          break;
        case MessageDeliveryStatus.failed:
          deliveryIcon = Icons.error;
          break;
      }
    }

    final ticks = RpgTheme.messageBubbleDeliveryTickColors(
      context,
      isMine: isMine,
      themePreference: themePreference,
    );
    final deliveryColor = message.deliveryStatus == MessageDeliveryStatus.read
        ? ticks.$2
        : ticks.$1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          RpgTheme.formatMessageClock(message.createdAt),
          style: RpgTheme.bodyFont(fontSize: 10, color: timeColor),
        ),
        if (deliveryIcon != null) ...[
          const SizedBox(width: 4),
          Icon(
            deliveryIcon,
            size: 12,
            color: message.deliveryStatus == MessageDeliveryStatus.failed
                ? Theme.of(context).colorScheme.error
                : deliveryColor,
          ),
        ],
      ],
    );
  }

  Widget _buildMediaBody(Color timeColor) {
    return SizedBox(
      width: double.infinity,
      height: kMessageMediaBubbleHeight,
      child: ColoredBox(
        color: Colors.black26,
        child: Center(
          child: Icon(
            switch (message.messageType) {
              MessageType.gif => Icons.gif_box_outlined,
              MessageType.video => Icons.videocam_outlined,
              _ => Icons.image_outlined,
            },
            color: timeColor,
            size: 40,
          ),
        ),
      ),
    );
  }

  Widget _buildMediaHighlight(
    BuildContext context,
    double safeWidth,
    Color timeColor,
  ) {
    return Material(
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.hardEdge,
      color: Colors.transparent,
      child: SizedBox(
        width: safeWidth,
        height: kMessageMediaBubbleHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildMediaBody(timeColor),
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: _metadataRow(
                  context,
                  Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = RpgTheme.isDark(context);
    final bubbleColor = isMine
        ? FireplaceColors.of(context).mineMsgBg
        : FireplaceColors.of(context).theirsMsgBg;
    final textColor = isMine
        ? (themePreference == 'teal'
              ? Colors.white
              : (isDark ? RpgTheme.textColor : RpgTheme.textColorLight))
        : (isDark ? RpgTheme.textColor : RpgTheme.textColorLight);
    final timeColor = RpgTheme.messageBubbleMetaColor(
      context,
      isMine: isMine,
      themePreference: themePreference,
    );
    final safeWidth = maxWidth.clamp(48.0, double.infinity);

    final isMediaMessage =
        message.messageType == MessageType.image ||
        message.messageType == MessageType.gif ||
        message.messageType == MessageType.video;
    if (isMediaMessage) {
      return _buildMediaHighlight(context, safeWidth, timeColor);
    }

    final displayContent = _displayContent(context);
    Widget body;
    switch (message.messageType) {
      case MessageType.voice:
        body = _VoiceBubbleHighlight(
          message: message,
          isMine: isMine,
          themePreference: themePreference,
          metaColor: timeColor,
          bubbleColor: bubbleColor,
          isDark: isDark,
        );
        break;
      case MessageType.file:
        body = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: textColor, size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                displayContent,
                style: RpgTheme.bodyFont(fontSize: 14, color: textColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        break;
      case MessageType.ping:
        body = Text(
          displayContent,
          style: RpgTheme.bodyFont(
            fontSize: 14,
            color: textColor,
            fontWeight: FontWeight.w600,
          ),
        );
        break;
      default:
        {
          // Mirror TextMessageContent: jumbo sizing for emoji-only messages and
          // enlarged inline emoji for mixed text so the replica does not visibly
          // shift when the long-press menu opens.
          final jumboSize = jumboEmojiFontSize(displayContent);
          body = jumboSize != null
              ? Text(
                  displayContent,
                  style: withEmojiFont(
                    RpgTheme.bodyFont(fontSize: jumboSize, color: textColor),
                  ),
                )
              : Text.rich(
                  TextSpan(
                    children: buildInlineEmojiSpans(
                      displayContent,
                      textStyle: RpgTheme.bodyFont(
                        fontSize: 15,
                        color: textColor,
                      ),
                    ),
                  ),
                );
        }
    }

    // Emoji-only messages stack the metadata below the emote (matches the live
    // bubble); everything else may keep the inline time row.
    final isEmojiOnly = jumboEmojiFontSize(displayContent) != null;
    final useInlineTime =
        !isEmojiOnly &&
        messageBubbleUsesInlineTime(
          message: message,
          displayContent: displayContent,
        );

    return Material(
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      color: bubbleColor,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: safeWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: useInlineTime
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(child: body),
                    const SizedBox(width: 6),
                    _metadataRow(context, timeColor),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: isMine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    body,
                    const SizedBox(height: 4),
                    _metadataRow(context, timeColor),
                  ],
                ),
        ),
      ),
    );
  }
}

class _VoiceBubbleHighlight extends StatelessWidget {
  const _VoiceBubbleHighlight({
    required this.message,
    required this.isMine,
    required this.themePreference,
    required this.metaColor,
    required this.bubbleColor,
    required this.isDark,
  });

  final MessageModel message;
  final bool isMine;
  final String themePreference;
  final Color metaColor;
  final Color bubbleColor;
  final bool isDark;

  String _formatDuration(int? seconds) {
    final total = seconds ?? 0;
    final minutes = total ~/ 60;
    final secs = total % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = isMine && !isDark && themePreference == 'light'
        ? RpgTheme.textColorLight
        : (isMine && themePreference == 'teal' ? Colors.white : null);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.play_arrow, size: 32, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 24,
            decoration: BoxDecoration(
              color: metaColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatDuration(message.mediaDuration),
          style: RpgTheme.bodyFont(fontSize: 10, color: metaColor),
        ),
      ],
    );
  }
}
