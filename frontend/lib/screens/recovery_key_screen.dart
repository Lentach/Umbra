import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import '../services/device_link/identity_backup.dart';
import '../services/recovery_phrase.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../widgets/top_snackbar.dart';

/// Recovery key enrolment (multi-device spec §6.2.1 + amendment (lxxviii)).
///
/// The phrase is a KEY BACKUP now, not just a reset-shortener: confirming it
/// seals the identity (+ DAK, when one exists) under a phrase-derived key and
/// uploads verifier + blob in one `setRecoveryKey`. Presenting the phrase
/// later restores the account instantly ((lxxviii) clause 3).
///
/// The phrase is generated here, shown ONCE, and never written to local
/// storage: a phrase kept on the device would be destroyed by the same event
/// it exists to recover from. Before anything is uploaded the user must type
/// ONE randomly chosen word back — proof they actually saved the words, not a
/// tap-through.
///
/// Pops `true` ONLY when verifier + backup landed on the server; any other
/// exit (back, "Później", failure) pops nothing/`false`, and the enable-linking
/// flow treats that as an abort ((lxxviii) clause 4 / falsification F9), while
/// the registration offer treats it as "later" ((lxxxiii) clause 3).
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key, this.codec, this.deferrable = false});

  /// Test seam; production seals with the real PBKDF2 + AES-GCM pair.
  final IdentityBackupCodec? codec;

  /// (lxxxiii) clause 1: the offer at the door shows a "Później" action.
  /// Forcing the phrase on someone who came to chat loses more users than it
  /// protects.
  final bool deferrable;

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  /// Held in memory only, for as long as this screen is open.
  List<String>? _words;

  /// 0-based index of the word the confirm step demands, or null while the
  /// words are still on screen.
  int? _confirmIndex;
  final TextEditingController _confirmController = TextEditingController();
  bool _mismatch = false;
  bool _saving = false;

  late final IdentityBackupCodec _codec =
      widget.codec ?? IdentityBackupCodec();

  @override
  void dispose() {
    // Not security theatre against a memory dump — just no reason to keep it
    // reachable once the screen is gone.
    _words = null;
    _confirmController.dispose();
    super.dispose();
  }

  void _generate() => setState(() => _words = RecoveryPhrase.generate());

  /// "I saved the words" → the one-random-word confirm step.
  void _startConfirm() {
    final words = _words;
    if (words == null) return;
    setState(() {
      _confirmIndex = Random.secure().nextInt(words.length);
      _mismatch = false;
      _confirmController.clear();
    });
  }

  Future<void> _confirmWord() async {
    final words = _words;
    final index = _confirmIndex;
    if (words == null || index == null || _saving) return;
    final typed = RecoveryPhrase.normalize(_confirmController.text);
    if (typed != words[index]) {
      setState(() => _mismatch = true);
      return;
    }
    final l10n = AppLocalizations.of(context);
    final encryption = context.read<EncryptionProvider>();

    setState(() => _saving = true);
    encryption.clearRecoveryKeySetResult();
    // Enrolment and later verification MUST produce byte-identical strings —
    // the server compares an Argon2id hash, so any divergence fails the check
    // and burns one of the few attempts before lockout. Both sides go through
    // normalize() so they cannot drift apart. The SAME string derives the
    // backup key, so the sealed blob is always openable by the phrase the
    // verifier accepts ((lxxviii): the blob rides the latest phrase).
    final phrase = RecoveryPhrase.normalize(words.join(' '));
    try {
      final payload = await encryption.encryptionService
          .exportIdentityForBackup();
      final sealed = await _codec.seal(payload, phrase);
      encryption.setRecoveryKey(phrase, backup: sealed);
    } catch (_) {
      // Nothing reached the server; the phrase on screen enrolled nothing.
      if (!mounted) return;
      setState(() => _saving = false);
      showTopSnackBar(
        context,
        l10n.recoveryKeySaveFailed,
        backgroundColor: Theme.of(context).colorScheme.error,
      );
      return;
    }

    // The server answers on the socket; wait briefly rather than claiming
    // success the moment the emit returns.
    bool? result;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      result = encryption.recoveryKeySetResult;
      if (result != null) break;
    }
    if (!mounted) return;
    setState(() => _saving = false);

    if (result == true) {
      encryption.clearRecoveryKeySetResult();
      // The PR2.4 phrase wrap of the contact-backup key is minted from
      // `EncryptionProvider.setRecoveryKey` (above), not here: this screen
      // must not acquire a dependency on the auth layer for a side effect.
      setState(() => _words = null);
      showTopSnackBar(context, l10n.recoveryKeySaved);
      Navigator.of(context).pop(true);
      return;
    }
    // Nothing was stored, so the phrase on screen is worthless — say so.
    showTopSnackBar(
      context,
      l10n.recoveryKeySaveFailed,
      backgroundColor: Theme.of(context).colorScheme.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final words = _words;
    final confirmIndex = _confirmIndex;
    // (lxxxiii) clause 2: `exportIdentityForBackup` throws until
    // `initialize()` has run, and at the door the identity is minted seconds
    // after the shell appears. A disabled button for those seconds beats a
    // phrase-shaped failure.
    final encryption = context.watch<EncryptionProvider>();
    final e2eReady = encryption.isE2EReady;
    // (lxxxiii) clause 4: a phrase already enrolled (blob or not) is REPLACED
    // by confirming a new one. Said before the words exist, not after — the
    // field case was a user with an older phrase on paper and twelve new
    // words on screen, no hint which one counts.
    final replacesExisting = encryption.hasRecoveryPhrase == true;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          l10n.recoveryKeyTitle,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: colors.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          top:
              MediaQuery.paddingOf(context).top +
              GlassTopBar.capsuleHeight +
              16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.recoveryKeyBackupExplainer,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (words == null) ...[
              if (replacesExisting) ...[
                Text(
                  l10n.recoveryKeyReplacesExisting,
                  key: const Key('recovery-key-replaces-existing'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                key: const Key('recovery-key-generate'),
                onPressed: e2eReady ? _generate : null,
                child: Text(l10n.recoveryKeyGenerateAction),
              ),
              if (widget.deferrable) ...[
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('recovery-key-later'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.recoveryKeyLaterAction),
                ),
              ],
            ] else if (confirmIndex != null)
              ..._confirmStep(context, confirmIndex)
            else
              ..._wordsStep(context, words),
          ],
        ),
      ),
    );
  }

  List<Widget> _wordsStep(BuildContext context, List<String> words) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: SelectableText(
          words.join('  '),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 15,
            height: 1.7,
            letterSpacing: 0.5,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        l10n.recoveryKeyShownOnceWarning,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.error,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: words.join(' ')));
          if (context.mounted) {
            showTopSnackBar(context, l10n.recoveryKeyCopied);
          }
        },
        icon: const Icon(Icons.copy_outlined, size: 18),
        label: Text(l10n.recoveryKeyCopyAction),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _startConfirm,
        child: Text(l10n.recoveryKeySavedAction),
      ),
    ];
  }

  List<Widget> _confirmStep(BuildContext context, int confirmIndex) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return [
      Text(
        l10n.recoveryKeyConfirmTitle,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        // 1-based for humans; the index is 0-based.
        l10n.recoveryKeyConfirmPrompt(confirmIndex + 1),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('recovery-key-confirm-field'),
        controller: _confirmController,
        enabled: !_saving,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _confirmWord(),
        onChanged: (_) {
          if (_mismatch) setState(() => _mismatch = false);
        },
        decoration: InputDecoration(
          errorText: _mismatch ? l10n.recoveryKeyConfirmMismatch : null,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('recovery-key-confirm-action'),
        onPressed: _saving ? null : _confirmWord,
        child: _saving
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.recoveryKeyConfirmAction),
      ),
    ];
  }
}
