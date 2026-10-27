import 'package:flutter/material.dart';
import '../theme/rpg_theme.dart';
import 'glass/glass_top_bar.dart';

/// Shows a snackbar-style notification at the **top** of the screen
/// so it does not cover the chat input bar at the bottom.
///
/// [overlay] targets a specific overlay instead of [context]'s; pass the root
/// overlay together with its own context (`overlay.context`) to toast after
/// the caller's screen is gone.
void showTopSnackBar(
  BuildContext context,
  String message, {
  Color? backgroundColor,
  Duration duration = const Duration(milliseconds: 2500),
  VoidCallback? onTap,
  String? actionLabel,
  OverlayState? overlay,
}) {
  assert(onTap == null || actionLabel != null);
  final target = overlay ?? Overlay.of(context);
  final theme = Theme.of(context);
  // Default (no explicit color): themed console-style surface — the old
  // inverseSurface default rendered near-white on every dark theme. An
  // EXPLICIT backgroundColor (error red, accent blue) keeps the legacy
  // borderless look and its readableOn foreground untouched.
  final themedDefault = backgroundColor == null;
  final bg = backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
  // Pick the readable foreground for the actual fill: hardwired white failed
  // 4.5:1 on bright fills (#FF4444, #2AABEE).
  final textColor = themedDefault
      ? theme.colorScheme.onSurface
      : RpgTheme.readableOn(bg);
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
    side: themedDefault
        ? BorderSide(color: theme.colorScheme.outlineVariant)
        : BorderSide.none,
  );
  // Snapshot the inset from the CALLER context (not the root OverlayEntry ctx)
  // so the toast clears the same app-bar band the triggering screen sees.
  final topInset = MediaQuery.paddingOf(context).top;

  late OverlayEntry entry;
  entry = OverlayEntry(
    // Sit below the app-bar band (status-bar inset + toolbar height) so the
    // opaque fill never covers the back arrow it used to overlap at top:0.
    // IgnorePointer is kept so this informational overlay never intercepts
    // taps for whatever sits under it.
    builder: (_) => Positioned(
      top: topInset + GlassTopBar.capsuleHeight + 16 + 8,
      left: 16,
      right: 16,
      child: onTap == null
          ? IgnorePointer(
              child: Material(
                elevation: 6,
                shape: shape,
                color: bg,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      if (themedDefault) ...[
                        Icon(Icons.info_outline, size: 20, color: textColor),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(
                          message,
                          style: RpgTheme.bodyFont(
                            fontSize: 14,
                            color: textColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Material(
              elevation: 6,
              shape: shape,
              color: bg,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    if (themedDefault) ...[
                      Icon(Icons.info_outline, size: 20, color: textColor),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        message,
                        style: RpgTheme.bodyFont(
                          fontSize: 14,
                          color: textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        entry.remove();
                        onTap();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: RpgTheme.readableOn(bg),
                        textStyle: RpgTheme.bodyFont(
                          fontSize: 14,
                          color: RpgTheme.readableOn(bg),
                        ),
                      ),
                      child: Text(actionLabel!),
                    ),
                  ],
                ),
              ),
            ),
    ),
  );

  target.insert(entry);
  Future.delayed(duration, () {
    try {
      entry.remove();
    } catch (_) {}
  });
}
