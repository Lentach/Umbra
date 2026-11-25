import 'dart:async';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/screens/recovery_key_screen.dart';
import 'package:fireplace/services/device_link/identity_backup.dart';
import 'package:fireplace/services/encryption_service.dart';
import 'package:fireplace/services/recovery_phrase.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart' as support;
import '../support/passcode_fakes.dart';

/// A codec whose `seal` waits for the test, so the "saving" window can be held
/// open while the user (or the app) tries to leave.
class _GatedCodec extends IdentityBackupCodec {
  _GatedCodec()
    : super(kdf: FakePasscodeKdf(), sealer: FakeContentSealer());

  final Completer<void> gate = Completer<void>();

  @override
  Future<SealedIdentityBackup> seal(
    IdentityBackupPayload payload,
    String phrase,
  ) async {
    await gate.future;
    return super.seal(payload, phrase);
  }
}

/// The (lxxviii) clause-4 enrolment screen: words → one-random-word confirm
/// → export + seal + `setRecoveryKey {phrase, backup}` → pop(true) ONLY on
/// the server's success. The pop contract is what F9 rides on: the devices
/// screen calls `enableLinking` only on a `true` result.
void main() {
  const userId = 9;

  late EncryptionProvider provider;
  late List<(String, dynamic)> emitted;

  Future<void> pumpScreen(
    WidgetTester tester, {
    required List<bool?> results,
    void Function(String event, dynamic data)? onEmit,
    bool e2eReady = true,
    bool deferrable = false,
    IdentityBackupCodec? codec,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final service = EncryptionService();
    await service.initialize(
      userId,
      checkServerIdentity: () async =>
          const ServerIdentityGuard(exists: false),
    );
    provider = EncryptionProvider(service: service);
    // The real flow reaches this screen with `_initializeE2EInner` done;
    // (lxxxiii) clause 2 gates the generate button on exactly that.
    if (e2eReady) provider.markE2EInitialized();
    emitted = [];
    provider.setEmitCallback((event, data) {
      emitted.add((event, data));
      onEmit?.call(event, data);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<EncryptionProvider>.value(
        value: provider,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: RpgTheme.themeDataLight,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('open-screen'),
                  onPressed: () async {
                    final saved = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => RecoveryKeyScreen(
                          deferrable: deferrable,
                          codec:
                              codec ??
                              IdentityBackupCodec(
                                kdf: FakePasscodeKdf(),
                                sealer: FakeContentSealer(),
                              ),
                        ),
                      ),
                    );
                    results.add(saved);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-screen')));
    await tester.pumpAndSettle();
  }

  /// Generates the phrase and walks to the confirm step; returns the words.
  Future<List<String>> walkToConfirm(WidgetTester tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.recoveryKeyGenerateAction));
    await tester.pumpAndSettle();
    final words = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!
        .split(RegExp(r'\s+'));
    expect(words, hasLength(12));
    await tester.tap(find.text(l10n.recoveryKeySavedAction));
    await tester.pumpAndSettle();
    return words;
  }

  int promptedIndex(WidgetTester tester) {
    final prompt = tester
        .widgetList<Text>(find.textContaining('#'))
        .map((t) => t.data!)
        .firstWhere((t) => t.contains('#'));
    return int.parse(RegExp(r'#(\d+)').firstMatch(prompt)!.group(1)!) - 1;
  }

  testWidgets('shows no phrase until one is explicitly generated; generating '
      'shows twelve real BIP39 words', (tester) async {
    await pumpScreen(tester, results: <bool?>[]);
    expect(find.byType(SelectableText), findsNothing);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.recoveryKeyGenerateAction));
    await tester.pumpAndSettle();
    final shown = tester.widget<SelectableText>(find.byType(SelectableText));
    final phrase = RecoveryPhrase.normalize(shown.data ?? '');
    expect(phrase.split(' ').length, 12);
    expect(
      RecoveryPhrase.isValid(phrase),
      isTrue,
      reason: 'a phrase the server cannot verify is worse than none',
    );
  });

  testWidgets('a wrong confirm word shows the mismatch and uploads NOTHING',
      (tester) async {
    final results = <bool?>[];
    await pumpScreen(tester, results: results);
    final words = await walkToConfirm(tester);
    final index = promptedIndex(tester);

    // Any word that is guaranteed not to be the demanded one.
    final wrong = words[(index + 1) % words.length] == words[index]
        ? 'zebra'
        : words[(index + 1) % words.length];
    await tester.enterText(
      find.byKey(const Key('recovery-key-confirm-field')),
      wrong,
    );
    await tester.tap(find.byKey(const Key('recovery-key-confirm-action')));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.recoveryKeyConfirmMismatch), findsOneWidget);
    expect(emitted, isEmpty, reason: 'no upload before a passed confirm');

    // Retry with the RIGHT word from the same prompt succeeds.
    provider.onOwnKeyBundleStatus(const {'exists': true});
    await tester.enterText(
      find.byKey(const Key('recovery-key-confirm-field')),
      words[index],
    );
    await tester.tap(find.byKey(const Key('recovery-key-confirm-action')));
    await tester.pump();
    // Let export + seal run, then answer the server ack and drain the poll.
    for (var i = 0; i < 5 && emitted.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(emitted.map((e) => e.$1), contains('setRecoveryKey'));
    provider.onRecoveryKeySet(const {'success': true});
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final payload =
        emitted.firstWhere((e) => e.$1 == 'setRecoveryKey').$2 as Map;
    // Plan B7: the phrase itself is never in the emitted payload; the server
    // gets the derived proof and a v2 backup sealed under an HKDF key.
    expect(payload.containsKey('phrase'), isFalse);
    expect(payload['authSecret'], RecoveryPhrase.deriveAuthSecret(words.join(' ')));
    expect(payload.toString(), isNot(contains(words.join(' '))));
    final backup = payload['backup'] as Map;
    expect(backup['version'], 2);
    expect(backup['iterations'], 0);
    expect(backup['blob'], isA<String>());
    expect(backup['salt'], isA<String>());
    expect(results, [true], reason: 'a landed backup pops true');
    // The phrase is never written to local storage: it would be destroyed by
    // exactly the event it exists to recover from.
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(
        prefs.get(key).toString(),
        isNot(contains(words.join(' '))),
        reason: 'storing the phrase loses it with the device',
      );
    }
    // Drain the success snackbar's auto-dismiss timer.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('F9: a refused backup upload stays on screen and never pops true',
      (tester) async {
    final results = <bool?>[];
    await pumpScreen(
      tester,
      results: results,
      onEmit: (event, data) {
        if (event == 'setRecoveryKey') {
          provider.onRecoveryKeySet(const {'success': false});
        }
      },
    );
    final words = await walkToConfirm(tester);
    final index = promptedIndex(tester);
    await tester.enterText(
      find.byKey(const Key('recovery-key-confirm-field')),
      words[index],
    );
    await tester.tap(find.byKey(const Key('recovery-key-confirm-action')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.recoveryKeySaveFailed), findsOneWidget);
    expect(find.byType(RecoveryKeyScreen), findsOneWidget,
        reason: 'the screen must not pretend success');
    expect(results, isEmpty,
        reason: 'no result yet — and never true, so enableLinking stays uncalled');
    // Drain the failure snackbar's auto-dismiss timer.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('(lxxxiii) clause 2: the generate button is disabled until E2E '
      'is ready and enables when it becomes ready', (tester) async {
    await pumpScreen(tester, results: <bool?>[], e2eReady: false);
    final button = find.byKey(const Key('recovery-key-generate'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull,
        reason: 'exportIdentityForBackup throws before initialize() ran');

    provider.markE2EInitialized();
    provider.notifyListeners();
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('(lxxxiii) clause 1: "Later" exists only on the deferrable door '
      'and pops false', (tester) async {
    final results = <bool?>[];
    await pumpScreen(tester, results: results);
    expect(find.byKey(const Key('recovery-key-later')), findsNothing,
        reason: 'Settings/Devices/nudge doors have no "later"');
    await tester.pageBack();
    await tester.pumpAndSettle();

    results.clear();
    await pumpScreen(tester, results: results, deferrable: true);
    await tester.tap(find.byKey(const Key('recovery-key-later')));
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(emitted, isEmpty, reason: 'declining uploads nothing');
  });

  /// Walks to confirm, types the right word and taps confirm, then pumps
  /// until the screen is "saving" (spinner up) with the seal still gated.
  Future<List<String>> startSavingWithGatedSeal(WidgetTester tester) async {
    final words = await walkToConfirm(tester);
    await tester.enterText(
      find.byKey(const Key('recovery-key-confirm-field')),
      words[promptedIndex(tester)],
    );
    await tester.tap(find.byKey(const Key('recovery-key-confirm-action')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    return words;
  }

  /// Opens the seal gate and lets the export + emit run.
  Future<void> finishSave(WidgetTester tester, _GatedCodec codec) async {
    codec.gate.complete();
    for (var i = 0; i < 5 && emitted.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void answerSuccess(String event, dynamic data) {
    if (event == 'setRecoveryKey') {
      provider.onRecoveryKeySet(const {'success': true});
    }
  }

  testWidgets('A2-AUTH-03: the back arrow does nothing while the phrase is '
      'being saved', (tester) async {
    final codec = _GatedCodec();
    final results = <bool?>[];
    await pumpScreen(
      tester,
      results: results,
      codec: codec,
      onEmit: answerSuccess,
    );
    await startSavingWithGatedSeal(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RecoveryKeyScreen), findsOneWidget,
        reason: 'leaving mid-save hides the outcome from the user');
    expect(results, isEmpty);

    await finishSave(tester, codec);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(results, [true], reason: 'the save still lands and pops true');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('A2-AUTH-03: system back does nothing while the phrase is '
      'being saved', (tester) async {
    final codec = _GatedCodec();
    final results = <bool?>[];
    await pumpScreen(
      tester,
      results: results,
      codec: codec,
      onEmit: answerSuccess,
    );
    await startSavingWithGatedSeal(tester);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RecoveryKeyScreen), findsOneWidget);
    expect(results, isEmpty);

    await finishSave(tester, codec);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(results, [true]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('A2-AUTH-03: a screen closed during the seal never sends the '
      'phrase to the server', (tester) async {
    final codec = _GatedCodec();
    final results = <bool?>[];
    await pumpScreen(tester, results: results, codec: codec);
    await startSavingWithGatedSeal(tester);

    // The app closes the route under it (not a user back tap).
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyScreen), findsNothing);

    await finishSave(tester, codec);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      emitted.map((e) => e.$1),
      isNot(contains('setRecoveryKey')),
      reason: 'a phrase the user can no longer see must not replace theirs',
    );
  });

  /// A system clipboard behind the platform channel. `text` is what a paste
  /// would give; null models an empty clipboard.
  String? clipboardText;

  void mockClipboard(WidgetTester tester) {
    clipboardText = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboardText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return clipboardText == null
                ? null
                : <String, dynamic>{'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  /// Generates the phrase and taps Copy; returns the words, still on the
  /// words step.
  Future<List<String>> generateAndCopy(WidgetTester tester) async {
    await tester.tap(find.text(support.l10n.recoveryKeyGenerateAction));
    await tester.pumpAndSettle();
    final words = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!
        .split(RegExp(r'\s+'));
    await tester.tap(find.text(support.l10n.recoveryKeyCopyAction));
    await tester.pump();
    expect(clipboardText, words.join(' '), reason: 'Copy fills the clipboard');
    await tester.pump(const Duration(seconds: 3));
    return words;
  }

  testWidgets('A2-AUTH-02: a saved phrase is wiped from the clipboard once '
      'enrolment succeeds', (tester) async {
    mockClipboard(tester);
    final results = <bool?>[];
    await pumpScreen(tester, results: results, onEmit: (event, data) {
      if (event == 'setRecoveryKey') {
        provider.onRecoveryKeySet(const {'success': true});
      }
    });
    final words = await generateAndCopy(tester);

    await tester.tap(find.text(support.l10n.recoveryKeySavedAction));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('recovery-key-confirm-field')),
      words[promptedIndex(tester)],
    );
    await tester.tap(find.byKey(const Key('recovery-key-confirm-action')));
    for (var i = 0; i < 5 && emitted.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(results, [true]);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(
      clipboardText ?? '',
      isEmpty,
      reason: 'the 12 words must not outlive the enrolment in the clipboard',
    );
  });

  testWidgets('A2-AUTH-02: leaving the screen wipes the copied phrase',
      (tester) async {
    mockClipboard(tester);
    await pumpScreen(tester, results: <bool?>[]);
    await generateAndCopy(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyScreen), findsNothing);

    expect(clipboardText ?? '', isEmpty);
  });

  testWidgets('A2-AUTH-02: leaving while the copy is still being written '
      'still wipes the phrase', (tester) async {
    final firstWrite = Completer<void>();
    var writes = 0;
    clipboardText = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboardText = (call.arguments as Map)['text'] as String?;
            // The platform takes its time over the user's Copy only.
            if (writes++ == 0) await firstWrite.future;
            return null;
          case 'Clipboard.getData':
            return clipboardText == null
                ? null
                : <String, dynamic>{'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpScreen(tester, results: <bool?>[]);
    await tester.tap(find.text(support.l10n.recoveryKeyGenerateAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(support.l10n.recoveryKeyCopyAction));
    await tester.pump();
    expect(clipboardText, isNotEmpty, reason: 'the write is under way');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyScreen), findsNothing);
    firstWrite.complete();
    await tester.pumpAndSettle();

    expect(clipboardText ?? '', isEmpty);
  });

  testWidgets('A2-AUTH-02: something the user copied since is left alone',
      (tester) async {
    mockClipboard(tester);
    await pumpScreen(tester, results: <bool?>[]);
    await generateAndCopy(tester);
    clipboardText = 'a shopping list';

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(clipboardText, 'a shopping list');
  });

  testWidgets('A2-AUTH-02: a clipboard the screen never filled is not touched',
      (tester) async {
    mockClipboard(tester);
    clipboardText = 'unrelated';
    await pumpScreen(tester, results: <bool?>[]);
    await tester.tap(find.text(support.l10n.recoveryKeyGenerateAction));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(clipboardText, 'unrelated');
  });
}
