import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/rpg_theme.dart';
import '../utils/contact_backup_prompt.dart';
import 'glass/glass_sheet.dart';

/// Decision 76: asks once for the account password to mint the contact
/// backup. Any exit but a saved backup snoozes the sheet
/// (`kContactBackupPromptSnooze`), so it does not return under the screen the
/// user just closed.
Future<void> showContactBackupPasswordSheet(
  BuildContext context, {
  required AuthProvider auth,
  required SettingsProvider settings,
  required int userId,
}) async {
  final saved = await showGlassSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (_) => ContactBackupPasswordSheet(auth: auth),
  );
  if (saved == true) return;
  await settings.snoozeContactBackupPrompt(userId);
}

class ContactBackupPasswordSheet extends StatefulWidget {
  const ContactBackupPasswordSheet({required this.auth, super.key});

  final AuthProvider auth;

  @override
  State<ContactBackupPasswordSheet> createState() =>
      _ContactBackupPasswordSheetState();
}

class _ContactBackupPasswordSheetState
    extends State<ContactBackupPasswordSheet> {
  final _controller = TextEditingController();
  bool _busy = false;
  ContactBackupPromptResult? _failure;
  bool _empty = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (_controller.text.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    setState(() {
      _busy = true;
      _empty = false;
      _failure = null;
    });
    final result = await widget.auth.confirmPasswordForContactBackup(
      _controller.text,
    );
    if (!mounted) return;
    if (result == ContactBackupPromptResult.saved) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final fc = FireplaceColors.of(context);

    final error = _empty
        ? l10n.passwordRequired
        : switch (_failure) {
            ContactBackupPromptResult.wrongPassword =>
              l10n.authStatusWrongPassword,
            ContactBackupPromptResult.unavailable =>
              l10n.contactBackupPromptFailed,
            _ => null,
          };

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.contactBackupPromptTitle,
              key: const Key('contact-backup-prompt-title'),
              style: RpgTheme.bodyFont(
                color: colorScheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.contactBackupPromptBody,
              // Full-contrast text: the muted token misses 4.5:1 on the grey
              // glass of the light and teal themes (driven 2026-09-30).
              style: RpgTheme.bodyFont(color: colorScheme.onSurface),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('contact-backup-prompt-password'),
              controller: _controller,
              obscureText: true,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _confirm(),
              onChanged: (_) {
                if (_empty || _failure != null) {
                  setState(() {
                    _empty = false;
                    _failure = null;
                  });
                }
              },
              decoration: InputDecoration(
                labelText: l10n.enterPasswordToConfirm,
                labelStyle: RpgTheme.bodyFont(color: fc.mutedText),
                errorText: error,
                errorMaxLines: 3,
                filled: true,
                fillColor: fc.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: fc.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: fc.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colorScheme.primary, width: 2),
                ),
              ),
              style: RpgTheme.bodyFont(color: colorScheme.onSurface),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('contact-backup-prompt-later'),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.recoveryKeyLaterAction),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('contact-backup-prompt-confirm'),
                  onPressed: _busy ? null : _confirm,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.recoveryKeyConfirmAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
