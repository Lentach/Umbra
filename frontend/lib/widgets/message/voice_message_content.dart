import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/encryption_provider.dart';
import '../../utils/reply_preview_helper.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/message_expiry.dart';
import '../audio/playback_controller.dart';
import '../audio/waveform_display.dart';
import '../hearth_fade_arc.dart';
import '../message_swipe_wrapper.dart';
import '../dialogs/message_delete_dialog.dart';
import 'message_context_menu_overlay.dart';
import 'reaction_tap.dart';
import 'message_context_menu_bubble_highlight.dart';
import 'context_menu_bubble_anchor.dart';
import 'reaction_chips_row.dart';
import 'reply_quote_card.dart';

/// Full voice-message bubble: outer bubble shell + PlaybackController + WaveformDisplay.
///
/// Kept as a focused widget so playback, waveform, reactions, and context-menu
/// shell stay readable without changing the visual output.
class VoiceMessageContent extends StatelessWidget {
  final MessageModel message;
  final bool isMine;

  const VoiceMessageContent({
    super.key,
    required this.message,
    required this.isMine,
  });

  // ── helpers ──────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  bool _isExpired() => isMessageExpired(message);

  Widget _buildEphemeralMeta(Color metaColor) {
    if (!HearthFadeArcIndicator.showsEphemeralState(message)) {
      return const SizedBox.shrink();
    }
    final countdown = HearthFadeArcIndicator.countdownLabel(message);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 6),
        HearthFadeArcIndicator(
          message: message,
          color: metaColor,
          trackColor: metaColor.withValues(alpha: 0.28),
          size: 12,
        ),
        if (countdown != null) ...[
          const SizedBox(width: 3),
          Text(
            countdown,
            style: RpgTheme.bodyFont(fontSize: 10, color: metaColor),
          ),
        ],
      ],
    );
  }

  void _openContextMenu(BuildContext context) {
    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();
    final renderBox = ContextMenuBubbleAnchor.renderBoxOf(context);
    if (renderBox == null) return;
    final bubbleSize = renderBox.size;
    final themePreference = context.read<SettingsProvider>().themePreference;
    openMessageContextMenu(
      context: context,
      message: message,
      bubbleRenderBox: renderBox,
      isMine: isMine,
      currentUserId: auth.currentUser?.id,
      bubblePreviewBuilder: (_) => MessageContextMenuBubbleHighlight(
        message: message,
        isMine: isMine,
        maxWidth: bubbleSize.width,
        themePreference: themePreference,
      ),
      onReply: () => messaging.setReplyingTo(message),
      onPin: () => messaging.pinMessage(message.conversationId, message.id),
      onDelete: () {
        showMessageDeleteDialog(
          context: context,
          isMine: isMine,
          messageId: message.id,
          wireId: message.wireId,
          onDeleteForMe: () =>
              messaging.deleteMessage(message.id, forEveryone: false),
          onDeleteForEveryone: () =>
              messaging.deleteMessage(message.id, forEveryone: true),
        );
      },
      onReaction: (emoji, alreadyReacted) {
        toggleReaction(
          context,
          message.id,
          emoji,
          alreadyReacted: alreadyReacted,
        ).ignore();
      },
    );
  }

  // ── reply quote ───────────────────────────────────────────────────────────

  /// Resolves the quoted text from THIS bubble's conversation context; the card
  /// itself is shared (see [ReplyQuoteCard]).
  String _replyQuoteContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final encryption = context.read<EncryptionProvider>();
    final messaging = context.read<MessagingProvider>();
    return replyDisplayContentForQuote(
      l10n,
      message.replyTo!,
      encryption: encryption,
      conversationId: message.conversationId,
      createdAt: message.createdAt,
      messagesForLookup: messaging.messages,
    );
  }

  // ── delivery icon ─────────────────────────────────────────────────────────

  Widget _buildDeliveryIcon(BuildContext context) {
    if (!isMine) return const SizedBox.shrink();
    if (message.deliveryStatus == MessageDeliveryStatus.failed) {
      return Icon(
        Icons.error,
        size: 12,
        color: Theme.of(context).colorScheme.error,
      );
    }
    IconData icon;
    switch (message.deliveryStatus) {
      case MessageDeliveryStatus.sending:
        icon = Icons.access_time;
        break;
      case MessageDeliveryStatus.sent:
      case MessageDeliveryStatus.delivered:
        icon = Icons.check;
        break;
      case MessageDeliveryStatus.read:
        icon = Icons.done_all;
        break;
      default:
        icon = Icons.check;
    }
    final pref = context.read<SettingsProvider>().themePreference;
    final ticks = RpgTheme.messageBubbleDeliveryTickColors(
      context,
      isMine: isMine,
      themePreference: pref,
    );
    final color = message.deliveryStatus == MessageDeliveryStatus.read
        ? ticks.$2
        : ticks.$1;
    return Icon(icon, size: 12, color: color);
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = RpgTheme.isDark(context);
    final bubbleColor = isMine
        ? FireplaceColors.of(context).mineMsgBg
        : FireplaceColors.of(context).theirsMsgBg;
    final themePreference = context.read<SettingsProvider>().themePreference;
    final borderColor = isMine
        ? Theme.of(context).colorScheme.primary
        : FireplaceColors.of(context).borderColor;
    final waveformColor = isMine && !isDark && themePreference == 'light'
        ? RpgTheme.textSecondaryLight
        : (isMine && themePreference == 'teal'
              ? Colors.white.withValues(alpha: 0.82)
              : borderColor);
    final metaColor = RpgTheme.messageBubbleMetaColor(
      context,
      isMine: isMine,
      themePreference: themePreference,
    );
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final messaging = context.read<MessagingProvider>();

    return MessageSwipeWrapper(
      isMine: isMine,
      onSwipeReply: () => messaging.setReplyingTo(message),
      onLongPress: () => _openContextMenu(context),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        // The chip row's room lives INSIDE the Stack, as in
        // `ChatMessageBubble`: a chip at a negative `top` sits outside the
        // Stack's bounds, where Flutter never hit-tests it.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: message.reactions.isNotEmpty ? 14.0 : 0.0,
              ),
              child: ContextMenuBubbleAnchor(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.6,
                  ),
                  margin: EdgeInsets.only(
                    left: isMine ? 48 : 0,
                    right: isMine ? 0 : 48,
                    bottom: kContextMenuAnchorBottomMargin,
                  ),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: PlaybackController(
                    message: message,
                    builder:
                        (
                          context,
                          isPlaying,
                          isLoading,
                          position,
                          duration,
                          speed,
                          togglePlayPause,
                          seekFromWaveform,
                          toggleSpeed,
                        ) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (message.replyTo != null) ...[
                                ReplyQuoteCard(
                                  replyTo: message.replyTo!,
                                  isDark: isDark,
                                  borderColor: borderColor,
                                  content: _replyQuoteContent(context),
                                ),
                                const SizedBox(height: 8),
                              ],

                              // Playback controls row
                              Row(
                                children: [
                                  // Play/Pause (or loading spinner with tap-to-cancel)
                                  isLoading
                                      ? GestureDetector(
                                          onTap: togglePlayPause,
                                          child: SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color:
                                                  isMine &&
                                                      !isDark &&
                                                      themePreference == 'light'
                                                  ? RpgTheme.textSecondaryLight
                                                  : (isMine &&
                                                            themePreference ==
                                                                'teal'
                                                        ? Colors.white
                                                              .withValues(
                                                                alpha: 0.85,
                                                              )
                                                        : null),
                                            ),
                                          ),
                                        )
                                      : IconButton(
                                          icon: Icon(
                                            isPlaying
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                          ),
                                          onPressed: _isExpired()
                                              ? null
                                              : togglePlayPause,
                                          iconSize: 32,
                                          color: _isExpired()
                                              ? Colors.grey
                                              : (isMine &&
                                                        !isDark &&
                                                        themePreference ==
                                                            'light'
                                                    ? RpgTheme.textColorLight
                                                    : (isMine &&
                                                              themePreference ==
                                                                  'teal'
                                                          ? Colors.white
                                                          : null)),
                                        ),

                                  const SizedBox(width: 8),

                                  // Waveform: scrubbable (tap/drag to seek)
                                  Expanded(
                                    child: WaveformDisplay(
                                      messageId: message.id,
                                      position: position,
                                      duration: duration,
                                      color: waveformColor,
                                      onSeek: seekFromWaveform,
                                    ),
                                  ),

                                  const SizedBox(width: 4),

                                  // Position / total duration
                                  Text(
                                    '${_formatDuration(position)}/${_formatDuration(duration)}',
                                    style: RpgTheme.bodyFont(
                                      fontSize: 10,
                                      color: metaColor,
                                    ),
                                  ),

                                  const SizedBox(width: 6),

                                  // Speed toggle: 1x → 1.5x → 2x → 1x
                                  InkWell(
                                    onTap: toggleSpeed,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: waveformColor,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '${speed}x',
                                        style: RpgTheme.bodyFont(
                                          fontSize: 11,
                                          color: metaColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.bottomRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      RpgTheme.formatMessageClock(
                                        message.createdAt,
                                      ),
                                      style: RpgTheme.bodyFont(
                                        fontSize: 10,
                                        color: metaColor,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    _buildDeliveryIcon(context),
                                    // Subscribe to the 1 Hz countdown tick only for
                                    // a genuinely ephemeral message; otherwise every
                                    // visible voice bubble rebuilt once per second
                                    // for a SizedBox.shrink.
                                    if (HearthFadeArcIndicator.showsEphemeralState(
                                      message,
                                    ))
                                      ValueListenableBuilder<int>(
                                        valueListenable: context
                                            .read<MessagingProvider>()
                                            .countdownTickNotifier,
                                        builder: (context, tick, child) =>
                                            _buildEphemeralMeta(metaColor),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                  ),
                ),
              ),
            ),
            if (message.reactions.isNotEmpty)
              Positioned(
                top: 0,
                left: isMine ? null : 8,
                right: isMine ? 8 : null,
                child: ReactionChipsRow(
                  reactions: message.reactions,
                  currentUserId: currentUserId ?? -1,
                  onTap: (emoji, isMyReaction) {
                    toggleReaction(
                      context,
                      message.id,
                      emoji,
                      alreadyReacted: isMyReaction,
                    ).ignore();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
