import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import '../services/recovery_phrase.dart';

/// The gate's third door (amendment (lxxviii) clause 3): restore this
/// account's identity from the 12-word recovery phrase.
///
/// Collapsed to a single button; expanding shows the phrase field inline —
/// the gate is not a route, so there is no Navigator to push a screen onto.
/// The section never closes the gate itself: a successful restore flips
/// `needsDeviceLink` through the adopt + rebind, and `AuthGate` unmounts the
/// whole screen.
class LinkRestoreSection extends StatefulWidget {
  const LinkRestoreSection({super.key});

  @override
  State<LinkRestoreSection> createState() => _LinkRestoreSectionState();
}

class _LinkRestoreSectionState extends State<LinkRestoreSection> {
  final TextEditingController _controller = TextEditingController();
  bool _open = false;
  bool _malformed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    // Same local validation as the reset prompt: the BIP39 checksum catches a
    // typo before any server round trip is spent.
    final phrase = RecoveryPhrase.normalize(_controller.text);
    if (!RecoveryPhrase.isValid(phrase)) {
      setState(() => _malformed = true);
      return;
    }
    context.read<EncryptionProvider>().restoreFromPhrase(phrase);
  }

  String _failureLabel(AppLocalizations l10n, IdentityRestoreFailure? failure) {
    return switch (failure) {
      IdentityRestoreFailure.wrongPhrase => l10n.linkGateRestoreWrongPhrase,
      IdentityRestoreFailure.noBackup => l10n.linkGateRestoreNoBackup,
      IdentityRestoreFailure.refused ||
      IdentityRestoreFailure.failed ||
      null => l10n.linkGateRestoreFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final stage = context.select<EncryptionProvider, IdentityRestoreStage>(
      (e) => e.restoreStage,
    );
    final failure = context.select<EncryptionProvider, IdentityRestoreFailure?>(
      (e) => e.restoreFailure,
    );
    final busy =
        stage != IdentityRestoreStage.idle &&
        stage != IdentityRestoreStage.done &&
        stage != IdentityRestoreStage.failed;

    if (!_open) {
      return OutlinedButton(
        key: const Key('link-gate-restore'),
        onPressed: () => setState(() => _open = true),
        child: Text(l10n.linkGateRestoreAction),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.linkGateRestoreTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.linkGateRestoreBody,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('link-gate-restore-field'),
          controller: _controller,
          enabled: !busy,
          // The phrase is the account's master secret: the keyboard must not
          // alter a word nor learn the words (IME hint; no-op off Android).
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          minLines: 2,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_malformed) setState(() => _malformed = false);
          },
          decoration: InputDecoration(
            hintText: l10n.recoveryPhrasePromptHint,
            errorText: _malformed ? l10n.recoveryPhraseMalformed : null,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (busy) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.linkGateRestoring,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ] else ...[
          if (stage == IdentityRestoreStage.failed) ...[
            Text(
              _failureLabel(l10n, failure),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
            const SizedBox(height: 8),
          ],
          if (stage == IdentityRestoreStage.done) ...[
            // Normally unseen — the gate unmounts on the rebind — but a slow
            // guard pass must not look like a hang.
            Text(
              l10n.linkGateRestoreDone,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(
            key: const Key('link-gate-restore-submit'),
            onPressed: _submit,
            child: Text(l10n.linkGateRestoreAction),
          ),
        ],
      ],
    );
  }
}
