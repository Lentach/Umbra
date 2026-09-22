import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/encryption_provider.dart';
import '../providers/passcode_provider.dart';
import '../screens/passcode_unlock_screen.dart';
import '../screens/storage_loss_screen.dart';
import '../services/backup/storage_loss.dart';
import '../services/local_data_eraser.dart';
import '../utils/privacy_curtain.dart';
import 'input/composer_keyboard_signals.dart';
import 'passcode_curtain.dart';

/// Wraps the whole app below `MaterialApp.builder`, so the lock covers every
/// pushed route and the bottom nav — not just the shell.
///
/// The guarded subtree is hidden with [Offstage], never unmounted: tearing
/// down `MainShell` would drop the socket, the active conversation and any
/// in-flight send, and this app's reconnect path is where its worst field bugs
/// have lived. Offstage skips paint, hit-testing and semantics, so the content
/// is unreachable while its state stays intact.
class PasscodeGate extends StatelessWidget {
  const PasscodeGate({super.key, required this.child, LocalDataEraser? eraser})
    : _eraser = eraser;

  final Widget child;

  /// Injectable so widget tests can prove the destructive path runs without
  /// wiping the test host's own stores.
  final LocalDataEraser? _eraser;

  @override
  Widget build(BuildContext context) {
    final passcode = context.watch<PasscodeProvider>();
    return ValueListenableBuilder<bool>(
      valueListenable: composerNativePickerActive,
      builder: (context, pickerActive, _) => ValueListenableBuilder<bool>(
        // The link ceremony is the picker's twin (amendment (lxxvi) clause 2):
        // its scanner/permission surfaces hide the page, and a DOM curtain
        // over the QR would flash mid-ceremony exactly like one over the
        // composer. Listened here so an arm/disarm happens on the flip, not
        // on the next unrelated rebuild.
        valueListenable: linkCeremonyActive,
        builder: (context, ceremonyActive, _) =>
            _body(context, passcode, pickerActive || ceremonyActive),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    PasscodeProvider passcode,
    bool departureExempt,
  ) {
    final state = passcode.state;
    // `unknown` counts as covered: the credential has not been read yet, and
    // painting the shell for one frame on every cold start of a locked app
    // would defeat the point.
    final covered =
        state == PasscodeLockState.locked || state == PasscodeLockState.unknown;
    // The curtain is painted OVER the app rather than Offstage-ing it: the
    // subtree may hold a pending `<input type=file>` (the attach picker), and
    // un-painting it mid-pick is the (2026-08-21) lost-pick shape again.
    final curtained = !covered && passcode.curtained;

    // The DOM curtain (web/index.html) is shown by the page itself on blur —
    // no Flutter frame needed — and at boot when a passcode is enabled. It is
    // lifted HERE, after a frame that paints the state replacing it: the lock
    // screen, or the app once the return verdict said "still inside the
    // window". Lifting any earlier is the chat-for-one-frame flash again.
    // Disarmed for the attach picker span (`composerNativePickerActive`) and
    // for a live link ceremony (`linkCeremonyActive`): the OS sheet / scanner
    // hides the page, and a curtain would flash when it closes — the same
    // exemption the immediate lock has.
    armDomCurtain(passcode.isEnabled && !departureExempt);
    if (state != PasscodeLockState.unknown && !curtained) {
      WidgetsBinding.instance.addPostFrameCallback((_) => hideDomCurtain());
    }
    return Stack(
      children: [
        Positioned.fill(child: Offstage(offstage: covered, child: child)),
        // BELOW the lock layers, and Offstage under the same `covered` flag
        // that hides the app. Paint order alone would already keep it behind
        // an opaque lock screen; the Offstage is the second half, so a locked
        // device cannot leak this surface through a hit test, a semantics
        // walk, or a lock layer that is ever less than fully opaque. The
        // storage-loss notice names what this account lost — it is content,
        // and content lives behind the passcode.
        Positioned.fill(
          child: Offstage(offstage: covered, child: const _StorageLossLayer()),
        ),
        if (covered)
          Positioned.fill(
            child: state == PasscodeLockState.unknown
                ? const PasscodeCurtain()
                : PasscodeUnlockScreen(onErase: () => _erase(context)),
          ),
        if (curtained) const Positioned.fill(child: PasscodeCurtain()),
      ],
    );
  }

  /// The only way past a forgotten code (owner ruling 2026-09-04): destroy
  /// every local store, then sign out.
  ///
  /// Order matters. The eraser clears the passcode flag before the credential
  /// (see `services/local_data_eraser.dart`), then the provider re-reads the
  /// now-empty store so the gate opens, and only then does the logout run —
  /// a failing logout must not leave the user staring at a lock screen they
  /// already told us they cannot satisfy.
  Future<LocalDataEraseReport> _erase(BuildContext context) async {
    final passcode = context.read<PasscodeProvider>();
    final auth = context.read<AuthProvider>();
    final report = await (_eraser ?? DeviceLocalDataEraser()).eraseEverything();
    await passcode.initialize();
    await auth.logout();
    return report;
  }
}

/// Holds the storage-loss surface on screen for exactly as long as the boot
/// latch stands, and only for a signed-in account.
///
/// A [ValueListenableBuilder] rather than a per-build read of a static: the
/// latch is set while the content store opens, which is strictly AFTER this
/// layer first mounts, and a widget that read a false static registered no
/// dependency on anything — nothing would ever ask it to look again, and a
/// `const` instance is not even rebuilt when its parent is.
class _StorageLossLayer extends StatelessWidget {
  const _StorageLossLayer();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: StorageLoss.listenable,
    builder: (context, lost, _) {
      if (!lost) return const SizedBox.shrink();
      // No account, nothing to name a loss against: a signed-out user is
      // looking at a login screen, and a full-screen accusation there is
      // about a device state they cannot act on yet. Watched, not read, so
      // the surface appears the moment they do sign in.
      final userId = context.watch<AuthProvider>().currentUser?.id;
      if (userId == null) return const SizedBox.shrink();
      // The device-link gate outranks this notice. This layer sits above the
      // WHOLE navigator — `AuthGate`'s gate included — and a Keystore-only
      // loss takes the Signal identity down with the store, so the boot
      // latches the loss and opens the gate in the same second (Pixel_7,
      // 2026-09-22, Run C′). Painted first, this file-only screen covered the
      // gate's phrase door — the ONE path that brings the account keys back —
      // with copy that never mentioned the identity. The latch is process-
      // scoped, so yielding costs nothing: the notice appears the moment the
      // gate releases, which is exactly when history is the next question.
      final gated = context.select<EncryptionProvider, bool>(
        (e) => e.needsDeviceLink || e.identityCheckUnavailable,
      );
      if (gated) return const SizedBox.shrink();
      // `acknowledge()` writes the same notifier, so the dismiss needs no
      // callback of its own — the builder simply runs again with false.
      return StorageLossScreen(userId: userId, onDismiss: () {});
    },
  );
}
