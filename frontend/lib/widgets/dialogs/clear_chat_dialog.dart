import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../glass/glass_dialog.dart';

/// Informed consent for `clearChatHistory`: every message and media file of
/// the chat is deleted from THIS device, irreversibly (owner decision 52).
/// The other person keeps their copy and nothing is sent to them.
///
/// The action tile's 1.5 s hold guards against an accidental touch and cannot
/// state that scope — a warning has to be readable at the user's own pace, not
/// in the window where their finger is already down. Same shape as
/// [showMessageDeleteDialog]: destructive label in `colorScheme.error`, cancel
/// from [MaterialLocalizations].
Future<void> showClearChatDialog({
  required BuildContext context,
  required VoidCallback onConfirm,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => GlassDialog(
      title: Text(l10n.clearChatConfirmTitle),
      content: Text(l10n.clearChatConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
        ),
        TextButton(
          key: const Key('clear-chat-confirm'),
          onPressed: () {
            Navigator.pop(ctx);
            onConfirm();
          },
          child: Text(
            l10n.clearChatConfirmAction,
            style: TextStyle(color: Theme.of(ctx).colorScheme.error),
          ),
        ),
      ],
    ),
  );
}
