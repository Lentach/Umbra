import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:webcrypto/webcrypto.dart';

import '../../config/app_config.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_exception.dart';
import '../../services/api_service.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/anti_quantum_note_link.dart';
import '../glass/glass_sheet.dart';

/// Outcome of one reveal+decrypt attempt. Network/transport failures are NOT
/// an outcome — they throw, because a thrown attempt may or may not have
/// burned the note and the sheet must say neither "destroyed" nor "safe".
sealed class NoteRevealOutcome {
  const NoteRevealOutcome();
}

/// The note was destroyed server-side and decrypted successfully.
class NoteRevealed extends NoteRevealOutcome {
  final String plaintext;
  const NoteRevealed(this.plaintext);
}

/// Server answered 404: the note is gone — already read, or expired. The
/// caller disambiguates with the link's own `e=` clock.
class NoteRevealGone extends NoteRevealOutcome {
  const NoteRevealGone();
}

/// The reveal succeeded (the note IS destroyed) but the ciphertext could not
/// be decrypted — wrong key of the right length or corrupt payload.
class NoteRevealCorrupt extends NoteRevealOutcome {
  const NoteRevealCorrupt();
}

/// Test seam: performs the destructive reveal POST + decrypt.
typedef NoteRevealAttempt = Future<NoteRevealOutcome> Function();

/// Byte-exact Dart mirror of the server landing page's reveal script
/// (`secret-notes.controller.ts` `landingPage()`):
///
///  1. Key: first `&`-segment of the URL fragment, base64url, EXACTLY 32
///     bytes — validated and imported BEFORE the destructive POST, so a
///     mangled fragment can never burn the note.
///  2. `POST /note/<token>/reveal` (public, no body) → `{ ciphertext }`,
///     404 `{ error: 'gone' }` when read/expired.
///  3. Ciphertext `base64(iv):base64(ct||tag)` — 12-byte IV, AES-256-GCM
///     with the 16-byte tag appended (WebCrypto convention on both ends).
Future<NoteRevealOutcome> revealAntiQuantumNote(
  ApiService api,
  AntiQuantumNoteLink link,
) async {
  final keyBytes = decodeAntiQuantumNoteKey(link.url);
  // The sheet pre-checks the key and never attempts with a broken link; a
  // direct caller with a bad fragment gets Corrupt WITHOUT a server call.
  if (keyBytes == null) return const NoteRevealCorrupt();
  final aesKey = await AesGcmSecretKey.importRawKey(keyBytes);

  final ciphertext = await api.revealSecretNote(link.token, origin: link.origin);
  if (ciphertext == null) return const NoteRevealGone();

  try {
    final parts = ciphertext.split(':');
    if (parts.length != 2) return const NoteRevealCorrupt();
    final iv = Uint8List.fromList(base64.decode(parts[0]));
    final ct = Uint8List.fromList(base64.decode(parts[1]));
    final plain = await aesKey.decryptBytes(ct, iv);
    return NoteRevealed(utf8.decode(plain));
  } on Object {
    return const NoteRevealCorrupt();
  }
}

/// Opens the in-app one-time reveal surface for an own-origin Anti-Quantum
/// Note. Once the reveal is decrypting it cannot be closed (the note is burned
/// and this screen holds the only copy of its text); in every other phase,
/// closing simply returns to the chat — that is the
/// whole point of revealing in-app instead of launching a browser tab.
Future<void> showAntiQuantumNoteRevealSheet(
  BuildContext context, {
  required AntiQuantumNoteLink link,
  NoteRevealAttempt? attempt,
}) {
  return showGlassSheet<void>(
    context,
    isScrollControlled: true,
    enableDrag: false,
    builder: (_) => AntiQuantumNoteRevealSheet(link: link, attempt: attempt),
  );
}

/// State machine: `confirm` (burn warning — NEVER auto-reveals) → `revealing`
/// → `revealed` | `destroyed` | `expired` | `corrupt` | `networkError` |
/// `serverError` | `rateLimited` | `maybeBurned` (a retry found the note gone
/// after an earlier attempt whose outcome is unknown, so it must not claim
/// someone else read it).
/// A link whose fragment key fails the 32-byte pre-flight opens straight in
/// `invalidLink` (nothing was burned); a link whose `e=` clock already ran
/// out opens straight in `expired` (the server would 404 anyway — no reason
/// to spend the destructive POST).
class AntiQuantumNoteRevealSheet extends StatefulWidget {
  final AntiQuantumNoteLink link;

  /// Overrides the default REST reveal in tests.
  final NoteRevealAttempt? attempt;

  const AntiQuantumNoteRevealSheet({
    super.key,
    required this.link,
    this.attempt,
  });

  @override
  State<AntiQuantumNoteRevealSheet> createState() =>
      _AntiQuantumNoteRevealSheetState();
}

enum _Phase {
  confirm,
  revealing,
  revealed,
  destroyed,
  expired,
  corrupt,
  invalidLink,
  networkError,
  serverError,
  rateLimited,
  maybeBurned,
}

class _AntiQuantumNoteRevealSheetState
    extends State<AntiQuantumNoteRevealSheet> {
  late _Phase _phase;
  String? _plaintext;

  /// An attempt threw (timeout, dropped response, a 5xx answer): the server
  /// may have deleted the note before the answer was lost or failed.
  bool _attemptOutcomeUnknown = false;

  @override
  void initState() {
    super.initState();
    if (decodeAntiQuantumNoteKey(widget.link.url) == null) {
      _phase = _Phase.invalidLink;
    } else if (_clockDead) {
      _phase = _Phase.expired;
    } else {
      _phase = _Phase.confirm;
    }
  }

  bool get _clockDead {
    final expiresAt = widget.link.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(DateTime.now());
  }

  /// The ONE close. The outgoing confirm child stays on screen (and tappable)
  /// for the 220 ms cross-fade, so its Cancel/X must not pop mid-reveal.
  void _close() {
    if (_phase == _Phase.revealing) return;
    Navigator.of(context).pop();
  }

  Future<void> _reveal() async {
    // The old "Reveal & destroy" / "Try again" button stays tappable for the
    // 220 ms cross-fade; a second POST would find the note already burned by
    // the first and replace its text with "already read".
    if (_phase == _Phase.revealing) return;
    setState(() => _phase = _Phase.revealing);
    final attempt = widget.attempt ??
        () => revealAntiQuantumNote(
              ApiService(baseUrl: AppConfig.baseUrl),
              widget.link,
            );
    try {
      final outcome = await attempt();
      if (!mounted) return;
      setState(() {
        switch (outcome) {
          case NoteRevealed(:final plaintext):
            _plaintext = plaintext;
            _phase = _Phase.revealed;
          case NoteRevealGone():
            // Re-check the clock AFTER the await: gone past the clock is
            // expiry, gone before it means someone already read the note.
            // An earlier attempt that threw may itself have burned the note
            // (the response was lost), so "gone" is then not proof that
            // someone else read it.
            _phase = _clockDead
                ? _Phase.expired
                : _attemptOutcomeUnknown
                    ? _Phase.maybeBurned
                    : _Phase.destroyed;
          case NoteRevealCorrupt():
            _phase = _Phase.corrupt;
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      // The server's throttler answers 429 BEFORE the reveal handler runs, so
      // that attempt cannot have burned the note. Any other answer (a gateway
      // 502/504 can follow the DELETE) and any lost answer leave it unknown.
      if (e is ApiException && e.statusCode == 429) {
        setState(() => _phase = _Phase.rateLimited);
        return;
      }
      _attemptOutcomeUnknown = true;
      setState(
        () => _phase =
            e is ApiException ? _Phase.serverError : _Phase.networkError,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      // The reveal POST has burned (or is burning) the note; closing now would
      // throw the only copy of its text away. Back and a barrier tap both
      // route through here; the swipe is off in [showAntiQuantumNoteRevealSheet].
      canPop: _phase != _Phase.revealing,
      child: Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
      ),
      child: AnimatedSwitcher(
        duration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeOut,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        // Bottom-aligned so the sheet growing/shrinking between phases
        // doesn't visually detach content from the sheet's bottom edge.
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.bottomCenter,
          children: [...previousChildren, ?currentChild],
        ),
        child: KeyedSubtree(
          key: ValueKey(_phase),
          child: switch (_phase) {
            _Phase.confirm => _buildConfirm(context),
            _Phase.revealing => _buildRevealing(context),
            _Phase.revealed => _buildRevealed(context),
            _Phase.destroyed => _buildTerminal(
                context,
                key: const Key('note-reveal-destroyed'),
                icon: Icons.local_fire_department,
                title: AppLocalizations.of(context).antiQuantumNoteBurnedTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealDestroyedBody,
              ),
            _Phase.expired => _buildTerminal(
                context,
                key: const Key('note-reveal-expired'),
                icon: Icons.hourglass_bottom,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealExpiredTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealExpiredBody,
              ),
            _Phase.corrupt => _buildTerminal(
                context,
                key: const Key('note-reveal-corrupt'),
                icon: Icons.error_outline,
                title: AppLocalizations.of(context).antiQuantumNoteBurnedTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealCorruptBody,
              ),
            _Phase.invalidLink => _buildTerminal(
                context,
                key: const Key('note-reveal-invalid-link'),
                icon: Icons.link_off,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealInvalidLinkTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealInvalidLinkBody,
              ),
            _Phase.serverError => _buildTerminal(
                context,
                key: const Key('note-reveal-server-error'),
                icon: Icons.cloud_off,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealServerErrorTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealServerErrorBody,
                retry: true,
              ),
            _Phase.rateLimited => _buildTerminal(
                context,
                key: const Key('note-reveal-rate-limited'),
                icon: Icons.hourglass_top,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealBusyTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealBusyBody,
                retry: true,
              ),
            _Phase.networkError => _buildTerminal(
                context,
                key: const Key('note-reveal-network-error'),
                icon: Icons.wifi_off,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealNetworkErrorTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealUnknownOutcomeBody,
                retry: true,
              ),
            _Phase.maybeBurned => _buildTerminal(
                context,
                key: const Key('note-reveal-maybe-burned'),
                icon: Icons.help_outline,
                title: AppLocalizations.of(context)
                    .antiQuantumNoteRevealMaybeBurnedTitle,
                body: AppLocalizations.of(context)
                    .antiQuantumNoteRevealMaybeBurnedBody,
              ),
          },
        ),
      ),
    ));
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final fc = FireplaceColors.of(context);
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Icon(Icons.lock_outline, size: 20, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.antiQuantumNoteTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (_phase != _Phase.revealing)
          IconButton(
            key: const Key('note-reveal-close'),
            icon: const Icon(Icons.close, size: 20),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: _close,
            color: fc.mutedText,
          ),
      ],
    );
  }

  Widget _buildConfirm(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fc = FireplaceColors.of(context);
    final l10n = AppLocalizations.of(context);
    final onError = RpgTheme.readableOn(colorScheme.error);
    return Column(
      key: const Key('note-reveal-confirm'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colorScheme.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: colorScheme.error.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.local_fire_department,
                size: 20,
                color: colorScheme.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.antiQuantumNoteRevealWarning,
                  style: RpgTheme.bodyFont(
                    fontSize: 13,
                    color: colorScheme.onSurface,
                  ).copyWith(height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('note-reveal-cancel'),
                onPressed: _close,
                style: OutlinedButton.styleFrom(
                  foregroundColor: fc.mutedText,
                  side: BorderSide(color: fc.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  l10n.cancel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                key: const Key('note-reveal-button'),
                onPressed: _reveal,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: onError,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  l10n.antiQuantumNoteRevealConfirm,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            l10n.antiQuantumNoteFooter,
            style: TextStyle(fontSize: 10, color: fc.mutedText),
          ),
        ),
      ],
    );
  }

  Widget _buildRevealing(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      key: const Key('note-reveal-loading'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 20),
        Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: colorScheme.error,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            l10n.antiQuantumNoteRevealLoading,
            style: RpgTheme.bodyFont(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildRevealed(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fc = FireplaceColors.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 4),
        Text(
          l10n.antiQuantumNoteRevealedHeader.toUpperCase(),
          style: RpgTheme.bodyFont(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurfaceVariant,
          ).copyWith(letterSpacing: 1.1),
        ),
        const SizedBox(height: 10),
        // The plaintext exists ONLY on this screen now — the note is gone
        // server-side. Selectable so the reader can copy it before closing.
        Flexible(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: fc.borderColor),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _plaintext ?? '',
                key: const Key('note-reveal-plaintext'),
                style: RpgTheme.bodyFont(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ).copyWith(height: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.antiQuantumNoteRevealedFooter,
          style: TextStyle(fontSize: 11, color: fc.mutedText),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _close,
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.onSurface,
              side: BorderSide(color: fc.borderColor),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              l10n.antiQuantumNoteRevealClose,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTerminal(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String body,
    bool retry = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fc = FireplaceColors.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: RpgTheme.bodyFont(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: RpgTheme.bodyFont(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ).copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _close,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.onSurface,
                  side: BorderSide(color: fc.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  l10n.antiQuantumNoteRevealClose,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (retry) ...[
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  key: const Key('note-reveal-retry'),
                  onPressed: _reveal,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: RpgTheme.readableOn(colorScheme.primary),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    l10n.antiQuantumNoteRevealRetry,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
