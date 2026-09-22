// Amendment (lxxiii) clause 3 — an enrolled account that lost its keys meets
// a GATE, not a banner.
//
// AuthGate's logged-in branch renders DeviceLinkGateScreen ABOVE MainShell,
// which stays MOUNTED but Offstage: the socket, the guard's round trip and
// the reset hydration all live under the shell. The gate is ONE screen whose
// states are chosen by provider state, never by navigation.
//
// Falsification contract (spec F5-F7): removing the gate mount turns the
// first test RED (a visible MainShell on a keyless enrolled install);
// removing the reset-pending state turns the countdown/cancel test RED;
// removing the UNKNOWN state turns the retry test RED.

import 'package:fireplace/config/app_version_info.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/main.dart' show AuthGate;
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/device_link_gate_screen.dart';
import 'package:fireplace/screens/link_restore_section.dart';
import 'package:fireplace/screens/link_this_device_screen.dart'
    show LinkThisDeviceBody;
import 'package:fireplace/screens/main_shell.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/passcode_fakes.dart';

class _FakeAuth extends AuthProvider {
  int logoutCalls = 0;

  @override
  bool get isLoggedIn => true;

  @override
  bool get isRestoringSession => false;

  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');

  @override
  String? get token => 'jwt';

  @override
  Future<void> ensureSessionReady() async {}

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

class _FakeConnection extends ConnectionProvider {
  final List<(String, dynamic)> emitted = [];

  @override
  int? get currentUserId => 7;

  @override
  void emit(String event, dynamic data) => emitted.add((event, data));

  @override
  Future<void> connect(
    int userId,
    String token,
    String baseUrl, {
    bool immediate = false,
  }) async {}
}

class _FakeEncryption extends EncryptionProvider {
  _FakeEncryption({
    this.incomplete = false,
    this.unavailable = false,
    this.deadline,
    this.answer,
  });

  bool incomplete;
  bool unavailable;
  DateTime? deadline;
  String? answer;
  int retryCalls = 0;
  int cancelCalls = 0;

  @override
  bool get identityIncomplete => incomplete;

  @override
  bool get identityCheckUnavailable => unavailable;

  @override
  DateTime? get identityResetDeadline => deadline;

  @override
  String? get identityResetRequestStatus => answer;

  @override
  Future<void> retryE2EInit() async {
    retryCalls++;
  }

  @override
  void cancelIdentityReset() {
    cancelCalls++;
    deadline = null;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    AppVersionInfo.debugResetForTest();
    PackageInfo.setMockInitialValues(
      appName: 'fireplace',
      packageName: 'com.fireplace.app',
      version: '0.0.2',
      buildNumber: '42',
      buildSignature: '',
    );
  });

  /// The gate and shell both animate (spinners, skeletons), so pumpAndSettle
  /// never quiesces.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Disposes the tree so the screens' periodic timers cannot outlive the
  /// test body.
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  /// The full logged-in AuthGate, the way FireplaceApp mounts it.
  Widget authGateHost(_FakeEncryption encryption, _FakeAuth auth) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(),
        ),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider<FriendsProvider>(create: (_) => FriendsProvider()),
        ChangeNotifierProvider<ConversationsProvider>(
          create: (_) => ConversationsProvider(),
        ),
        ChangeNotifierProvider<MessagingProvider>(
          create: (_) => MessagingProvider(),
        ),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (_) => _FakeConnection(),
        ),
        // The Chats header carries the Passcode Lock padlock, so the shell
        // this host mounts needs the provider; a memory-backed one keeps the
        // suite off disk.
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
    );
  }

  /// The gate alone, for its per-state contracts.
  Widget gateHost(_FakeEncryption encryption, {_FakeAuth? auth}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth ?? _FakeAuth()),
        ChangeNotifierProvider<ConnectionProvider>(
          create: (_) => _FakeConnection(),
        ),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
      ],
      child: MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DeviceLinkGateScreen(),
      ),
    );
  }

  testWidgets(
    'keyless enrolled install: the gate covers the shell, and the shell '
    'stays MOUNTED but offstage',
    (tester) async {
      final auth = _FakeAuth();
      await tester.pumpWidget(
        authGateHost(_FakeEncryption(incomplete: true), auth),
      );
      await pumpFrames(tester);

      expect(find.byKey(const Key('device-link-gate')), findsOneWidget);
      // F5: no VISIBLE shell on a keyless install…
      expect(find.byType(MainShell), findsNothing);
      // …but the shell is still in the tree — the socket and the guard's own
      // round trip live under it.
      expect(find.byType(MainShell, skipOffstage: false), findsOneWidget);

      await teardown(tester);
    },
  );

  testWidgets('a healthy install renders the shell and never the gate', (
    tester,
  ) async {
    await tester.pumpWidget(authGateHost(_FakeEncryption(), _FakeAuth()));
    await pumpFrames(tester);

    expect(find.byKey(const Key('device-link-gate')), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('the UNKNOWN outcome gates too — never a keyless shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      authGateHost(_FakeEncryption(unavailable: true), _FakeAuth()),
    );
    await pumpFrames(tester);

    expect(find.byKey(const Key('device-link-gate')), findsOneWidget);
    expect(find.byType(MainShell), findsNothing);

    await teardown(tester);
  });

  testWidgets(
    'link state: explainer + inline ceremony body + reset door + logout',
    (tester) async {
      await tester.pumpWidget(gateHost(_FakeEncryption(incomplete: true)));
      await pumpFrames(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      // (lxxvii) clause 3: the body copy now names both directions (scan /
      // show), so the pinned string is linkGateScanBody.
      expect(find.text(l10n.linkGateScanBody), findsOneWidget);
      expect(find.byType(LinkThisDeviceBody), findsOneWidget);
      expect(find.text(l10n.linkGateNoPrimaryQuestion), findsOneWidget);
      expect(find.byKey(const Key('link-gate-start-reset')), findsOneWidget);
      expect(find.byKey(const Key('link-gate-logout')), findsOneWidget);

      await teardown(tester);
    },
  );

  testWidgets(
    'reset-pending state: countdown + cancel, start-reset HIDDEN, link '
    'still offered',
    (tester) async {
      final encryption = _FakeEncryption(
        incomplete: true,
        deadline: DateTime.now().add(const Duration(hours: 71, minutes: 30)),
      );
      await tester.pumpWidget(gateHost(encryption));
      await pumpFrames(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(l10n.linkGateResetPendingTitle), findsOneWidget);
      // The countdown rides the body copy (coarse hours, never seconds).
      expect(find.textContaining('71 hours'), findsOneWidget);
      expect(find.byKey(const Key('link-gate-cancel-reset')), findsOneWidget);
      // (lxxii) two-buttons rule: a running ceremony hides the start door.
      expect(find.byKey(const Key('link-gate-start-reset')), findsNothing);
      // The primary may reappear, so the link stays offered below.
      expect(find.byType(LinkThisDeviceBody), findsOneWidget);

      await tester.tap(find.byKey(const Key('link-gate-cancel-reset')));
      await pumpFrames(tester);
      expect(encryption.cancelCalls, 1);

      await teardown(tester);
    },
  );

  testWidgets('a phrase_too_new answer names why the wait is 72 h', (
    tester,
  ) async {
    final encryption = _FakeEncryption(
      incomplete: true,
      deadline: DateTime.now().add(const Duration(hours: 71)),
      answer: EncryptionProvider.identityResetPhraseTooNewStatus,
    );
    await tester.pumpWidget(gateHost(encryption));
    await pumpFrames(tester);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(l10n.linkGateResetPhraseTooNew), findsOneWidget);

    await teardown(tester);
  });

  testWidgets(
    'UNKNOWN state: spinner + retry re-runs the init, no ceremony body',
    (tester) async {
      final encryption = _FakeEncryption(unavailable: true);
      await tester.pumpWidget(gateHost(encryption));
      await pumpFrames(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));

      expect(find.text(l10n.linkGateCheckingTitle), findsOneWidget);
      // F7: an unknown verdict must not start a ceremony it cannot justify.
      expect(find.byType(LinkThisDeviceBody), findsNothing);

      await tester.tap(find.byKey(const Key('link-gate-retry')));
      await pumpFrames(tester);
      expect(encryption.retryCalls, 1);

      await teardown(tester);
    },
  );

  testWidgets('logout is available from the gate and reaches the provider', (
    tester,
  ) async {
    final auth = _FakeAuth();
    await tester.pumpWidget(
      gateHost(_FakeEncryption(incomplete: true), auth: auth),
    );
    await pumpFrames(tester);

    await tester.ensureVisible(find.byKey(const Key('link-gate-logout')));
    await tester.tap(find.byKey(const Key('link-gate-logout')));
    await pumpFrames(tester);

    expect(auth.logoutCalls, 1);

    await teardown(tester);
  });

  testWidgets(
    'the phrase door renders ABOVE the reset door: the option that keeps the '
    'keys comes before the one that destroys them',
    (tester) async {
      // Pixel_7, 2026-09-22 (Run C): the restore section was the LAST item,
      // below the fold and below "Rozpocznij reset", so a wiped user read
      // "new keys after 6 h, old history lost" before finding the door that
      // restores the same identity in seconds.
      await tester.pumpWidget(gateHost(_FakeEncryption(incomplete: true)));
      await pumpFrames(tester);

      final restoreTop = tester
          .getTopLeft(find.byType(LinkRestoreSection))
          .dy;
      final resetTop = tester
          .getTopLeft(find.byKey(const Key('link-gate-start-reset')))
          .dy;
      expect(restoreTop, lessThan(resetTop));

      await teardown(tester);
    },
  );
}
