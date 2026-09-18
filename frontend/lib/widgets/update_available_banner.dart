import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/apk_update_service.dart';
import 'identity_alert_banner.dart';

/// Tells a SIDELOADED Android install that a newer APK exists.
///
/// This sits in the app shell rather than only in Settings because the people
/// it exists for never open Settings: a friend who installed from a link runs
/// whatever they last tapped until somebody messages them. Settings keeps the
/// same offer as the deliberate "check now" path.
///
/// It wears [IdentityAlertBanner]'s NEUTRAL tone, not the security palette.
/// The identity banners mean "your keys are at stake"; an update notice does
/// not, and dressing it the same way would spend their urgency on routine
/// news. It is also collapsed by default like every banner in that shell, so
/// the detail — including the warning not to uninstall — is one tap away
/// rather than four lines of permanent chrome.
///
/// Silence is the default: [ApkUpdateService.check] answers null off Android,
/// with no published channel, on any network failure, and for a build the user
/// already dismissed. Dismissing is per-build, so a LATER release asks again.
class UpdateAvailableBanner extends StatefulWidget {
  const UpdateAvailableBanner({super.key, this.service});

  /// Test seam. Production leaves this null and the state builds the real
  /// service, which answers null on every platform except Android.
  final ApkUpdateService? service;

  @override
  State<UpdateAvailableBanner> createState() => _UpdateAvailableBannerState();
}

class _UpdateAvailableBannerState extends State<UpdateAvailableBanner> {
  late final ApkUpdateService _service = widget.service ?? ApkUpdateService();
  ApkRelease? _release;

  @override
  void initState() {
    super.initState();
    _check().ignore();
  }

  Future<void> _check() async {
    final release = await _service.check();
    if (release != null && mounted) {
      setState(() => _release = release);
    }
  }

  void _download(ApkRelease release) {
    launchUrl(
      Uri.parse(release.url),
      mode: LaunchMode.externalApplication,
    ).ignore();
  }

  Future<void> _dismiss(ApkRelease release) async {
    await _service.dismiss(release.versionCode);
    if (mounted) {
      setState(() => _release = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    if (release == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return IdentityAlertBanner(
      key: const Key('update-available-banner'),
      icon: Icons.system_update_outlined,
      background: colors.surfaceContainerHighest,
      foreground: colors.onSurface,
      title: l10n.updateAvailableTitle,
      summary: release.versionName,
      detail: l10n.updateAvailableBody(release.versionName),
      action: TextButton(
        key: const Key('update-available-download'),
        onPressed: () => _download(release),
        child: Text(l10n.updateAvailableDownload),
      ),
      secondaryAction: TextButton(
        key: const Key('update-available-later'),
        onPressed: () => _dismiss(release).ignore(),
        child: Text(l10n.updateAvailableLater),
      ),
    );
  }
}
