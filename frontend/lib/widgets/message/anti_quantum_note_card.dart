import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_config.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/anti_quantum_note_link.dart';
import 'anti_quantum_note_reveal_sheet.dart';

// The burn-after-reading card's own gradient. `_kNoteRed` happens to share a
// hex with RpgTheme.errorColorLight, but that is coincidence, not identity:
// this is a brand surface, not an error state, and binding it to the error
// token would let a future error-colour change silently restyle the card.
const Color _kNoteRed = Color(0xFFC0392B);
const Color _kNoteRedDark = Color(0xFF922B21);

/// How often a live card re-checks server-side note existence.
const kNoteAliveProbeInterval = Duration(seconds: 30);

/// Test seam: resolves whether the note behind [token] still exists.
typedef NoteAliveProbe = Future<bool> Function(String token);

/// The probe a card uses when none is injected: a bare `GET /note/<token>/status`
/// on the app's own API. It carries no login and no other identifier, so the
/// server cannot tie the polling account to the account that created the note
/// (A3-MSG-B-04, owner decision 2026-11-26).
NoteAliveProbe defaultNoteAliveProbe() =>
    ApiService(baseUrl: AppConfig.baseUrl).isNoteAlive;

/// In-chat banner for an Anti-Quantum Note link. Replaces the raw URL text
/// (and any link-preview card) inside the TEXT bubble. Tapping an own-origin
/// link opens the in-app reveal sheet (burn-confirm first — see
/// anti_quantum_note_reveal_sheet.dart); a foreign-origin URL keeps the
/// external browser launch the plain-link path uses.
///
/// When the link carries an `e=` expiry (see anti_quantum_note_link.dart) the
/// banner shows a live self-destruct countdown, and flips to a "destroyed"
/// state at the exact server-side death moment — fully client-side.
///
/// While the note is alive by its clock, the card also probes the status
/// endpoint (on mount + every [kNoteAliveProbeInterval]): a note that is gone
/// BEFORE its clock ran out was read, and the card collapses to a burned
/// "Note destroyed — it was read" remnant. Probe failures fail OPEN (a
/// network blip must never claim a live note burned); without a known expiry
/// (legacy links) a dead note falls back to the generic destroyed state.
class AntiQuantumNoteCard extends StatefulWidget {
  final String noteUrl;

  /// Overrides the default REST probe in tests. When null the card uses
  /// [defaultNoteAliveProbe] (an anonymous status call).
  final NoteAliveProbe? aliveProbe;
  final bool isMine;
  final Color textColor;
  final bool isDark;
  final double maxWidth;

  const AntiQuantumNoteCard({
    super.key,
    required this.noteUrl,
    required this.isMine,
    required this.textColor,
    required this.isDark,
    required this.maxWidth,
    this.aliveProbe,
  });

  @override
  State<AntiQuantumNoteCard> createState() => _AntiQuantumNoteCardState();
}

class _AntiQuantumNoteCardState extends State<AntiQuantumNoteCard> {
  DateTime? _expiresAt;
  String? _token;
  Timer? _ticker;
  Timer? _probeTimer;
  bool _burned = false;
  bool _probeInFlight = false;

  bool get _destroyed =>
      _expiresAt != null && !_expiresAt!.isAfter(DateTime.now());

  @override
  void initState() {
    super.initState();
    _parseLink();
    _armTicker();
    _armProbe();
  }

  @override
  void didUpdateWidget(covariant AntiQuantumNoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteUrl != widget.noteUrl) {
      _parseLink();
      _burned = false;
      _armTicker();
      _armProbe();
    }
  }

  void _parseLink() {
    final link = parseAntiQuantumNoteLink(widget.noteUrl);
    _expiresAt = link?.expiresAt;
    _token = link?.token;
  }

  void _armTicker() {
    _ticker?.cancel();
    if (_expiresAt == null || _destroyed) return;
    // Minute granularity is what the label shows; re-arm each tick so the
    // final tick lands on the destruction moment, not up to 59s past it.
    final remaining = _expiresAt!.difference(DateTime.now());
    final tickIn = remaining.inSeconds <= 60
        ? remaining + const Duration(seconds: 1)
        : Duration(seconds: (remaining.inSeconds % 60) + 1);
    _ticker = Timer(tickIn, () {
      if (!mounted) return;
      setState(() {});
      _armTicker();
    });
  }

  /// Probe only while the note can still flip to "burned": a known expiry in
  /// the future. Once burned, clock-dead, or expiry-less there is nothing a
  /// probe could change — legacy links without `e=` cannot distinguish
  /// read-vs-expired, so they keep the generic destroyed state.
  void _armProbe() {
    _probeTimer?.cancel();
    if (_burned || _destroyed || _expiresAt == null || _token == null) return;
    scheduleMicrotask(_probeOnce);
    _probeTimer = Timer.periodic(kNoteAliveProbeInterval, (_) => _probeOnce());
  }

  /// Built once per card: every probe reuses one HTTP client instead of
  /// opening a new one every [kNoteAliveProbeInterval].
  late final NoteAliveProbe _probe =
      widget.aliveProbe ?? defaultNoteAliveProbe();

  Future<void> _probeOnce() async {
    if (_probeInFlight || _burned || _destroyed) return;
    final probe = _probe;
    _probeInFlight = true;
    try {
      final alive = await probe(_token!);
      if (!mounted) return;
      // Re-check the clock AFTER the await: if the timer ran out mid-flight,
      // "gone" is just expiry and must not claim a read.
      if (!alive && !_destroyed && !_burned) {
        setState(() => _burned = true);
        _probeTimer?.cancel();
        _ticker?.cancel();
      }
    } catch (_) {
      // Fail open: transport/HTTP errors keep the card alive; the periodic
      // timer retries.
    } finally {
      _probeInFlight = false;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _probeTimer?.cancel();
    super.dispose();
  }

  String _countdownLabel() {
    final remaining = _expiresAt!.difference(DateTime.now());
    final h = remaining.inHours;
    final m = remaining.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (remaining.inMinutes >= 1) return '${m}m';
    return '<1m';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_burned) return _buildBurnedPill(l10n);
    final destroyed = _destroyed;
    final cardBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);
    final subtitleColor = widget.isMine
        ? widget.textColor.withValues(alpha: 0.75)
        : (widget.isDark
              ? RpgTheme.timeColorDark
              : RpgTheme.textSecondaryLight);
    final badgeGradient = destroyed
        ? LinearGradient(
            colors: [Colors.grey.shade600, Colors.grey.shade800],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [_kNoteRed, _kNoteRedDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: GestureDetector(
        key: const Key('anti-quantum-note-card'),
        onTap: () {
          final link = parseOwnOriginNoteLink(widget.noteUrl);
          if (link != null) {
            showAntiQuantumNoteRevealSheet(context, link: link);
          } else {
            launchUrl(
              Uri.parse(widget.noteUrl),
              mode: LaunchMode.externalApplication,
            );
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.hardEdge,
          // No IntrinsicHeight: it measures text at unconstrained width, so a
          // wrapped 2-line subtitle overflows the frozen height. The Stack lets
          // the Row size itself; the accent bar is pinned to the full height.
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: destroyed
                        ? LinearGradient(
                            colors: [
                              Colors.grey.shade600,
                              Colors.grey.shade800,
                            ],
                          )
                        : const LinearGradient(
                            colors: [_kNoteRed, _kNoteRedDark],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: badgeGradient,
                          boxShadow: destroyed
                              ? null
                              : [
                                  BoxShadow(
                                    color: _kNoteRed.withValues(alpha: 0.35),
                                    blurRadius: 6,
                                  ),
                                ],
                        ),
                        child: Icon(
                          destroyed
                              ? Icons.local_fire_department
                              : Icons.lock_outline,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          right: 12,
                          top: 8,
                          bottom: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.antiQuantumNoteTitle,
                              style: RpgTheme.bodyFont(
                                fontSize: 13,
                                color: widget.textColor,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              destroyed
                                  ? l10n.antiQuantumNoteCardDestroyed
                                  : l10n.antiQuantumNoteCardSubtitle,
                              style: RpgTheme.bodyFont(
                                fontSize: 11,
                                color: subtitleColor,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (!destroyed && _expiresAt != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                l10n.antiQuantumNoteCardCountdown(
                                  _countdownLabel(),
                                ),
                                key: const Key('anti-quantum-note-countdown'),
                                style: RpgTheme.bodyFont(
                                  fontSize: 11,
                                  // Brand red drowns on dark bubbles; use the
                                  // lightened variant there for contrast.
                                  color: widget.isDark
                                      ? const Color(0xFFE9776B)
                                      : _kNoteRed,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Option-C burned remnant: the card collapses to a slim ash pill. Nothing
  /// is tappable — the reveal page behind the link no longer exists.
  Widget _buildBurnedPill(AppLocalizations l10n) {
    final labelColor = widget.isMine
        ? widget.textColor.withValues(alpha: 0.55)
        : (widget.isDark
              ? RpgTheme.timeColorDark
              : RpgTheme.textSecondaryLight);
    final titleColor = widget.isMine
        ? widget.textColor.withValues(alpha: 0.8)
        : (widget.isDark ? Colors.white70 : Colors.black54);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Container(
        key: const Key('anti-quantum-note-burned-pill'),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: widget.isDark ? 0.28 : 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        padding: const EdgeInsets.fromLTRB(6, 5, 14, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.grey.shade700, Colors.grey.shade900],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(
                Icons.local_fire_department,
                size: 13,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: l10n.antiQuantumNoteBurnedTitle,
                      style: RpgTheme.bodyFont(
                        fontSize: 12,
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(
                      text: ' — ${l10n.antiQuantumNoteBurnedSubtitle}',
                      style: RpgTheme.bodyFont(fontSize: 12, color: labelColor),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
