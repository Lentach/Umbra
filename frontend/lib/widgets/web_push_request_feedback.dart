import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/push_service.dart';
import 'top_snackbar.dart';

/// The snackbar for the outcome of a tapped web-push request: shared by the
/// Settings row and the chat list's "notifications are off" line (E90a).
void showWebPushRequestFeedback(
  BuildContext context,
  WebPushRequestResult result,
) {
  final l10n = AppLocalizations.of(context);
  final colors = Theme.of(context).colorScheme;
  final (text, color) = switch (result.status) {
    WebPushRequestStatus.subscribed => (l10n.webPushEnabled, colors.primary),
    WebPushRequestStatus.denied => (l10n.webPushPermissionDenied, colors.error),
    WebPushRequestStatus.requiresStandalone => (
      l10n.webPushInstallRequired,
      colors.error,
    ),
    WebPushRequestStatus.unsupported => (
      l10n.webPushNotSupported,
      colors.error,
    ),
    WebPushRequestStatus.noChange => (l10n.webPushNoChanges, colors.primary),
    WebPushRequestStatus.failed => (
      '${l10n.webPushEnableFailed}: ${result.details ?? ''}',
      colors.error,
    ),
  };
  showTopSnackBar(context, text, backgroundColor: color);
}
