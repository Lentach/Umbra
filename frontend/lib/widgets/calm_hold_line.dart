import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/messaging_provider.dart';
import '../theme/rpg_theme.dart';

/// The neutral line a CALM hold shows (decision 152, option C): a friend's
/// message from a new device or browser waits for one tap. Muted — not the red
/// [PeerIdentityChangedRow]: nothing is wrong yet, the key is simply not
/// confirmed. Three states: the invitation, "checking", and a retry hint.
class CalmHoldLine extends StatelessWidget {
  const CalmHoldLine({
    required this.peerName,
    required this.state,
    required this.onTap,
    super.key,
  });

  final String peerName;
  final CalmHoldState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mutedColor = RpgTheme.isDark(context)
        ? RpgTheme.mutedDark
        : RpgTheme.textSecondaryLight;
    final text = switch (state) {
      CalmHoldState.waiting => l10n.calmHoldLine(peerName),
      CalmHoldState.checking => l10n.calmHoldChecking,
      CalmHoldState.failed => l10n.calmHoldFailed,
    };
    return Semantics(
      button: true,
      label: text,
      child: GestureDetector(
        key: const ValueKey('calm-hold-line'),
        behavior: HitTestBehavior.opaque,
        // A second tap while checking is ignored by the provider too.
        onTap: state == CalmHoldState.checking ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: ExcludeSemantics(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: mutedColor),
            ),
          ),
        ),
      ),
    );
  }
}
