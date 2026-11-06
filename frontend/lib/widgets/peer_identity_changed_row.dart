import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';
import 'peer_identity_fingerprint_dialog.dart';

/// In-conversation timeline row shown while the peer's identity change is
/// unacknowledged (Phase 0a, owner-ratified 2026-08-17 — this narrower
/// event-driven row explicitly supersedes the 2026-08-15 banner removal; do
/// NOT resurrect `PeerIdentityChangedBanner`).
///
/// Rendered at the newest end of the chat timeline while
/// `EncryptionProvider.peersWithChangedIdentity` contains the peer; tapping it
/// opens the fingerprint dialog, whose confirm action
/// (`acknowledgePeerIdentity`) is the only thing that clears the state and
/// therefore this row. Styled after [MessageDateSeparator]'s centered pill but
/// on the error palette: a system row, not a message bubble.
class PeerIdentityChangedRow extends StatelessWidget {
  final int peerId;
  final String peerName;

  const PeerIdentityChangedRow({
    super.key,
    required this.peerId,
    required this.peerName,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Material(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showPeerIdentityFingerprintDialog(
              context: context,
              peerId: peerId,
              peerName: peerName,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.key_outlined,
                    size: 14,
                    color: colors.onErrorContainer,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      l10n.peerIdentityChangedTimelineRow(peerName),
                      textAlign: TextAlign.center,
                      style: RpgTheme.bodyFont(
                        fontSize: 11,
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The DEMOTED key-change surface (amendment (lxxix)): with
/// `SettingsProvider.keyChangeWarnings` OFF (the default) a peer identity
/// change is auto-acknowledged and the timeline gets this ONE muted system
/// line instead of the [PeerIdentityChangedRow] pill.
///
/// Muted body-small text on purpose: no
/// error palette, no security icon — a routine "new device" note, not an
/// alarm. No tap is required, but tapping still opens the fingerprint dialog
/// so a curious user can verify.
class PeerIdentityChangedNote extends StatelessWidget {
  final int peerId;
  final String peerName;

  const PeerIdentityChangedNote({
    super.key,
    required this.peerId,
    required this.peerName,
  });

  @override
  Widget build(BuildContext context) {
    final mutedColor = RpgTheme.isDark(context)
        ? RpgTheme.mutedDark
        : RpgTheme.textSecondaryLight;
    return GestureDetector(
      key: const ValueKey('peer-identity-changed-note'),
      behavior: HitTestBehavior.opaque,
      onTap: () => showPeerIdentityFingerprintDialog(
        context: context,
        peerId: peerId,
        peerName: peerName,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          AppLocalizations.of(context).peerIdentityChangedSystemLine(peerName),
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: mutedColor),
        ),
      ),
    );
  }
}
