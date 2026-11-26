import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/rpg_theme.dart';
import '../ping_glyph.dart';

/// Content widget for PING message type.
class PingMessageContent extends StatelessWidget {
  final bool isMine;
  final Color textColor;

  const PingMessageContent({
    super.key,
    required this.isMine,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: isMine
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        PingGlyph(size: 18, color: textColor),
        const SizedBox(width: 6),
        Text(
          AppLocalizations.of(context).pingBubbleLabel,
          style: RpgTheme.bodyFont(
            fontSize: 14,
            color: textColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
