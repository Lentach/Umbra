import 'dart:async';
import 'dart:io';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/services/encryption_service.dart'
    show LocalHistoryWipeResult;
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

/// A3-MSG-A-04 (N3): leaving the screen while "Delete all local messages" runs
/// must not skip the voice cache or the saved copies; they are plaintext.
///
/// Its own file on purpose: `AudioCacheStore` keeps a static queue whose tail
/// is a future from the first test's fake-async zone, so a second test in
/// `privacy_safety_delete_history_saved_copies_test.dart` waits on it forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory docs;
  late File savedCopy;
  late File audio;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    docs = Directory.systemTemp.createTempSync('delete_history_unmounted_');
    savedCopy = File('${docs.path}/saved_downloads/photo.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    audio = File('${docs.path}/audio_cache/7.audio')
      ..createSync(recursive: true)
      ..writeAsBytesSync([2]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => docs.path);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    docs.deleteSync(recursive: true);
  });

  testWidgets('leaving the screen mid-delete does not skip the voice cache '
      'or the saved copies', (tester) async {
    // App-level in the real app: the providers outlive the screen.
    final encryption = _GatedWipeEncryption();
    final settings = SettingsProvider(initialThemePreference: 'dark');
    final messaging = MessagingProvider();
    addTearDown(() {
      encryption.dispose();
      settings.dispose();
      messaging.dispose();
    });
    // A changed `home` does not rebuild the Navigator's first route, so a new
    // [appKey] is what really removes the screen.
    Widget app(Widget home, Key appKey) => MultiProvider(
      providers: [
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: messaging),
      ],
      child: MaterialApp(
        key: appKey,
        theme: RpgTheme.themeDataDarkGray,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

    await tester.pumpWidget(app(const PrivacySafetyScreen(), UniqueKey()));
    await tester.pumpAndSettle();
    final button = find.text(l10n.deleteAllLocalHistoryButton);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.deleteAllLocalHistoryConfirm));
    // The dialog's pop has to finish first, or the delete never starts.
    for (var i = 0; i < 20 && !encryption.started; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(encryption.started, isTrue);

    // Back out while the history clear is still running.
    await tester.pumpWidget(app(const SizedBox.shrink(), UniqueKey()));
    expect(find.byType(PrivacySafetyScreen), findsNothing);
    encryption.gate.complete();
    // Real file IO: each hop resumes in the fake-async zone only on a pump.
    for (var i = 0; i < 40 && savedCopy.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    expect(savedCopy.existsSync(), isFalse);
    expect(audio.existsSync(), isFalse, reason: 'the voice cache goes too');
  });
}

/// The history clear parks on [gate], so the test can leave the screen while
/// it runs.
class _GatedWipeEncryption extends EncryptionProvider {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<LocalHistoryWipeResult> clearLocalDecryptedContentCache() async {
    started = true;
    await gate.future;
    return const LocalHistoryWipeResult(removed: 0, failedKeys: {});
  }
}
