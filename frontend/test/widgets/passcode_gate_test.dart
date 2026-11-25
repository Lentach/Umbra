import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/services/local_data_eraser.dart';
import 'package:fireplace/services/passcode_store.dart';
import 'package:fireplace/screens/passcode_unlock_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/input/composer_keyboard_signals.dart';
import 'package:fireplace/widgets/passcode_gate.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';
import '../support/passcode_fakes.dart';

/// Stands in for the whole logged-in app. If this text is reachable while the
/// passcode is locked, the feature has failed.
const _guarded = Key('guarded-app');

Widget _host(PasscodeProvider passcode) => ChangeNotifierProvider.value(
  value: passcode,
  child: MaterialApp(
    theme: RpgTheme.themeDataLight,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: const PasscodeGate(
      child: Scaffold(body: Text('SECRET CHATS', key: _guarded)),
    ),
  ),
);

void main() {
  late MemoryPasscodeStore store;
  late FakePasscodeKdf kdf;
  late PasscodeProvider passcode;
  late int now;

  setUp(() {
    store = MemoryPasscodeStore();
    kdf = FakePasscodeKdf();
    now = 1757000000000;
    passcode = PasscodeProvider(store: store, kdf: kdf, nowMs: () => now);
  });

  testWidgets('with no passcode configured the app is shown', (tester) async {
    await passcode.initialize();
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    expect(find.byKey(_guarded), findsOneWidget);
    expect(find.text('SECRET CHATS'), findsOneWidget);
  });

  testWidgets('before initialize resolves, the app is NOT painted',
      (tester) async {
    // PasscodeLockState.unknown: painting the shell here would flash the chat
    // list for a frame on every cold start of a locked app.
    await tester.pumpWidget(_host(passcode));
    await tester.pump();

    expect(find.text('SECRET CHATS'), findsNothing);
  });

  testWidgets('before initialize resolves, the cover is the lock screen\'s own '
      'chrome, not a bare scaffold colour', (tester) async {
    // Owner, 2026-09-06: a wake-lock showed "chat → white → lock screen". The
    // white was ours — this branch painted a plain ColoredBox until the
    // credential read resolved.
    await tester.pumpWidget(_host(passcode));
    await tester.pump();

    expect(find.byKey(const Key('passcode-curtain')), findsOneWidget);
    expect(find.byKey(const Key('passcode-dots')), findsNothing);
  });

  testWidgets('a departure with the passcode ON drops the curtain over the app '
      'before the browser snapshots the frame; the return lifts it',
      (tester) async {
    // The chat flash on wake is the browser re-showing the LAST PAINTED frame
    // before any code runs. The only way to not show the chat is to have
    // painted something else on the way out.
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();
    expect(find.text('SECRET CHATS'), findsOneWidget);

    await passcode.noteBackgrounded(); // blur / inactive on the way out
    await tester.pump();
    // The app stays mounted underneath (a pending attach picker must survive);
    // the curtain is opaque and on top, so nothing of it is reachable.
    expect(find.text('SECRET CHATS').hitTestable(), findsNothing);
    expect(find.byKey(const Key('passcode-curtain')), findsOneWidget);
    expect(find.byKey(const Key('passcode-dots')), findsNothing,
        reason: 'a curtain is not a lock: no keypad, nothing to type');

    now += 10000; // inside the 1-minute window
    await passcode.evaluateOnForeground();
    await tester.pump();
    expect(find.byKey(const Key('passcode-curtain')), findsNothing);
    expect(find.text('SECRET CHATS').hitTestable(), findsOneWidget);
  });

  testWidgets('a return past the window turns the curtain into the lock, never '
      'the app', (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    await passcode.noteBackgrounded();
    await tester.pump();
    now += 61000;
    await passcode.evaluateOnForeground();
    await tester.pump();

    expect(find.text('SECRET CHATS'), findsNothing);
    expect(find.byKey(const Key('passcode-curtain')), findsNothing);
    expect(find.byKey(const Key('passcode-dots')), findsOneWidget);
  });

  testWidgets('a departure during the attach picker span does NOT curtain — '
      'the OS sheet is the cover, and a curtain would flash over the composer '
      'when it closes', (tester) async {
    final passcodeWithPicker = PasscodeProvider(
      store: store,
      kdf: kdf,
      nowMs: () => now,
      nativePickerActive: () => composerNativePickerActive.value,
    );
    await passcodeWithPicker.initialize();
    await passcodeWithPicker.enable(
      passcode: '1234',
      mode: PasscodeMode.digits4,
    );
    await tester.pumpWidget(_host(passcodeWithPicker));
    await tester.pumpAndSettle();

    beginComposerNativePicker();
    try {
      await passcodeWithPicker.noteBackgrounded();
      await tester.pump();

      expect(find.byKey(const Key('passcode-curtain')), findsNothing);
      expect(find.text('SECRET CHATS').hitTestable(), findsOneWidget);
    } finally {
      // Ends the span AND cancels its 3-minute self-cap timer, which the
      // test binding would otherwise report as still pending.
      endComposerNativePicker();
    }
  });

  testWidgets('with no passcode there is no curtain: departures are nobody\'s '
      'business', (tester) async {
    await passcode.initialize();
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    await passcode.noteBackgrounded();
    await tester.pump();

    expect(find.text('SECRET CHATS'), findsOneWidget);
    expect(find.byKey(const Key('passcode-curtain')), findsNothing);
  });

  testWidgets('while locked the app is hidden behind the lock screen',
      (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    passcode.lockNow();

    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    expect(find.text('SECRET CHATS'), findsNothing);
    expect(find.byKey(const Key('passcode-dots')), findsOneWidget);
  });

  testWidgets('the right code reveals the app; the wrong one does not',
      (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    passcode.lockNow();
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    for (final d in '9999'.split('')) {
      await tester.tap(find.byKey(Key('passcode-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('SECRET CHATS'), findsNothing);
    expect(find.byKey(const Key('passcode-error')), findsOneWidget);

    for (final d in '1234'.split('')) {
      await tester.tap(find.byKey(Key('passcode-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('SECRET CHATS'), findsOneWidget);
  });

  testWidgets('the guarded subtree keeps its state across a lock',
      (tester) async {
    // The lock must not tear down the app: disposing MainShell would drop the
    // socket, the open conversation and every in-flight send.
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: passcode,
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const PasscodeGate(child: _Counter()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('counter-bump')));
    await tester.pump();
    expect(find.text('taps: 1'), findsOneWidget);

    passcode.lockNow();
    await tester.pumpAndSettle();
    expect(find.text('taps: 1'), findsNothing);

    for (final d in '1234'.split('')) {
      await tester.tap(find.byKey(Key('passcode-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('taps: 1'), findsOneWidget,
        reason: 'state survived: the subtree was hidden, not rebuilt');
  });
  Future<void> pumpLockScreen(
    WidgetTester tester, {
    required Future<LocalDataEraseReport> Function() onErase,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: passcode,
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: PasscodeUnlockScreen(onErase: onErase),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The whole point of the 2026-09-04 redesign: there is NO password door.
  // A forgotten code can only be escaped by destroying what it guards, which
  // is how every key-derived lock in the field behaves (Telegram: "you'll
  // need to reinstall the app"; Phantom: "Reset & wipe app"). So the panel
  // must not offer a bypass, and it must not fire on a stray tap either.
  testWidgets('a forgotten code offers erase only, behind a typed confirmation',
      (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    passcode.lockNow();

    final eraser = FakeLocalDataEraser();
    await pumpLockScreen(tester, onErase: eraser.eraseEverything);

    expect(find.byKey(const Key('passcode-erase-confirm')), findsNothing);

    await tester.tap(find.byKey(const Key('passcode-forgot-link')));
    await tester.pumpAndSettle();
    expect(eraser.calls, 0, reason: 'opening the panel must destroy nothing');

    // Confirmation still empty: the button exists but refuses.
    await tester.tap(find.byKey(const Key('passcode-erase-confirm')));
    await tester.pumpAndSettle();
    expect(eraser.calls, 0);

    await tester.enterText(
      find.byKey(const Key('passcode-erase-field')),
      'nope',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passcode-erase-confirm')));
    await tester.pumpAndSettle();
    expect(eraser.calls, 0, reason: 'the wrong word must not erase anything');

    await tester.enterText(
      find.byKey(const Key('passcode-erase-field')),
      l10n.passcodeEraseConfirmWord,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passcode-erase-confirm')));
    await tester.pumpAndSettle();
    expect(eraser.calls, 1);
  });

  testWidgets('a partial erase is reported instead of claiming a clean slate',
      (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    passcode.lockNow();

    final eraser = FakeLocalDataEraser(
      failed: const [LocalDataEraseArm.secureStorage],
    );
    await pumpLockScreen(tester, onErase: eraser.eraseEverything);

    await tester.tap(find.byKey(const Key('passcode-forgot-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('passcode-erase-field')),
      l10n.passcodeEraseConfirmWord,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passcode-erase-confirm')));
    await tester.pumpAndSettle();

    expect(eraser.calls, 1);
    expect(find.byKey(const Key('passcode-erase-partial')), findsOneWidget);
  });

  // NIST SP 800-63B's usability guidance: tell the claimant how many attempts
  // remain before the throttle bites. Silence here reads as "the app is
  // broken", and the user finds out only when the cooldown starts.
  testWidgets('the last few attempts before a cooldown are counted out',
      (tester) async {
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    passcode.lockNow();

    await pumpLockScreen(tester, onErase: FakeLocalDataEraser().eraseEverything);

    expect(find.byKey(const Key('passcode-subtitle')), findsNothing);

    for (var i = 0; i < 3; i++) {
      for (final digit in ['9', '9', '9', '9']) {
        await tester.tap(find.byKey(Key('passcode-key-$digit')));
        await tester.pumpAndSettle();
      }
    }

    expect(passcode.failedAttempts, 3);
    final subtitle = tester.widget<Text>(
      find.byKey(const Key('passcode-subtitle')),
    );
    expect(subtitle.data, contains('2'));
  });


  testWidgets('a departure during the link ceremony does NOT curtain — '
      '(lxxvi) clause 2: the scanner/permission surface is the cover, and a '
      'curtain would flash over the QR when it closes', (tester) async {
    // `passcode` from setUp leaves `ceremonyActive` at its default, so this
    // proves the real wiring to the `linkCeremonyActive` global.
    await passcode.initialize();
    await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
    await tester.pumpWidget(_host(passcode));
    await tester.pumpAndSettle();

    linkCeremonyActive.value = true;
    try {
      await passcode.noteBackgrounded();
      await tester.pump();

      expect(find.byKey(const Key('passcode-curtain')), findsNothing);
      expect(find.text('SECRET CHATS').hitTestable(), findsOneWidget);
    } finally {
      linkCeremonyActive.value = false;
    }
  });

  // (lxxvi) clause 1: the erase warning is enrolment-aware. An enrolled
  // account is NOT "log in again and start over" — the identity survives the
  // erase (recovery phrase, another device, or the 72 h reset), and telling
  // an enrolled user their safety number will change is simply false.
  group('enrolment-aware erase copy', () {
    String jwtFor(int uid) {
      String enc(Map<String, dynamic> claims) =>
          base64Url.encode(utf8.encode(jsonEncode(claims)));
      return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${enc({'sub': uid, 'username': 'u', 'tag': '0001'})}.sig';
    }

    Future<void> openErasePanel(WidgetTester tester) async {
      await passcode.initialize();
      await passcode.enable(passcode: '1234', mode: PasscodeMode.digits4);
      passcode.lockNow();
      await pumpLockScreen(
        tester,
        onErase: FakeLocalDataEraser().eraseEverything,
      );
      await tester.tap(find.byKey(const Key('passcode-forgot-link')));
      await tester.pumpAndSettle();
    }

    testWidgets('hint TRUE for the last-logged-in account: the enrolled copy, '
        'naming the three doors', (tester) async {
      // The lock screen has no AuthProvider (deliberately); the account comes
      // from the stored access JWT — the same claim AuthProvider restores.
      SharedPreferences.setMockInitialValues({
        'jwt_token': jwtFor(7),
        'account_enrolled_hint_7': true,
      });
      await openErasePanel(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.passcodeEraseWarningEnrolled), findsOneWidget);
      expect(find.text(l10n.passcodeEraseWarning), findsNothing);
    });

    testWidgets('hint absent: the un-enrolled copy (FALSIFICATION control — '
        'fails if the panel always renders the enrolled text)', (tester) async {
      SharedPreferences.setMockInitialValues({'jwt_token': jwtFor(7)});
      await openErasePanel(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.passcodeEraseWarning), findsOneWidget);
      expect(find.text(l10n.passcodeEraseWarningEnrolled), findsNothing);
    });

    testWidgets('hint true for a DIFFERENT account stays un-enrolled copy',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': jwtFor(7),
        'account_enrolled_hint_9': true,
      });
      await openErasePanel(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.passcodeEraseWarning), findsOneWidget);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('taps: $_taps'),
        TextButton(
          key: const Key('counter-bump'),
          onPressed: () => setState(() => _taps++),
          child: const Text('bump'),
        ),
      ],
    ),
  );
}
