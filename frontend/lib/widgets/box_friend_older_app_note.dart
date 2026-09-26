import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';

/// The one quiet line above the composer while a friend is not on the box
/// yet (metadata-privacy owner decision 48): messages to [name] still take
/// the old path, whose timing the server sees. Informational only — sending
/// is never blocked, so it borrows `DevicesSyncingNote`'s muted body-small
/// text and nothing from the warning surfaces. Mounted and unmounted
/// instantly: it sits on the composer, a no-animation zone
/// (`frontend/docs/composer-media.md`).
class BoxFriendOlderAppNote extends StatelessWidget {
  const BoxFriendOlderAppNote({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final mutedColor = RpgTheme.isDark(context)
        ? RpgTheme.mutedDark
        : RpgTheme.textSecondaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        AppLocalizations.of(context).boxFriendOlderAppNote(name),
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: mutedColor),
      ),
    );
  }
}
