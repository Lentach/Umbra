import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../glass/glass_dialog.dart';

/// A Cancel/confirm [GlassDialog]; true only when the confirm button was
/// pressed (a dismissal counts as cancel).
///
/// [destructive] paints the confirm button in `colorScheme.error`; without it
/// the button keeps the theme's default filled style.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      final l10n = AppLocalizations.of(dialogContext);
      return GlassDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colorScheme.error,
                    foregroundColor: colorScheme.onError,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
