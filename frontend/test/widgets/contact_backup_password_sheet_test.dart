import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/contact_backup_password_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('an empty confirm is refused and the error goes when typing '
      'starts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <String>[];
    final auth = AuthProvider(
      api: ApiService(
        baseUrl: 'http://t',
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response(jsonEncode({}), 404);
        }),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: RpgTheme.themeDataLight,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ContactBackupPasswordSheet(auth: auth)),
      ),
    );
    await tester.pump();
    requests.clear();

    await tester.tap(find.byKey(const Key('contact-backup-prompt-confirm')));
    await tester.pump();
    expect(find.text('Password is required'), findsOneWidget);
    expect(requests, isEmpty, reason: 'nothing to check yet');

    await tester.enterText(
      find.byKey(const Key('contact-backup-prompt-password')),
      'p',
    );
    await tester.pump();
    expect(find.text('Password is required'), findsNothing);
  });
}
