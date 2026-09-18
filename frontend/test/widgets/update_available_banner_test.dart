import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/services/apk_update_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/update_available_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Client serving(Object? android) => MockClient(
  (_) async => http.Response(
    jsonEncode({
      'version': '0.2.50',
      'gitCommit': 'd37e2dcc',
      'buildTime': '',
      'android': android,
    }),
    200,
  ),
);

Map<String, Object?> channel({int code = 20050}) => {
  'versionCode': code,
  'versionName': '0.2.50',
  'url': 'https://example.invalid/umbra-0.2.50.apk',
};

Future<void> pump(
  WidgetTester tester, {
  required http.Client client,
  bool isAndroid = true,
  int installed = 20049,
  int? dismissed,
  void Function(int)? onDismiss,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: UpdateAvailableBanner(
          service: ApkUpdateService(
            client: client,
            baseUrl: 'https://example.invalid',
            isAndroid: isAndroid,
            readInstalledCode: () async => installed,
            readDismissed: () async => dismissed,
            writeDismissed: (code) async => onDismiss?.call(code),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('announces a newer build in the app shell', (tester) async {
    await pump(tester, client: serving(channel()));

    expect(find.byKey(const Key('update-available-banner')), findsOneWidget);
    expect(find.text('0.2.50'), findsOneWidget);
  });

  testWidgets('renders nothing when no APK is published', (tester) async {
    await pump(tester, client: serving(null));

    expect(find.byKey(const Key('update-available-banner')), findsNothing);
  });

  testWidgets('renders nothing off Android', (tester) async {
    await pump(tester, client: serving(channel()), isAndroid: false);

    expect(find.byKey(const Key('update-available-banner')), findsNothing);
  });

  // The uninstall warning is the load-bearing sentence: this is the moment a
  // user reaches for "uninstall and install the new one", which is what
  // destroys their keys. Collapsed chrome must not hide it from a screen
  // reader.
  testWidgets('keeps the uninstall warning in the semantic announcement', (
    tester,
  ) async {
    await pump(tester, client: serving(channel()));

    final node = tester.getSemantics(
      find.byKey(const Key('update-available-banner')),
    );
    expect(node.label, contains('Do not uninstall the app'));
  });

  testWidgets('Later dismisses that exact build', (tester) async {
    int? dismissed;
    await pump(
      tester,
      client: serving(channel()),
      onDismiss: (code) => dismissed = code,
    );

    // Secondary action lives inside the disclosure.
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-available-later')));
    await tester.pumpAndSettle();

    expect(dismissed, 20050);
    expect(find.byKey(const Key('update-available-banner')), findsNothing);
  });

  testWidgets('stays quiet for a build already dismissed', (tester) async {
    await pump(tester, client: serving(channel()), dismissed: 20050);

    expect(find.byKey(const Key('update-available-banner')), findsNothing);
  });

  testWidgets('asks again for a build newer than the dismissed one', (
    tester,
  ) async {
    await pump(
      tester,
      client: serving(channel(code: 20051)),
      dismissed: 20050,
    );

    expect(find.byKey(const Key('update-available-banner')), findsOneWidget);
  });
}
