import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/encryption_provider.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/reply_preview_helper.dart';

/// Displays the quoted reply preview above the input bar.
/// Shows sender name, content preview, and a dismiss button.
///
/// Liquid Glass: floats as a rounded solid card (content layer) above the
/// composer pill instead of a full-width strip; accent bar is
/// direction-aware (leading edge).
class ReplyPreviewBar extends StatelessWidget {
  const ReplyPreviewBar({
    super.key,
    required this.message,
    required this.onDismiss,
    this.currentUserId,
  });

  /// Already resolved from the open message list when possible (parent owns lookup).
  final MessageModel message;
  final VoidCallback onDismiss;

  /// The signed-in user: a reply to their own message is labelled "You".
  final int? currentUserId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final encryption = context.read<EncryptionProvider>();
    final previewText = replyPreviewForMessage(
      l10n,
      message,
      encryption: encryption,
    );
    final fc = FireplaceColors.of(context);
    final accentColor = Theme.of(context).colorScheme.primary;
    // Per-theme token, not a two-way dark/light guess.
    final mutedColor = fc.mutedText;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fc.tabBorder),
      ),
      child: Stack(
        children: [
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(color: accentColor),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        quotedSenderLabel(
                          l10n,
                          senderUsername: message.senderUsername,
                          senderId: message.senderId,
                          currentUserId: currentUserId,
                        ),
                        style: RpgTheme.bodyFont(
                          fontSize: 12,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        previewText,
                        style: RpgTheme.bodyFont(
                          fontSize: 12,
                          color: mutedColor,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onDismiss,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  color: mutedColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
