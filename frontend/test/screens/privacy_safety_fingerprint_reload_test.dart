// A2-SET-5: the identity fingerprint was read once, in initState. Opened
// offline or right after start-up (E2E not ready yet), the screen got null,
// hid the section, and never asked again — even after setup finished. A read
// that throws must not leave the placeholder up for good either.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/privacy_safety_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/l10n.dart';

const _fingerprint = '12345 67890 12345 67890';

class _LateReadyEncryption extends EncryptionProvider {
  bool ready = false;
  bool throwOnRead = false;
  int reads = 0;

  @override
  bool get isE2EReady => ready;

  @override
  Future<String?> getIdentityFingerprint() async {
    reads++;
    if (throwOnRead) throw StateError('store closed');
    return ready ? _fingerprint : null;
  }

  void becomeReady() {
    ready = true;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpScreen(
    WidgetTester tester,
    _LateReadyEncryption encryption,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
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
  }

  testWidgets('a screen opened before E2E is ready shows the fingerprint '
      'once setup finishes, without reopening', (tester) async {
    final encryption = _LateReadyEncryption();
    addTearDown(encryption.dispose);
    await pumpScreen(tester, encryption);
    expect(find.text(_fingerprint), findsNothing);

    encryption.becomeReady();
    await tester.pumpAndSettle();

    expect(find.text(_fingerprint), findsOneWidget);
  });

  testWidgets('a fingerprint read that throws ends the loading state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final encryption = _LateReadyEncryption()..throwOnRead = true;
    addTearDown(encryption.dispose);
    await pumpScreen(tester, encryption);

    // The loading placeholder is gone and nothing escaped as an exception.
    expect(find.bySemanticsLabel(l10n.devicesLoading), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a screen opened when E2E is ready reads the fingerprint once', (
    tester,
  ) async {
    final encryption = _LateReadyEncryption()..ready = true;
    addTearDown(encryption.dispose);
    await pumpScreen(tester, encryption);

    expect(find.text(_fingerprint), findsOneWidget);
    expect(encryption.reads, 1);
  });
}
