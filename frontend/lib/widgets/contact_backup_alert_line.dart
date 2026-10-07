import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';

/// Decision 94: the red line at the top of the chat list while this account
/// has no contact backup. Tap opens the password sheet. It has no close
/// button: it is how the ask stays visible without blocking the app, and it
/// goes once the backup exists.
class ContactBackupAlertLine extends StatelessWidget {
  const ContactBackupAlertLine({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: const Key('contact-backup-alert'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: colorScheme.onError,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.contactBackupAlertLine,
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
