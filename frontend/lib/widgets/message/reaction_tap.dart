import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/messaging_provider.dart';
import '../top_snackbar.dart';

/// Toggles a reaction and reports the one failure a user can act on.
///
/// A reaction travels over the box (item 4) and names its message by id: the
/// provider returns false when the box did not take it, or the row is one
/// this device cannot name yet (an unsent or failed own message). Without a
/// toast the tap would look dead, so every such case says "couldn't send,
/// try again".
///
/// Shared by every reaction entry point (bubble chips, voice-message chips,
/// the context menu's picker) so all of them fail the same visible way.
Future<void> toggleReaction(
  BuildContext context,
  int messageId,
  String emoji, {
  required bool alreadyReacted,
}) async {
  final messaging = context.read<MessagingProvider>();
  // Resolved BEFORE the await: the overlay this was tapped from may be gone by
  // the time the round trip answers, and a dead context cannot be localized.
  final l10n = AppLocalizations.of(context);
  final message = l10n.snackbarBoxReactionFailed;
  final sent = alreadyReacted
      ? await messaging.removeReaction(messageId, emoji)
      : await messaging.addReaction(messageId, emoji);
  if (sent || !context.mounted) return;
  showTopSnackBar(context, message);
}
