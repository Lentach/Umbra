import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/identity_reset_pending_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Phase 0b reset ceremony (multi-device spec §6.2).
///
/// This banner is the entire protection: the server's delay only helps someone
/// who SEES the countdown and can stop it. So the tests hold two lines — it
/// must never appear when no ceremony is running (a permanent "someone is
/// resetting your keys" bar would train users to ignore the real one), and
/// when it does appear the cancel action must actually reach the server.
class _FakeEncryption extends EncryptionProvider {
  _FakeEncryption({this.deadline});

  DateTime? deadline;
  int cancelCalls = 0;
  String? answer;
  int clearAnswerCalls = 0;

  @override
  String? get identityResetRequestStatus => answer;

  @override
  void clearIdentityResetRequestStatus() {
    clearAnswerCalls++;
    answer = null;
    notifyListeners();
  }

  @override
  DateTime? get identityResetDeadline => deadline;

  @override
  void cancelIdentityReset() {
    cancelCalls++;
    deadline = null;
    notifyListeners();
  }

}

class _FakeAuthProvider extends AuthProvider {
  @override
  UserModel? get currentUser => UserModel(id: 7, username: 'qa', tag: '0001');
}

class _FakeConnectionProvider extends ConnectionProvider {
  @override
  int? get currentUserId => 7;
}

Widget _host(EncryptionProvider encryption) {
  // The auth and connection fakes exist so the DevicesScreen the (lxvii) link
  // action pushes can build; the banner itself reads only encryption.
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuthProvider()),
      ChangeNotifierProvider<ConnectionProvider>(
        create: (_) => _FakeConnectionProvider(),
      ),
      ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: IdentityResetPendingBanner()),
    ),
  );
}

void main() {
  testWidgets('renders NOTHING when no ceremony is running', (tester) async {
    await tester.pumpWidget(_host(_FakeEncryption()));

    expect(find.byIcon(Icons.lock_reset_outlined), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('warns with the remaining time and offers a one-tap cancel', (
    tester,
  ) async {
    final encryption = _FakeEncryption(
      deadline: DateTime.now().add(const Duration(hours: 71, minutes: 30)),
    );
    await tester.pumpWidget(_host(encryption));

    expect(find.byIcon(Icons.lock_reset_outlined), findsOneWidget);
    // Coarse hours, never a live seconds counter.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      find.textContaining(l10n.identityResetHoursLeft(71)),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('cancelling reaches the provider and clears the banner', (
    tester,
  ) async {
    final encryption = _FakeEncryption(
      deadline: DateTime.now().add(const Duration(hours: 5)),
    );
    await tester.pumpWidget(_host(encryption));

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(encryption.cancelCalls, 1);
    expect(find.byIcon(Icons.lock_reset_outlined), findsNothing);
  });

  testWidgets('shows minutes once under an hour remains', (tester) async {
    final encryption = _FakeEncryption(
      deadline: DateTime.now().add(const Duration(minutes: 42)),
    );
    await tester.pumpWidget(_host(encryption));

    // Remaining time truncates down (41:59 renders as "41 minutes"), which
    // understates the window rather than overstating it — the safe direction
    // for a warning the user is meant to act on.
    expect(find.textContaining(RegExp(r'4[12] minutes')), findsOneWidget);
  });

  testWidgets('a passed deadline still shows the cancel affordance', (
    tester,
  ) async {
    // The server commits on its own clock, so a client whose countdown ran out
    // must not silently drop the banner while the cancel could still win.
    final encryption = _FakeEncryption(
      deadline: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    await tester.pumpWidget(_host(encryption));

    expect(find.byIcon(Icons.lock_reset_outlined), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });

  // The lock-refused notice this banner used to carry moved to the (lxxiii)
  // DeviceLinkGateScreen: a keyless/lock-refused install never reaches the
  // shell any more, and a healthy device watching someone ELSE's reset must
  // not be offered a start-reset door — cancel is its only action.
  testWidgets('a pending ceremony offers cancel and never start-reset', (
    tester,
  ) async {
    final encryption = _FakeEncryption(
      deadline: DateTime.now().add(const Duration(hours: 3)),
    );
    await tester.pumpWidget(_host(encryption));

    expect(
      find.byKey(const Key('identity-reset-banner-start-reset')),
      findsNothing,
    );
    expect(find.byIcon(Icons.key_off_outlined), findsNothing);
  });

  testWidgets('a refused request is said out loud, not swallowed', (
    tester,
  ) async {
    // A genuine owner recovering lost keys meets every refusal: a mistyped
    // phrase, the lockout after five of those, the post-cancel cooldown. With
    // no message the button looks broken while the account stays unreachable.
    // The answer surfaces even while the banner itself renders nothing — the
    // request may have been sent from the (lxxiii) gate.
    final encryption = _FakeEncryption()..answer = 'invalid_phrase';
    await tester.pumpWidget(_host(encryption));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.identityResetPhraseRejected), findsOneWidget);
    // Consumed, so a rebuild cannot replay it.
    expect(encryption.clearAnswerCalls, 1);
    // Let the toast retire; it owns a dismissal timer.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the cooldown answer names the way out of it', (tester) async {
    final encryption = _FakeEncryption()..answer = 'cooldown';
    await tester.pumpWidget(_host(encryption));
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.identityResetCooldown), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
