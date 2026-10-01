import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/rpg_theme.dart';
import '../hearth_fade_hex.dart';

/// Timestamp + delivery icon + Hearth Fade ephemeral indicator (Telegram style).
class MessageMetadataRow extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final Color timeColor;

  /// True when this row sits on the bare chat background (bubbleless emotes)
  /// rather than on a colored message bubble. On-surface mode uses
  /// background-readable delivery-tick colors instead of the pale on-bubble
  /// palette (which is invisible on a light chat surface).
  final bool onChatSurface;

  const MessageMetadataRow({
    super.key,
    required this.message,
    required this.isMine,
    required this.timeColor,
    this.onChatSurface = false,
  });

  /// One check = delivered. Two checks = read.
  /// Icon colors follow bubble luminance (see [RpgTheme.messageBubbleDeliveryTickColors]).
  Widget _buildDeliveryIcon(BuildContext context) {
    if (!isMine) return const SizedBox.shrink();

    if (message.deliveryStatus == MessageDeliveryStatus.failed) {
      return Icon(Icons.error, size: 12, color: Theme.of(context).colorScheme.error);
    }

    IconData icon;
    switch (message.deliveryStatus) {
      case MessageDeliveryStatus.sending:
        icon = Icons.access_time;
        break;
      case MessageDeliveryStatus.sent:
      case MessageDeliveryStatus.delivered:
        icon = Icons.check;
        break;
      case MessageDeliveryStatus.read:
        icon = Icons.done_all;
        break;
      case MessageDeliveryStatus.failed:
        icon = Icons.error;
        break;
    }

    final Color color;
    if (onChatSurface) {
      color = message.deliveryStatus == MessageDeliveryStatus.read
          ? Theme.of(context).colorScheme.primary
          : timeColor;
    } else {
      final tickPref = context.read<SettingsProvider>().themePreference;
      final ticks = RpgTheme.messageBubbleDeliveryTickColors(
        context,
        isMine: isMine,
        themePreference: tickPref,
      );
      color = message.deliveryStatus == MessageDeliveryStatus.read
          ? ticks.$2
          : ticks.$1;
    }
    return Icon(icon, size: 12, color: color);
  }

  Widget _buildEphemeralIndicator() {
    if (!HearthFadeHexIndicator.showsEphemeralState(message)) {
      return const SizedBox.shrink();
    }

    final countdown = HearthFadeHexIndicator.countdownLabel(message);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 6),
        HearthFadeHexIndicator(
          message: message,
          color: timeColor,
          size: 12,
        ),
        if (countdown != null) ...[
          const SizedBox(width: 3),
          Text(
            countdown,
            style: RpgTheme.bodyFont(fontSize: 10, color: timeColor),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final staticRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.editedAt != null) ...[
          Text(
            AppLocalizations.of(context).messageEditedLabel,
            style: RpgTheme.bodyFont(fontSize: 10, color: timeColor),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          RpgTheme.formatMessageClock(message.createdAt),
          style: RpgTheme.bodyFont(fontSize: 10, color: timeColor),
        ),
        const SizedBox(width: 4),
        _buildDeliveryIcon(context),
      ],
    );

    // countdownTickNotifier ticks once per second UNCONDITIONALLY. Subscribing
    // regardless of the message rebuilt every visible bubble's metadata — plus
    // a SettingsProvider read inside the delivery icon — at 1 Hz in chats with
    // no ephemeral messages at all. Same gate as conversation_tile.dart.
    if (!HearthFadeHexIndicator.showsEphemeralState(message)) {
      return staticRow;
    }

    return ValueListenableBuilder<int>(
      valueListenable: context.read<MessagingProvider>().countdownTickNotifier,
      child: staticRow,
      builder: (ctx, tick, child) {
        if (!HearthFadeHexIndicator.showsEphemeralState(message)) {
          return child!;
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [child!, _buildEphemeralIndicator()],
        );
      },
    );
  }
}
