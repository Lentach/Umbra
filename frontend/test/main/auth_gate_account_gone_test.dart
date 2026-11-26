// X3: a device whose account was deleted elsewhere. AuthGate wires the
// connection's `onSessionRejected` to the auth session's account-gone verdict;
// a positive verdict must land on the auth screen and clear the local keys
// exactly once. A negative verdict must leave the session alone.

import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/main.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/auth_screen.dart';
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

class _Auth extends AuthProvider {
  _Auth({required this.gone});
  final bool gone;
  bool _loggedIn = true;

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  bool get isRestoringSession => false;

  @override
  UserModel? get currentUser =>
      _loggedIn ? UserModel(id: 7, username: 'qa', tag: '0001') : null;

  @override
  Future<void> ensureSessionReady() => Completer<void>().future;

  @override
  Future<bool> endSessionIfAccountGone() async {
    if (!gone) return false;
    _loggedIn = false;
    notifyListeners();
    return true;
  }
}

class _Encryption extends EncryptionProvider {
  int keyWipes = 0;

  @override
  Future<void> clearEncryptionKeys() async => keyWipes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'e2e_7_identity_record_v1': '{}',
    });
    SharedPreferences.setMockInitialValues({});
  });

  Future<(ConnectionProvider, _Encryption)> pump(
    WidgetTester tester,
    _Auth auth,
  ) async {
    final connection = ConnectionProvider();
    final encryption = _Encryption();
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
          ChangeNotifierProvider(create: (_) => FriendsProvider()),
          ChangeNotifierProvider(create: (_) => ConversationsProvider()),
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          ChangeNotifierProvider<PasscodeProvider>(
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
          home: const AuthGate(),
        ),
      ),
    );
    await tester.pump();
    return (connection, encryption);
  }

  Future<void> frames(WidgetTester tester, [int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a rejected session whose account is gone shows the auth '
      'screen and clears the keys once', (tester) async {
    final (connection, encryption) = await pump(tester, _Auth(gone: true));
    expect(find.byType(MainShell), findsOneWidget);

    await connection.onSessionRejected!();
    await frames(tester);

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(MainShell), findsNothing);
    expect(encryption.keyWipes, 1);
  });

  testWidgets('a rejected session whose account still exists is left '
      'alone', (tester) async {
    final (connection, encryption) = await pump(tester, _Auth(gone: false));

    await connection.onSessionRejected!();
    await frames(tester);

    expect(find.byType(MainShell), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
    expect(encryption.keyWipes, 0);
  });
}
