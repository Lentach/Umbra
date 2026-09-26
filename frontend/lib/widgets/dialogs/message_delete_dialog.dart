import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/message_ids.dart';
import '../glass/glass_dialog.dart';

Future<void> showMessageDeleteDialog({
  required BuildContext context,
  required bool isMine,
  required int messageId,
  required VoidCallback onDeleteForMe,
  required VoidCallback onDeleteForEveryone,
  String? wireId,
}) {
  final l10n = AppLocalizations.of(context);
  // A server row, or a box message named by its wire id (item 4).
  final showForEveryone = isMine && hasActionTarget(messageId, wireId: wireId);
  return showDialog<void>(
    context: context,
    builder: (ctx) => GlassDialog(
      title: Text(l10n.messageDeleteDialogTitle),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            onDeleteForMe();
          },
          child: Text(l10n.messageDeleteForMe),
        ),
        if (showForEveryone)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onDeleteForEveryone();
            },
            child: Text(
              l10n.messageDeleteForEveryone,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
        ),
      ],
    ),
  );
}
