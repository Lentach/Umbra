import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/encryption_provider.dart';
import 'recovery_phrase_prompt.dart'
    show identityResetAnswerIsRefusal, identityResetAnswerMessage;
import 'identity_alert_banner.dart';
import 'top_snackbar.dart';

/// Phase 0b reset ceremony (multi-device spec §6.2): somebody asked the server
/// to let this account install new encryption keys, and a countdown is running.
///
/// This banner IS the protection. The delay only matters if the account owner
/// sees it and can stop it, so the cancel action is prominent, needs no key,
/// and is available from any signed-in session for the whole window. Every
/// session gets this — the request does not have to come from this device.
///
/// The countdown ticks locally against a server-issued deadline; the server
/// remains the authority and re-states it on every reconnect.
class IdentityResetPendingBanner extends StatefulWidget {
  const IdentityResetPendingBanner({super.key});

  @override
  State<IdentityResetPendingBanner> createState() =>
      _IdentityResetPendingBannerState();
}

class _IdentityResetPendingBannerState
    extends State<IdentityResetPendingBanner> {
  Timer? _ticker;

  /// The last request answer already shown, so a rebuild does not repeat it.
  String? _reportedAnswer;

  @override
  void initState() {
    super.initState();
    // One tick a minute is enough for a 72 h (or 1 h) countdown and keeps the
    // banner from repainting the shell every second.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Says out loud what the server answered.
  ///
  /// Three of the five answers REFUSE to start anything, and a user who lost
  /// their keys can hit all three — a mistyped phrase, the lockout after five
  /// of those, or the cooldown that follows a cancel. Without this the button
  /// simply appears dead while the account stays unreachable.
  void _reportAnswer(String status) {
    if (_reportedAnswer == status) return;
    _reportedAnswer = status;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final message = identityResetAnswerMessage(
        AppLocalizations.of(context),
        status,
      );
      context.read<EncryptionProvider>().clearIdentityResetRequestStatus();
      if (message == null) return;
      showTopSnackBar(
        context,
        message,
        backgroundColor: identityResetAnswerIsRefusal(status)
            ? Theme.of(context).colorScheme.error
            : null,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final deadline = context.select<EncryptionProvider, DateTime?>(
      (e) => e.identityResetDeadline,
    );
    // Watched here rather than in the dialog that sent the request: the answer
    // can land after that dialog is gone, and `existing` can arrive because
    // ANOTHER session started the ceremony.
    final answer = context.select<EncryptionProvider, String?>(
      (e) => e.identityResetRequestStatus,
    );
    // The shell stays mounted under the device-link gate (`AuthGate`), and the
    // gate shows `phrase_too_new` as a lasting line of its own: consuming it
    // here would leave the owner a snackbar for 2.5 s instead.
    final gated = context.select<EncryptionProvider, bool>(
      (e) => e.needsDeviceLink || e.identityCheckUnavailable,
    );
    if (answer == null) {
      _reportedAnswer = null;
    } else if (!gated ||
        answer != EncryptionProvider.identityResetPhraseTooNewStatus) {
      _reportAnswer(answer);
    }
    // (lxxiii) clause 3: this banner renders ONLY the pending countdown — for
    // the account's OTHER, healthy sessions, which may want to cancel a reset
    // somebody started. The lock-refused branch (and its start-reset door)
    // moved to `DeviceLinkGateScreen`: a keyless install never reaches the
    // shell any more, and a healthy device watching someone else's reset must
    // not be offered to start one.
    if (deadline == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return IdentityAlertBanner(
      icon: Icons.lock_reset_outlined,
      title: l10n.identityResetPendingTitle,
      // The countdown is STATUS, not prose, so it stays visible while the
      // explanation is collapsed — the whole point of the delay is that someone
      // sees it running.
      summary: identityResetRemainingLabel(l10n, deadline),
      detail: l10n.identityResetPendingBody(
        identityResetRemainingLabel(l10n, deadline),
      ),
      // Foreground pinned to onErrorContainer: theme primary is nearly
      // invisible on the error container (same reason as the 0a banner).
      action: TextButton(
        key: const Key('identity-reset-banner-action'),
        onPressed: () =>
            context.read<EncryptionProvider>().cancelIdentityReset(),
        style: TextButton.styleFrom(
          foregroundColor: colors.onErrorContainer,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
        child: Text(l10n.identityResetCancelAction),
      ),
    );
  }
}

/// Coarse, human remaining time for a §6.2 countdown: hours while there is
/// more than one left, minutes below that. Deliberately never seconds — this
/// is a 72 h window, not a stopwatch. Shared with `DeviceLinkGateScreen`'s
/// reset-pending state so the two countdowns cannot drift apart.
String identityResetRemainingLabel(AppLocalizations l10n, DateTime deadline) {
  final left = deadline.difference(DateTime.now());
  if (left.isNegative) return l10n.identityResetAnyMoment;
  if (left.inHours >= 1) return l10n.identityResetHoursLeft(left.inHours);
  return l10n.identityResetMinutesLeft(left.inMinutes);
}
