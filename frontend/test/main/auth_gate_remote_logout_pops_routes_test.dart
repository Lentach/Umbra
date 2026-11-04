// Amendment (lxvi) clause 1 — a remote session end must leave the auth surface
// on top.
//
// Live QA 2026-09-02, twice: the primary revoked the web install (§5.5) while
// it sat inside an open chat. AuthGate swapped its own subtree to AuthScreen,
// but the chat route pushed ABOVE it on the root navigator survived the swap
// and painted a blank grey page (empty semantics tree, no thrown error) over
// the (lxiv) notice that tells the user to sign in and re-link.
//
// Falsification contract: removing the `popUntil` from AuthGate's logout
// transition turns the first test RED (the orphan stays on top, AuthScreen is
// never visible); the control proves an ordinary logged-in tree is untouched.

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

/// Session state the test flips by hand; nothing touches storage or network.
class _ToggleAuth extends AuthProvider {
  bool _loggedIn = true;

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  bool get isRestoringSession => false;

  @override
  UserModel? get currentUser =>
      _loggedIn ? UserModel(id: 7, username: 'qa', tag: '0001') : null;

  /// ConversationsScreen awaits this before opening the socket; parking it
  /// keeps the test free of a real connection attempt and its timers.
  @override
  Future<void> ensureSessionReady() => Completer<void>().future;

  /// The shape of every provider-driven logout, `deviceRevoked` included:
  /// the state flips and listeners are told — no navigation of its own.
  void remoteLogout() {
    _loggedIn = false;
    notifyListeners();
  }
}

const _orphanKey = Key('orphan-route-above-auth-gate');

Future<void> _pumpApp(WidgetTester tester, _ToggleAuth auth) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => EncryptionProvider()),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider(create: (_) => ConversationsProvider()),
        ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        // The Chats header carries the Passcode Lock padlock, so the shell
        // AuthGate mounts needs the provider; memory-backed to stay off disk.
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
}

/// Both shells animate continuously, so pumpAndSettle never quiesces.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Holds its identity: a keyless install waits behind the honeycomb.
    FlutterSecureStorage.setMockInitialValues({
      'e2e_7_identity_record_v1': '{}',
    });
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a remote logout pops the route pushed above AuthGate so the auth '
    'surface (and its notice) is what the user sees',
    (tester) async {
      final auth = _ToggleAuth();
      addTearDown(auth.dispose);
      await _pumpApp(tester, auth);
      expect(find.byType(MainShell), findsOneWidget);

      // The open chat / devices screen shape: a route on the ROOT navigator,
      // above the gate's own subtree.
      final nav = Navigator.of(tester.element(find.byType(MainShell)));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: _orphanKey, body: SizedBox()),
        ),
      );
      await _pumpFrames(tester);
      expect(find.byKey(_orphanKey), findsOneWidget);

      auth.remoteLogout();
      // The pop is a 300 ms route transition; the popped route stays in the
      // tree until it completes.
      await _pumpFrames(tester, 30);

      expect(find.byKey(_orphanKey), findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
    },
  );

  testWidgets('a logged-in tree with a pushed route is left alone', (
    tester,
  ) async {
    final auth = _ToggleAuth();
    addTearDown(auth.dispose);
    await _pumpApp(tester, auth);

    final nav = Navigator.of(tester.element(find.byType(MainShell)));
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(key: _orphanKey, body: SizedBox()),
      ),
    );
    await _pumpFrames(tester);

    // An unrelated rebuild while still logged in must not pop anything.
    auth.notifyListeners();
    await _pumpFrames(tester);

    expect(find.byKey(_orphanKey), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });
}
