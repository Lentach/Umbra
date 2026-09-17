import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/messaging_provider.dart';
import '../top_snackbar.dart';

/// Toggles a reaction and reports the one failure a user can act on.
///
/// Since reactions became blinded tokens (`docs/design/reaction-privacy.md`)
/// a tap can legitimately fail: this device may hold no key for the
/// conversation — a locked vault, an offline pull, or a device linked after
/// the key was distributed. The provider refuses to fall back to a plaintext
/// emoji in that case, so without this the chip would just never appear and
/// the tap would look broken.
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
  final message = AppLocalizations.of(context).snackbarReactionUnavailable;
  final sent = alreadyReacted
      ? await messaging.removeReaction(messageId, emoji)
      : await messaging.addReaction(messageId, emoji);
  if (sent || !context.mounted) return;
  showTopSnackBar(context, message);
}
