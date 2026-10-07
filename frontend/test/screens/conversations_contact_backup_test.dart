import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/conversations_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/contact_backup_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Decision 94: the contact-backup ask never blocks the app. The sheet opens
/// at app open and can always be dismissed; a red line stays on the chat list
/// until the backup exists.
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({required this.awaitsPassword});

  bool awaitsPassword;
  final List<String> confirmed = [];

  @override
  UserModel? get currentUser =>
      UserModel(id: 7, username: 'Marta', tag: '0007');

  @override
  String? get token => 'test-token';

  @override
  Future<void> ensureSessionReady() async {}

  @override
  bool consumeFreshRegistration() => false;

  @override
  bool get contactBackupAwaitsPassword => awaitsPassword;

  @override
  Future<void> get contactBackupReady async {}

  @override
  Future<ContactBackupPromptResult> confirmPasswordForContactBackup(
    String password,
  ) async {
    confirmed.add(password);
    if (password != 'right') return ContactBackupPromptResult.wrongPassword;
    awaitsPassword = false;
    return ContactBackupPromptResult.saved;
  }
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  Future<void> connect(
    int userId,
    String token,
    String baseUrl, {
    bool immediate = false,
  }) async {}
}

const _alert = Key('contact-backup-alert');
const _sheetTitle = Key('contact-backup-prompt-title');
const _password = Key('contact-backup-prompt-password');
const _confirm = Key('contact-backup-prompt-confirm');
const _later = Key('contact-backup-prompt-later');

Future<_FakeAuthProvider> _pump(
  WidgetTester tester, {
  required bool awaitsPassword,
}) async {
  final auth = _FakeAuthProvider(awaitsPassword: awaitsPassword);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (_) => _FakeConnectionProvider(),
        ),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(
          create: (_) => ConversationsProvider()..setCurrentUserId(7),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'light'),
        ),
        ChangeNotifierProvider(create: (_) => EncryptionProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProvider(
          create: (_) => PasscodeProvider(
            store: MemoryPasscodeStore(),
            kdf: FakePasscodeKdf(),
          ),
        ),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const MediaQuery(
          data: MediaQueryData(size: Size(400, 800), disableAnimations: true),
          child: ConversationsScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an account with a backup sees neither the sheet nor the line', (
    tester,
  ) async {
    await _pump(tester, awaitsPassword: false);

    expect(find.byKey(_sheetTitle), findsNothing);
    expect(find.byKey(_alert), findsNothing);
  });

  testWidgets('the sheet opens at app open and Later leaves the app usable '
      'with the red line still up', (tester) async {
    await _pump(tester, awaitsPassword: true);
    expect(find.byKey(_sheetTitle), findsOneWidget);

    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();

    expect(find.byKey(_sheetTitle), findsNothing);
    expect(find.byKey(_alert), findsOneWidget);
    // Nothing modal is left over the screen: the line itself takes a tap.
    await tester.tap(find.byKey(_alert));
    await tester.pumpAndSettle();
    expect(find.byKey(_sheetTitle), findsOneWidget);
  });

  testWidgets('a wrong password keeps the line; the right one removes it', (
    tester,
  ) async {
    final auth = await _pump(tester, awaitsPassword: true);
    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_alert));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_password), 'wrong');
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password.'), findsOneWidget);

    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();
    expect(find.byKey(_alert), findsOneWidget, reason: 'still no backup');

    await tester.tap(find.byKey(_alert));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_password), 'right');
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    expect(auth.confirmed, ['wrong', 'right']);
    expect(find.byKey(_sheetTitle), findsNothing);
    expect(find.byKey(_alert), findsNothing);
  });
}
