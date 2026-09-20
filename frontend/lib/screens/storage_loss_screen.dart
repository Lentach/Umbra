import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import '../services/backup/history_backup.dart';
import '../services/backup/history_backup_service.dart';
import '../services/backup/storage_loss.dart';
import '../theme/rpg_theme.dart';
import '../widgets/dialogs/backup_passphrase_dialog.dart';
import '../widgets/settings_console.dart';
import '../widgets/top_snackbar.dart';

/// The answer to [StorageLoss.lostThisBoot]: this device's content store was
/// provably destroyed and rebuilt empty.
///
/// It is a full, opaque surface rather than a banner or a dialog because the
/// two facts it carries are not glanceable. Contacts repair themselves from
/// the account backup; message history does NOT, and the only thing that can
/// bring it back is a file the user already holds. A banner the user swipes
/// past is a banner that lets them keep using a device whose history they
/// still believe is recoverable.
///
/// The screen is DISMISSED by choosing, never by leaving: `PopScope` refuses
/// the system back gesture, and both exits latch [StorageLoss.acknowledge].
class StorageLossScreen extends StatefulWidget {
  const StorageLossScreen({
    required this.userId,
    required this.onDismiss,
    super.key,
    this.service,
  });

  /// The signed-in account a restore would write under. Passed in rather than
  /// read from a provider so this surface has exactly one dependency — the
  /// backup service — and the mount owns the "is anyone signed in" question.
  final int userId;

  /// Called after the latch is acknowledged, so the mount re-reads it and
  /// takes this screen down.
  final VoidCallback onDismiss;

  /// Injectable purely for tests. Production leaves it null and the screen
  /// builds the real service off [EncryptionProvider].
  final HistoryBackupService? service;

  @override
  State<StorageLossScreen> createState() => _StorageLossScreenState();
}

class _StorageLossScreenState extends State<StorageLossScreen> {
  bool _restoring = false;
  String? _error;

  HistoryBackupService _service() {
    final injected = widget.service;
    if (injected != null) return injected;
    final encryption = context.read<EncryptionProvider>();
    return HistoryBackupService(
      open: () => encryption.encryptionService.contentKv,
    );
  }

  void _continueWithoutRestore() {
    StorageLoss.acknowledge();
    widget.onDismiss();
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context);
    final service = _service();

    final passphrase = await showBackupPassphraseDialog(
      context,
      mode: BackupPassphraseMode.enter,
    );
    if (!mounted || passphrase == null) return;

    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      final counts = await service.pickAndImport(
        userId: widget.userId,
        passphrase: passphrase,
      );
      if (!mounted) return;
      // Acknowledged only HERE: every failure below leaves the latch
      // standing, so a user who mistyped a passphrase lands back on this
      // screen instead of in an app that has quietly written the loss off.
      StorageLoss.acknowledge();
      showTopSnackBar(
        context,
        l10n.snackbarHistoryBackupImported(counts.records, counts.contacts),
      );
      widget.onDismiss();
    } on HistoryBackupWrongPassphrase {
      _fail(l10n.snackbarHistoryBackupWrongPassphrase);
    } on HistoryBackupCorrupt {
      // Never the wrong-passphrase message: the file is broken, and telling
      // this user to retype sends them hunting for a mistake they did not
      // make at the one moment their history is already gone.
      _fail(l10n.snackbarHistoryBackupCorrupt);
    } on HistoryBackupForeignAccount {
      _fail(l10n.snackbarHistoryBackupForeignAccount);
      // `avoid_catching_errors` is waived here: `pickAndImport` documents
      // `StateError('cancelled')` as its cancellation channel, so this is a
      // contract the caller must honour, not a swallowed bug.
      // ignore: avoid_catching_errors
    } on StateError {
      // Picker dismissed — no file was ever chosen, so there is nothing to
      // report and nothing to acknowledge.
    } on Object catch (_) {
      _fail(l10n.snackbarHistoryBackupImportFailed);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    // Inline, not a toast: this screen is a decision point the user may sit
    // on for a minute, and a 2.5s overlay is the wrong place for the reason
    // their restore did not take.
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return PopScope(
      // The back gesture is not a choice. Leaving here without one puts the
      // user in an app that looks intact and is not.
      canPop: false,
      child: Scaffold(
        // Opaque by contract: this sits over the live shell.
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 32,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(
                    child: ConsoleHexIcon(
                      glyph: ConsoleGlyph.deleteNode,
                      height: 68,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.storageLossTitle,
                    textAlign: TextAlign.center,
                    style: RpgTheme.bodyFont(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.storageLossBody,
                    textAlign: TextAlign.center,
                    style: RpgTheme.bodyFont(
                      fontSize: 13.5,
                      color: colorScheme.onSurfaceVariant,
                    ).copyWith(height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  _note(
                    context,
                    icon: Icons.groups_outlined,
                    text: l10n.storageLossContactsNote,
                  ),
                  const SizedBox(height: 12),
                  _note(
                    context,
                    icon: Icons.history_toggle_off,
                    text: l10n.storageLossHistoryNote,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _error!,
                      key: const Key('storage-loss-error'),
                      textAlign: TextAlign.center,
                      style: RpgTheme.bodyFont(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      key: const Key('storage-loss-restore'),
                      onPressed: _restoring ? null : _restore,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_restoring) ...[
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(l10n.storageLossRestoreAction),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('storage-loss-continue'),
                    onPressed: _restoring ? null : _continueWithoutRestore,
                    child: Text(
                      l10n.storageLossContinueAction,
                      style: RpgTheme.bodyFont(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One consequence line. Same grammar as the Privacy screen's anti-quantum
  /// explainer: a 16px primary-tinted mark, top-aligned against its sentence.
  Widget _note(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: RpgTheme.bodyFont(
              fontSize: 12.5,
              color: colorScheme.onSurfaceVariant,
            ).copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}
