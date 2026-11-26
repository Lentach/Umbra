import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/screens/passcode_lock_screen.dart';
import 'package:fireplace/services/passcode_store.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/passcode_autolock.dart';
import 'package:provider/provider.dart';

import '../support/l10n.dart';
import '../support/passcode_fakes.dart';

Widget _host(PasscodeProvider passcode) => ChangeNotifierProvider.value(
  value: passcode,
  child: MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: const PasscodeLockScreen(),
  ),
);

Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.byKey(Key('passcode-key-$d')));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  late MemoryPasscodeStore store;
  late FakePasscodeKdf kdf;
  late PasscodeProvider passcode;

  setUp(() async {
    store = MemoryPasscodeStore();
    kdf = FakePasscodeKdf();
    passcode = PasscodeProvider(
      store: store,
      kdf: kdf,
      nowMs: () => 1757000000000,
    );
    await passcode.initialize();
  });

  group('disabled state', () {
    testWidgets('warns that a forgotten code costs this device\'s data',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('passcode-turn-on')), findsOneWidget);
      // The substance, not the wording: before turning the lock on, the user
      // must be told the escape hatch DESTROYS local data, and must not be
      // promised the account-password bypass this screen advertised until
      // 2026-09-04.
      expect(find.text(l10n.passcodeNote), findsOneWidget);
      expect(
        find.textContaining('sign back in with your account password'),
        findsNothing,
      );
      expect(find.byKey(const Key('passcode-turn-off')), findsNothing);
    });

    testWidgets('enter then repeat the same code enables the lock',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-on')));
      await tester.pumpAndSettle();

      // Default shape is the 6-digit code, like Zangi's middle option.
      expect(find.byKey(const Key('passcode-dot-empty-5')), findsOneWidget);

      await _type(tester, '123456');
      expect(find.text(l10n.passcodeRepeatTitle), findsOneWidget);

      await _type(tester, '123456');

      expect(passcode.isEnabled, isTrue);
      expect(passcode.mode, PasscodeMode.digits6);
      expect(store.record.enabled, isTrue);
    });

    testWidgets('a mismatched repeat reports it and enables nothing',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-on')));
      await tester.pumpAndSettle();
      await _type(tester, '123456');
      await _type(tester, '654321');

      expect(find.text(l10n.passcodeMismatch), findsOneWidget);
      expect(passcode.isEnabled, isFalse);
      expect(store.credentialWrites, 0);
    });

    testWidgets('Passcode Options switches the code shape to 4 digits',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-on')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('passcode-options-link')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('passcode-option-four')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('passcode-dot-empty-3')), findsOneWidget);
      expect(find.byKey(const Key('passcode-dot-empty-4')), findsNothing);

      await _type(tester, '1111');
      await _type(tester, '1111');

      expect(passcode.mode, PasscodeMode.digits4);
      expect(passcode.isEnabled, isTrue);
    });
  });

  group('enabled state', () {
    setUp(() async {
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    });

    testWidgets('shows the management rows instead of the intro',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('passcode-turn-on')), findsNothing);
      expect(find.byKey(const Key('passcode-change-row')), findsOneWidget);
      expect(find.byKey(const Key('passcode-autolock-row')), findsOneWidget);
      expect(find.byKey(const Key('passcode-turn-off')), findsOneWidget);
    });

    testWidgets('auto-lock row picks a new delay', (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-autolock-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('passcode-autolock-3600')));
      await tester.pumpAndSettle();

      expect(passcode.autoLockSeconds, 3600);
      expect(find.text(l10n.passcodeAutoLockHour), findsOneWidget);
    });

    testWidgets('turning the lock off requires the current code', (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-off')));
      await tester.pumpAndSettle();
      await _type(tester, '9999');

      expect(passcode.isEnabled, isTrue, reason: 'wrong code must not disable');

      await _type(tester, '1234');

      expect(passcode.isEnabled, isFalse);
      expect(store.record.enabled, isFalse);
    });

    testWidgets('changing the passcode needs the old one first',
        (tester) async {
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-change-row')));
      await tester.pumpAndSettle();
      await _type(tester, '1234');

      // Now the set + repeat pair, still in 4-digit shape.
      await _type(tester, '5678');
      await _type(tester, '5678');

      expect(passcode.isEnabled, isTrue);
      expect(await passcode.unlock('5678'), PasscodeUnlockResult.ok);
    });

    testWidgets(
        'a cooldown in Settings is never reported as a wrong passcode',
        (tester) async {
      // Regression: `verifyCurrent` became throttled, so false stopped
      // meaning "wrong". Reporting the cooldown as a wrong code tells a user
      // their CORRECT passcode is wrong for as long as an hour.
      await tester.pumpWidget(_host(passcode));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-off')));
      await tester.pumpAndSettle();

      for (var i = 0; i < kPasscodeAttemptsBeforeBackoff; i++) {
        await _type(tester, '9999');
      }
      expect(passcode.lockoutRemaining, isNotNull);

      // The correct code, while the ladder is running.
      await _type(tester, '1234');

      // Positive assertion first: absence of the wrong-code string alone
      // would also pass on a BLANK error, which pins nothing.
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      expect(find.text(l10n.passcodeWrong), findsNothing);
      expect(passcode.isEnabled, isTrue, reason: 'cooldown must still gate');
    });

    testWidgets('turning the passcode off returns to where the user came from, '
        'not to the "enable it" page', (tester) async {
      // Owner, 2026-09-06: after "Wyłącz blokadę kodem" the page just
      // re-rendered as the setup page. The job is done; go back.
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: passcode,
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open-passcode'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PasscodeLockScreen(),
                  ),
                ),
                child: const Text('SETTINGS HOME'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open-passcode')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('passcode-turn-off')), findsOneWidget);

      // A cancelled prompt stays put.
      await tester.tap(find.byKey(const Key('passcode-turn-off')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('passcode-turn-off')), findsOneWidget);
      expect(passcode.isEnabled, isTrue);

      // The right code disables AND leaves.
      await tester.tap(find.byKey(const Key('passcode-turn-off')));
      await tester.pumpAndSettle();
      await _type(tester, '1234');

      expect(passcode.isEnabled, isFalse);
      expect(find.text('SETTINGS HOME'), findsOneWidget);
      expect(find.byKey(const Key('passcode-turn-off')), findsNothing);
      expect(find.byKey(const Key('passcode-enable')), findsNothing,
          reason: 'the setup page must not be what the user lands on');
    });

    // A2-AUTH-06: the prompt accepted the code, yet `disable` can still
    // refuse (vault unwrap failed). The user was returned to the same page
    // with the lock on and no word why.
    testWidgets('a refused turn-off says so instead of staying silent',
        (tester) async {
      final refusing = _RefusingDisable(store: store, kdf: kdf);
      await refusing.initialize();
      await refusing.enable(passcode: '1234', mode: PasscodeMode.digits4);
      await tester.pumpWidget(_host(refusing));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('passcode-turn-off')));
      await tester.pumpAndSettle();
      await _type(tester, '1234');

      expect(find.text(l10n.passcodeTurnOffFailed), findsOneWidget);
      expect(refusing.isEnabled, isTrue);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

/// A provider whose disable is refused after the code verified.
class _RefusingDisable extends PasscodeProvider {
  _RefusingDisable({super.store, super.kdf});

  @override
  Future<bool> disable({required String passcode}) async => false;
}
