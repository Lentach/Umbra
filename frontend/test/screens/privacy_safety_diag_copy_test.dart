import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/user_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/e2e_diag_log.dart';
import 'package:fireplace/utils/e2e_persistent_diag.dart';
import 'package:fireplace/widgets/settings_console.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignedIn extends AuthProvider {
  @override
  UserModel? get currentUser =>
      UserModel(id: 4711, username: 'own', tag: '0001');
}

/// The hidden diagnostic panel's Copy button is how a log reaches a bug
/// report: what lands on the clipboard must not name who the user talks to.
void main() {
  String? copied;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await E2ePersistentDiag.init();
    E2eDiagLog.clear();
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    E2eDiagLog.clear();
    await E2ePersistentDiag.clear();
  });

  testWidgets('Copy puts no user, conversation or device id on the clipboard', (
    tester,
  ) async {
    // Tall enough that the panel needs no scrolling (it parks under the bar).
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Four digits or more: a shorter id also matches the clock in each line.
    E2eDiagLog.add('SOCKET_CONNECT', {'userId': 4711});
    E2eDiagLog.add('SOCKET_READY', {'activeConvId': 990077});
    E2eDiagLog.add('BOX_FRIEND_NOT_LIVE', {'peer': 8123, 'device': 6502});
    E2ePersistentDiag.record('DECRYPT_FAIL', {
      'senderId': 8123,
      'msgId': 12,
      'error': 'Bad Mac!',
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => _SignedIn()),
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

    await tester.longPress(find.byType(ConsoleHexIcon).first);
    await tester.pumpAndSettle();
    final copy = find.widgetWithText(TextButton, 'Copy');
    await tester.tap(copy);
    await tester.pump();
    // The confirmation toast's own timer.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    for (final id in ['4711', '990077', '8123', '6502']) {
      expect(copied, isNot(contains(id)), reason: 'id $id was copied');
    }
    expect(copied, contains('userId: me'));
    expect(copied, contains('BOX_FRIEND_NOT_LIVE'));
    expect(copied, contains('DECRYPT_FAIL'));
    expect(copied, contains('error: Bad Mac!'));
    expect(copied, contains('msgId: 12'));
    // One peer, one placeholder: the durable line and the live lines agree.
    final peer = RegExp(r'senderId: (\S+?),').firstMatch(copied!)!.group(1)!;
    expect(copied, contains('peer: $peer,'));
  });
}
