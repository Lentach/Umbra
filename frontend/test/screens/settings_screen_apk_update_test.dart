import 'dart:convert';

import 'package:fireplace/config/app_version_info.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/services/apk_update_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../support/passcode_fakes.dart';

/// Serves a channel one build ahead of the installed 20049.
http.Client servingNewer() => MockClient(
  (_) async => http.Response(
    jsonEncode({
      'version': '0.2.50',
      'gitCommit': 'd37e2dcc',
      'buildTime': '',
      'android': {
        'versionCode': 20050,
        'versionName': '0.2.50',
        'url': 'https://example.invalid/umbra-0.2.50.apk',
      },
    }),
    200,
  ),
);

Future<void> pumpSettings(WidgetTester tester, ApkUpdateService service) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(
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
        home: SettingsScreen(apkUpdateService: service),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView), const Offset(0, -800));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  setUp(() {
    AppVersionInfo.debugResetForTest();
    PackageInfo.setMockInitialValues(
      appName: 'fireplace',
      packageName: 'com.fireplace.app',
      version: '0.2.49',
      buildNumber: '20049',
      buildSignature: '',
    );
  });

  testWidgets('offers the newer build, naming the version', (tester) async {
    await pumpSettings(
      tester,
      ApkUpdateService(
        client: servingNewer(),
        baseUrl: 'https://example.invalid',
        isAndroid: true,
        readDismissed: () async => null,
        writeDismissed: (_) async {},
      ),
    );

    expect(find.byKey(const Key('settings-apk-update-card')), findsOneWidget);
    expect(find.textContaining('0.2.50'), findsWidgets);
  });

  testWidgets('shows nothing when the server publishes no APK', (tester) async {
    await pumpSettings(
      tester,
      ApkUpdateService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'version': '0.2.50',
              'gitCommit': 'd37e2dcc',
              'buildTime': '',
              'android': null,
            }),
            200,
          ),
        ),
        baseUrl: 'https://example.invalid',
        isAndroid: true,
        readDismissed: () async => null,
        writeDismissed: (_) async {},
      ),
    );

    expect(find.byKey(const Key('settings-apk-update-card')), findsNothing);
  });

  testWidgets('Later hides the card and records the dismissed build', (
    tester,
  ) async {
    int? dismissed;
    await pumpSettings(
      tester,
      ApkUpdateService(
        client: servingNewer(),
        baseUrl: 'https://example.invalid',
        isAndroid: true,
        readDismissed: () async => null,
        writeDismissed: (code) async => dismissed = code,
      ),
    );

    await tester.tap(find.byKey(const Key('settings-apk-update-later')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-apk-update-card')), findsNothing);
    expect(dismissed, 20050);
  });
}
