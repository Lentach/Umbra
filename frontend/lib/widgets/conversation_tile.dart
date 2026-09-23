import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';
import '../theme/glass_theme.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import '../providers/messaging_provider.dart';
import '../providers/settings_provider.dart';
import 'glass/glass_dialog.dart';
import 'hex_avatar.dart';
import 'hearth_fade_arc.dart';
import '../utils/jumbo_emoji.dart';
import '../utils/anti_quantum_note_link.dart';
import '../utils/message_display_text.dart';

class ConversationTile extends StatelessWidget {
  final int conversationId;
  final String displayName;
  final MessageModel? lastMessage;
  final bool isActive;
  final int unreadCount;
  final bool isMuted;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final UserModel? otherUser;
  final bool isTyping;

  /// The row the preview line is drawn from when it is not [lastMessage]
  /// itself: the plaintext this install holds for that message id (amendment
  /// (lxxxviii) A1). [lastMessage] still supplies the time and the metadata.
  final MessageModel? previewMessage;

  /// No preview text at all (amendment (lxxxviii) A1): the row keeps its name
  /// and time. Decided by the screen from `MessagingProvider.listPreviewFor` —
  /// a row this install can never read, a read or own row it holds no
  /// plaintext for, or a stored copy still being read.
  final bool hidePreview;

  const ConversationTile({
    super.key,
    required this.conversationId,
    required this.displayName,
    this.lastMessage,
    this.isActive = false,
    this.unreadCount = 0,
    this.isMuted = false,
    required this.onTap,
    required this.onDelete,
    this.otherUser,
    this.isTyping = false,
    this.previewMessage,
    this.hidePreview = false,
  });

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    final local = dt.toLocal();
    if (diff.inDays > 0) {
      return '${local.day}/${local.month}';
    }
    return RpgTheme.formatMessageClock(dt);
  }

  String _lastMessagePreview(BuildContext context, MessageModel lastMessage) {
    // FIRST, above the media labels: "Photo" for a photo that will never open
    // is as misleading as a placeholder.
    if (hidePreview) return '';
    final l10n = AppLocalizations.of(context);
    if (lastMessage.messageType == MessageType.ping) return 'PING!';
    if (lastMessage.messageType == MessageType.voice) return l10n.voiceMessage;
    if (lastMessage.messageType == MessageType.image) {
      return l10n.attachment;
    }
    if (lastMessage.messageType == MessageType.gif) return 'GIF';
    if (lastMessage.messageType == MessageType.video) {
      return l10n.videoMessage;
    }
    if (lastMessage.messageType == MessageType.file) {
      return l10n.attachmentOptionDocument;
    }
    // AFTER the media branches on purpose: a keyed media row keeps
    // `content == '[encrypted]'` forever (its payload is the mediaKey, not
    // text), and it must render as "Photo"/"Voice message", not as an
    // unreadable row.
    final sentinel = sentinelPreviewText(context, lastMessage);
    if (sentinel != null) return sentinel;
    if (isAntiQuantumNoteUrl(lastMessage.content)) {
      return l10n.antiQuantumNoteTitle;
    }
    return lastMessage.content;
  }

  String _ephemeralTooltip(BuildContext context, MessageModel message) {
    final l10n = AppLocalizations.of(context);
    final countdown = HearthFadeArcIndicator.countdownLabel(message);
    if (countdown != null) {
      return l10n.conversationLastMessageEphemeralRemaining(countdown);
    }
    return l10n.conversationLastMessageEphemeralPreRead;
  }

  Widget _buildEphemeralPrefix(
    BuildContext context,
    MessageModel message,
    Color ephemeralColor,
    Color secondaryColor,
  ) {
    return Tooltip(
      message: _ephemeralTooltip(context, message),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: HearthFadeArcIndicator(
          message: message,
          color: ephemeralColor,
          trackColor: secondaryColor.withValues(alpha: 0.35),
          size: 12,
        ),
      ),
    );
  }

  Widget _buildTrailingMetaRow(
    BuildContext context,
    Color ephemeralColor,
    Color secondaryColor,
    bool live,
  ) {
    final accent = Theme.of(context).colorScheme.primary;
    final staticTrailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isMuted)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: AppLocalizations.of(context).userCardNotificationsMuted,
              child: Icon(
                Icons.notifications_off_outlined,
                size: 14,
                color: secondaryColor,
              ),
            ),
          ),
        if (lastMessage != null)
          Text(
            _formatTime(lastMessage!.createdAt),
            style: RpgTheme.bodyFont(
              fontSize: 11,
              color: live ? accent : secondaryColor,
              fontWeight: live ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        // The count rides with the time in accent; the row's lit edge is
        // what actually announces unread (owner-approved 2026-07-24).
        if (unreadCount > 0) ...[
          const SizedBox(width: 6),
          Text(
            unreadCount > 99 ? '99+' : '$unreadCount',
            style: RpgTheme.bodyFont(
              fontSize: 11,
              color: accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );

    final message = lastMessage;
    if (message == null ||
        !HearthFadeArcIndicator.showsEphemeralState(message)) {
      return staticTrailing;
    }

    return ValueListenableBuilder<int>(
      valueListenable: context.read<MessagingProvider>().countdownTickNotifier,
      child: staticTrailing,
      builder: (context, _, child) {
        if (!HearthFadeArcIndicator.showsEphemeralState(message)) {
          return child!;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildEphemeralPrefix(
              context,
              message,
              ephemeralColor,
              secondaryColor,
            ),
            child!,
          ],
        );
      },
    );
  }

  /// Row weight, derived from data the tile already receives: rows that want
  /// you get bigger, dead threads shrink. No new inputs, no backend.
  _RowWeight get _weight {
    if (unreadCount > 0 || isTyping) return _RowWeight.live;
    final at = lastMessage?.createdAt;
    if (at != null && DateTime.now().difference(at) > _coldAfter) {
      return _RowWeight.cold;
    }
    return _RowWeight.normal;
  }

  /// Recency as warmth for the hex ring: 1 fresh, 0 once [_coldAfter] old.
  double get _ember {
    final at = lastMessage?.createdAt;
    if (at == null) return 0;
    final age = DateTime.now().difference(at).inSeconds;
    return (1 - age / _coldAfter.inSeconds).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final themePref = context.watch<SettingsProvider>().themePreference;
    final ephemeralColor = RpgTheme.ephemeralAccent(
      context,
      themePreference: themePref,
    );
    final colors = FireplaceColors.of(context);
    final activeBg = GlassTheme.of(context).activeCapsule;
    // Per-theme muted (FireplaceColors) instead of the legacy warm gray that
    // tinted blue/teal dark themes orange-ish.
    final secondaryColor = colors.mutedText;

    final weight = _weight;
    final live = weight == _RowWeight.live;
    final cold = weight == _RowWeight.cold;
    final hexSize = switch (weight) {
      _RowWeight.live => 50.0,
      // Normal rows keep the legacy 64px row height (owner: Chats and the
      // Contacts list must line up), so the hex matches the old 44px circle.
      _RowWeight.normal => 44.0,
      _RowWeight.cold => 36.0,
    };
    final verticalPad = switch (weight) {
      _RowWeight.live => 12.0,
      _RowWeight.normal => 10.0,
      _RowWeight.cold => 7.0,
    };

    return Dismissible(
      key: ValueKey<int>(conversationId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.delete,
          color: Theme.of(context).colorScheme.onError,
          size: 28,
        ),
      ),
      confirmDismiss: (direction) async {
        return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final colorScheme = Theme.of(dialogContext).colorScheme;
            final isDark = RpgTheme.isDark(dialogContext);
            final mutedColor = isDark
                ? RpgTheme.mutedDark
                : RpgTheme.textSecondaryLight;
            final l10n = AppLocalizations.of(dialogContext);
            return GlassDialog(
              title: Text(
                l10n.deleteConversationTitle,
                style: RpgTheme.bodyFont(
                  fontSize: 16,
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: Text(
                l10n.deleteConversationConfirm,
                style: RpgTheme.bodyFont(
                  fontSize: 14,
                  color: colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                    l10n.cancel,
                    style: RpgTheme.bodyFont(fontSize: 14, color: mutedColor),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(
                    l10n.delete,
                    style: RpgTheme.bodyFont(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
      onDismissed: (direction) => onDelete(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Material(
          color: isActive
              ? activeBg
              : live
              ? colorScheme.primary.withValues(alpha: 0.05)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            splashColor: colorScheme.primary.withValues(alpha: 0.2),
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, verticalPad, 12, verticalPad),
              child: Row(
                children: [
                  // Unread is the row's own edge, not a stock badge pill.
                  SizedBox(
                    width: 3,
                    height: live ? hexSize * 0.8 : 0,
                    child: live
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: live ? 9 : 12),
                  HexAvatar(
                    size: hexSize,
                    displayName: displayName,
                    imageUrl: otherUser?.profilePictureUrl,
                    surface: colors.convItemBg,
                    borderColor: colors.convItemBorder,
                    ember: _ember,
                    initialsStyle: RpgTheme.bodyFont(
                      fontSize: hexSize * 0.34,
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: RpgTheme.bodyFont(
                                  fontSize: cold ? 13 : 14,
                                  color: cold
                                      ? secondaryColor
                                      : colorScheme.onSurface,
                                  fontWeight: live
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildTrailingMetaRow(
                              context,
                              ephemeralColor,
                              secondaryColor,
                              live,
                            ),
                          ],
                        ),
                        if (isTyping) ...[
                          const SizedBox(height: 3),
                          Text(
                            AppLocalizations.of(context).typing,
                            style: RpgTheme.bodyFont(
                              fontSize: 13,
                              color: colorScheme.primary,
                            ).copyWith(fontStyle: FontStyle.italic),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ] else if (lastMessage != null) ...[
                          const SizedBox(height: 3),
                          Text.rich(
                            TextSpan(
                              children: buildInlineEmojiSpans(
                                _lastMessagePreview(
                                  context,
                                  previewMessage ?? lastMessage!,
                                ),
                                textStyle: RpgTheme.bodyFont(
                                  fontSize: cold ? 12 : 13,
                                  color: live
                                      ? colorScheme.onSurface.withValues(
                                          alpha: 0.78,
                                        )
                                      : secondaryColor,
                                ),
                                emojiFontSize: cold ? 12 : 13,
                              ),
                            ),
                            // Live rows earn a second line of context.
                            maxLines: live ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _RowWeight { live, normal, cold }

/// A thread with no activity for this long reads as cold.
const Duration _coldAfter = Duration(days: 6);
