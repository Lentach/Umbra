import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/rpg_theme.dart';

/// The row under an own message whose send failed: the red "Retry" button,
/// and, when THIS row was refused for a changed key, the line saying so.
/// A row that merely WAITS to be sent ([MessageModel.waitingToSend], status
/// still failed) is drawn calm instead: a clock and grey words by the reason
/// (`MessagingProvider.sendWaitReason`), no Retry, nothing red.
/// Shared by every bubble type (text, media, voice) so none can lack it.
///
/// Empty for a message that is not mine or did not fail.
class FailedSendRetry extends StatelessWidget {
  const FailedSendRetry({
    required this.message,
    required this.isMine,
    required this.textColor,
    required this.maxWidth,
    required this.peerRefusedIdentity,
    super.key,
  });

  final MessageModel message;
  final bool isMine;

  /// The bubble's own text colour, for the keys-changed line.
  final Color textColor;

  /// Widest the keys-changed line may grow.
  final double maxWidth;

  /// True when a ceremony is outstanding for this chat's peer: the
  /// account-anchor gate is still refusing sends
  /// (`EncryptionProvider.peersRefusedIdentity`), i.e. the fingerprint
  /// ceremony is outstanding, or the peer's new key waits for the tap on its
  /// calm line (decision 152).
  final bool peerRefusedIdentity;

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

  /// The calm line of a waiting row. The reason is read live, so the words
  /// change when the person taps the calm line while the row is on screen.
  Widget _buildWaiting(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reason = context.select<MessagingProvider, SendWaitReason>(
      (p) => p.sendWaitReason(message),
    );
    final text = reason == SendWaitReason.calmLineUntapped
        ? l10n.messageWaitingTapCalmLine
        : l10n.messageWaitingToSend;
    // The timestamp's own colour: muted, and legible on the bubble fill.
    final color = RpgTheme.messageBubbleMetaColor(
      context,
      isMine: isMine,
      themePreference: context.read<SettingsProvider>().themePreference,
    );
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.schedule, size: 12, color: color),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    textAlign: isMine ? TextAlign.end : TextAlign.start,
                    style: RpgTheme.bodyFont(fontSize: 12, color: color),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isMine || message.deliveryStatus != MessageDeliveryStatus.failed) {
      return const SizedBox.shrink();
    }
    if (message.waitingToSend) return _buildWaiting(context);
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
              unawaited(
                context.read<MessagingProvider>().retryFailedMessage(tempId),
              );
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
