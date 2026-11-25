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
import 'package:fireplace/screens/recovery_key_screen.dart';
import 'package:fireplace/services/passcode_store.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/dialogs/legacy_recovery_key_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

/// Plan B7: an account whose recovery key is legacy (`phrase_v1`) is asked once
/// per app start, on the chat list, to replace it. One modal at a time.
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({required this.userId, this.awaitsPassword = false});

  final int userId;
  final bool awaitsPassword;

  @override
  UserModel? get currentUser =>
      UserModel(id: userId, username: 'user$userId', tag: '000$userId');

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

const _later = Key('legacy-key-dialog-later');
const _replace = Key('legacy-key-dialog-replace');
const _backupSheet = Key('contact-backup-prompt-title');
const _backupLater = Key('contact-backup-prompt-later');

late AppLocalizations _l10n;

void _legacy(EncryptionProvider enc, {bool? value = true}) {
  enc.onOwnKeyBundleStatus({
    'exists': true,
    if (value != null) 'recoveryKeyLegacy': value,
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required EncryptionProvider enc,
  required PasscodeProvider passcode,
  int userId = 7,
  bool awaitsPassword = false,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(
          value: _FakeAuthProvider(
            userId: userId,
            awaitsPassword: awaitsPassword,
          ),
        ),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (_) => _FakeConnectionProvider(),
        ),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(
          create: (_) => ConversationsProvider()..setCurrentUserId(userId),
        ),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'light'),
        ),
        ChangeNotifierProvider<EncryptionProvider>.value(value: enc),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProvider<PasscodeProvider>.value(value: passcode),
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
}

Future<PasscodeProvider> _passcode() async {
  final passcode = PasscodeProvider(
    store: MemoryPasscodeStore(),
    kdf: FakePasscodeKdf(),
  );
  // The app reads the credential at start; until then the state is `unknown`
  // and the chat list is covered.
  await passcode.initialize();
  return passcode;
}

Finder get _title => find.text(_l10n.recoveryKeyLegacyTitle);

void main() {
  setUpAll(() async {
    _l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LegacyRecoveryKeyAsked.reset();
  });

  testWidgets('opens when the flag turns true after the first build', (
    tester,
  ) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    expect(_title, findsNothing);

    _legacy(enc);
    await tester.pumpAndSettle();

    expect(_title, findsOneWidget);
    expect(find.text(_l10n.recoveryKeyLegacyDialogBody), findsOneWidget);
    expect(find.byKey(_later), findsOneWidget);
    expect(find.byKey(_replace), findsOneWidget);
  });

  testWidgets('never opens on false or on an unknown flag', (tester) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());

    enc.onOwnKeyBundleStatus({'exists': true}); // older server: null
    await tester.pumpAndSettle();
    expect(enc.recoveryKeyLegacy, isNull);
    expect(_title, findsNothing);

    _legacy(enc, value: false);
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
  });

  testWidgets('is not dismissed by a tap outside', (tester) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    _legacy(enc);
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(_title, findsOneWidget);
  });

  testWidgets('Replace now opens the recovery key screen', (tester) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    _legacy(enc);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_replace));
    await tester.pumpAndSettle();

    expect(_title, findsNothing, reason: 'the dialog itself is gone');
    expect(find.byType(RecoveryKeyScreen), findsOneWidget);
  });

  testWidgets('Later closes it and it does not come back in the same run', (
    tester,
  ) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    _legacy(enc);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
    expect(find.byType(RecoveryKeyScreen), findsNothing);

    // The provider speaks again (every status after a reconnect), and the
    // screen is rebuilt: still asked once.
    enc.onOwnKeyBundleStatus({'exists': true, 'hasRecoveryPhrase': true});
    _legacy(enc, value: false);
    _legacy(enc);
    await tester.pumpAndSettle();
    expect(_title, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, enc: enc, passcode: await _passcode());
    expect(_title, findsNothing);
  });

  testWidgets('back counts as Later: closes it, never opens the key screen', (
    tester,
  ) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    _legacy(enc);
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();

    expect(_title, findsNothing);
    expect(find.byType(RecoveryKeyScreen), findsNothing);
    _legacy(enc, value: false);
    _legacy(enc);
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
  });

  testWidgets('a second account in the same run is asked once, too', (
    tester,
  ) async {
    final first = EncryptionProvider();
    await _pump(tester, enc: first, passcode: await _passcode(), userId: 7);
    _legacy(first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    final second = EncryptionProvider();
    await _pump(tester, enc: second, passcode: await _passcode(), userId: 8);
    _legacy(second);
    await tester.pumpAndSettle();
    expect(_title, findsOneWidget, reason: 'account 8 has its own showing');
    await tester.tap(find.byKey(_later));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    // Back to account 7 with a fresh provider: already asked this run.
    final again = EncryptionProvider();
    await _pump(tester, enc: again, passcode: await _passcode(), userId: 7);
    _legacy(again);
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
  });

  testWidgets('a key replaced before the ask is never asked about', (
    tester,
  ) async {
    final passcode = await _passcode();
    await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
    await passcode.lockNow();
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: passcode);

    _legacy(enc); // due, but the app is locked
    await tester.pumpAndSettle();
    expect(_title, findsNothing);

    enc.onRecoveryKeySet({'success': true}); // replaced from another device
    await passcode.unlock('123456');
    await tester.pumpAndSettle();

    expect(enc.recoveryKeyLegacy, isFalse);
    expect(_title, findsNothing);
  });

  testWidgets('waits while the app is locked and opens on unlock', (
    tester,
  ) async {
    final passcode = await _passcode();
    await passcode.enable(passcode: '123456', mode: PasscodeMode.digits6);
    await passcode.lockNow();
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: passcode);

    _legacy(enc);
    await tester.pumpAndSettle();
    expect(_title, findsNothing);

    await passcode.unlock('123456');
    await tester.pumpAndSettle();
    expect(_title, findsOneWidget);
  });

  testWidgets('does not open over the contact-backup sheet; opens when it '
      'closes', (tester) async {
    final enc = EncryptionProvider();
    await _pump(
      tester,
      enc: enc,
      passcode: await _passcode(),
      awaitsPassword: true,
    );
    expect(find.byKey(_backupSheet), findsOneWidget);

    _legacy(enc);
    await tester.pumpAndSettle();
    expect(_title, findsNothing, reason: 'one modal at a time');
    expect(find.byKey(_backupSheet), findsOneWidget);

    await tester.tap(find.byKey(_backupLater));
    await tester.pumpAndSettle();
    expect(find.byKey(_backupSheet), findsNothing);
    expect(_title, findsOneWidget);
  });

  testWidgets('goes before the contact-backup sheet when both are due', (
    tester,
  ) async {
    final enc = EncryptionProvider();
    _legacy(enc); // known before the screen opens
    await _pump(
      tester,
      enc: enc,
      passcode: await _passcode(),
      awaitsPassword: true,
    );

    expect(_title, findsOneWidget);
    expect(find.byKey(_backupSheet), findsNothing);
  });

  testWidgets('does not open over the key screen pushed from the chat list', (
    tester,
  ) async {
    final enc = EncryptionProvider();
    await _pump(tester, enc: enc, passcode: await _passcode());
    final context = tester.element(find.byType(ConversationsScreen));
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RecoveryKeyScreen()),
    );
    await tester.pumpAndSettle();

    _legacy(enc);
    await tester.pumpAndSettle();

    expect(_title, findsNothing);
  });
}
