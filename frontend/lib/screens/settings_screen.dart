import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/chat_background_preference.dart';
import '../theme/rpg_theme.dart';
import '../widgets/appearance_preview.dart';
import '../providers/auth_provider.dart';
import '../l10n/auth_status_text.dart';
import '../providers/connection_provider.dart';
import '../providers/encryption_provider.dart';
import '../providers/passcode_provider.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/push_service.dart';
import '../config/app_config.dart';
import '../config/app_version_info.dart';
import '../models/user_model.dart';
import '../widgets/local_node_core.dart';
import '../widgets/settings_console.dart';
import '../widgets/dialogs/reset_password_dialog.dart';
import '../widgets/main_tab_screen_header.dart';
import '../widgets/dialogs/delete_account_dialog.dart';
import '../widgets/top_snackbar.dart';
import '../l10n/app_localizations.dart';
import 'appearance_screen.dart';
import 'blocked_users_screen.dart';
import 'devices_screen.dart';
import 'privacy_safety_screen.dart';
import 'recovery_key_screen.dart';
import 'passcode_lock_screen.dart';
import '../utils/instant_opaque_route.dart';
import 'user_card_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _deviceName;
  static final Uri _aboutFireplaceUri = Uri.parse(
    'https://fireplace.ignorelist.com/welcome/',
  );
  String? _appVersionLine;
  late final PushService _pushService = PushService(
    ApiService(baseUrl: AppConfig.baseUrl),
  );

  @override
  void initState() {
    super.initState();
    _loadDeviceName();
    _loadAppVersion();
    final userId = context.read<AuthProvider>().currentUser?.id;
    if (userId != null) {
      context.read<SettingsProvider>().loadChatBackground(userId);
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await AppVersionInfo.load();
      if (mounted) {
        setState(() => _appVersionLine = info.displayLine);
      }
    } catch (e) {
      debugPrint('Error loading app version: $e');
    }
  }


  Future<void> _loadDeviceName() async {
    String name = 'Unknown Device';

    try {
      if (kIsWeb) {
        name = 'Web Browser';
      } else {
        // Native platforms: generic name. Naming the real model would mean
        // taking a device-info plugin back on as a dependency (device_info_plus
        // was removed 2026-08-02 as unused) AND handling hardware identifiers.
        name = 'Native Device';
      }
    } catch (e) {
      debugPrint('Error loading device name: $e');
    }

    if (mounted) {
      setState(() => _deviceName = name);
    }
  }

  void _openMyProfile() {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;
    Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (_) => UserCardScreen(
          data: UserCardVisualData.fromUser(
            user,
            isSelf: true,
            hasConversation: false,
          ),
        ),
      ),
    );
  }

  void _openAboutFireplace() {
    launchUrl(
      _aboutFireplaceUri,
      mode: LaunchMode.externalApplication,
    ).ignore();
  }

  Future<void> _showResetPasswordDialog() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const ResetPasswordDialog(),
    );

    if (result == null || !mounted) return;

    try {
      final auth = context.read<AuthProvider>();
      await auth.resetPassword(result['oldPassword']!, result['newPassword']!);

      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context).passwordUpdatedSuccessfully,
          backgroundColor: Theme.of(context).colorScheme.primary,
        );
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          _credentialFailureText(e),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    }
  }

  /// Why a password change or an account deletion was refused, in the user's
  /// language. Appending `e.toString()` (what this did until 2026-09-06) put
  /// untranslated backend English — or a bare status code — behind a generic
  /// prefix, so "wrong current password" and "the server is down" read alike.
  String _credentialFailureText(Object error) {
    final l10n = AppLocalizations.of(context);
    return authStatusText(
      l10n,
      classifyAuthFailure(error, attempt: AuthAttempt.credentialChange),
    );
  }

  Future<void> _showDeleteAccountDialog() async {
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const DeleteAccountDialog(),
    );

    if (password == null || !mounted) return;

    try {
      final auth = context.read<AuthProvider>();
      final enc = context.read<EncryptionProvider>();
      final conn = context.read<ConnectionProvider>();

      await auth.deleteAccount(password);
      await enc.clearEncryptionKeys();
      conn.disconnect(isLogout: true);

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          _credentialFailureText(e),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    }
  }

  Future<void> _enableWebPushNotifications() async {
    final token = context.read<AuthProvider>().token;
    if (token == null) return;

    final result = await _pushService.requestWebPushFromUserGesture(token);
    if (!mounted) return;

    final l10n = AppLocalizations.of(context);
    switch (result.status) {
      case WebPushRequestStatus.subscribed:
        showTopSnackBar(
          context,
          l10n.webPushEnabled,
          backgroundColor: Theme.of(context).colorScheme.primary,
        );
        break;
      case WebPushRequestStatus.denied:
        showTopSnackBar(
          context,
          l10n.webPushPermissionDenied,
          backgroundColor: Theme.of(context).colorScheme.error,
        );
        break;
      case WebPushRequestStatus.requiresStandalone:
        showTopSnackBar(
          context,
          l10n.webPushInstallRequired,
          backgroundColor: Theme.of(context).colorScheme.error,
        );
        break;
      case WebPushRequestStatus.unsupported:
        showTopSnackBar(
          context,
          l10n.webPushNotSupported,
          backgroundColor: Theme.of(context).colorScheme.error,
        );
        break;
      case WebPushRequestStatus.noChange:
        showTopSnackBar(
          context,
          l10n.webPushNoChanges,
          backgroundColor: Theme.of(context).colorScheme.primary,
        );
        break;
      case WebPushRequestStatus.failed:
        showTopSnackBar(
          context,
          '${l10n.webPushEnableFailed}: ${result.details ?? ''}',
          backgroundColor: Theme.of(context).colorScheme.error,
        );
        break;
    }
  }

  /// The Appearance row's "glyph" is the live theme itself — the real
  /// [AppearancePreview] miniature, hex-clipped so it reads as a terminal
  /// like every other row.
  ///
  /// **No chat background** (owner, 2026-07-25: *"background in appearance
  /// hex is not really needed"*). The row's subtitle already names it, and
  /// dropping it also removes the `glyphs` layer's rendering trick from this
  /// call site: that layer lays its scene out at 2× and `FittedBox`es it back
  /// down, which halves every ABSOLUTE offset in the scene and left the
  /// bubbles half-height and high in the terminal. Plain keeps one geometry.
  ///
  /// The remaining two axes need opposite treatment, because
  /// `_AppearancePreviewScene` positions everything at ABSOLUTE insets and
  /// only scales bubble WIDTH:
  ///
  /// * Width is the terminal's own. It used to be 92 and centre-cropped to
  ///   hide the miniature's radius-12 border, but the hex only shows the
  ///   middle 38px of those 92 — exactly cropping away the `left: 8` and
  ///   `right: 8` strips that carry both bubble colours. `showBorder: false`
  ///   removes the reason for the crop; the hex already paints a ring.
  /// * Height stays natural and overflows. Shrinking it to the terminal's 44
  ///   moved the composer bar (`bottom: 6`, height 7) up to y 31–38, straight
  ///   through the "mine" bubble at y 25–36 — and the bar paints after it, so
  ///   it covered it (*"green/blue bubble is covered by bottom block"*).
  ///   Anything below [kPreviewMinHeight] collides.
  Widget _appearancePreviewInHex(SettingsProvider settings) {
    // Headroom over the collision floor so the bar also clears the clip.
    const previewHeight = kPreviewMinHeight + 9;

    return OverflowBox(
      maxWidth: kConsoleHexWidth,
      maxHeight: previewHeight,
      alignment: Alignment(
        0,
        appearancePreviewAlignY(
          previewHeight: previewHeight,
          terminalHeight: kConsoleHexHeight,
        ),
      ),
      child: AppearancePreview(
        themeData: settings.themeData,
        background: ChatBackgroundLayer.plain,
        width: kConsoleHexWidth,
        height: previewHeight,
        showBorder: false,
      ),
    );
  }

  Widget _buildAppearanceRow(BuildContext context, SettingsProvider settings) {
    final l10n = AppLocalizations.of(context);
    final themeName = switch (settings.themePreference) {
      'light' => l10n.appearanceThemeLight,
      'teal' => l10n.appearanceThemeTeal,
      'dark' => l10n.appearanceThemeDark,
      'cosmic' => l10n.appearanceThemeCosmic,
      _ => l10n.appearanceThemeBlue,
    };
    final backgroundName = switch (settings.chatBackground) {
      ChatBackgroundPreference.themeDefault =>
        settings.themePreference == 'cosmic'
            ? l10n.appearanceBackgroundStarfield
            : l10n.appearanceBackgroundPlain,
      ChatBackgroundPreference.plain => l10n.appearanceBackgroundPlain,
      ChatBackgroundPreference.glyphs => l10n.appearanceBackgroundGlyphs,
    };

    return SettingsConsoleRow(
      glyph: ConsoleGlyph.appearance,
      leadingOverride: _appearancePreviewInHex(settings),
      title: l10n.appearance,
      subtitle: l10n.appearanceSummary(themeName, backgroundName),
      onTap: () {
        final userId = context.read<AuthProvider>().currentUser?.id;
        if (userId == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AppearanceScreen(userId: userId)),
        );
      },
    );
  }

  Widget _buildLanguageRow(BuildContext context, SettingsProvider settings) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final current = settings.localeCode;

    // The chip shows the CODE, not the language name. At 320px with a 1.6
    // text scale "Polski"+"Angielski" is ~210px of non-flexible trailing,
    // which collapses the title to a one-letter-per-line column. The full
    // name stays on the semantics node so screen readers still announce it.
    Widget chip(String code, String label) {
      final selected = current == code;
      return Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            onTap: () => settings.setLocalePreference(code),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primary.withValues(alpha: 0.16)
                    : null,
                border: Border.all(
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.28),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                code.toUpperCase(),
                style: RpgTheme.bodyFont(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ).copyWith(letterSpacing: 1.2),
              ),
            ),
          ),
        ),
      );
    }

    // No row-level onTap: the chips are the affordance, so the row itself
    // must not be a button that does nothing.
    return SettingsConsoleRow(
      glyph: ConsoleGlyph.language,
      title: l10n.language,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip('pl', l10n.languagePolish),
          chip('en', l10n.languageEnglish),
        ],
      ),
    );
  }

  /// The local node: the same round reticle the Contacts core uses. Tapping
  /// it opens your own user card, which is what the old floating badge did.
  Widget _buildLocalNode(BuildContext context, UserModel? user) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final name = user?.username ?? 'Hero';

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Column(
        children: [
          Semantics(
            button: true,
            label: l10n.contactNetworkYouLocalNode,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: _openMyProfile,
              child: LocalNodeCore(
                radius: 46,
                displayName: name,
                avatarUrl: user?.profilePictureUrl,
                initialsFontSize: 24,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$name#${user?.tag ?? '0000'}',
            style: RpgTheme.bodyFont(
              fontSize: 18,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.contactNetworkLocalNode,
            style: RpgTheme.bodyFont(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface.withValues(alpha: 0.5),
            ).copyWith(letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutFireplaceLink() {
    final colorScheme = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context).settingsAboutFireplace;

    return Semantics(
      button: true,
      link: true,
      label: label,
      child: Align(
        child: InkWell(
          key: const Key('settings-about-fireplace-link'),
          borderRadius: BorderRadius.circular(8),
          onTap: _openAboutFireplace,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'UMBRA',
                      style: RpgTheme.bodyFont(
                        fontSize: 10,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ).copyWith(letterSpacing: 1.6),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 1,
                      height: 12,
                      color: colorScheme.outlineVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      label,
                      style: RpgTheme.bodyFont(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.north_east_rounded,
                      size: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final conn = context.read<ConnectionProvider>();
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MainTabScreenHeader(title: l10n.settings),
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: ListView(
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 16,
                ),
                children: [
                  _buildLocalNode(context, auth.currentUser),

                  SettingsSectionCaption(
                    label: l10n.settingsSectionPreferences,
                  ),
                  _buildAppearanceRow(context, settings),
                  _buildLanguageRow(context, settings),
                  SettingsConsoleRow(
                    key: const ValueKey('settings-autoplay-videos-row'),
                    glyph: ConsoleGlyph.media,
                    title: l10n.settingsAutoplayVideos,
                    subtitle: l10n.settingsAutoplayVideosSubtitle,
                    trailing: Switch(
                      value: settings.autoplayVideos,
                      onChanged: (v) => settings.setAutoplayVideos(v),
                    ),
                    onTap: () =>
                        settings.setAutoplayVideos(!settings.autoplayVideos),
                  ),

                  SettingsSectionCaption(label: l10n.settingsSectionSecurity),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.privacy,
                    title: l10n.privacyAndSafety,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PrivacySafetyScreen(),
                        ),
                      );
                    },
                  ),
                  // (lxxix): key-change warnings are demoted by default; this
                  // switch restores the manual-confirmation red pill.
                  SettingsConsoleRow(
                    key: const ValueKey('settings-key-change-warnings-row'),
                    glyph: ConsoleGlyph.keys,
                    title: l10n.settingsKeyChangeWarnings,
                    subtitle: l10n.settingsKeyChangeWarningsSubtitle,
                    trailing: Switch(
                      value: settings.keyChangeWarnings,
                      onChanged: (v) => settings.setKeyChangeWarnings(v),
                    ),
                    onTap: () => settings.setKeyChangeWarnings(
                      !settings.keyChangeWarnings,
                    ),
                  ),
                  Consumer<PasscodeProvider>(
                    builder: (context, passcode, _) => SettingsConsoleRow(
                      key: const Key('settings-passcode-row'),
                      glyph: ConsoleGlyph.password,
                      title: l10n.passcodeLock,
                      subtitle: passcode.isEnabled
                          ? l10n.passcodeStateOn
                          : l10n.passcodeStateOff,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PasscodeLockScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.keys,
                    title: l10n.recoveryKeyTitle,
                    subtitle: l10n.recoveryKeySubtitle,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RecoveryKeyScreen(),
                        ),
                      );
                    },
                  ),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.blocked,
                    title: l10n.blocked,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const BlockedUsersScreen(),
                        ),
                      );
                    },
                  ),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.devices,
                    title: l10n.devices,
                    subtitle: _deviceName ?? l10n.devicesLoading,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DevicesScreen(),
                        ),
                      );
                    },
                  ),
                  if (kIsWeb)
                    SettingsConsoleRow(
                      glyph: ConsoleGlyph.push,
                      title: l10n.webPushEnableTitle,
                      subtitle: l10n.webPushEnableSubtitle,
                      onTap: _enableWebPushNotifications,
                    ),

                  SettingsSectionCaption(label: l10n.settingsSectionSession),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.password,
                    title: l10n.resetPassword,
                    onTap: _showResetPasswordDialog,
                  ),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.deleteNode,
                    title: l10n.deleteAccount,
                    edge: ConsoleRowEdge.danger,
                    onTap: _showDeleteAccountDialog,
                  ),
                  SettingsConsoleRow(
                    glyph: ConsoleGlyph.logout,
                    title: l10n.logout,
                    edge: ConsoleRowEdge.accent,
                    onTap: () {
                      conn.disconnect(isLogout: true);
                      auth.logout();
                      if (Navigator.of(context).canPop()) {
                        Navigator.pop(context);
                      }
                    },
                  ),

                  const SizedBox(height: 28),
                  _buildAboutFireplaceLink(),

                  if (_appVersionLine != null) ...[
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          Text(
                            l10n.settingsAppVersion,
                            textAlign: TextAlign.center,
                            style: RpgTheme.bodyFont(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _appVersionLine!,
                            textAlign: TextAlign.center,
                            style: RpgTheme.bodyFont(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // The uninstall/clear-data key-loss warning used to sit here,
                  // under the version line. Moved to Privacy & Safety
                  // 2026-09-14 (owner's call): it is a security fact, and a
                  // build string is the wrong neighbour for it.
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
