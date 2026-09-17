import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/encryption_provider.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/reply_preview_helper.dart';
import '../../utils/message_edit_eligibility.dart';
import '../../utils/jumbo_emoji.dart';
import '../../utils/message_display_text.dart';
import '../message_swipe_wrapper.dart';
import '../dialogs/message_delete_dialog.dart';
import '../top_snackbar.dart';
import 'message_context_menu_overlay.dart';
import 'reaction_tap.dart';
import 'message_context_menu_bubble_highlight.dart';
import 'context_menu_bubble_anchor.dart';
import 'message_bubble_inline_time.dart';
import 'message_content_factory.dart';
import 'voice_message_content.dart';
import 'message_metadata_row.dart';
import 'reaction_chips_row.dart';
import 'reply_quote_card.dart';

export 'reaction_chips_row.dart' show ReactionChipsRow;

class ChatMessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;

  /// True when the account-anchor gate is still refusing sends to this chat's
  /// peer (`EncryptionProvider.peersRefusedIdentity`), i.e. the fingerprint
  /// ceremony is outstanding.
  ///
  /// Passed in rather than derived here. `ChatDetailScreen` already computes
  /// it with a `context.select` from state it owns (`:1000-1004`), and it is
  /// the ONLY construction site — re-deriving it inside the bubble meant
  /// walking `ConversationsProvider` to find the peer, which also silently
  /// skipped the subscription whenever the conversation had not loaded yet.
  final bool peerRefusedIdentity;

  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.peerRefusedIdentity = false,
  });

  String _displayContent(BuildContext context) => messageDisplayContent(
    context,
    message,
    isMine: isMine,
    // Must match what the BODY renders: this string also feeds the
    // inline-vs-stacked timestamp probe, so measuring the unreadable sentence
    // while `TextMessageContent` paints "Decrypting…" can flip that layout
    // decision for the duration of the pass.
    decryptInProgress: historyDecryptInFlight(context),
  );

  String _replyDisplayContent(BuildContext context, ReplyToPreview replyTo) {
    final l10n = AppLocalizations.of(context);
    final encryption = context.read<EncryptionProvider>();
    final messaging = context.read<MessagingProvider>();
    return replyDisplayContentForQuote(
      l10n,
      replyTo,
      encryption: encryption,
      conversationId: message.conversationId,
      createdAt: message.createdAt,
      messagesForLookup: messaging.messages,
    );
  }

  Widget? _buildRetryButton(BuildContext context) {
    if (!isMine || message.deliveryStatus != MessageDeliveryStatus.failed) {
      return null;
    }
    return TextButton.icon(
      onPressed: () {
        final messaging = Provider.of<MessagingProvider>(
          context,
          listen: false,
        );
        if (message.tempId != null) {
          messaging.retryFailedMessage(message.tempId!);
        }
      },
      icon: const Icon(Icons.refresh, size: 16),
      label: Text(AppLocalizations.of(context).messageRetrySend),
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
    );
  }

  /// True when THIS row may tell the user their peer's keys changed.
  ///
  /// Two conditions, and both are load-bearing:
  ///  * the row's own last send attempt was refused by the account-anchor gate
  ///    (`AccountIdentityMismatch`, recorded per tempId by the send path) — so
  ///    a timeout or an "Image too large" bounce in the same chat is not
  ///    explained away as a key change;
  ///  * the ceremony is STILL outstanding ([peerRefusedIdentity]) — once the
  ///    user has compared fingerprints the remedy really is just "Retry", and
  ///    repeating the instruction would send them back through a ceremony they
  ///    already completed.
  bool _mayNameTheRefusal(BuildContext context) =>
      peerRefusedIdentity &&
      context.read<MessagingProvider>().sendRefusedForIdentity(message.tempId);

  void _openContextMenu(BuildContext context) {
    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();
    final renderBox = ContextMenuBubbleAnchor.renderBoxOf(context);
    if (renderBox == null) return;
    final bubbleSize = renderBox.size;
    final themePreference = context.read<SettingsProvider>().themePreference;
    final l10n = AppLocalizations.of(context);
    openMessageContextMenu(
      context: context,
      message: message,
      bubbleRenderBox: renderBox,
      isMine: isMine,
      currentUserId: auth.currentUser?.id,
      // `decryptInProgress` is captured HERE, where providers are in scope,
      // and handed over as a plain field: the replica itself stays
      // provider-free (it mounts in an Overlay), but it must not disagree with
      // the bubble underneath it. Without this an own `[encrypted]` row read
      // "Decrypting…" in the bubble and "can't be read" in the overlay.
      bubblePreviewBuilder: (_) => MessageContextMenuBubbleHighlight(
        message: message,
        isMine: isMine,
        maxWidth: bubbleSize.width,
        themePreference: themePreference,
        decryptInProgress: historyDecryptInFlight(context, listen: false),
      ),
      onReply: () => messaging.setReplyingTo(message),
      onCopy: !message.hasCopyablePlaintext
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: message.content));
              showTopSnackBar(context, l10n.snackbarMessageCopied);
            },
      onEdit: messageEditEligible(message, isMine: isMine)
          ? () => messaging.beginEditMessage(message)
          : null,
      onPin: () {
        if (message.id > 0) {
          messaging.pinMessage(message.conversationId, message.id);
        }
      },
      onDelete: () {
        showMessageDeleteDialog(
          context: context,
          isMine: isMine,
          messageId: message.id,
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

  Widget _buildContentColumn(
    BuildContext context,
    bool isDark,
    Color textColor,
    Color borderColor, {
    required double contentAreaWidth,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isMine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (message.replyTo != null) ...[
          ReplyQuoteCard(
            replyTo: message.replyTo!,
            isDark: isDark,
            borderColor: borderColor,
            content: _replyDisplayContent(context, message.replyTo!),
          ),
          const SizedBox(height: 8),
        ],
        MessageContentFactory.build(
          context: context,
          message: message,
          isMine: isMine,
          isDark: isDark,
          textColor: textColor,
          contentAreaWidth: contentAreaWidth,
          // Only the unreadable-reason caption consumes this, so it can share
          // `messageBubbleMetaColor` with the timestamp instead of inventing
          // an alpha that would disagree with it on the white-on-teal bubbles.
          themePreference: context.read<SettingsProvider>().themePreference,
        ),
        Builder(
          builder: (ctx) {
            final retryBtn = _buildRetryButton(ctx);
            if (retryBtn == null) return const SizedBox.shrink();
            // "Retry" alone is a trap here: while the anchor is stale every
            // attempt fails the same way, so the row has to name the remedy.
            final refused = _mayNameTheRefusal(ctx);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                if (refused)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: contentAreaWidth),
                    child: Text(
                      AppLocalizations.of(ctx).messageSendBlockedKeysChanged,
                      textAlign: isMine ? TextAlign.end : TextAlign.start,
                      // The bubble's OWN text color, not `colorScheme.error`:
                      // painted on the sent-bubble fill, error red lands on a
                      // saturated blue in the blue/cosmic themes and a whole
                      // wrapped paragraph of it is unreadable (seen, §9 loop).
                      // The red retry button right below still carries the
                      // error signal; weight carries the emphasis here.
                      style: RpgTheme.bodyFont(
                        fontSize: 12,
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                retryBtn,
              ],
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // A retired media row no longer has its one-shot media keys; render the
    // same factual placeholder as retired text instead of opening its decoder.
    if (message.messageType == MessageType.voice &&
        message.content != kRetiredMessageLabel) {
      return VoiceMessageContent(message: message, isMine: isMine);
    }

    final isDark = RpgTheme.isDark(context);
    final bubbleColor = isMine
        ? FireplaceColors.of(context).mineMsgBg
        : FireplaceColors.of(context).theirsMsgBg;
    final borderColor = isMine
        ? Theme.of(context).colorScheme.primary
        : FireplaceColors.of(context).borderColor;
    final themePreference = context.read<SettingsProvider>().themePreference;
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

    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final messaging = context.read<MessagingProvider>();

    return MessageSwipeWrapper(
      isMine: isMine,
      onSwipeReply: () => messaging.setReplyingTo(message),
      onLongPress: () => _openContextMenu(context),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            top: message.reactions.isNotEmpty ? 14.0 : 0.0,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              LayoutBuilder(
                builder: (context, layoutConstraints) {
                  final maxBubbleWidth = layoutConstraints.maxWidth * 0.85;
                  final contentAreaWidth = maxBubbleWidth - 32;

                  final isMediaMessage =
                      message.messageType == MessageType.gif ||
                      message.messageType == MessageType.image ||
                      message.messageType == MessageType.video;
                  final useTextOverlay =
                      message.messageType == MessageType.text &&
                      message.linkPreviewUrl == null;
                  final isEmojiOnlyText =
                      useTextOverlay &&
                      message.replyTo == null &&
                      emojiOnlyCount(message.content) != null;

                  final standardTimeWidget = MessageMetadataRow(
                    message: message,
                    isMine: isMine,
                    timeColor: timeColor,
                  );

                  final mediaTimeOverlay = Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: MessageMetadataRow(
                        message: message,
                        isMine: isMine,
                        timeColor: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  );

                  Widget child;

                  if (isEmojiOnlyText) {
                    return ContextMenuBubbleAnchor(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: isMine ? 48 : 0,
                            right: isMine ? 0 : 48,
                            bottom: kContextMenuAnchorBottomMargin,
                          ),
                          // Emoji-only messages stack the metadata UNDER the
                          // emote (Telegram parity) so a single emote stays
                          // flush to its side instead of being shoved toward
                          // center by an inline time run. Metadata legibility on
                          // the bubbleless chat surface is handled by the
                          // on-surface color below, not by this layout.
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: isMine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              _buildContentColumn(
                                context,
                                isDark,
                                textColor,
                                borderColor,
                                contentAreaWidth: contentAreaWidth,
                              ),
                              const SizedBox(height: 4),
                              MessageMetadataRow(
                                message: message,
                                isMine: isMine,
                                // Emotes render with no bubble, so the metadata
                                // sits on the bare chat background. Use the
                                // received-side (background-readable) meta color
                                // regardless of sender — the on-bubble sent
                                // color is white and vanishes on a light chat
                                // surface (the persisted iOS light-theme bug).
                                timeColor: RpgTheme.messageBubbleMetaColor(
                                  context,
                                  isMine: false,
                                  themePreference: themePreference,
                                ),
                                onChatSurface: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  if (isMediaMessage) {
                    child = Stack(
                      children: [
                        _buildContentColumn(
                          context,
                          isDark,
                          textColor,
                          borderColor,
                          contentAreaWidth: contentAreaWidth,
                        ),
                        mediaTimeOverlay,
                      ],
                    );
                  } else {
                    // Text bubble (with or without link preview): identical
                    // inline-vs-stacked time layout regardless of useTextOverlay,
                    // which now only gates isEmojiOnlyText above.
                    final displayContent = _displayContent(context);
                    final useInlineTime = messageBubbleUsesInlineTime(
                      message: message,
                      displayContent: displayContent,
                    );
                    if (useInlineTime) {
                      child = Wrap(
                        alignment: isMine
                            ? WrapAlignment.end
                            : WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          _buildContentColumn(
                            context,
                            isDark,
                            textColor,
                            borderColor,
                            contentAreaWidth: contentAreaWidth,
                          ),
                          standardTimeWidget,
                        ],
                      );
                    } else {
                      child = Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: isMine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          _buildContentColumn(
                            context,
                            isDark,
                            textColor,
                            borderColor,
                            contentAreaWidth: contentAreaWidth,
                          ),
                          const SizedBox(height: 4),
                          standardTimeWidget,
                        ],
                      );
                    }
                  }

                  return ContextMenuBubbleAnchor(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: isMine ? 48 : 0,
                          right: isMine ? 0 : 48,
                          bottom: kContextMenuAnchorBottomMargin,
                        ),
                        child: Container(
                          key: ValueKey('message-bubble-surface-${message.id}'),
                          decoration: BoxDecoration(
                            color: isMediaMessage
                                ? Colors.transparent
                                : bubbleColor,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          foregroundDecoration: isMediaMessage
                              ? BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: borderColor,
                                    width: 1.25,
                                  ),
                                )
                              : null,
                          clipBehavior: isMediaMessage
                              ? Clip.hardEdge
                              : Clip.none,
                          padding: isMediaMessage
                              ? (message.replyTo != null
                                    ? const EdgeInsets.only(
                                        top: 8,
                                        left: 12,
                                        right: 12,
                                      )
                                    : EdgeInsets.zero)
                              : const EdgeInsets.fromLTRB(16, 10, 16, 8),
                          child: child,
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (message.reactions.isNotEmpty)
                Positioned(
                  top: -14,
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
      ),
    );
  }
}
