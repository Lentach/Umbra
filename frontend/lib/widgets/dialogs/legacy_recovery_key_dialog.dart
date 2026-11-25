import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../glass/glass_dialog.dart';

/// Plan B7: which accounts were already asked, in THIS app run.
///
/// Deliberately a process-lifetime static and never a preference: the ask
/// must come back after every app start (and web reload) until the key is
/// replaced, and must not repeat within one run after "Later".
class LegacyRecoveryKeyAsked {
  LegacyRecoveryKeyAsked._();

  static final Set<int> _userIds = <int>{};

  static bool contains(int userId) => _userIds.contains(userId);

  static void add(int userId) => _userIds.add(userId);

  @visibleForTesting
  static void reset() => _userIds.clear();
}

/// The once-per-app-start dialog for an account whose recovery key is legacy.
///
/// Returns true only for "Replace now". "Later" and the system back gesture
/// both return false (back = Later); a tap outside does nothing.
Future<bool> showLegacyRecoveryKeyDialog(BuildContext context) async {
  final replace = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      return GlassDialog(
        title: Text(l10n.recoveryKeyLegacyTitle),
        content: Text(l10n.recoveryKeyLegacyDialogBody),
        actions: [
          TextButton(
            key: const Key('legacy-key-dialog-later'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.recoveryKeyLaterAction),
          ),
          FilledButton(
            key: const Key('legacy-key-dialog-replace'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.recoveryKeyLegacyReplaceNow),
          ),
        ],
      );
    },
  );
  return replace ?? false;
}
