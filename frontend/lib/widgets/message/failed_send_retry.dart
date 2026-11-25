import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/messaging_provider.dart';
import '../../theme/rpg_theme.dart';

/// The row under an own message whose send failed: the red "Retry" button,
/// and, when THIS row was refused for a changed key, the line saying so.
/// Shared by every bubble type (text, media, voice) so none can lack it.
///
/// Empty for a message that is not mine or did not fail.
class FailedSendRetry extends StatelessWidget {
  final MessageModel message;
  final bool isMine;

  /// The bubble's own text colour, for the keys-changed line.
  final Color textColor;

  /// Widest the keys-changed line may grow.
  final double maxWidth;

  /// True when the account-anchor gate is still refusing sends to this chat's
  /// peer (`EncryptionProvider.peersRefusedIdentity`), i.e. the fingerprint
  /// ceremony is outstanding.
  final bool peerRefusedIdentity;

  const FailedSendRetry({
    super.key,
    required this.message,
    required this.isMine,
    required this.textColor,
    required this.maxWidth,
    required this.peerRefusedIdentity,
  });

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

  @override
  Widget build(BuildContext context) {
    if (!isMine || message.deliveryStatus != MessageDeliveryStatus.failed) {
      return const SizedBox.shrink();
    }
    // "Retry" alone is a trap here: while the anchor is stale every attempt
    // fails the same way, so the row has to name the remedy.
    final refused = _mayNameTheRefusal(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isMine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        if (refused)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Text(
              AppLocalizations.of(context).messageSendBlockedKeysChanged,
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
        TextButton.icon(
          onPressed: () {
            final tempId = message.tempId;
            if (tempId != null) {
              context.read<MessagingProvider>().retryFailedMessage(tempId);
            }
          },
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(AppLocalizations.of(context).messageRetrySend),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
        ),
      ],
    );
  }
}
