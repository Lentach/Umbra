import 'package:flutter/material.dart';

import '../theme/rpg_theme.dart';

/// A red line at the top of the chat list for something the user should fix
/// and can fix with one tap: no contact backup (decision 94), notifications
/// off on this browser (decision 90, E90a). It has no close button: it is how
/// the ask stays visible without blocking the app, and it goes once fixed.
class AlertLine extends StatelessWidget {
  const AlertLine({
    required this.text,
    required this.icon,
    required this.tapKey,
    required this.onTap,
    super.key,
  });

  final String text;
  final IconData icon;

  /// On the tappable area, so tests and drives can find the line.
  final Key tapKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: tapKey,
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.onError),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: RpgTheme.bodyFont(
                      color: colorScheme.onError,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: colorScheme.onError),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
