import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/reply_preview_helper.dart';

/// The quoted-message card above a reply, shared by the text and voice bubbles.
///
/// Extracted from two byte-identical copies. The padding, the 3px left rule,
/// the 6% wash and both type ramps had to be edited in two files, so a
/// contrast or spacing fix applied to one silently missed the other — the same
/// duplication that let the identity banners drift apart.
///
/// [content] arrives already resolved: each bubble looks the quoted text up
/// through its own conversation and message-cache context, and that lookup is
/// deliberately NOT pulled in here.
class ReplyQuoteCard extends StatelessWidget {
  final ReplyToPreview replyTo;
  final bool isDark;

  /// Accent for the left rule and the username — the bubble's own, since the
  /// mine/theirs bubbles carry different accents.
  final Color borderColor;

  final String content;

  /// The signed-in user: a quote of their own message is labelled "You".
  final int? currentUserId;

  const ReplyQuoteCard({
    super.key,
    required this.replyTo,
    required this.isDark,
    required this.borderColor,
    required this.content,
    this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mutedColor = isDark
        ? RpgTheme.timeColorDark
        : RpgTheme.textSecondaryLight;
    return Container(
      padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6, right: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: borderColor, width: 3)),
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            quotedSenderLabel(
              l10n,
              senderUsername: replyTo.senderUsername,
              senderId: replyTo.senderId,
              currentUserId: currentUserId,
            ),
            style: RpgTheme.bodyFont(
              fontSize: 12,
              color: borderColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            content,
            style: RpgTheme.bodyFont(fontSize: 12, color: mutedColor),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
