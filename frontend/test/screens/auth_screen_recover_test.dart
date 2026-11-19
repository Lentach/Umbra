// Amendment (lxxxii) clause 2 — the recovery phrase as a credential, as the
// SCREEN drives it: the link under the sign-in form opens the recover form,
// a well-formed phrase + a rule-passing new password reach the provider as
// ONE normalized request, and a refusal reads as the phrase, not a password.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/screens/auth_screen.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/services/recovery_phrase.dart';
import 'package:fireplace/theme/rpg_theme.dart';

const _accessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoibWEwaSIsInRhZyI6IjUyNjkiLCJleHAiOjk5OTk5OTk5OTl9.abc';
// Checksum-valid: the form's typo guard runs before anything is sent.
const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'Content-Type': 'application/json'},
);

Future<AppLocalizations> _pump(
  WidgetTester tester,
  http.Client client,
) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    MaterialApp(
      theme: RpgTheme.themeDataLight,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('pl'),
      home: ChangeNotifierProvider(
        create: (_) => AuthProvider(
          api: ApiService(baseUrl: 'http://localhost:3999', httpClient: client),
        ),
        child: const AuthScreen(),
      ),
    ),
  );
  await tester.pump();
  return AppLocalizations.delegate.load(const Locale('pl'));
}

Future<void> _openRecoverAndFill(
  WidgetTester tester, {
  required String phrase,
  String password = 'NewPass1x',
}) async {
  await tester.tap(find.byKey(const Key('auth-forgot-password')));
  await tester.pumpAndSettle();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'ma0i#5269');
  await tester.enterText(find.byKey(const Key('auth-recover-phrase')), phrase);
  await tester.enterText(fields.at(2), password);
  await tester.ensureVisible(find.byKey(const Key('auth-submit')));
  await tester.tap(find.byKey(const Key('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the link opens a form that sends ONE normalized request and '
      'signs the user in', (tester) async {
    Map<String, dynamic>? sent;
    final l10n = await _pump(
      tester,
      MockClient((req) async => switch (req.url.path) {
            '/auth/recover' => (
                sent = jsonDecode(req.body) as Map<String, dynamic>,
                _json({'access_token': _accessJwt, 'refresh_token': 'r'}, 201),
              ).$2,
            '/users/me' =>
              _json({'id': 114, 'username': 'ma0i', 'tag': '5269'}, 200),
            _ => throw StateError('unexpected ${req.url.path}'),
          }),
    );

    // Casing and whitespace are typing noise, not part of the secret.
    await _openRecoverAndFill(
      tester,
      phrase: '  ${_phrase.toUpperCase().replaceAll(' ', '   ')} ',
    );

    expect(sent?['identifier'], 'ma0i#5269');
    // Plan B7: only the derived proof crosses the wire — never the phrase
    // (and the typing noise above normalizes to the same proof).
    expect(sent?['authSecret'], RecoveryPhrase.deriveAuthSecret(_phrase));
    expect(sent?.containsKey('phrase'), isFalse);
    expect(sent.toString(), isNot(contains(_phrase)));
    expect(sent?['newPassword'], 'NewPass1x');
    // The gate above this screen switches on the session; the screen itself
    // has nothing left to say.
    final auth = tester.element(find.byType(AuthScreen)).read<AuthProvider>();
    expect(auth.isLoggedIn, isTrue);
    expect(auth.statusCode, isNull);
    expect(l10n.authRecoverSubmit, isNotEmpty);
  });

  testWidgets('a malformed phrase never leaves the device', (tester) async {
    var calls = 0;
    final l10n = await _pump(
      tester,
      MockClient((req) async {
        calls++;
        return _json({}, 500);
      }),
    );

    await _openRecoverAndFill(tester, phrase: 'only three words');

    expect(calls, 0, reason: 'a typo must not spend a server attempt');
    expect(find.text(l10n.recoveryPhraseMalformed), findsOneWidget);
  });

  testWidgets('a refusal names the phrase, and the way back is one tap', (
    tester,
  ) async {
    final l10n = await _pump(
      tester,
      MockClient((req) async => _json({'message': 'Invalid credentials'}, 401)),
    );

    await _openRecoverAndFill(tester, phrase: _phrase);

    expect(find.text(l10n.authStatusPhraseRejected), findsOneWidget);
    expect(find.text(l10n.authStatusInvalidCredentials), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('auth-recover-back')));
    await tester.tap(find.byKey(const Key('auth-recover-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-forgot-password')), findsOneWidget);
    expect(find.byKey(const Key('auth-recover-phrase')), findsNothing);
  });
}
