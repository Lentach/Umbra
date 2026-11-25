// A2-AUTH-08 + A2-AUTH-01: MainShell's lifecycle wiring around the passcode
// lock.
//
// Android's lock is only a cover: the socket and the open chat keep running
// under it. So while the lock is up the app must not count as visible (no read
// receipt, no disappearing-message countdown), and the moment the code is
// accepted the open chat is shown as on any foreground.

import 'dart:async';

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
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

class _Auth extends AuthProvider {
  /// The shell's own screen parks on this first; once released, the resume
  /// path's wait returns at once.
  bool released = false;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isRestoringSession => false;

  @override
  String? get token => 'tok';

  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');

  @override
  Future<void> ensureSessionReady() =>
      released ? Future<void>.value() : Completer<void>().future;
}

/// Records what the shell tells the lock and lets the test flip its verdict.
class _Passcode extends PasscodeProvider {
  _Passcode() : super(store: MemoryPasscodeStore(), kdf: FakePasscodeKdf());

  final List<String> calls = [];
  PasscodeLockState _fake = PasscodeLockState.unlocked;

  @override
  PasscodeLockState get state => _fake;

  @override
  bool get isLocked => _fake == PasscodeLockState.locked;

  @override
  bool get isEnabled => _fake != PasscodeLockState.disabled;

  @override
  Future<void> noteBackgrounded() async => calls.add('noteBackgrounded');

  @override
  Future<void> evaluateOnForeground() async => calls.add('evaluateOnForeground');

  void setLock(PasscodeLockState next) {
    _fake = next;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Auth auth;
  late _Passcode passcode;
  late ConversationsProvider conversations;
  late int shownCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'e2e_7_identity_record_v1': '{}',
    });
    SharedPreferences.setMockInitialValues({});
    shownCalls = 0;
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    PasscodeLockState initial = PasscodeLockState.unlocked,
  }) async {
    auth = _Auth();
    passcode = _Passcode().._fake = initial;
    conversations = ConversationsProvider();
    addTearDown(auth.dispose);
    addTearDown(passcode.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => EncryptionProvider()),
          ChangeNotifierProvider(create: (_) => FriendsProvider()),
          ChangeNotifierProvider<ConversationsProvider>.value(
            value: conversations,
          ),
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider<PasscodeProvider>.value(value: passcode),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MainShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The wiring (`onClientVisible` -> report the shown chat read) is what a
    // real show triggers; count it.
    conversations.onClientVisible = () => shownCalls++;
    auth.released = true;
  }

  Future<void> lifecycle(WidgetTester tester, AppLifecycleState s) async {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('going to the background and coming back tells the passcode '
      'lock, in that order', (tester) async {
    await pumpShell(tester);
    await lifecycle(tester, AppLifecycleState.paused);
    expect(passcode.calls, ['noteBackgrounded']);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(passcode.calls, ['noteBackgrounded', 'evaluateOnForeground']);
  });

  testWidgets('no passcode: a resume counts the app as visible, as before', (
    tester,
  ) async {
    await pumpShell(tester, initial: PasscodeLockState.disabled);
    await lifecycle(tester, AppLifecycleState.paused);
    expect(conversations.isClientVisible, isFalse);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(conversations.isClientVisible, isTrue);
    expect(shownCalls, 1);
  });

  testWidgets('a resume onto the lock screen does not count as visible; the '
      'unlock does, and shows the open chat', (tester) async {
    await pumpShell(tester);
    await lifecycle(tester, AppLifecycleState.paused);
    passcode.setLock(PasscodeLockState.locked);
    await lifecycle(tester, AppLifecycleState.resumed);

    expect(conversations.isClientVisible, isFalse);
    expect(shownCalls, 0);

    passcode.setLock(PasscodeLockState.unlocked);
    await tester.pump();
    await tester.pump();

    expect(conversations.isClientVisible, isTrue);
    expect(shownCalls, 1);
  });

  testWidgets('the lock engaging under a foreground app (auto-lock, another '
      'tab) stops counting it as visible until the unlock', (tester) async {
    await pumpShell(tester);
    expect(conversations.isClientVisible, isTrue);

    passcode.setLock(PasscodeLockState.locked);
    await tester.pump();
    expect(conversations.isClientVisible, isFalse);

    passcode.setLock(PasscodeLockState.unlocked);
    await tester.pump();
    await tester.pump();
    expect(conversations.isClientVisible, isTrue);
    expect(shownCalls, 1);
  });

  testWidgets('an unlock while the app is in the background does not count '
      'it as visible', (tester) async {
    await pumpShell(tester);
    passcode.setLock(PasscodeLockState.locked);
    await tester.pump();
    await lifecycle(tester, AppLifecycleState.paused);

    passcode.setLock(PasscodeLockState.unlocked);
    await tester.pump();
    await tester.pump();

    expect(conversations.isClientVisible, isFalse);
    expect(shownCalls, 0);
  });
}
