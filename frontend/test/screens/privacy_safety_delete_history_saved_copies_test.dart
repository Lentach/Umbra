import 'dart:io';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

/// A3-MSG-A-04: "Delete all local messages" also deletes the files the user
/// saved out of chats; they are plaintext outside every store.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory docs;
  late File savedCopy;
  late File audio;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    docs = Directory.systemTemp.createTempSync('delete_history_saved_');
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

  testWidgets('the confirmed delete removes the saved copies', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => EncryptionProvider()),
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(initialThemePreference: 'dark'),
          ),
          ChangeNotifierProvider(create: (_) => MessagingProvider()),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataDarkGray,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PrivacySafetyScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.text(l10n.deleteAllLocalHistoryButton);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.deleteAllLocalHistoryConfirm));
    await tester.pump();
    // Real file IO: each hop resumes in the fake-async zone only on a pump.
    for (var i = 0; i < 40 && savedCopy.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    // Let the confirmation toast time out.
    await tester.pump(const Duration(seconds: 4));

    expect(savedCopy.existsSync(), isFalse);
    expect(audio.existsSync(), isFalse, reason: 'the voice cache goes too');
  });
}
