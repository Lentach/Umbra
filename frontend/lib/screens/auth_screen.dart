import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/chat_background_preference.dart';
import '../theme/rpg_theme.dart';
import '../providers/auth_provider.dart';
import '../widgets/auth_form.dart';
import '../widgets/glass/glass_surface.dart';
import '../services/api_service.dart';
import '../widgets/chat_background_pattern.dart';
import '../l10n/app_localizations.dart';
import '../l10n/auth_status_text.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  AuthFormMode _mode = AuthFormMode.login;

  /// The recover door lives under the LOGOWANIE tab: it is a way to sign in.
  bool get _isLogin => _mode != AuthFormMode.register;

  /// Prefills the username field when the screen itself puts one there (the
  /// "sign in instead" jump after a taken name, or the way into / out of the
  /// recover door).
  String? _prefilledUsername;

  /// True only right after a registration that created the account but could
  /// not sign in: the sign-in tab then keeps the password the user chose.
  /// Every other tab change resets it.
  bool _keepPassword = false;

  /// The status line to show, localized here because the provider has no
  /// locale. A code always wins over [AuthProvider.statusMessage]: the latter
  /// is the pre-localized channel used for the device-revoked notice, and the
  /// provider clears one whenever it sets the other.
  String? _statusText(AuthProvider auth, AppLocalizations l10n) {
    final code = auth.statusCode;
    if (code == null) return auth.statusMessage;
    return authStatusText(l10n, code);
  }

  void _switchTab(AuthProvider auth, {required bool login}) {
    setState(() {
      _mode = login ? AuthFormMode.login : AuthFormMode.register;
      _keepPassword = false;
    });
    auth.clearStatus();
  }

  /// The way OUT of a registration that cannot proceed: carry the username to
  /// the sign-in tab instead of leaving the user to invent another name — the
  /// one move that guarantees they never reach an account they already own.
  void _goToLoginWith(AuthProvider auth, String username) {
    setState(() {
      _mode = AuthFormMode.login;
      _prefilledUsername = username;
      _keepPassword = false;
    });
    auth.clearStatus();
  }

  /// The recovery phrase as a credential (spec (lxxxii) clause 2).
  void _goToRecover(AuthProvider auth) {
    setState(() {
      _mode = AuthFormMode.recover;
      _keepPassword = false;
    });
    auth.clearStatus();
  }

  Widget _tab(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final muted = FireplaceColors.of(context).mutedText;
    return Expanded(
      // `selected` is the only thing distinguishing these two tabs, and it was
      // conveyed by colour alone — a screen reader could not tell which of
      // Login / Create account was active. The 48dp floor is the Material
      // minimum touch target; the padding alone left it at ~40dp.
      child: Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: RpgTheme.bodyFont(
                fontSize: 14,
                color: selected ? scheme.primary : muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The auth screen is the app's front door and ALWAYS wears Hot Stone
    // (owner call 2026-07-28, superseding the 2026-07-18 always-Cosmic
    // ruling) — the warm-paper + ember world that is now the app default —
    // regardless of the saved chat theme. Forcing the real `themeDataLight`
    // here means the card (GlassTheme.light), inputs/button (ember primary),
    // and the plain warm-paper backdrop all come from the ONE light theme —
    // no parallel login-only palette.
    return Theme(
      data: RpgTheme.themeDataLight,
      child: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fc = FireplaceColors.of(context);

    return Scaffold(
      body: ChatBackgroundPattern(
        // The front door always shows the plain Hot Stone paper. Chat
        // wallpaper is an authenticated per-user choice and must not leak
        // into this screen.
        layer: ChatBackgroundLayer.plain,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The landing wordmark: Archivo 900, UMBRA in warm
                    // near-black (onSurface). The old FIRE/PLACE two-tone
                    // split does not map to a single word.
                    Text(
                      'UMBRA',
                      style: GoogleFonts.archivo(
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.8,
                        height: 1,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.authTagline,
                      textAlign: TextAlign.center,
                      style: RpgTheme.bodyFont(
                        fontSize: 14,
                        color: fc.mutedText,
                      ),
                    ),
                    const SizedBox(height: 32),
                    GlassSurface(
                      borderRadius: BorderRadius.circular(20),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: fc.inputBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: fc.tabBorder,
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                _tab(context, l10n.authLoginTab, _isLogin, () {
                                  _switchTab(authProvider, login: true);
                                }),
                                _tab(
                                  context,
                                  l10n.authRegisterTab,
                                  !_isLogin,
                                  () {
                                    _switchTab(authProvider, login: false);
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          AuthForm(
                            mode: _mode,
                            initialUsername: _prefilledUsername,
                            keepPassword: _keepPassword,
                            // A status describes ONE attempt. Leaving it under
                            // an edited form is how a stale "already taken"
                            // ended up under a name the user had just changed.
                            onEdited: authProvider.statusCode == null
                                ? null
                                : authProvider.clearStatus,
                            onRecover: authProvider.recoverPassword,
                            onSubmit: (username, password) async {
                              switch (_mode) {
                                case AuthFormMode.login:
                                  await authProvider.login(username, password);
                                case AuthFormMode.recover:
                                  // The form routes this door to onRecover.
                                  break;
                                case AuthFormMode.register:
                                  final created = await authProvider.register(
                                    username,
                                    password,
                                  );
                                  // Registration signs the user in itself; the
                                  // shell takes over and this screen is gone.
                                  // It lands here only when that sign-in
                                  // failed: the account exists, so the login
                                  // tab gets the username AND the password the
                                  // user just chose (every other tab change
                                  // clears the password field).
                                  if (created &&
                                      mounted &&
                                      !authProvider.isLoggedIn) {
                                    setState(() {
                                      _mode = AuthFormMode.login;
                                      _prefilledUsername = username;
                                      _keepPassword = true;
                                    });
                                  }
                              }
                            },
                          ),
                          if (_mode == AuthFormMode.login) ...[
                            const SizedBox(height: 4),
                            TextButton(
                              key: const Key('auth-forgot-password'),
                              onPressed: () => _goToRecover(authProvider),
                              child: Text(l10n.authForgotPassword),
                            ),
                          ] else if (_mode == AuthFormMode.recover) ...[
                            const SizedBox(height: 4),
                            TextButton(
                              key: const Key('auth-recover-back'),
                              onPressed: () => _switchTab(
                                authProvider,
                                login: true,
                              ),
                              child: Text(l10n.authGoToLogin),
                            ),
                          ],
                          // The provider holds no locale, so it reports a CODE
                          // and this layer picks the words. `statusMessage` is
                          // the pre-localized channel (the device-revoked
                          // notice), so a code always wins when both are set.
                          if (_statusText(authProvider, l10n)
                              case final text?) ...[
                            const SizedBox(height: 16),
                            Text(
                              text,
                              textAlign: TextAlign.center,
                              style: RpgTheme.bodyFont(
                                fontSize: 13,
                                color: authProvider.isError
                                    ? scheme.error
                                    // Dark-only neon green is illegible on
                                    // paper; this door is always light.
                                    : RpgTheme.successColorLight,
                              ),
                            ),
                          ],
                          // Only on the register tab: after a created account
                          // whose auto sign-in failed the screen already put
                          // the user on LOGOWANIE with the name filled in, and
                          // "sign in instead" there points at the tab they are
                          // standing on.
                          if (authProvider.recoverableUsername
                                  case final username?
                              when _mode == AuthFormMode.register) ...[
                            const SizedBox(height: 4),
                            TextButton(
                              key: const Key('auth-go-to-login'),
                              onPressed: () =>
                                  _goToLoginWith(authProvider, username),
                              child: Text(l10n.authGoToLogin),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Diagnostic footer: running-bundle commit (stale-build
                    // discriminator in every victim screenshot) plus the
                    // recorded involuntary session-end reason when one exists.
                    // Deliberately NOT the async PackageInfo semver: on web
                    // that fetches the SERVER's version.json and can lie about
                    // the running bundle; the compiled commit cannot.
                    Text(
                      authProvider.lastSessionEndReason == null
                          ? ApiService.appCommit
                          : '${ApiService.appCommit} · ${l10n.sessionEndedReason(authProvider.lastSessionEndReason!)}',
                      textAlign: TextAlign.center,
                      style: RpgTheme.bodyFont(
                        fontSize: 11,
                        color: fc.mutedText.withValues(alpha: 0.7),
                      ),
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
}
