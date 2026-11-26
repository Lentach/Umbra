import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../services/device_link/link_ceremony_controller.dart';
import '../services/device_link/link_code_extract.dart';
import '../services/device_link/link_crypto.dart';
import '../utils/link_fragment_stub.dart'
    if (dart.library.html) '../utils/link_fragment_web.dart';
import '../theme/rpg_theme.dart';
import '../widgets/top_snackbar.dart';
import 'link_scan_screen.dart';

/// The NEW-DEVICE side (N) of the §5.1 link ceremony (Phase 2 T3), mounted
/// inline by the (lxxiii) clause 3 `DeviceLinkGateScreen`, which is
/// provider-state, not navigation.
///
/// Renders the out-of-band code BOTH as selectable text with a copy button
/// (the required manual path, spec §12 item (i)) and as a QR. The code is
/// the ONLY channel `ephPubN` travels — it never touches the server
/// (amendment (c)). Every failure path discards the adopted identity and
/// minted keys (I1 abort hygiene, falsification 18). Starts
/// `startNewDeviceFlow` on mount and reports `done` through [onDone] exactly
/// once (post-frame — the notification can land mid-build).
class LinkThisDeviceBody extends StatefulWidget {
  const LinkThisDeviceBody({
    super.key,
    required this.controller,
    this.onDone,
    this.waitingLabel,
    this.scannerBuilder,
  });

  final LinkCeremonyController controller;

  /// Fired once when the ceremony reaches [NewDeviceLinkStep.done].
  final VoidCallback? onDone;

  /// Replaces the default "waiting for the primary" line — the gate says
  /// "Czekam na urządzenie główne…" in its own words.
  final String? waitingLabel;

  /// Scanner injection seam, handed through to [LinkScanScreen]: tests hand
  /// a fake that fires the scanner's callbacks without a camera.
  final Widget Function({
    required void Function(String code) onCode,
    VoidCallback? onUnsupported,
  })?
  scannerBuilder;

  @override
  State<LinkThisDeviceBody> createState() => _LinkThisDeviceBodyState();
}

class _LinkThisDeviceBodyState extends State<LinkThisDeviceBody> {
  bool _doneFired = false;

  /// Local surface state of the `showCode` step ((lxxvii) clause 3): the
  /// typed-field fallback, the unsupported-scanner notice and the last
  /// refusal. Scanning itself is a pushed route.
  bool _manualEntry = false;
  bool _scanUnsupported = false;
  String? _codeError;
  final TextEditingController _manualCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onStep);
    widget.controller.startNewDeviceFlow(platform: linkPlatformLabel());
  }

  void _onStep() {
    if (_doneFired || !mounted) return;
    if (widget.controller.newDeviceStep != NewDeviceLinkStep.done) return;
    _doneFired = true;
    // Delivered from a controller notification, possibly mid-build: never
    // navigate inside a build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onDone?.call();
    });
  }

  Future<void> _submitCode(String raw) async {
    final refusal = await widget.controller.startNewDeviceFromCode(
      extractLinkCode(raw) ?? raw,
      platform: linkPlatformLabel(),
    );
    if (!mounted) return;
    setState(() => _codeError = refusal);
  }

  /// Scanning is its own full-screen surface (`LinkScanScreen`); what comes
  /// back decides the next step here.
  Future<void> _scan() async {
    final result = await Navigator.of(context).push<LinkScanResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        // Named so the gate's route sweep (main.dart, issue #175) keeps the
        // ceremony's own scanner instead of closing it.
        settings: const RouteSettings(name: kLinkScanRouteName),
        builder: (_) => LinkScanScreen(scannerBuilder: widget.scannerBuilder),
      ),
    );
    if (!mounted) return;
    switch (result) {
      case LinkScanCode(:final code):
        _submitCode(code);
      case LinkScanUnsupported():
        setState(() {
          _scanUnsupported = true;
          _manualEntry = true;
        });
      case LinkScanManual():
        setState(() => _manualEntry = true);
      case null:
        break;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onStep);
    _manualCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildStep(context),
      ),
    );
  }

  List<Widget> _buildStep(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;

    switch (controller.newDeviceStep) {
      case NewDeviceLinkStep.idle:
      case NewDeviceLinkStep.opening:
        return const [
          Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ];
      case NewDeviceLinkStep.showCode:
      case NewDeviceLinkStep.showSas:
        final code = controller.oobCode ?? '';
        final sas = controller.newDeviceSas;
        // FLIPPED flow ((lxxvii) clause 3): this device scanned the
        // primary's `p` code — it has no code of its own to display, only
        // the SAS once the hello is acked.
        if (controller.oobCode == null) {
          return sas == null
              ? const [
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ]
              : _sasSection(context, sas);
        }
        return [
          Text(
            l10n.linkNewExplainer,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                // A QR quiet zone must be light for scanability on every
                // theme — functional, not styling (playbook literal-color
                // exception).
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              // The QR is the deep-link form: a phone camera opens the app
              // at `/link#<code>`; the fragment never leaves the browser.
              // The semantics label carries the same payload so a screen
              // reader (and the widget test) sees exactly what the camera
              // will.
              child: Builder(
                builder: (_) {
                  final qrPayload =
                      LinkOobCode.tryParse(
                        code,
                      )?.toDeepLink(linkDeepLinkOrigin()) ??
                      code;
                  return QrImageView(
                    data: qrPayload,
                    semanticsLabel: 'link qr $qrPayload',
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Semantics(
              label: 'link code',
              child: SelectableText(
                code,
                key: const Key('link-oob-code'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            label: l10n.linkNewCopy,
            button: true,
            child: OutlinedButton.icon(
              key: const Key('link-copy-code'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) {
                  showTopSnackBar(context, l10n.linkNewCopied);
                }
              },
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: Text(l10n.linkNewCopy),
            ),
          ),
          const SizedBox(height: 24),
          if (sas == null) ...[
            Text(
              widget.waitingLabel ?? l10n.linkNewWaitingHello,
              key: const Key('link-new-waiting-hello'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              label: l10n.linkScanAction,
              button: true,
              child: OutlinedButton.icon(
                key: const Key('link-scan'),
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(l10n.linkScanAction),
              ),
            ),
            const SizedBox(height: 8),
            if (!_manualEntry)
              TextButton(
                key: const Key('link-enter-manually'),
                onPressed: () => setState(() => _manualEntry = true),
                child: Text(l10n.linkEnterCodeManually),
              ),
            if (_scanUnsupported) ...[
              const SizedBox(height: 8),
              Text(
                l10n.linkScanUnsupported,
                key: const Key('link-scan-unsupported'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            if (_manualEntry) ...[
              const SizedBox(height: 12),
              Semantics(
                label: l10n.linkNewCodeLabel,
                textField: true,
                child: TextField(
                  key: const Key('link-new-code-field'),
                  controller: _manualCode,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    labelText: l10n.linkNewCodeLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: l10n.linkPrimaryContinue,
                button: true,
                child: FilledButton(
                  key: const Key('link-new-code-continue'),
                  onPressed: () => _submitCode(_manualCode.text),
                  child: Text(l10n.linkPrimaryContinue),
                ),
              ),
            ],
            if (_codeError != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.linkInvalidCode,
                key: const Key('link-new-code-error'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.error,
                ),
              ),
            ],
          ] else
            ..._sasSection(context, sas),
        ];
      case NewDeviceLinkStep.awaitingHelloAck:
        return const [
          Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ];
      case NewDeviceLinkStep.completing:
      case NewDeviceLinkStep.rebinding:
        return [
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          Text(
            controller.newDeviceStep == NewDeviceLinkStep.rebinding
                ? l10n.linkNewRebinding
                : l10n.linkNewCompleting,
            key: const Key('link-new-progress'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ];
      case NewDeviceLinkStep.done:
        return [
          Icon(Icons.check_circle_outline, size: 48, color: colors.primary),
          const SizedBox(height: 16),
          Text(
            l10n.linkNewDone,
            key: const Key('link-new-done'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ];
      case NewDeviceLinkStep.aborted:
        final reason = controller.newDeviceError;
        final reasonLabel = switch (reason) {
          'expired' => l10n.linkAbortReasonExpired,
          'cancelled' => l10n.linkAbortReasonCancelled,
          'bad_mac' ||
          'malformed' ||
          'blob_user_mismatch' => l10n.linkAbortReasonBadBlob,
          _ => '${l10n.linkNewAborted} ($reason)',
        };
        return [
          Icon(Icons.error_outline, size: 48, color: colors.error),
          const SizedBox(height: 16),
          Text(
            reasonLabel,
            key: const Key('link-new-error'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: l10n.linkNewRetry,
            button: true,
            child: OutlinedButton(
              key: const Key('link-new-retry'),
              onPressed: () =>
                  controller.startNewDeviceFlow(platform: linkPlatformLabel()),
              child: Text(l10n.linkNewRetry),
            ),
          ),
        ];
    }
  }

  /// The SAS block, shared by the classic (under the code) and flipped
  /// (stand-alone) shapes.
  List<Widget> _sasSection(BuildContext context, String sas) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    return [
      Text(
        l10n.linkSasHeading,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        l10n.linkSasExplainer,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 16),
      Semantics(
        label: 'security code $sas',
        child: Container(
          key: const Key('link-new-sas-code'),
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Text(
            sas,
            textAlign: TextAlign.center,
            style: RpgTheme.bodyFont(
              fontSize: 40,
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ).copyWith(letterSpacing: 6),
          ),
        ),
      ),
    ];
  }
}
