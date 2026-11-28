import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import '../services/encryption_service.dart';
import 'glass/glass_dialog.dart';

/// Side-by-side identity fingerprints for out-of-band verification.
///
/// This is the ONLY defence against a server-side key substitution. Fireplace's
/// server hands out prekey bundles and nothing in the Signal protocol proves a
/// bundle belongs to the claimed user, so two humans comparing these numbers —
/// in person or over a call where they recognise the voice — is what separates
/// "encrypted" from "encrypted to whoever the server said".
///
/// Opened proactively from the peer's Safety section ("Verify security keys"
/// on the user card), BEFORE anything goes wrong — the proactive door matters
/// because a first-contact substitution never produces a change to warn about,
/// there being no earlier key to differ from — and reactively from
/// [PeerIdentityChangedRow] when a change is standing.
///
/// **It shows the key that confirming will PIN** (spec §12 amendment (xlvii)
/// clause 2). Until that amendment it displayed the currently pinned anchor
/// while the confirm button promoted a different, never-displayed candidate: for
/// any real rotation the number on screen could not match what the peer read
/// out, so a careful user refused a legitimate change and a careless one
/// accepted a key they had never compared. The ceremony verified one number and
/// adopted another.
Future<void> showPeerIdentityFingerprintDialog({
  required BuildContext context,
  required int peerId,
  required String peerName,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _PeerIdentityFingerprintDialog(peerId: peerId, peerName: peerName),
  );
}

/// Stateful because the offered key must be readable by the CONFIRM ACTION, not
/// only by the content builder: the button pins exactly the bytes whose
/// fingerprint was rendered, and a `FutureBuilder` wrapping only the content
/// cannot hand them to `actions`.
class _PeerIdentityFingerprintDialog extends StatefulWidget {
  const _PeerIdentityFingerprintDialog({
    required this.peerId,
    required this.peerName,
  });

  final int peerId;
  final String peerName;

  @override
  State<_PeerIdentityFingerprintDialog> createState() =>
      _PeerIdentityFingerprintDialogState();
}

class _PeerIdentityFingerprintDialogState
    extends State<_PeerIdentityFingerprintDialog> {
  PeerIdentityVerification? _verification;
  String? _ownFingerprint;
  bool _loading = true;

  /// The confirmation was refused because what the user compared is not what
  /// would be pinned — the candidate moved while this dialog was open, or the
  /// key was never recorded. The dialog stays open showing the CURRENT
  /// fingerprint, because closing it would leave a standing warning with no
  /// explanation of why nothing happened.
  bool _staleOffer = false;

  /// "Mark as verified" was refused: the pinned key is no longer the one shown.
  bool _keyChangedWhileOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final encryption = context.read<EncryptionProvider>();
    // loadPeerIdentityVerification may go to the network — a standing warning
    // with no local candidate is the (xlvii) clause 3 shape, where the peer's
    // currently served identity is the only thing there is to compare.
    final verification = await encryption.loadPeerIdentityVerification(
      widget.peerId,
    );
    final own = await encryption.getIdentityFingerprint();
    if (!mounted) return;
    setState(() {
      _verification = verification;
      _ownFingerprint = own;
      _loading = false;
    });
  }

  Future<void> _confirm(String? adoptIdentityBase64) async {
    final encryption = context.read<EncryptionProvider>();
    final navigator = Navigator.of(context);
    final adopted = await encryption.acknowledgePeerIdentity(
      widget.peerId,
      adoptIdentityBase64: adoptIdentityBase64,
      // Comparing the new fingerprint IS verifying it: re-bind the flag.
      markVerified: true,
    );
    if (!mounted) return;
    if (adopted) {
      navigator.pop();
      return;
    }
    // Refused. Re-read and show the fingerprint that is actually on offer now,
    // so the user compares the right number rather than being dropped back to a
    // warning that silently did not clear.
    setState(() {
      _staleOffer = true;
      _loading = true;
    });
    await _load();
  }

  Future<void> _markFriendVerified() async {
    final shown = _verification?.pinnedIdentityBase64;
    if (shown == null) return;
    // Binds to the key that was DISPLAYED; refused when the anchor moved
    // while this dialog was open.
    final marked = await context.read<EncryptionProvider>().markPeerVerified(
      widget.peerId,
      expectedIdentityBase64: shown,
    );
    if (!mounted) return;
    setState(() {
      _keyChangedWhileOpen = !marked;
      _loading = true;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Rebuilds when the warning clears, so the confirm button disappears the
    // moment it is used.
    final hasStandingWarning = context.select<EncryptionProvider, bool>(
      (e) => e.peersWithChangedIdentity.contains(widget.peerId),
    );
    final verification = _verification;
    final offered = verification?.offeredFingerprint;
    final offeredKey = verification?.offeredIdentityBase64;

    // GlassDialog is the app's dialog shell; a raw AlertDialog here was a
    // second convention on a security surface.
    return GlassDialog(
      title: Text(l10n.peerIdentityFingerprintDialogTitle),
      content: _loading
          ? const SizedBox(
              height: 56,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.peerIdentityFingerprintDialogDescription(
                      widget.peerName,
                    ),
                  ),
                  if (_staleOffer) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.peerIdentityFingerprintOfferChanged(widget.peerName),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_keyChangedWhileOpen) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.peerIdentityKeyChangedWhileOpen,
                      key: const ValueKey('peer-identity-key-changed-open'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (offered != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.peerIdentityFingerprintChangedNotice(
                        widget.peerName,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (verification!.offeredWasServed) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.peerIdentityFingerprintServedNotice(
                          widget.peerName,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 16),
                    // The key confirming will pin, first: it is the one the
                    // user must read against the peer's own copy.
                    _FingerprintBlock(
                      label: l10n.peerIdentityFingerprintNewLabel(
                        widget.peerName,
                      ),
                      value: offered,
                      missing: l10n.peerIdentityFingerprintNoStoredKey,
                    ),
                    const SizedBox(height: 16),
                    _FingerprintBlock(
                      label: l10n.peerIdentityFingerprintPreviousLabel,
                      value: verification.pinnedFingerprint,
                      missing: l10n.peerIdentityFingerprintNoStoredKey,
                    ),
                  ] else ...[
                    if (hasStandingWarning) ...[
                      const SizedBox(height: 12),
                      Text(
                        // Two very different situations, and conflating them
                        // would be a lie: either the key is confirmed
                        // UNCHANGED (so confirming just dismisses), or we could
                        // not load it at all (so there is nothing to compare).
                        verification?.offerMatchesPin == true
                            ? l10n.peerIdentityFingerprintUnchangedNotice(
                                widget.peerName,
                              )
                            : l10n.peerIdentityFingerprintOfferUnavailable(
                                widget.peerName,
                              ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _FingerprintBlock(
                      label: l10n.peerIdentityFingerprintPeerLabel(
                        widget.peerName,
                      ),
                      value: verification?.pinnedFingerprint,
                      missing: l10n.peerIdentityFingerprintNoStoredKey,
                    ),
                    if (verification?.verified == true && !hasStandingWarning) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.peerIdentityVerifiedState,
                        key: const ValueKey('peer-identity-verified-state'),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  _FingerprintBlock(
                    label: l10n.yourIdentityFingerprint,
                    value: _ownFingerprint,
                    missing: l10n.identityFingerprintUnavailable,
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        // Offered nothing to pin => nothing to confirm. Confirming with no
        // offer would land on the pending-candidate fallback, which is exactly
        // the no-op that used to destroy the warning ((xlvii) clause 1).
        if (hasStandingWarning && !_loading && offeredKey != null)
          TextButton(
            onPressed: () => _confirm(offeredKey),
            child: Text(l10n.peerIdentityMarkVerifiedAction),
          ),
        // No standing change and not verified yet: the user compared the
        // number above with the friend's own and says so. Bound to this key.
        if (!hasStandingWarning &&
            !_loading &&
            verification != null &&
            verification.pinnedFingerprint != null &&
            !verification.verified &&
            !verification.verifiedUnknown)
          TextButton(
            key: const ValueKey('peer-identity-mark-friend-verified'),
            onPressed: _markFriendVerified,
            child: Text(l10n.peerIdentityMarkFriendVerifiedAction),
          ),
      ],
    );
  }
}

/// One labelled fingerprint. An absent value renders as PLAIN text, never
/// selectable: "no stored key" is an explanation, not a number to compare, and
/// making it selectable invites copying it as if it were one.
class _FingerprintBlock extends StatelessWidget {
  const _FingerprintBlock({
    required this.label,
    required this.value,
    required this.missing,
  });

  final String label;
  final String? value;
  final String missing;

  @override
  Widget build(BuildContext context) {
    final fingerprint = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        if (fingerprint == null)
          Text(missing)
        else
          // MONOSPACE, with generous letter spacing. The entire defence of this
          // ceremony is a human reading digits aloud and another human checking
          // them one by one; proportional Inter makes 1/l and 0/O ambiguous and
          // lets the columns drift, which is precisely the comparison we are
          // asking them to perform accurately.
          SelectableText(
            fingerprint,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Courier New', 'monospace'],
              fontSize: 15,
              letterSpacing: 1.2,
              height: 1.5,
            ),
          ),
      ],
    );
  }
}
