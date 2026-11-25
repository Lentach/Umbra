import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/rpg_theme.dart';
import '../glass/glass_dialog.dart';

class ResetPasswordDialog extends StatefulWidget {
  const ResetPasswordDialog({super.key});

  @override
  State<ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _repeatPasswordController = TextEditingController();

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _repeatPasswordController.dispose();
    super.dispose();
  }

  String? _validatePassword(BuildContext context, String? value) {
    final l10n = AppLocalizations.of(context);
    if (value == null || value.isEmpty) {
      return l10n.passwordRequired;
    }
    if (value.length < 8) {
      return l10n.passwordMinLength;
    }
    if (!RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$').hasMatch(value)) {
      return l10n.passwordMustContain;
    }
    return null;
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(<String, String>{
        'oldPassword': _oldPasswordController.text,
        'newPassword': _newPasswordController.text,
      });
    }
  }

  InputDecoration _passwordDecoration(
    BuildContext context, {
    required String label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final fc = FireplaceColors.of(context);
    return InputDecoration(
      labelText: label,
      labelStyle: RpgTheme.bodyFont(color: fc.mutedText),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textColor = Theme.of(context).colorScheme.onSurface;

    return GlassDialog(
      maxWidth: 400,
      title: Text(l10n.resetPasswordDialogTitle),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _oldPasswordController,
              obscureText: true,
              decoration: _passwordDecoration(context, label: l10n.oldPassword),
              style: RpgTheme.bodyFont(color: textColor),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.oldPasswordRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: _passwordDecoration(context, label: l10n.newPassword),
              style: RpgTheme.bodyFont(color: textColor),
              validator: (value) => _validatePassword(context, value),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _repeatPasswordController,
              obscureText: true,
              decoration: _passwordDecoration(
                context,
                label: l10n.repeatNewPassword,
              ),
              style: RpgTheme.bodyFont(color: textColor),
              validator: (value) => value == _newPasswordController.text
                  ? null
                  : l10n.passwordsDoNotMatch,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.resetButton)),
      ],
    );
  }
}
