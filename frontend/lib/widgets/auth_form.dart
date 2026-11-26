import 'package:flutter/material.dart';
import '../theme/rpg_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/recovery_phrase.dart';

/// Which door the form is. `recover` is the recovery phrase as a credential
/// (multi-device spec §12 amendment (lxxxii) clause 2): identifier, the 12
/// words, and a NEW password under the register rules.
enum AuthFormMode { login, register, recover }

class AuthForm extends StatefulWidget {
  final AuthFormMode mode;

  /// [AuthFormMode.login] and [AuthFormMode.register]: the typed credentials.
  final Future<void> Function(String username, String password) onSubmit;

  /// [AuthFormMode.recover]: identifier, the normalized 12 words, and the NEW
  /// password. The other two modes never call it.
  final Future<void> Function(
    String username,
    String phrase,
    String newPassword,
  )
  onRecover;

  /// Username to start with. Set when the screen sends the user from the
  /// register tab to the sign-in tab, so they never retype a name the app
  /// already knows.
  final String? initialUsername;

  /// Called on the first keystroke after a status is showing, so a message
  /// about the PREVIOUS attempt cannot sit under an edited form.
  final VoidCallback? onEdited;

  const AuthForm({
    super.key,
    required this.mode,
    required this.onSubmit,
    required this.onRecover,
    this.initialUsername,
    this.onEdited,
  });

  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _usernameController =
      TextEditingController(text: widget.initialUsername ?? '');
  final _passwordController = TextEditingController();
  final _phraseController = TextEditingController();
  bool _loading = false;

  bool get _isLogin => widget.mode == AuthFormMode.login;
  bool get _isRecover => widget.mode == AuthFormMode.recover;

  @override
  void didUpdateWidget(AuthForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // One password field serves every door; a value typed for one (a failed
    // sign-in guess) must not become the NEW password of another.
    if (widget.mode != oldWidget.mode) _passwordController.clear();
    final prefill = widget.initialUsername;
    if (prefill != null && prefill != oldWidget.initialUsername) {
      _usernameController.text = prefill;
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _phraseController.dispose();
    super.dispose();
  }

  /// The server's rule (`RegisterDto`), enforced here so the user reads it
  /// under the field instead of receiving a 400 the surface cannot explain.
  static final RegExp _usernameCharset = RegExp(r'^[a-zA-Z0-9_]+$');

  String? _validateUsername(String? value, AppLocalizations l10n) {
    final username = value?.trim() ?? '';
    if (username.isEmpty) return l10n.authUsernameRequired;
    if (widget.mode != AuthFormMode.register) return null;
    if (username.length < 3 ||
        username.length > 20 ||
        !_usernameCharset.hasMatch(username)) {
      return l10n.authUsernameRules;
    }
    return null;
  }

  String? _validatePassword(String? value, AppLocalizations l10n) {
    if (value == null || value.isEmpty) return l10n.passwordRequired;
    if (value.length < 8) return l10n.passwordMinLength;
    if (!RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$').hasMatch(value)) {
      return l10n.passwordMustContain;
    }
    return null;
  }

  /// The same typo guard the gate's restore door applies before spending one
  /// of the few server-side attempts the lockout allows.
  String? _validatePhrase(String? value, AppLocalizations l10n) =>
      RecoveryPhrase.isValid(value ?? '') ? null : l10n.recoveryPhraseMalformed;

  Future<void> _handleSubmit() async {
    // Enter on a field reaches this directly; the button's own disabling only
    // covers taps. A second submit while one is in flight is two sessions.
    if (_loading) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    try {
      if (_isRecover) {
        await widget.onRecover(
          username,
          RecoveryPhrase.normalize(_phraseController.text),
          password,
        );
      } else {
        await widget.onSubmit(username, password);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The rule stated BEFORE the user hits it. The registration rules live on
  /// the server (`RegisterDto`); a door that keeps them secret can only answer
  /// a violation with a refusal, which is what made "something went wrong" the
  /// whole conversation.
  Widget _rules(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
    child: Text(
      text,
      style: RpgTheme.bodyFont(
        fontSize: 11,
        color: FireplaceColors.of(context).mutedText,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final fieldStyle = RpgTheme.bodyFont(
      fontSize: 14,
      color: colorScheme.onSurface,
    );
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _usernameController,
            style: fieldStyle,
            decoration: RpgTheme.rpgInputDecoration(
              hintText: l10n.authUsernameHint,
              prefixIcon: Icons.person_outlined,
              context: context,
            ),
            onFieldSubmitted: (_) => _handleSubmit(),
            onChanged: (_) => widget.onEdited?.call(),
            validator: (value) => _validateUsername(value, l10n),
          ),
          if (widget.mode == AuthFormMode.register)
            _rules(context, l10n.authUsernameRules),
          const SizedBox(height: 16),
          if (_isRecover) ...[
            TextFormField(
              key: const Key('auth-recover-phrase'),
              controller: _phraseController,
              style: fieldStyle,
              decoration: RpgTheme.rpgInputDecoration(
                hintText: l10n.recoveryPhrasePromptHint,
                prefixIcon: Icons.key_outlined,
                context: context,
              ),
              minLines: 2,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => widget.onEdited?.call(),
              validator: (value) => _validatePhrase(value, l10n),
            ),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: _passwordController,
            style: fieldStyle,
            decoration: RpgTheme.rpgInputDecoration(
              hintText: switch (widget.mode) {
                AuthFormMode.login => l10n.authPasswordHint,
                AuthFormMode.register => l10n.authPasswordHintRegister,
                AuthFormMode.recover => l10n.authNewPasswordHint,
              },
              prefixIcon: Icons.lock_outlined,
              context: context,
            ),
            obscureText: true,
            onFieldSubmitted: (_) => _handleSubmit(),
            onChanged: (_) => widget.onEdited?.call(),
            // Enforce strength wherever a password is being SET; login just
            // needs non-empty.
            validator: _isLogin
                ? (value) => (value == null || value.isEmpty)
                      ? l10n.passwordRequired
                      : null
                : (value) => _validatePassword(value, l10n),
          ),
          if (!_isLogin) _rules(context, l10n.authPasswordRules),
          const SizedBox(height: 24),
          ElevatedButton(
            key: const Key('auth-submit'),
            onPressed: _loading ? null : _handleSubmit,
            child: _loading
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      // The BUTTON's own foreground, read from the same theme
                      // that painted its fill. `colorScheme.primary` here was
                      // primary-on-primary: an invisible spinner on the themes
                      // whose buttonBg IS primary.
                      color:
                          Theme.of(context)
                              .elevatedButtonTheme
                              .style
                              ?.foregroundColor
                              ?.resolve(const {}) ??
                          colorScheme.onPrimary,
                    ),
                  )
                : Text(switch (widget.mode) {
                    AuthFormMode.login => l10n.authLoginButton,
                    AuthFormMode.register => l10n.authCreateAccountButton,
                    AuthFormMode.recover => l10n.authRecoverSubmit,
                  }),
          ),
        ],
      ),
    );
  }
}
