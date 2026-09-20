import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../glass/glass_dialog.dart';

/// Which side of the backup the passphrase is being collected for.
enum BackupPassphraseMode {
  /// Export: the passphrase is being CHOSEN, so it is typed twice and the
  /// dialog says plainly that nobody can recover it.
  create,

  /// Import: the passphrase already exists, so one field is enough. A wrong
  /// one is answered by the caller, not here — this dialog cannot know.
  enter,
}

/// The shortest passphrase the create side accepts.
///
/// Not a strength meter: the file is sealed with a slow KDF, and a meter that
/// blocks a determined owner from their own backup is worse than a floor.
const int kBackupPassphraseMinLength = 8;

/// Collects the passphrase that seals (or opens) a history backup file.
///
/// Returns the passphrase, or null when the user backed out — which must be
/// read as "do nothing", never as "use an empty passphrase".
Future<String?> showBackupPassphraseDialog(
  BuildContext context, {
  required BackupPassphraseMode mode,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _BackupPassphraseDialog(mode: mode),
  );
}

class _BackupPassphraseDialog extends StatefulWidget {
  const _BackupPassphraseDialog({required this.mode});

  final BackupPassphraseMode mode;

  @override
  State<_BackupPassphraseDialog> createState() =>
      _BackupPassphraseDialogState();
}

class _BackupPassphraseDialogState extends State<_BackupPassphraseDialog> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _obscured = true;
  String? _error;

  bool get _creating => widget.mode == BackupPassphraseMode.create;

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    final value = _passphrase.text;
    if (_creating) {
      if (value.length < kBackupPassphraseMinLength) {
        setState(
          () => _error = l10n.backupPassphraseTooShort(
            kBackupPassphraseMinLength,
          ),
        );
        return;
      }
      if (value != _repeat.text) {
        setState(() => _error = l10n.backupPassphraseMismatch);
        return;
      }
    } else if (value.isEmpty) {
      setState(() => _error = l10n.backupPassphraseRequired);
      return;
    }
    Navigator.of(context).pop(value);
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return GlassDialog(
      title: Text(
        _creating
            ? l10n.backupPassphraseCreateTitle
            : l10n.backupPassphraseEnterTitle,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _creating
                ? l10n.backupPassphraseCreateBody
                : l10n.backupPassphraseEnterBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passphrase,
            autofocus: true,
            obscureText: _obscured,
            // A passphrase field must never be autocorrected: the keyboard
            // would silently change what the user sealed with. (Capitalisation
            // is already off by `TextField`'s default.)
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: _creating
                ? TextInputAction.next
                : TextInputAction.done,
            onChanged: (_) => _clearError(),
            onSubmitted: _creating ? null : (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.backupPassphraseLabel,
              border: const OutlineInputBorder(),
              errorText: _creating ? null : _error,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscured ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                tooltip: _obscured
                    ? l10n.backupPassphraseReveal
                    : l10n.backupPassphraseHide,
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
          ),
          if (_creating) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _repeat,
              obscureText: _obscured,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onChanged: (_) => _clearError(),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.backupPassphraseRepeatLabel,
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(
            _creating
                ? l10n.backupPassphraseCreateAction
                : l10n.backupPassphraseEnterAction,
          ),
        ),
      ],
    );
  }
}
