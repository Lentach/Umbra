import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/chat_background_preference.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/screens/auth_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/auth_form.dart';
import 'package:fireplace/widgets/chat_background_pattern.dart';

// Owner ruling 2026-07-28 (supersedes the 2026-07-18 always-Cosmic door):
// the front door ALWAYS wears Hot Stone — light theme, plain warm-paper
// backdrop — regardless of the ambient app theme.
void main() {
  testWidgets('auth screen always wears the Hot Stone light theme', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        // Ambient app theme is DARK on purpose: the door must override it.
        theme: RpgTheme.themeDataDarkGray,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: ChangeNotifierProvider(
          create: (_) => AuthProvider(),
          child: const AuthScreen(),
        ),
      ),
    );
    await tester.pump();

    // The theme INSIDE the door is the light one, not the ambient dark.
    final formContext = tester.element(find.byType(AuthForm));
    final theme = Theme.of(formContext);
    expect(theme.brightness, Brightness.light);
    expect(
      theme.scaffoldBackgroundColor,
      RpgTheme.themeDataLight.scaffoldBackgroundColor,
    );

    // Backdrop is the plain warm paper — no starfield, no wallpaper leak.
    final pattern = tester.widget<ChatBackgroundPattern>(
      find.byType(ChatBackgroundPattern),
    );
    expect(pattern.layer, ChatBackgroundLayer.plain);
  });

  // The two tabs were distinguished by COLOUR alone and sat under the 48dp
  // Material touch minimum.
  testWidgets('the auth tabs announce which one is selected, and are 48dp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: ChangeNotifierProvider(
          create: (_) => AuthProvider(),
          child: const AuthScreen(),
        ),
      ),
    );
    await tester.pump();

    final selected = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((s) => s.properties.selected != null)
        .toList();
    expect(
      selected.length,
      2,
      reason: 'both tabs carry a selected state, not just a colour',
    );
    expect(
      selected.where((s) => s.properties.selected == true).length,
      1,
      reason: 'exactly one tab is announced as active',
    );

    for (final label in ['LOGIN', 'REGISTER']) {
      final size = tester.getSize(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(Container),
        ).first,
      );
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason: '$label tab must meet the 48dp minimum touch target',
      );
    }
  });
  // The login screen is the app's front door and its ONLY feedback channel.
  // Every status it showed used to be a hardcoded English literal built in
  // AuthProvider — including a developer message naming docker-compose and a
  // raw exception passthrough — so on the Polish locale the whole channel was
  // English and a failure could surface an unmapped backend string.
  group('auth status is localized, never raw', () {
    Future<void> pumpWith(
      WidgetTester tester,
      AuthStatusCode code,
      Locale locale,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final auth = _StatusAuthProvider(code);
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: ChangeNotifierProvider<AuthProvider>.value(
            value: auth,
            child: const AuthScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('an unreachable server reads as Polish, not English', (
      tester,
    ) async {
      await pumpWith(
        tester,
        AuthStatusCode.serverUnreachable,
        const Locale('pl'),
      );
      final pl = await AppLocalizations.delegate.load(const Locale('pl'));
      final en = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(pl.authStatusServerUnreachable), findsOneWidget);
      expect(find.text(en.authStatusServerUnreachable), findsNothing);
    });

    testWidgets('no status names a developer tool or an exception', (
      tester,
    ) async {
      for (final code in AuthStatusCode.values) {
        await pumpWith(tester, code, const Locale('en'));
        for (final leak in const [
          'docker',
          'Exception',
          'SocketException',
          'Hero created',
        ]) {
          expect(
            find.textContaining(leak, findRichText: true),
            findsNothing,
            reason: '$code must not surface "$leak" to a user',
          );
        }
      }
    });

    testWidgets('every code maps to a real string', (tester) async {
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final expected = {
        AuthStatusCode.savedSessionUnreadable:
            en.authStatusSavedSessionUnreadable,
        AuthStatusCode.registerSucceeded: en.authStatusRegisterSucceeded,
        AuthStatusCode.nicknameTaken: en.authStatusNicknameTaken,
        AuthStatusCode.usernameInvalid: en.authStatusUsernameInvalid,
        AuthStatusCode.passwordTooWeak: en.authStatusPasswordTooWeak,
        AuthStatusCode.invalidCredentials: en.authStatusInvalidCredentials,
        AuthStatusCode.wrongPassword: en.authStatusWrongPassword,
        AuthStatusCode.tooManyAttempts: en.authStatusTooManyAttempts,
        AuthStatusCode.serverError: en.authStatusServerError,
        AuthStatusCode.phraseRejected: en.authStatusPhraseRejected,
        AuthStatusCode.serverUnreachable: en.authStatusServerUnreachable,
        AuthStatusCode.unexpectedError: en.authStatusUnexpectedError,
        AuthStatusCode.deviceRevoked: en.deviceRevokedNotice,
      };
      // A new code added without a mapping would render nothing at all, so the
      // enum and the switch are pinned to each other here.
      expect(expected.keys, containsAll(AuthStatusCode.values));
      for (final entry in expected.entries) {
        await pumpWith(tester, entry.key, const Locale('en'));
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      }
    });
  });
}

/// Reports a fixed status code without touching storage or the network.
class _StatusAuthProvider extends AuthProvider {
  _StatusAuthProvider(this._code);

  final AuthStatusCode _code;

  @override
  AuthStatusCode? get statusCode => _code;

  @override
  String? get statusMessage => null;

  @override
  bool get isError => _code != AuthStatusCode.registerSucceeded;

  @override
  bool get isRestoringSession => false;
}
