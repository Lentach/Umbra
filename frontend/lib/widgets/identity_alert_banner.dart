import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Which palette an [IdentityAlertBanner] wears.
///
/// An ENUM rather than a pair of colors on purpose: this shell exists because
/// three banners each carried their own hand-pinned foreground, and handing
/// callers raw `Color`s would reopen exactly that — including the freedom to
/// pair two slots that do not contrast. The mapping to `ColorScheme` lives in
/// one place, below.
enum AlertTone {
  /// Identity and key material: "act now, your keys are at stake."
  security,

  /// Routine news that happens to need the same collapsed chrome. Kept
  /// visually distinct so it cannot spend [security]'s urgency.
  informational;

  Color background(ColorScheme colors) => switch (this) {
    security => colors.errorContainer,
    informational => colors.surfaceContainerHighest,
  };

  Color foreground(ColorScheme colors) => switch (this) {
    security => colors.onErrorContainer,
    informational => colors.onSurface,
  };
}

/// The ONE shell every identity/security banner in the app shell uses.
///
/// Banners ([OwnIdentityReplacedBanner],
/// [IdentityResetPendingBanner]) previously each carried their own copy of the
/// same skeleton — `Material(errorContainer)` → `SafeArea` → `Padding(16,12,8,12)`
/// → `Row` → 20px glyph → title `titleSmall/w700` → 4px → body `bodySmall` →
/// `TextButton` with a hand-pinned foreground. Three copies of one layout is
/// three places for a contrast or padding fix to be missed, and the pinned
/// foreground comment had already been copy-pasted twice.
///
/// **Collapsed by default, and that is the point.** Each of those banners
/// rendered two to four sentences of prose in PERSISTENT chrome, on every
/// launch, and they stack: two of them together took roughly half a phone
/// screen before the conversation list even started. A warning nobody finishes
/// reading trains exactly the dismissal reflex that the whole identity surface
/// exists to avoid — the same argument the spec uses to refuse server-summonable
/// alarms, applied to our own copy. So the collapsed form carries the one line
/// that says what happened plus the action, and the full explanation is one tap
/// away and still fully available.
///
/// [SafeArea] is deliberately NOT applied here: these banners are siblings in a
/// [Column], and sibling `SafeArea`s each apply the FULL top inset, so three of
/// them stacked produced two phantom status-bar gaps. The shell wraps the whole
/// stack once instead.

class IdentityAlertBanner extends StatefulWidget {
  const IdentityAlertBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.summary,
    this.action,
    this.secondaryAction,
    this.semanticPrefix,
    this.tone = AlertTone.security,
  });

  /// The 20px security glyph. Distinct per banner so the three states are
  /// visually separable at a glance while collapsed.
  final IconData icon;

  /// The one line that says what happened. Shown always.
  final String title;

  /// The full explanation. Hidden until the user asks for it.
  final String detail;

  /// Optional short status kept visible while collapsed — a countdown, not
  /// prose. One line, ellipsized.
  final String? summary;

  /// The primary action. Stays visible while collapsed: for a damaged identity
  /// this is the user's ONLY way out, so it must never be behind a disclosure.
  final Widget? action;

  /// An optional second action, shown ONLY inside the disclosure under the
  /// detail text. For a destructive remedy that is the rarer of two shapes
  /// (amendment (lxvii): "start fresh" behind "link this device") — still two
  /// taps away and still visible to a screen reader, but never the thing a
  /// thumb lands on while the banner is collapsed.
  final Widget? secondaryAction;

  /// Prepended to the screen-reader announcement, e.g. a severity word.
  final String? semanticPrefix;

  /// Which palette this banner wears. See [AlertTone].
  final AlertTone tone;

  @override
  State<IdentityAlertBanner> createState() => _IdentityAlertBannerState();
}

class _IdentityAlertBannerState extends State<IdentityAlertBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final onColor = widget.tone.foreground(colors);
    // Screen readers get the whole thing regardless of the visual disclosure:
    // collapsing is a density decision, never a way to hide a warning from
    // someone who cannot see the chevron.
    final announcement = [
      ?widget.semanticPrefix,
      widget.title,
      ?widget.summary,
      widget.detail,
    ].join('. ');

    return Semantics(
      container: true,
      label: announcement,
      child: Material(
        color: widget.tone.background(colors),
        // A hairline so two stacked warnings do not read as one red block.
        // It matters here specifically: the damaged-identity action is
        // DESTRUCTIVE ("start fresh") and the takeover action is a benign
        // dismissal, so the two must not look like one banner with two buttons.
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: onColor.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(widget.icon, color: onColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: onColor,
                              fontWeight: FontWeight.w700,
                            ),
                            // Polish runs ~15% longer than English here; two
                            // lines plus an ellipsis keeps a 360dp screen from
                            // overflowing, and the untruncated string is always
                            // reachable in the detail below.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.summary case final summary?) ...[
                            const SizedBox(height: 2),
                            Text(
                              summary,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: onColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?widget.action,
                    // Excluded from semantics: the announcement above already
                    // carries the detail, so a screen reader would otherwise be
                    // offered a control that reveals text it has already read.
                    ExcludeSemantics(
                      child: IconButton(
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          color: onColor,
                          size: 20,
                        ),
                        tooltip: _expanded
                            ? l10n.identityAlertHideDetails
                            : l10n.identityAlertShowDetails,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                // 150ms/easeOut per the project motion spec, and instant when the
                // OS asks for reduced motion.
                AnimatedSize(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _expanded
                      ? Padding(
                          // Left inset matches the glyph column (20px icon +
                          // 12px gap) so the detail sits in the same text column
                          // as the title instead of running to the edge.
                          padding: const EdgeInsets.only(
                            left: 32,
                            top: 8,
                            right: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.detail,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: onColor,
                                ),
                              ),
                              if (widget.secondaryAction case final second?)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: second,
                                ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
