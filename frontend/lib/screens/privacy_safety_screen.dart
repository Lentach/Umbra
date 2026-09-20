import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/encryption_provider.dart';
import '../services/backup/history_backup.dart';
import '../services/backup/history_backup_service.dart';
import '../theme/rpg_theme.dart';
import '../utils/e2e_diag_log.dart';
import '../utils/e2e_persistent_diag.dart';
import '../widgets/audio/playback_controller.dart';
import '../widgets/dialogs/backup_passphrase_dialog.dart';
import '../widgets/glass/glass_dialog.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../widgets/settings_console.dart';
import '../widgets/top_snackbar.dart';

class PrivacySafetyScreen extends StatefulWidget {
  const PrivacySafetyScreen({super.key});

  @override
  State<PrivacySafetyScreen> createState() => _PrivacySafetyScreenState();
}

class _PrivacySafetyScreenState extends State<PrivacySafetyScreen> {
  String? _fingerprint;
  bool _loading = true;
  bool _deletingAllLocalHistory = false;
  bool _exportingHistoryBackup = false;
  bool _importingHistoryBackup = false;
  bool _diagLogUnlocked = false;
  String _diagFilter = 'current';
  String? _storageSetsSummary;
  String? _storageSetsFull;
  bool _loadingStorageSets = false;

  @override
  void initState() {
    super.initState();
    _loadFingerprint();
  }

  Future<void> _loadFingerprint() async {
    final fp = await context
        .read<EncryptionProvider>()
        .getIdentityFingerprint();
    if (mounted) {
      setState(() {
        _fingerprint = fp;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

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
          _diagLogUnlocked ? '🔓 hacker mode' : l10n.privacySafetyTitle,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: colorScheme.onSurface,
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
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Long-pressing the privacy terminal unlocks the E2E log.
                  Center(
                    child: Semantics(
                      button: true,
                      label: l10n.privacySafetyTitle,
                      onLongPress: () =>
                          setState(() => _diagLogUnlocked = true),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: () =>
                            setState(() => _diagLogUnlocked = true),
                        child: SizedBox(
                          width: 88,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 72,
                                child: Center(
                                  child: const ConsoleHexIcon(
                                    glyph: ConsoleGlyph.privacy,
                                    height: 68,
                                  ),
                                ),
                              ),
                              if (_diagLogUnlocked) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '🔓 hacker mode',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.primary,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.e2eEncryptionEnabled,
                    style: RpgTheme.bodyFont(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.e2eEncryptionDescription,
                    style: RpgTheme.bodyFont(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SettingsSectionCaption(label: l10n.settingsSectionSecurity),
            ConsoleInfoRow(
              glyph: ConsoleGlyph.keys,
              title: l10n.yourEncryptionKeys,
              body: l10n.yourEncryptionKeysDescription,
            ),
            ConsoleInfoRow(
              glyph: ConsoleGlyph.devices,
              title: l10n.singleDeviceEncryption,
              body: l10n.singleDeviceEncryptionDescription,
            ),
            if (kIsWeb)
              ConsoleInfoRow(
                glyph: ConsoleGlyph.webStorage,
                title: l10n.webKeyStorage,
                body: l10n.webKeyStorageDescription,
              ),
            // Moved off the Settings version footer 2026-09-14 (owner's call):
            // this is a security fact about local key/history loss, so it
            // belongs next to the other key-material rows, not under a build
            // string. It is literally true on NATIVE — uninstalling the mobile
            // app destroys the Signal keys and the SQLCipher store — while an
            // installed PWA's origin storage usually survives (root
            // `CLAUDE.md` §6), which is why it reads as a warning, not a step.
            ConsoleInfoRow(
              glyph: ConsoleGlyph.deleteNode,
              title: l10n.uninstallWarningTitle,
              body: l10n.uninstallWarning,
            ),
            SettingsSectionCaption(label: l10n.privacySafetyTitle),
            ConsoleInfoRow(
              glyph: ConsoleGlyph.media,
              title: l10n.whatIsEncrypted,
              body: l10n.whatIsEncryptedDescription,
            ),
            ConsoleInfoRow(
              glyph: ConsoleGlyph.metadata,
              title: l10n.serverStoresMetadata,
              body: l10n.serverStoresMetadataDescription,
            ),
            _buildAntiQuantumNoteExplainer(context),
            SettingsSectionCaption(label: l10n.settingsSectionPreferences),
            _buildDeleteAllLocalHistoryCard(context),
            _buildHistoryBackupCard(context),
            if (_loading || _fingerprint != null) ...[
              SettingsSectionCaption(label: l10n.yourIdentityFingerprint),
              if (!_loading && _fingerprint != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(kConsoleHexLeft, 0, 16, 0),
                  child: Text(
                    l10n.shareFingerprintHint,
                    style: RpgTheme.bodyFont(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.fromLTRB(kConsoleHexLeft, 0, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: SelectableText(
                      _fingerprint!,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface,
                        fontFamily: 'monospace',
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
              if (_loading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(kConsoleHexLeft, 0, 16, 0),
                  child: Semantics(
                    label: l10n.devicesLoading,
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 168,
                        height: 12,
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
            if (_diagLogUnlocked) ...[
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(kConsoleHexLeft, 0, 16, 0),
                child: _buildDiagLogPanel(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Bespoke structured explainer for Anti-Quantum Notes: the single ~90-word
  /// paragraph became a short lead + four scannable glyph rows, preserving
  /// every security claim of the old `privacyAntiQuantumNoteDescription`.
  /// Same console grammar as [ConsoleInfoRow] (hex terminal, top-aligned),
  /// which stays shared and untouched.
  Widget _buildAntiQuantumNoteExplainer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final points = <(IconData, String)>[
      (Icons.lock_outline, l10n.privacyAntiQuantumNotePointDevice),
      (Icons.tag, l10n.privacyAntiQuantumNotePointKey),
      (Icons.local_fire_department, l10n.privacyAntiQuantumNotePointOnce),
      (Icons.hourglass_bottom, l10n.privacyAntiQuantumNotePointTimer),
    ];

    return Semantics(
      container: true,
      label: l10n.privacyAntiQuantumNoteTitle,
      value:
          '${l10n.privacyAntiQuantumNoteLead} '
          '${points.map((p) => p.$2).join(' ')}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: kConsoleHexLeft),
            const ConsoleHexIcon(glyph: ConsoleGlyph.quantum),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.privacyAntiQuantumNoteTitle,
                    style: RpgTheme.bodyFont(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.privacyAntiQuantumNoteLead,
                    style: RpgTheme.bodyFont(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ).copyWith(height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  for (final (icon, text) in points)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              icon,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 8),
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
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteAllLocalHistoryCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsoleInfoRow(
          glyph: ConsoleGlyph.deleteNode,
          title: l10n.deleteAllLocalHistoryTitle,
          body: l10n.deleteAllLocalHistoryDescription,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            kConsoleHexLeft + kConsoleHexWidth + 12,
            0,
            16,
            12,
          ),
          child: SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: _deletingAllLocalHistory
                  ? null
                  : _deleteAllLocalHistory,
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.error,
                side: BorderSide(color: colorScheme.error),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_deletingAllLocalHistory) ...[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Flexible + scaleDown: the PL label overflows a 412px
                  // viewport by ~4px; shrink slightly instead of clipping.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(l10n.deleteAllLocalHistoryButton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The constructive twin of [_buildDeleteAllLocalHistoryCard]: same console
  /// grammar (explainer row, then one 48px button on the same rail), but the
  /// primary palette, because nothing here destroys anything.
  Widget _buildHistoryBackupCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsoleInfoRow(
          glyph: ConsoleGlyph.cache,
          title: l10n.historyBackupTitle,
          body: l10n.historyBackupDescription,
        ),
        _buildBackupActionButton(
          context,
          label: l10n.historyBackupExportButton,
          busy: _exportingHistoryBackup,
          onPressed: _exportHistoryBackup,
        ),
        // Import is ABSENT on web, not disabled: `importSupported` is a scope
        // line, not a transient condition, and a permanently dead tile reads
        // as a broken build. The `webStorage` glyph it borrows can never
        // collide with the web-key-storage row above, which renders only when
        // this block does not.
        if (HistoryBackupService.importSupported) ...[
          ConsoleInfoRow(
            glyph: ConsoleGlyph.webStorage,
            title: l10n.historyBackupImportTitle,
            body: l10n.historyBackupImportDescription,
          ),
          _buildBackupActionButton(
            context,
            label: l10n.historyBackupImportButton,
            busy: _importingHistoryBackup,
            onPressed: _importHistoryBackup,
          ),
        ],
      ],
    );
  }

  Widget _buildBackupActionButton(
    BuildContext context, {
    required String label,
    required bool busy,
    required Future<void> Function() onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        kConsoleHexLeft + kConsoleHexWidth + 12,
        0,
        16,
        12,
      ),
      child: SizedBox(
        height: 48,
        child: OutlinedButton(
          onPressed: busy ? null : () => unawaited(onPressed()),
          style: OutlinedButton.styleFrom(
            foregroundColor: colorScheme.primary,
            side: BorderSide(color: colorScheme.primary),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Same guard the delete button needs: the PL labels are the
              // longest strings on this rail and clip on a 412px viewport.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  HistoryBackupService _historyBackupService() {
    // Captured now, not inside the closure: the closure runs after an await,
    // and reading a provider off a disposed element would throw there.
    final encryption = context.read<EncryptionProvider>();
    return HistoryBackupService(
      open: () => encryption.encryptionService.contentKv,
    );
  }

  Future<void> _exportHistoryBackup() async {
    final l10n = AppLocalizations.of(context);
    final userId = context.read<AuthProvider>().currentUser?.id;
    if (userId == null) return;
    final service = _historyBackupService();

    final passphrase = await showBackupPassphraseDialog(
      context,
      mode: BackupPassphraseMode.create,
    );
    if (!mounted || passphrase == null) return;

    setState(() => _exportingHistoryBackup = true);
    try {
      final counts = await service.exportAndShare(
        userId: userId,
        passphrase: passphrase,
      );
      if (!mounted) return;
      showTopSnackBar(
        context,
        l10n.snackbarHistoryBackupExported(counts.records, counts.contacts),
      );
    } on Object catch (_) {
      if (!mounted) return;
      showTopSnackBar(
        context,
        l10n.snackbarHistoryBackupExportFailed,
        backgroundColor: Theme.of(context).colorScheme.error,
      );
    } finally {
      if (mounted) {
        setState(() => _exportingHistoryBackup = false);
      }
    }
  }

  Future<void> _importHistoryBackup() async {
    final l10n = AppLocalizations.of(context);
    final userId = context.read<AuthProvider>().currentUser?.id;
    if (userId == null) return;
    final service = _historyBackupService();

    final passphrase = await showBackupPassphraseDialog(
      context,
      mode: BackupPassphraseMode.enter,
    );
    if (!mounted || passphrase == null) return;

    setState(() => _importingHistoryBackup = true);
    try {
      final counts = await service.pickAndImport(
        userId: userId,
        passphrase: passphrase,
      );
      if (!mounted) return;
      showTopSnackBar(
        context,
        l10n.snackbarHistoryBackupImported(counts.records, counts.contacts),
      );
    } on HistoryBackupWrongPassphrase {
      // The ONLY branch allowed to say "wrong passphrase". A damaged file
      // reaching this message would teach the user to retype a passphrase
      // that was never wrong.
      _reportImportFailure(l10n.snackbarHistoryBackupWrongPassphrase);
    } on HistoryBackupCorrupt {
      _reportImportFailure(l10n.snackbarHistoryBackupCorrupt);
    } on HistoryBackupForeignAccount {
      _reportImportFailure(l10n.snackbarHistoryBackupForeignAccount);
      // `avoid_catching_errors` is waived here: `pickAndImport` documents
      // `StateError('cancelled')` as its cancellation channel, so this is a
      // contract the caller must honour, not a swallowed bug.
      // ignore: avoid_catching_errors
    } on StateError {
      // The picker was dismissed. The user already knows what they did;
      // anything shown here would read as a failure they caused by accident.
    } on Object catch (_) {
      _reportImportFailure(l10n.snackbarHistoryBackupImportFailed);
    } finally {
      if (mounted) {
        setState(() => _importingHistoryBackup = false);
      }
    }
  }

  void _reportImportFailure(String message) {
    if (!mounted) return;
    showTopSnackBar(
      context,
      message,
      backgroundColor: Theme.of(context).colorScheme.error,
    );
  }

  Widget _buildDiagLogPanel(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = theme.colorScheme.onSurfaceVariant;
    final allEntries = E2eDiagLog.entries.reversed.toList();
    final durable = E2ePersistentDiag.entries.reversed.toList();
    final entries = switch (_diagFilter) {
      'historical' => durable,
      '24h' => E2eDiagLog.since(const Duration(hours: 24)).reversed.toList(),
      'build' => E2eDiagLog.since(
        DateTime.now().difference(E2eDiagLog.sessionStartedAt),
      ).reversed.toList(),
      'full' => [...durable, ...allEntries],
      _ => allEntries,
    };
    final failures = entries
        .where((e) => e.contains('FAIL') || e.contains('DECRYPT_DECISION'))
        .length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.terminal, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'E2E Diagnostic Log',
                  style: RpgTheme.bodyFont(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 0,
              children: [
                TextButton(
                  onPressed: () async {
                    final all =
                        '== DURABLE FAILURES (survives restart) ==\n'
                        '${E2ePersistentDiag.entries.join('\n')}\n\n'
                        '== LIVE LOG ==\n'
                        '${E2eDiagLog.entries.join('\n')}';
                    await Clipboard.setData(ClipboardData(text: all));
                    if (!context.mounted) return;
                    showTopSnackBar(context, 'Log copied to clipboard');
                  },
                  child: const Text('Copy'),
                ),
                TextButton(
                  onPressed: () async {
                    E2eDiagLog.clear();
                    await E2ePersistentDiag.clear();
                    if (!mounted) return;
                    setState(() {});
                  },
                  child: const Text('Clear diagnostic logs only'),
                ),
              ],
            ),
          ),
          Text(
            'Current session: ${allEntries.length} events · failures: $failures',
          ),
          DropdownButton<String>(
            value: _diagFilter,
            items: const [
              DropdownMenuItem(
                value: 'current',
                child: Text('Current session'),
              ),
              DropdownMenuItem(
                value: 'build',
                child: Text('Since current build'),
              ),
              DropdownMenuItem(value: '24h', child: Text('Last 24 hours')),
              DropdownMenuItem(value: 'historical', child: Text('Historical')),
              DropdownMenuItem(value: 'full', child: Text('Full raw log')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _diagFilter = value);
            },
          ),
          if (E2eDiagLog.groupedFailures(entries).isNotEmpty) ...[
            const Text('Grouped failures'),
            ...E2eDiagLog.groupedFailures(entries).map(Text.new),
          ],
          const SizedBox(height: 8),
          const Text(
            'Clears diagnostic logs only. Does not clear messages, encryption keys, sessions, or browser storage.',
            style: TextStyle(fontSize: 11),
          ),
          if (durable.isNotEmpty) ...[
            Text(
              'Durable failures (survives restart)',
              style: RpgTheme.bodyFont(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: durable.length,
                itemBuilder: (context, index) => SelectableText(
                  durable[index],
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.error,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Live log',
              style: RpgTheme.bodyFont(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: mutedColor,
              ),
            ),
            const SizedBox(height: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: entries.isEmpty
                ? Text(
                    'No events recorded',
                    style: RpgTheme.bodyFont(fontSize: 12, color: mutedColor),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, index) => SelectableText(
                      entries[index],
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          // Storage-set inspector: disk truth of the retired set, the decrypt
          // ledger, and the stored-record ids. Exists because the owner's
          // production device is an iOS Safari PWA with no devtools — this
          // panel is the ONLY way to read these sets in the field. Ids only,
          // never content.
          Row(
            children: [
              Expanded(
                child: Text(
                  'Storage sets (retired / ledger / stored)',
                  style: RpgTheme.bodyFont(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: mutedColor,
                  ),
                ),
              ),
              TextButton(
                onPressed: _loadingStorageSets ? null : _loadStorageSets,
                child: Text(_storageSetsSummary == null ? 'Load' : 'Reload'),
              ),
              if (_storageSetsFull != null)
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _storageSetsFull!),
                    );
                    if (!context.mounted) return;
                    showTopSnackBar(context, 'Storage sets copied');
                  },
                  child: const Text('Copy full'),
                ),
            ],
          ),
          if (_storageSetsSummary != null)
            SelectableText(
              _storageSetsSummary!,
              style: TextStyle(
                fontSize: 11,
                color: mutedColor,
                fontFamily: 'monospace',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _loadStorageSets() async {
    final encryption = context.read<EncryptionProvider>();
    setState(() => _loadingStorageSets = true);
    try {
      final sets = await encryption.diagStorageSets();
      String line(String name, Set<int> ids) {
        if (ids.isEmpty) return '$name | count: 0';
        final sorted = ids.toList()..sort();
        final last = sorted.length <= 20
            ? sorted
            : sorted.sublist(sorted.length - 20);
        return '$name | count: ${sorted.length} | min: ${sorted.first} '
            '| max: ${sorted.last} | last20: $last';
      }

      String full(String name, Set<int> ids) {
        final sorted = ids.toList()..sort();
        return '== $name (${sorted.length}) ==\n$sorted';
      }

      final summary = [
        line('retired', sets.retired),
        line('ledger ', sets.ledger),
        line('stored ', sets.stored),
      ].join('\n');
      if (!mounted) return;
      setState(() {
        _storageSetsSummary = summary;
        _storageSetsFull = [
          full('retired', sets.retired),
          full('ledger', sets.ledger),
          full('stored', sets.stored),
        ].join('\n\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _storageSetsSummary = 'failed: $e');
    } finally {
      if (mounted) setState(() => _loadingStorageSets = false);
    }
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        final l10n = AppLocalizations.of(dialogContext);

        return GlassDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    if (!mounted) return false;
    return confirmed ?? false;
  }

  Future<void> _deleteAllLocalHistory() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _confirmAction(
      title: l10n.deleteAllLocalHistoryDialogTitle,
      message: l10n.deleteAllLocalHistoryDialogBody,
      confirmLabel: l10n.deleteAllLocalHistoryConfirm,
    );
    if (!mounted) return;
    if (!confirmed) return;

    final encryptionProvider = context.read<EncryptionProvider>();
    setState(() => _deletingAllLocalHistory = true);
    try {
      final result = await encryptionProvider.clearLocalDecryptedContentCache();
      if (!mounted) return;
      await PlaybackController.clearAudioCache();
      if (!mounted) return;

      showTopSnackBar(
        context,
        result.isComplete
            ? l10n.snackbarAllLocalHistoryDeleted
            : l10n.snackbarFailedToDeleteAllLocalHistory,
      );
    } catch (_) {
      if (!mounted) return;
      showTopSnackBar(context, l10n.snackbarFailedToDeleteAllLocalHistory);
    } finally {
      if (mounted) {
        setState(() => _deletingAllLocalHistory = false);
      }
    }
  }
}
