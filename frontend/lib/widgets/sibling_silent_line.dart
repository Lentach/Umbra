import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'alert_line.dart';

/// Decision 101 B: the primary's red line above the chat list for a linked
/// device silent for 30 days, named as the Devices screen names it. A tap
/// asks what to do: [onRemove] once the user chose to remove it (the dialog
/// is the confirmation, with the Devices screen's own explainer), [onKeep]
/// when they keep it. Dismissing the dialog does neither; the line stays.
class SiblingSilentLine extends StatelessWidget {
  const SiblingSilentLine({
    required this.name,
    required this.onKeep,
    required this.onRemove,
    super.key,
  });

  final String name;
  final VoidCallback onKeep;
  final VoidCallback onRemove;

  Future<void> _ask(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.siblingSilentTitle(name)),
        content: Text(l10n.siblingSilentBody),
        actions: [
          TextButton(
            key: const Key('sibling-silent-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.siblingSilentKeep),
          ),
          TextButton(
            key: const Key('sibling-silent-remove'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.devicesRevokeAction),
          ),
        ],
      ),
    );
    switch (remove) {
      case true:
        onRemove();
      case false:
        onKeep();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => AlertLine(
    text: AppLocalizations.of(context).siblingSilentLine(name),
    icon: Icons.devices_other_outlined,
    tapKey: const Key('sibling-silent-alert'),
    onTap: () => _ask(context),
  );
}
