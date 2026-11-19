import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import '../services/recovery_phrase.dart';
import 'glass/glass_dialog.dart';

/// What the user chose when asked for their recovery phrase.
sealed class RecoveryPromptResult {
  const RecoveryPromptResult();
}

/// They entered a well-formed phrase.
class RecoveryPromptPhrase extends RecoveryPromptResult {
  const RecoveryPromptPhrase(this.phrase);
  final String phrase;
}

/// They have no phrase and accept the full delay.
class RecoveryPromptWithoutPhrase extends RecoveryPromptResult {
  const RecoveryPromptWithoutPhrase();
}

/// Asks for the recovery phrase before starting an identity reset (§6.2.1).
///
/// The BIP39 checksum is validated locally first. The server rate-limits
/// attempts and locks the phrase out after five failures, so spending one of
/// those on a typo the client could have caught would be a poor trade.
///
/// Returns null when the user backed out entirely — which must NOT be read as
/// "start the slow one anyway".
Future<RecoveryPromptResult?> showRecoveryPhrasePrompt(BuildContext context) {
  return showDialog<RecoveryPromptResult>(
    context: context,
    builder: (_) => const _RecoveryPhrasePrompt(),
  );
}

class _RecoveryPhrasePrompt extends StatefulWidget {
  const _RecoveryPhrasePrompt();

  @override
  State<_RecoveryPhrasePrompt> createState() => _RecoveryPhrasePromptState();
}

class _RecoveryPhrasePromptState extends State<_RecoveryPhrasePrompt> {
  final TextEditingController _controller = TextEditingController();
  bool _malformed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final phrase = RecoveryPhrase.normalize(_controller.text);
    if (!RecoveryPhrase.isValid(phrase)) {
      setState(() => _malformed = true);
      return;
    }
    Navigator.of(context).pop(RecoveryPromptPhrase(phrase));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return GlassDialog(
      title: Text(l10n.recoveryPhrasePromptTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.recoveryPhrasePromptBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const RecoveryPromptWithoutPhrase()),
          child: Text(l10n.recoveryPhraseNoneAction),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.recoveryPhraseUseAction),
        ),
      ],
    );
  }
}

/// The server's answer to a reset request, as a sentence for the user.
///
/// Pure on purpose: the refusals are exactly the ones a genuine owner hits
/// while recovering (a mistyped phrase that still passes the local checksum,
/// the lockout after five of those, the post-cancel cooldown), so the mapping
/// is worth pinning by test rather than burying in a widget callback.
///
/// An UNRECOGNISED status is answered like no answer at all. The server only
/// says `pending`/`existing` when a ceremony is running, and every status it
/// has ever added since has been a refusal (`not_enrolled`, 2026-09-05 —
/// cached PWA sessions during that deploy window were exactly this client).
/// Guessing "started" would leave the account unreachable with the user
/// believing otherwise; saying nothing lets the pending banner stay blank
/// while [identityResetAnswerIsRefusal] must still be true. So: the no-answer
/// sentence, and a refusal.
String? identityResetAnswerMessage(AppLocalizations l10n, String? status) {
  switch (status) {
    case 'pending':
      return l10n.identityResetStarted;
    case EncryptionProvider.identityResetPhraseTooNewStatus:
      // Started, but NOT shortened. Without this the owner sees 72 h after
      // typing a phrase they know is right and concludes it was rejected —
      // the one reading that makes them retype it into the lockout.
      return l10n.identityResetPhraseTooNew;
    case 'existing':
      return l10n.identityResetAlreadyRunning;
    case 'cooldown':
      return l10n.identityResetCooldown;
    case 'invalid_phrase':
      return l10n.identityResetPhraseRejected;
    case 'locked':
      return l10n.identityResetPhraseLocked;
    case 'legacy_recovery_key':
      // Plan B7: the stored key predates it and cannot check this client's
      // proof. Nothing was started and nothing was counted.
      return l10n.identityResetLegacyRecoveryKey;
    case 'not_enrolled':
      // (lxxiii) opt-in lock: nothing is locked, so nothing needs resetting.
      // Point at the recovery that actually works for this account — a fresh
      // sign-in — instead of leaving the user hunting for a ceremony.
      return l10n.identityResetNotEnrolled;
    case EncryptionProvider.identityResetNoAnswerStatus:
    case null:
    default:
      // Silence is an answer too: nothing was started, and saying "started"
      // (or nothing at all) would leave the account unreachable and the user
      // believing otherwise.
      return l10n.identityResetNoAnswer;
  }
}

/// True for the answers that mean nothing was started — which is every answer
/// except the two that report a running ceremony.
bool identityResetAnswerIsRefusal(String? status) =>
    status != 'pending' &&
    status != 'existing' &&
    status != EncryptionProvider.identityResetPhraseTooNewStatus;

/// Starts a reset, offering the recovery-key path first.
///
/// Every entry point into the ceremony goes through here so the question is
/// always asked in the same order: someone holding a phrase must never be
/// dropped into the 72-hour path just because the button they found was the
/// plain one. Backing out starts nothing at all.
///
/// The server's answer is surfaced by [IdentityResetPendingBanner], which is
/// mounted for the whole session: the answer can arrive after this dialog is
/// gone, and `existing` can arrive because another session started the
/// ceremony.
Future<void> startIdentityResetFlow(BuildContext context) async {
  final encryption = context.read<EncryptionProvider>();
  final result = await showRecoveryPhrasePrompt(context);
  switch (result) {
    case RecoveryPromptPhrase(:final phrase):
      encryption.requestIdentityReset(recoveryPhrase: phrase);
    case RecoveryPromptWithoutPhrase():
      encryption.requestIdentityReset();
    case null:
      // Dismissed: the user asked for nothing, so nothing starts.
      break;
  }
}
