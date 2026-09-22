import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/encryption_provider.dart';
import '../services/device_link/link_ceremony_controller.dart';
import '../services/device_link/link_code_extract.dart';
import '../services/device_link/link_crypto.dart';
import '../services/device_link/pending_link_code.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../widgets/identity_reset_pending_banner.dart'
    show identityResetRemainingLabel;
import '../widgets/recovery_phrase_prompt.dart' show startIdentityResetFlow;
import '../widgets/top_snackbar.dart';
import 'link_restore_section.dart';
import 'link_this_device_screen.dart' show LinkThisDeviceBody;

/// (lxxiii) clause 3: an enrolled account that lost its keys meets a GATE,
/// not a banner. Rendered by `AuthGate` ABOVE the (still mounted, `Offstage`)
/// `MainShell` while `needsDeviceLink || identityCheckUnavailable` — the
/// socket, the guard's round trip and the reset hydration all live under the
/// shell, so unmounting it would starve this screen of the very state that
/// opens it.
///
/// ONE screen, four states chosen by PROVIDER state, never by navigation:
/// (a) link — the device-side §5.1 ceremony inline; (b) reset pending — the
/// countdown + cancel, link still offered below (the primary may reappear);
/// (c) unknown — spinner + retry, never a keyless shell; (d) mismatch/locked
/// — state (a) with the (lxv)/(lxvii) disposal notice.
class DeviceLinkGateScreen extends StatefulWidget {
  const DeviceLinkGateScreen({super.key});

  @override
  State<DeviceLinkGateScreen> createState() => _DeviceLinkGateScreenState();
}

class _DeviceLinkGateScreenState extends State<DeviceLinkGateScreen> {
  LinkCeremonyController? _controller;
  ConnectionProvider? _connection;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // One tick a minute keeps the reset countdown honest without repainting
    // the gate every second (same cadence as IdentityResetPendingBanner).
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    // Same construction as DevicesScreen.initState: this screen owns the
    // ceremony controller and registers it as the provisioning sink for its
    // lifetime. A pending `n` code stays a PRIMARY-side concern, but a
    // deep-linked `p` code (the primary's display, (lxxvii)) belongs exactly
    // here — this keyless install is the hello side.
    final connection = context.read<ConnectionProvider>();
    final encryption = context.read<EncryptionProvider>();
    final auth = context.read<AuthProvider>();
    final userId = connection.currentUserId ?? auth.currentUser?.id;
    if (userId == null) return;
    final controller = LinkCeremonyController(
      userId: userId,
      emit: connection.emit,
      identity: EncryptionServiceLinkGateway(encryption.encryptionService),
      adoptSession: auth.adoptProvisionedSession,
      // (lxv)/(lxvii): the ceremony may dispose stale material — (lxiv)
      // mismatch or a lock-refused identity. Read live at blob time — the
      // predicate is the provider's, not a snapshot.
      staleDisposalAuthorized: () => encryption.linkDisposesStaleMaterial,
      reconnect: (accessToken) async {
        // `immediate`: the reconnect debounce would defer this to a timer and
        // return at once, so the rebind's await would resolve BEFORE the
        // socket carries the new device — the same reason the §6.2 rebind
        // passes it. Rate-limited by the ceremony itself, not the cooldown.
        await connection.connect(
          userId,
          accessToken,
          AppConfig.baseUrl,
          immediate: true,
        );
      },
    );
    _controller = controller;
    _connection = connection;
    connection.registerProvisioningSink(controller);
    controller.addListener(_maybeConsumePendingPrimaryCode);
    PendingLinkCode.listenable.addListener(_maybeConsumePendingPrimaryCode);
    // The controller has not notified yet — check the slot armed at boot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeConsumePendingPrimaryCode();
    });
  }

  /// A `p` code that arrived by deep link on this keyless install runs the
  /// flipped hello-side flow ((lxxvii) clause 3). Peeked by ROLE first: an
  /// `n` code is left armed for a primary (this install can never use it,
  /// and consuming it would eat the code a later primary-side screen needs).
  bool _consumedPendingPrimaryCode = false;
  void _maybeConsumePendingPrimaryCode() {
    final controller = _controller;
    if (controller == null || _consumedPendingPrimaryCode || !mounted) return;
    final raw = PendingLinkCode.listenable.value;
    if (raw == null) return;
    final code = extractLinkCode(raw) ?? raw;
    if (LinkOobCode.tryParse(code)?.role != LinkRole.primary) return;
    _consumedPendingPrimaryCode = true;
    PendingLinkCode.take();
    unawaited(
      controller.startNewDeviceFromCode(code, platform: linkPlatformLabel()),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    PendingLinkCode.listenable.removeListener(_maybeConsumePendingPrimaryCode);
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_maybeConsumePendingPrimaryCode);
      _connection?.unregisterProvisioningSink(controller);
      controller.dispose();
    }
    super.dispose();
  }


  /// The rebind's reconnect re-runs the E2E init, which clears
  /// `identityIncomplete` and unmounts this gate — the toast is the only
  /// confirmation the user needs.
  void _onLinked() {
    if (!mounted) return;
    showTopSnackBar(context, AppLocalizations.of(context).linkNewDone);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final encryption = context.watch<EncryptionProvider>();

    final resetDeadline = encryption.identityResetDeadline;
    final resetPending = resetDeadline != null;
    // (c): the guard could not be asked and nothing else is known — never a
    // keyless shell, and no ceremony to start against an unknown verdict.
    final checkingOnly =
        encryption.identityCheckUnavailable && !encryption.needsDeviceLink;

    final children = <Widget>[];
    if (resetPending) {
      children.addAll(_resetPendingSection(context, resetDeadline));
      children.add(const SizedBox(height: 32));
      children.addAll(_linkSection(context, encryption));
    } else if (checkingOnly) {
      children.addAll(_checkingSection(context));
    } else {
      children.addAll(_linkSection(context, encryption));
    }

    // Footer, in the order the doors deserve: the (lxxviii) clause-3 phrase
    // restore FIRST — it brings back the same identity in seconds — then the
    // reset door on every state EXCEPT reset-pending ((lxxii)'s two-buttons
    // rule — a running ceremony already answers `existing`), then sign-out
    // on every state (keys and history untouched). The restore section used
    // to be last: on a Pixel 7 it sat below the fold, under "Rozpocznij
    // reset", so a wiped user read "new keys after 6 h, old history lost"
    // before finding the door that keeps their keys (Run C, 2026-09-22).
    children.add(const SizedBox(height: 32));
    children.add(const LinkRestoreSection());
    children.add(const SizedBox(height: 16));
    if (!resetPending) {
      children.addAll([
        const SizedBox(height: 16),
        Text(
          l10n.linkGateNoPrimaryQuestion,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.linkGateResetHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('link-gate-start-reset'),
          onPressed: () => startIdentityResetFlow(context),
          child: Text(l10n.identityResetStartAction),
        ),
        const SizedBox(height: 16),
      ]);
    }
    children.add(
      TextButton(
        key: const Key('link-gate-logout'),
        onPressed: () => context.read<AuthProvider>().logout(),
        style: TextButton.styleFrom(foregroundColor: colors.onSurfaceVariant),
        child: Text(l10n.linkGateLogoutAction),
      ),
    );

    return Scaffold(
      key: const Key('device-link-gate'),
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      // No back arrow: this is not a route, and there is nothing behind it a
      // keyless install may use.
      appBar: GlassTopBar(
        title: Text(
          l10n.linkGateTitle,
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
          children: children,
        ),
      ),
    );
  }

  /// States (a)/(d): the inline device-side ceremony; (d) is (a) with the
  /// disposal notice.
  List<Widget> _linkSection(BuildContext context, EncryptionProvider e) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final controller = _controller;
    return [
      Text(
        e.linkDisposesStaleMaterial
            ? l10n.linkGateStaleBody
            // (lxxvii) clause 3: the body now names BOTH directions — scan
            // the primary's code or show it this one.
            : l10n.linkGateScanBody,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      if (controller == null)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else
        // Stable key: the reset section above appears and disappears, which
        // shifts this widget's column index. Without a key Flutter would
        // treat that as a fresh element and restart the ceremony (abort +
        // new stage) every time the countdown hydrates.
        LinkThisDeviceBody(
          key: const ValueKey('link-gate-ceremony'),
          controller: controller,
          waitingLabel: l10n.linkGateWaiting,
          onDone: _onLinked,
        ),
    ];
  }

  /// State (b): a §6.2 ceremony is counting down. Cancel is one tap; the
  /// start-reset door is HIDDEN (two "start" buttons for one ceremony would
  /// answer `existing`), and the link stays offered below because the primary
  /// may reappear. Linking does NOT cancel the ceremony — only a tap on
  /// cancel does (server `cancelReset` is reachable solely through
  /// `resetIdentityCancel`); the copy tells the user to cancel first.
  List<Widget> _resetPendingSection(BuildContext context, DateTime deadline) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final phraseTooNew = context.select<EncryptionProvider, bool>(
      (e) =>
          e.identityResetRequestStatus ==
          EncryptionProvider.identityResetPhraseTooNewStatus,
    );
    return [
      Text(
        l10n.linkGateResetPendingTitle,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.linkGateResetPendingBody(
          identityResetRemainingLabel(l10n, deadline),
        ),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      if (phraseTooNew) ...[
        const SizedBox(height: 8),
        // A `phrase_too_new` answer is not a refusal: the ceremony IS
        // running, just at the full 72 h. Say why.
        Text(
          l10n.linkGateResetPhraseTooNew,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
        ),
      ],
      const SizedBox(height: 12),
      OutlinedButton(
        key: const Key('link-gate-cancel-reset'),
        onPressed: () => context.read<EncryptionProvider>().cancelIdentityReset(),
        child: Text(l10n.identityResetCancelAction),
      ),
    ];
  }

  /// State (c): the guard answered UNKNOWN — the server could not be asked
  /// whether this account already holds keys. Retry re-runs the E2E init.
  List<Widget> _checkingSection(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return [
      const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      Text(
        l10n.linkGateCheckingTitle,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.linkGateCheckingBody,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        key: const Key('link-gate-retry'),
        onPressed: () =>
            context.read<EncryptionProvider>().retryE2EInit().ignore(),
        child: Text(l10n.linkGateRetryAction),
      ),
    ];
  }
}
