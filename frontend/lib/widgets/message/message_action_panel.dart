import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/rpg_theme.dart';
import '../glass/glass_surface.dart';

class MessageActionPanel extends StatelessWidget {
  const MessageActionPanel({
    super.key,
    required this.canPinOrDeleteForEveryone,
    required this.onReply,
    this.onCopy,
    required this.onEdit,
    required this.onPin,
    required this.onDelete,
  });

  final bool canPinOrDeleteForEveryone;
  final VoidCallback onReply;

  /// Null hides the Copy row (non-TEXT messages, E2E placeholders).
  final VoidCallback? onCopy;

  /// Null hides the Edit row (non-own / non-TEXT / unsent / past the 15-min window).
  final VoidCallback? onEdit;
  final VoidCallback onPin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _row(
                context,
                l10n.messageActionReply,
                Icons.reply,
                onReply,
                enabled: true,
              ),
              if (onCopy != null)
                _row(
                  context,
                  l10n.messageActionCopy,
                  Icons.copy_outlined,
                  onCopy!,
                  enabled: true,
                ),
              if (onEdit != null)
                _row(
                  context,
                  l10n.messageActionEdit,
                  Icons.edit_outlined,
                  onEdit!,
                  enabled: true,
                ),
              _row(
                context,
                l10n.messageActionPin,
                Icons.push_pin_outlined,
                onPin,
                enabled: canPinOrDeleteForEveryone,
              ),
              _row(
                context,
                l10n.messageActionDelete,
                Icons.delete_outline,
                onDelete,
                enabled: true,
                destructive: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback onTap, {
    required bool enabled,
    bool destructive = false,
  }) {
    final color = !enabled
        ? Theme.of(context).disabledColor
        : destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(label, style: RpgTheme.bodyFont(fontSize: 14, color: color)),
          ],
        ),
      ),
    );
  }
}
