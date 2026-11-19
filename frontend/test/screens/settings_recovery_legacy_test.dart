import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/recovery_key_screen.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Plan B7: a recovery key set by an older build crossed the wire in
/// plaintext, so Settings asks ONCE (dismissibly) for it to be replaced, and
/// the ask opens the ordinary enrolment screen.
class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser =>
      UserModel(id: 7, username: 'Marta', tag: '0007');

  @override
  String? get token => 'test-token';
}

const _legacyRow = Key('settings-recovery-legacy-row');
const _dismiss = Key('settings-recovery-legacy-dismiss');

Future<(EncryptionProvider, SettingsProvider)> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'contact_backup_laters_7': 99,
    ...prefs,
  });
  // Tall enough that the lazy list builds every row.
  tester.view.physicalSize = const Size(800, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final encryption = EncryptionProvider();
  final settings = SettingsProvider();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _FakeAuthProvider()),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider(
          create: (_) => PasscodeProvider(
            store: MemoryPasscodeStore(),
            kdf: FakePasscodeKdf(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsScreen(),
      ),
    ),
  );
  await settings.loadRecoveryLegacyPrompt(7);
  await tester.pumpAndSettle();
  return (encryption, settings);
}

void main() {
  testWidgets('a current-format key shows the ordinary row, no prompt', (
    tester,
  ) async {
    final (enc, _) = await _pump(tester);
    enc.onOwnKeyBundleStatus({'exists': true, 'recoveryKeyLegacy': false});
    await tester.pumpAndSettle();

    expect(find.byKey(_legacyRow), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.recoveryKeyTitle), findsOneWidget);
  });

  testWidgets('an older server (no flag) asks nothing', (tester) async {
    final (enc, _) = await _pump(tester);
    enc.onOwnKeyBundleStatus({'exists': true});
    await tester.pumpAndSettle();

    expect(find.byKey(_legacyRow), findsNothing);
  });

  testWidgets('a legacy key shows the prompt; tapping opens enrolment', (
    tester,
  ) async {
    final (enc, _) = await _pump(tester);
    enc.onOwnKeyBundleStatus({'exists': true, 'recoveryKeyLegacy': true});
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(_legacyRow), findsOneWidget);
    expect(find.text(l10n.recoveryKeyLegacyBody), findsOneWidget);

    await tester.tap(find.byKey(_legacyRow));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyScreen), findsOneWidget);
  });

  testWidgets('dismissing hides the prompt for good, but the row stays', (
    tester,
  ) async {
    final (enc, _) = await _pump(tester);
    enc.onOwnKeyBundleStatus({'exists': true, 'recoveryKeyLegacy': true});
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(_dismiss));
    await tester.tap(find.byKey(_dismiss));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(_legacyRow), findsNothing);
    expect(find.text(l10n.recoveryKeyTitle), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('recovery_legacy_prompt_dismissed_7'), isTrue);
  });

  testWidgets('a stored dismissal keeps the prompt away on the next launch', (
    tester,
  ) async {
    final (enc, _) = await _pump(
      tester,
      prefs: {'recovery_legacy_prompt_dismissed_7': true},
    );
    enc.onOwnKeyBundleStatus({'exists': true, 'recoveryKeyLegacy': true});
    await tester.pumpAndSettle();

    expect(find.byKey(_legacyRow), findsNothing);
  });

  testWidgets('replacing the key clears the prompt', (tester) async {
    final (enc, _) = await _pump(tester);
    enc.onOwnKeyBundleStatus({'exists': true, 'recoveryKeyLegacy': true});
    await tester.pumpAndSettle();
    expect(find.byKey(_legacyRow), findsOneWidget);

    enc.onRecoveryKeySet(const {'success': true});
    await tester.pumpAndSettle();
    expect(find.byKey(_legacyRow), findsNothing);
  });
}
