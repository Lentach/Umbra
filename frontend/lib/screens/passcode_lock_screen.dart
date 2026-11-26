import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/passcode_provider.dart';
import '../services/passcode_store.dart';
import '../theme/rpg_theme.dart';
import '../utils/passcode_autolock.dart';
import 'passcode_unlock_screen.dart' show passcodeScopeNote;
import '../widgets/glass/glass_sheet.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../widgets/passcode_entry_view.dart';
import '../widgets/settings_console.dart';
import '../widgets/top_snackbar.dart';

/// Settings → Security → Passcode Lock.
///
/// Two faces, like Zangi's: an intro that offers to turn the lock on, and a
/// management list once it is on. The screen owns the multi-step flows (set →
/// repeat, verify → set → repeat) so `PasscodeProvider` stays a state machine
/// with no wizard state in it.
class PasscodeLockScreen extends StatelessWidget {
  const PasscodeLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final passcode = context.watch<PasscodeProvider>();

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
          l10n.passcodeLock,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: passcode.isEnabled
            ? _EnabledBody(passcode: passcode)
            : const _IntroBody(),
      ),
    );
  }
}

class _IntroBody extends StatelessWidget {
  const _IntroBody();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = FireplaceColors.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Center(
          child: ConsoleHexIcon(glyph: ConsoleGlyph.password, height: 72),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.passcodeIntro,
          textAlign: TextAlign.center,
          style: RpgTheme.bodyFont(fontSize: 14, color: colors.mutedText),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('passcode-turn-on'),
            onPressed: () => _runSetup(context),
            child: Text(l10n.passcodeTurnOn),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          l10n.passcodeNote,
          textAlign: TextAlign.center,
          style: RpgTheme.bodyFont(fontSize: 12, color: colors.mutedText),
        ),
        const SizedBox(height: 12),
        Text(
          passcodeScopeNote(l10n),
          textAlign: TextAlign.center,
          style: RpgTheme.bodyFont(fontSize: 12, color: colors.mutedText),
        ),
      ],
    );
  }

  Future<void> _runSetup(BuildContext context) async {
    final passcode = context.read<PasscodeProvider>();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PasscodeSetupScreen(
          initialMode: PasscodeMode.digits6,
          allowModeChoice: true,
          keyMaterial: passcode.wrapsKeys,
          onCommit: (code, mode) =>
              passcode.enable(passcode: code, mode: mode),
        ),
      ),
    );
  }
}

class _EnabledBody extends StatelessWidget {
  const _EnabledBody({required this.passcode});

  final PasscodeProvider passcode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      children: [
        SettingsSectionCaption(label: l10n.passcodeLock),
        SettingsConsoleRow(
          key: const Key('passcode-change-row'),
          glyph: ConsoleGlyph.password,
          title: l10n.passcodeChange,
          onTap: () => _change(context),
        ),
        SettingsConsoleRow(
          key: const Key('passcode-autolock-row'),
          glyph: ConsoleGlyph.privacy,
          title: l10n.passcodeAutoLock,
          subtitle: autoLockLabel(l10n, passcode.autoLockSeconds),
          onTap: () => _pickAutoLock(context),
        ),
        SettingsConsoleRow(
          key: const Key('passcode-turn-off'),
          glyph: ConsoleGlyph.deleteNode,
          title: l10n.passcodeTurnOff,
          edge: ConsoleRowEdge.danger,
          onTap: () => _disable(context),
        ),
        ConsoleInfoRow(
          glyph: ConsoleGlyph.keys,
          title: l10n.passcodeNote,
          body: passcodeScopeNote(l10n),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '${l10n.passcodeStateOn} · ${autoLockLabel(l10n, passcode.autoLockSeconds)}',
            style: RpgTheme.bodyFont(
              fontSize: 12,
              color: colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _change(BuildContext context) async {
    final passcodeProvider = context.read<PasscodeProvider>();
    final current = await _askCurrentCode(context, passcodeProvider);
    if (current == null || !context.mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PasscodeSetupScreen(
          initialMode: passcodeProvider.mode,
          allowModeChoice: true,
          keyMaterial: passcodeProvider.wrapsKeys,
          onCommit: (code, mode) => passcodeProvider.change(
            current: current,
            next: code,
            mode: mode,
          ),
        ),
      ),
    );
  }

  Future<void> _disable(BuildContext context) async {
    final passcodeProvider = context.read<PasscodeProvider>();
    final current = await _askCurrentCode(context, passcodeProvider);
    if (current == null) return;
    final disabled = await passcodeProvider.disable(passcode: current);
    if (!context.mounted) return;
    // The job is done — leave, instead of re-rendering as the "enable it"
    // page the user has no reason to look at. A refusal stays put, but says
    // so (the code verified, yet the vault could not be opened or unwrapped).
    if (disabled) {
      Navigator.of(context).pop();
    } else if (passcodeProvider.lockoutRemaining == null) {
      showTopSnackBar(context, AppLocalizations.of(context).passcodeUnavailable);
    }
  }

  Future<void> _pickAutoLock(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final passcodeProvider = context.read<PasscodeProvider>();
    final chosen = await showGlassSheet<int>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            SettingsSectionCaption(label: l10n.passcodeAutoLock),
            for (final seconds in kPasscodeAutoLockChoices)
              SettingsConsoleRow(
                key: Key('passcode-autolock-$seconds'),
                glyph: ConsoleGlyph.privacy,
                title: autoLockLabel(l10n, seconds),
                edge: seconds == passcodeProvider.autoLockSeconds
                    ? ConsoleRowEdge.accent
                    : ConsoleRowEdge.none,
                onTap: () => Navigator.of(sheetContext).pop(seconds),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await passcodeProvider.setAutoLockSeconds(chosen);
  }
}

/// Asks for the CURRENT code and returns it once it verifies, or null if the
/// user backed out. Wrong codes keep the prompt open — the same surface the
/// lock screen uses, minus the recovery door (the user is already inside).
Future<String?> _askCurrentCode(
  BuildContext context,
  PasscodeProvider passcode,
) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => _PasscodePromptScreen(passcode: passcode),
    ),
  );
}

class _PasscodePromptScreen extends StatefulWidget {
  const _PasscodePromptScreen({required this.passcode});

  final PasscodeProvider passcode;

  @override
  State<_PasscodePromptScreen> createState() => _PasscodePromptScreenState();
}

class _PasscodePromptScreenState extends State<_PasscodePromptScreen> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          l10n.passcodeLock,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: PasscodeEntryView(
        mode: widget.passcode.mode,
        title: l10n.passcodeCurrentTitle,
        errorText: _error,
        onSubmit: (code) async {
          // `verifyCurrent` is throttled, so false no longer means "wrong".
          // Reporting a cooldown as a wrong code would tell a user their
          // CORRECT passcode is wrong for up to an hour.
          final blocked = widget.passcode.lockoutRemaining;
          if (blocked != null) {
            setState(
              () => _error = l10n.passcodeBlocked(blocked.inSeconds + 1),
            );
            return;
          }
          final ok = await widget.passcode.verifyCurrent(code);
          if (!context.mounted) return;
          if (!ok) {
            final cooldown = widget.passcode.lockoutRemaining;
            setState(
              () => _error = cooldown != null
                  ? l10n.passcodeBlocked(cooldown.inSeconds + 1)
                  : l10n.passcodeWrong,
            );
            return;
          }
          Navigator.of(context).pop(code);
        },
      ),
    );
  }
}

/// Set-and-repeat, with Zangi's "Passcode Options" shape chooser.
class PasscodeSetupScreen extends StatefulWidget {
  const PasscodeSetupScreen({
    super.key,
    required this.initialMode,
    required this.onCommit,
    this.allowModeChoice = true,
    this.keyMaterial = false,
  });

  final PasscodeMode initialMode;
  final bool allowModeChoice;

  /// True where the code derives the content KEK (web wrapping). Raises the
  /// custom-code floor and drops the 4-digit shape, which the provider
  /// refuses outright there — offering a choice that can only fail is how a
  /// user ends up staring at "this device could not secure the passcode".
  final bool keyMaterial;

  /// Persists the finished code. Returning false surfaces the generic
  /// unavailable message and keeps the user on the screen.
  final Future<bool> Function(String code, PasscodeMode mode) onCommit;

  @override
  State<PasscodeSetupScreen> createState() => _PasscodeSetupScreenState();
}

class _PasscodeSetupScreenState extends State<PasscodeSetupScreen> {
  late PasscodeMode _mode = widget.initialMode;
  String? _first;
  String? _error;

  Future<void> _submit(String code) async {
    final l10n = AppLocalizations.of(context);
    // Checked on the FIRST entry: making the user type a code twice before
    // telling them it is too weak is the same dead end as the generic
    // failure this replaces.
    if (refusePasscode(code, _mode, keyMaterial: widget.keyMaterial) ==
        PasscodeRefusal.tooWeakForKeys) {
      setState(() {
        _first = null;
        _error = l10n.passcodeTooWeakForKeys;
      });
      return;
    }
    if (_first == null) {
      setState(() {
        _first = code;
        _error = null;
      });
      return;
    }
    if (code != _first) {
      // Start over rather than let the user retry the confirmation against a
      // first entry they may have fat-fingered — that is how people end up
      // locked out by a code they never meant to set.
      setState(() {
        _first = null;
        _error = l10n.passcodeMismatch;
      });
      return;
    }
    final ok = await widget.onCommit(code, _mode);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _first = null;
        _error = l10n.passcodeUnavailable;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _pickMode() async {
    final l10n = AppLocalizations.of(context);
    final chosen = await showGlassSheet<PasscodeMode>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            SettingsSectionCaption(label: l10n.passcodeOptions),
            SettingsConsoleRow(
              key: const Key('passcode-option-custom'),
              glyph: ConsoleGlyph.password,
              title: l10n.passcodeOptionCustom,
              onTap: () =>
                  Navigator.of(sheetContext).pop(PasscodeMode.alphanumeric),
            ),
            SettingsConsoleRow(
              key: const Key('passcode-option-six'),
              glyph: ConsoleGlyph.password,
              title: l10n.passcodeOptionSixDigits,
              onTap: () => Navigator.of(sheetContext).pop(PasscodeMode.digits6),
            ),
            // Absent under wrapping: `_modeAllowed` refuses digits4 there, so
            // the row could only ever produce a failure.
            if (!widget.keyMaterial)
              SettingsConsoleRow(
                key: const Key('passcode-option-four'),
                glyph: ConsoleGlyph.password,
                title: l10n.passcodeOptionFourDigits,
                onTap: () =>
                    Navigator.of(sheetContext).pop(PasscodeMode.digits4),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _mode = chosen;
      // Switching shape mid-flow invalidates the first entry.
      _first = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          l10n.passcodeLock,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: PasscodeEntryView(
        // Rebuild the entry surface from scratch when the shape or the step
        // changes, so no digits survive into the next step.
        key: ValueKey('${_mode.name}-${_first == null ? 'first' : 'repeat'}'),
        mode: _mode,
        title: _first == null ? l10n.passcodeSetTitle : l10n.passcodeRepeatTitle,
        errorText: _error,
        onOptions: widget.allowModeChoice && _first == null ? _pickMode : null,
        onSubmit: _submit,
      ),
    );
  }
}

/// Human label for an auto-lock delay. Shared by the settings row and the
/// chooser sheet so the two can never disagree.
String autoLockLabel(AppLocalizations l10n, int seconds) => switch (seconds) {
  0 => l10n.passcodeAutoLockImmediately,
  60 => l10n.passcodeAutoLockMinute,
  300 => l10n.passcodeAutoLockFiveMinutes,
  _ => l10n.passcodeAutoLockHour,
};
