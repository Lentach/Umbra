import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../config/app_config.dart';
import '../providers/auth_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/encryption_provider.dart';
import '../services/device_link/link_ceremony_controller.dart';
import '../services/device_link/pending_link_code.dart';
import '../services/device_list/device_list_canonical.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';
import '../utils/web_display_mode.dart';
import '../utils/web_ios_viewport_pin.dart';
import 'link_device_screen.dart';
import 'recovery_key_screen.dart';

/// The account's devices (multi-device spec §4/§5.1 — Phase 2 T3).
///
/// Owns the screen-scoped [LinkCeremonyController] and registers it as
/// ConnectionProvider's provisioning sink for its lifetime; the two link-flow
/// screens drive the same instance. The rendered list is ONLY the DAK-signed
/// canonical list, verified along the I7 chain against this device's own
/// identity — never the server's bare word.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, this.revokeDeviceId});

  /// A device the user already chose to remove elsewhere — the chat list's
  /// 30-day question (decision 101 B), whose dialog is the confirmation —
  /// revoked once the verified list is here, through the same
  /// [LinkCeremonyController.revokeDevice] this screen's own confirm runs, so
  /// the outcome shows where it always does.
  final int? revokeDeviceId;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  LinkCeremonyController? _controller;
  ConnectionProvider? _connection;

  /// (lxix): tombstones start collapsed; the toggle is per screen visit.
  bool _showRevoked = false;

  @override
  void initState() {
    super.initState();
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
    controller
      ..addListener(_maybeOpenPendingLink)
      ..addListener(_maybeRevokeAsked)
      ..refreshDeviceList();
  }

  /// Runs [DevicesScreen.revokeDeviceId]'s revoke once the verified list is
  /// here, at most once per visit. A device that list no longer names live,
  /// this device itself, or the primary is left alone: the server refuses
  /// the last two anyway (amendment (xxi)).
  bool _revokeAskedRan = false;
  void _maybeRevokeAsked() {
    final id = widget.revokeDeviceId;
    final controller = _controller;
    if (id == null || controller == null || _revokeAskedRan || !mounted) {
      return;
    }
    final list = controller.verifiedList;
    if (controller.listState != DeviceListState.enrolled || list == null) {
      return;
    }
    _revokeAskedRan = true;
    final live = [
      for (final e in list.devices)
        if (e.revokedAtMs == null) e.deviceId,
    ];
    final primary = live.isEmpty ? null : live.reduce((a, b) => a < b ? a : b);
    if (!live.contains(id) ||
        id == primary ||
        id == context.read<EncryptionProvider>().ownDeviceId) {
      return;
    }
    // Delivered from a controller notification, possibly mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await controller.revokeDevice(id);
      // As [_confirmRevoke]: the tombstone is where the user sees it took.
      if (!mounted || controller.revokeError != null) return;
      setState(() => _showRevoked = true);
    });
  }

  /// A code that arrived by QR deep link opens the primary-side ceremony
  /// with the code already entered — but only once this install is KNOWN to
  /// hold the DAK ((lxviii) clause 2): a linked device that scanned a QR
  /// must not be walked into a flow that fails with `linkNoDak`. The
  /// verified list is NOT a precondition here: on a cold boot the DAK read
  /// wins the race against the list fetch, and gating on the list would
  /// park the code forever behind a list that never verifies. The ceremony
  /// itself waits for the list at staging (and fails with a reason if it
  /// never comes), so the user always sees a screen, never a silent no-op.
  /// Consumed exactly once; a stale slot never replays.
  ///
  /// Role routing ((lxxvii)): an `n` code here starts the classic paste
  /// flow. A `p` code on a KEYLESS install is consumed by the gate before
  /// this screen can exist; one that still reaches a DAK holder is fed
  /// through the same door and refused on-screen with `wrong_code_role` —
  /// visible feedback beats a silently parked slot.
  bool _openedPendingLink = false;
  void _maybeOpenPendingLink() {
    final controller = _controller;
    if (controller == null || _openedPendingLink || !mounted) return;
    if (controller.holdsDak != true || !PendingLinkCode.isArmed) return;
    final code = PendingLinkCode.take();
    if (code == null) return;
    _openedPendingLink = true;
    // Delivered from a controller notification, possibly mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              LinkDeviceScreen(controller: controller, initialCode: code),
        ),
      );
    });
  }

  /// (lxxviii) clause 4: "Włącz łączenie" = (web: warning dialog, already
  /// confirmed by the caller) → [LinkCeremonyController.mintDak] (no server
  /// call, idempotent) → MANDATORY [RecoveryKeyScreen] (the phrase + the
  /// sealed identity backup upload) → ONLY THEN [enableLinking], which
  /// enrols. Backing out of the phrase screen — or its upload failing —
  /// aborts with NOTHING enrolled (falsification F9); the minted DAK merely
  /// waits in the Keystore for the next attempt.
  Future<void> _enableLinkingWithBackup(
    LinkCeremonyController controller,
  ) async {
    try {
      await controller.mintDak();
    } catch (_) {
      // An unpersistable DAK must not walk the user through a phrase whose
      // enrolment can only fail afterwards.
      return;
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecoveryKeyScreen()),
    );
    if (saved != true || !mounted) return;
    await controller.enableLinking(platform: linkPlatformLabel());
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller
        ..removeListener(_maybeOpenPendingLink)
        ..removeListener(_maybeRevokeAsked);
      _connection?.unregisterProvisioningSink(controller);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final controller = _controller;

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
          l10n.devices,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: colors.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: controller == null
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: controller,
              builder: (context, _) => _buildBody(context, controller),
            ),
    );
  }

  Widget _buildBody(BuildContext context, LinkCeremonyController controller) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return ListView(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + GlassTopBar.capsuleHeight + 16,
        bottom: MediaQuery.paddingOf(context).bottom + 24,
        left: 24,
        right: 24,
      ),
      children: [
        Text(
          l10n.devicesExplainer,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        ..._buildListSection(context, controller),
        const SizedBox(height: 24),
        ..._buildActions(context, controller),
      ],
    );
  }

  List<Widget> _buildListSection(
    BuildContext context,
    LinkCeremonyController controller,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    switch (controller.listState) {
      case DeviceListState.loading:
        return [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.devicesLoading,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ];
      case DeviceListState.notEnrolled:
        return [
          Text(
            l10n.devicesNotEnrolled,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ];
      case DeviceListState.chainInvalid:
        return [
          Text(
            l10n.devicesChainInvalid,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ];
      case DeviceListState.enrolled:
        final list = controller.verifiedList;
        if (list == null) return const [];
        // (lxix): revoked rows are permanent tombstones in the DAK-signed
        // bytes (§3 — ids are never reused, so a revoked device re-links as a
        // fresh id and its old row stays forever). Live devices lead; the
        // tombstones collapse behind one disclosure so twenty old revokes do
        // not bury the device that matters. Wire bytes untouched.
        final live = [
          for (final e in list.devices)
            if (e.revokedAtMs == null) e,
        ];
        final revoked = [
          for (final e in list.devices)
            if (e.revokedAtMs != null) e,
        ];
        // (lxxx) clause 2: the signed list carries NO primary flag (§3) and
        // must not grow one. The badge is DERIVED as the lowest non-revoked
        // id — exactly the row `DevicesService.resolveLoginDeviceId`
        // resolves for login. Keying it on `deviceId == 1` was actively
        // misleading: every §6.2 reset and every (lxxviii) restore re-homes
        // the survivor onto a FRESH id and revokes the old one, so the live
        // primary lost the badge and the revoked device 1 kept it.
        final int? primaryDeviceId = live.isEmpty
            ? null
            : live.map((e) => e.deviceId).reduce((a, b) => a < b ? a : b);
        Widget row(DeviceListEntry entry) => _DeviceRow(
          entry: entry,
          l10n: l10n,
          isPrimary: entry.deviceId == primaryDeviceId,
          // Only the primary may revoke, and never itself (amendment
          // (xxi)) — the server enforces both; this just does not offer an
          // action guaranteed to be refused.
          onRevoke:
              entry.revokedAtMs == null &&
                  entry.deviceId != primaryDeviceId &&
                  entry.deviceId !=
                      context.read<EncryptionProvider>().ownDeviceId
              ? () => _confirmRevoke(context, controller, entry, l10n)
              : null,
          // (lxxx) clause 1: a name is informational, so ANY live row may
          // take one — including this device and the primary. A revoked row
          // is a tombstone and gets no affordance.
          onRename: entry.revokedAtMs == null
              ? () => _promptRename(context, controller, entry, l10n)
              : null,
          busy:
              controller.revokingDeviceId == entry.deviceId ||
              controller.renamingDeviceId == entry.deviceId,
        );
        return [
          for (final entry in live) row(entry),
          if (revoked.isNotEmpty) ...[
            TextButton.icon(
              key: const Key('devices-revoked-toggle'),
              onPressed: () => setState(() => _showRevoked = !_showRevoked),
              icon: Icon(
                _showRevoked ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(l10n.devicesRevokedSection(revoked.length)),
              style: TextButton.styleFrom(
                foregroundColor: colors.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
            if (_showRevoked)
              for (final entry in revoked) row(entry),
          ],
          if (controller.revokeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.devicesRevokeFailed,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
          if (controller.renameError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // (lxxx) clause 1: a name refused BEFORE signing gets its own
                // actionable line. "Try again" would be a dead end here —
                // retyping the same paste fails identically.
                controller.renameError == 'not_storable'
                    ? l10n.devicesRenameNotStorable
                    : l10n.devicesRenameFailed,
                key: const Key('devices-rename-error'),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
        ];
    }
  }

  /// Revocation is destructive for the other device's session, so it is
  /// confirmed — and the copy states the two things users get wrong: the
  /// device is signed out, and its local history is NOT erased (spec §5.5
  /// logout semantics, remote wipe is a §1 non-goal).
  Future<void> _confirmRevoke(
    BuildContext context,
    LinkCeremonyController controller,
    DeviceListEntry entry,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.devicesRevokeTitle),
        content: Text(l10n.devicesRevokeExplainer),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            key: const Key('devices-revoke-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.devicesRevokeAction),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await controller.revokeDevice(entry.deviceId);
      // (lxix): the tombstone is the user's confirmation that the revoke
      // took — open the section so the row lands where they can see it,
      // instead of vanishing behind a collapsed disclosure. Skipped when the
      // request never left this device (`no_dak`, `sign_failed`); the
      // server's answer arrives later and cannot be gated here.
      if (!mounted || controller.revokeError != null) return;
      setState(() => _showRevoked = true);
    }
  }

  /// (lxxx) clause 1: names are INFORMATIONAL — nothing in I1–I7, the SAS or
  /// any envelope reads them — so the prompt is a plain dialog, not a
  /// ceremony. Submitting an empty field CLEARS the name (the helper text
  /// says so), which reaches the same canonical bytes as never naming it.
  Future<void> _promptRename(
    BuildContext context,
    LinkCeremonyController controller,
    DeviceListEntry entry,
    AppLocalizations l10n,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameDialog(initialName: entry.name ?? '', l10n: l10n),
    );
    if (name == null) return;
    await controller.renameDevice(entry.deviceId, name);
  }

  List<Widget> _buildActions(
    BuildContext context,
    LinkCeremonyController controller,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final actions = <Widget>[];

    if (controller.listState == DeviceListState.notEnrolled) {
      // (lxxiv) clause 1: a web primary is asked to be INSTALLED first. A
      // browser tab's origin storage is the first thing a storage-pressure
      // sweep or "clear browsing data" takes, and a wiped primary's only
      // exit is the §6.2 delay (the DAK exists nowhere else, I2) — so a
      // plain tab sees an install instruction instead of the button, and an
      // installed web app gets a one-paragraph warning before enabling.
      // Android and desktop native are unchanged.
      final web = isWebPlatformForInstallRules();
      if (web && !isInstalledDisplayMode()) {
        actions.add(
          Text(
            l10n.devicesInstallFirst,
            key: const Key('devices-install-first'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        );
      } else {
        actions.add(
          Semantics(
            label: l10n.devicesEnableLinking,
            button: true,
            child: FilledButton(
              key: const Key('devices-enable-linking'),
              onPressed: controller.enrolling
                  ? null
                  : web
                  ? () => _confirmEnableLinkingWeb(context, controller, l10n)
                  : () => _enableLinkingWithBackup(controller),
              child: controller.enrolling
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.devicesEnableLinking),
            ),
          ),
        );
      }
    } else if (controller.listState == DeviceListState.enrolled) {
      // (lxviii) clause 2: the primary-side flow needs the DAK, and only the
      // primary holds it (§5.5). A linked device is told where linking
      // happens instead of being walked into `linkNoDak` after typing a code.
      // `null` = not resolved yet: offer nothing rather than the wrong thing.
      switch (controller.holdsDak) {
        case true:
          // (lxxiv) clause 2: an enrolled web primary running in a plain tab
          // is NUDGED to install — informational only, no gate, no modal.
          if (isWebPlatformForInstallRules() && !isInstalledDisplayMode()) {
            actions.addAll([
              Text(
                l10n.devicesInstallNudge,
                key: const Key('devices-install-nudge'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ]);
          }
          actions.add(
            Semantics(
              label: l10n.devicesLinkADevice,
              button: true,
              child: FilledButton(
                key: const Key('devices-link-a-device'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LinkDeviceScreen(controller: controller),
                    ),
                  );
                },
                child: Text(l10n.devicesLinkADevice),
              ),
            ),
          );
          // (lxxviii) clause 4: an enrolled DAK-holding primary whose account
          // has NO phrase-sealed backup (pre-(lxxviii) enrolments) is nudged
          // — only on an EXPLICIT server false, never on unknown.
          if (context.watch<EncryptionProvider>().hasIdentityBackup ==
              false) {
            actions.addAll([
              const SizedBox(height: 16),
              Text(
                l10n.devicesBackupMissing,
                key: const Key('devices-backup-missing'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('devices-create-backup'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RecoveryKeyScreen(),
                    ),
                  );
                },
                child: Text(l10n.devicesCreateBackupAction),
              ),
            ]);
          }
        case false:
          actions.add(
            Text(
              l10n.devicesLinkedDeviceNote,
              key: const Key('devices-linked-device-note'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          );
        case null:
          break;
      }
    }

    final enrollError = controller.enrollError;
    if (enrollError != null) {
      actions.addAll([
        const SizedBox(height: 12),
        Text(
          // `already_enrolled` is a DISTINCT state: another install of this
          // account holds the authority (first-write-wins, I2).
          enrollError == 'already_enrolled'
              ? l10n.devicesAlreadyEnrolled
              : l10n.devicesEnrollFailed,
          key: const Key('devices-enroll-error'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.error,
            fontWeight: FontWeight.w600,
          ),
        ),
      ]);
    }
    return actions;
  }

  /// (lxxiv) clause 1 + (lxxviii) clause 4: enabling linking on web mints
  /// the DAK into the sealed `sig_` KV — evictable with the browser's
  /// storage — so the choice is stated plainly first, and the phrase is
  /// named as MANDATORY. Confirm runs [_enableLinkingWithBackup]; cancel
  /// changes nothing.
  Future<void> _confirmEnableLinkingWeb(
    BuildContext context,
    LinkCeremonyController controller,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.devicesEnableLinkingWebWarningTitle),
        content: Text(
          '${l10n.devicesEnableLinkingWebWarningBody}\n\n'
          '${l10n.recoveryKeyRequiredForLinking}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          TextButton(
            key: const Key('devices-enable-linking-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.devicesEnableLinkingConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _enableLinkingWithBackup(controller);
  }
}

/// Owns the rename field's controller for exactly the dialog's lifetime —
/// disposing it at the `showDialog` await would kill it mid exit-transition,
/// while the field is still being laid out.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName, required this.l10n});

  final String initialName;
  final AppLocalizations l10n;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initialName,
  );
  // iOS WebKit keeps the LAYOUT viewport at full height when the keyboard
  // opens and scrolls the host document to reveal the focused input, so a
  // centred dialog was shoved off the top of the screen (owner's iPhone,
  // 2026-09-08). Same scoped pin the composer uses: while this field has
  // focus, `<flutter-view>` is pinned to the VISUAL viewport, the dialog
  // re-centres above the keyboard, and the document has no overflow to
  // scroll. Fully reverted on blur/dispose; no-op off iOS WebKit.
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setIOSComposerViewportPin(_focus.hasFocus);

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    setIOSComposerViewportPin(false);
    _focus.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      title: Text(l10n.devicesRenameTitle),
      content: TextField(
        key: const Key('device-rename-field'),
        controller: _field,
        focusNode: _focus,
        autofocus: true,
        maxLength: kDeviceNameMaxLength,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: l10n.devicesRenameHint,
          helperText: l10n.devicesRenameClearHint,
          helperMaxLines: 2,
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          key: const Key('device-rename-save'),
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: Text(l10n.devicesRenameSave),
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.entry,
    required this.l10n,
    this.isPrimary = false,
    this.onRevoke,
    this.onRename,
    this.busy = false,
  });

  final DeviceListEntry entry;
  final AppLocalizations l10n;

  /// (lxxx) clause 2: DERIVED by the caller as the lowest non-revoked id —
  /// the signed list carries no primary flag and must not grow one.
  final bool isPrimary;

  /// Null when this device may not be revoked from here: itself, the primary,
  /// or one already revoked (spec §12 amendment (xxi)).
  final VoidCallback? onRevoke;

  /// Null on a revoked row — a tombstone takes no name ((lxxx) clause 1).
  final VoidCallback? onRename;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final added = DateTime.fromMillisecondsSinceEpoch(entry.addedAtMs);
    final addedLabel =
        '${added.year}-${added.month.toString().padLeft(2, '0')}-'
        '${added.day.toString().padLeft(2, '0')}';
    final revoked = entry.revokedAtMs != null;
    // The name leads when there is one, but `platform · #id` never
    // disappears: the id is what every refusal code and support answer
    // names, so it stays on the secondary line ((lxxx) clause 1).
    final idLabel = '${entry.platform} · #${entry.deviceId}';
    final name = entry.name;
    final statusLabel = revoked ? l10n.devicesRevokedBadge : addedLabel;
    final title =
        '${name ?? idLabel}'
        '${isPrimary ? ' · ${l10n.devicesPrimaryBadge}' : ''}';
    final secondary = name == null ? statusLabel : '$idLabel · $statusLabel';

    return Semantics(
      label:
          'device ${entry.deviceId} ${entry.platform}'
          '${name == null ? '' : ' $name'}'
          '${isPrimary ? ' ${l10n.devicesPrimaryBadge}' : ''}'
          '${revoked ? ' ${l10n.devicesRevokedBadge}' : ''}',
      child: Container(
        key: Key('device-row-${entry.deviceId}'),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              entry.platform == 'web'
                  ? Icons.language
                  : Icons.smartphone_outlined,
              size: 20,
              color: revoked ? colors.onSurfaceVariant : colors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: revoked
                          ? colors.onSurfaceVariant
                          : colors.onSurface,
                      decoration: revoked ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    secondary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else ...[
              if (onRename != null)
                IconButton(
                  key: Key('device-rename-${entry.deviceId}'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: l10n.devicesRenameAction,
                  onPressed: onRename,
                ),
              if (onRevoke != null)
                IconButton(
                  key: Key('device-revoke-${entry.deviceId}'),
                  icon: const Icon(Icons.link_off, size: 20),
                  tooltip: l10n.devicesRevokeAction,
                  onPressed: onRevoke,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
