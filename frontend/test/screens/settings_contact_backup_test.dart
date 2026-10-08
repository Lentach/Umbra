import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/contact_backup_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Decision 95 mutes the chat-list ask after 5 "Later"s. A user who only
/// later learns the password (an owner-set one) must still be able to save
/// the backup without logging out: Settings keeps the way in while the
/// account has no backup, whatever the Later count.
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({required this.awaitsPassword});

  bool awaitsPassword;

  @override
  UserModel? get currentUser =>
      UserModel(id: 7, username: 'Marta', tag: '0007');

  @override
  String? get token => 'test-token';

  @override
  bool get contactBackupAwaitsPassword => awaitsPassword;

  @override
  Future<ContactBackupPromptResult> confirmPasswordForContactBackup(
    String password,
  ) async {
    if (password != 'right') return ContactBackupPromptResult.wrongPassword;
    awaitsPassword = false;
    notifyListeners();
    return ContactBackupPromptResult.saved;
  }
}

const _row = Key('settings-contact-backup-row');

Future<void> _pump(WidgetTester tester, _FakeAuthProvider auth) async {
  // The chat-list ask is muted on this install.
  SharedPreferences.setMockInitialValues({
    'contact_backup_laters_7': kContactBackupLaterLimit,
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
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
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a muted ask still leaves Settings a way to save the backup', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(awaitsPassword: true);
    await _pump(tester, auth);
    await tester.scrollUntilVisible(find.byKey(_row), 200);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_row));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('contact-backup-prompt-password')),
      'right',
    );
    await tester.tap(find.byKey(const Key('contact-backup-prompt-confirm')));
    await tester.pumpAndSettle();

    expect(auth.awaitsPassword, isFalse);
    expect(find.byKey(_row), findsNothing, reason: 'the backup exists now');
  });

  testWidgets('no row once the account has its backup', (tester) async {
    await _pump(tester, _FakeAuthProvider(awaitsPassword: false));

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(find.byKey(_row), findsNothing);
  });
}
