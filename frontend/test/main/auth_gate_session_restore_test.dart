import 'dart:async';
import 'dart:convert';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/main.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/auth_screen.dart';
import 'package:fireplace/services/api_service.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/boot_honeycomb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _expiredAccessJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoidGVzdCIsInRhZyI6IjAwMDAiLCJleHAiOjE1MTYyMzkwMjJ9.4Adcj3UFYzPUBaY63_UWOshvRZQZjm7uI9uWGQ8RrXc';

void main() {
  testWidgets('AuthGate hides login while a saved session is restoring', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': _expiredAccessJwt,
      'refresh_token': 'opaque_refresh',
    });
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    final mock = MockClient((request) async {
      if (request.url.path == '/auth/refresh') {
        refreshStarted.complete();
        await releaseRefresh.future;
        // Resolves as an INVALID session once released. The assertions are all
        // taken while the request is still in flight; resolving this way lands
        // on AuthScreen, which this minimal provider tree can build, and leaves
        // no session-refresh timer behind.
        return http.Response(
          jsonEncode({'message': 'invalid refresh token'}),
          401,
          headers: {'Content-Type': 'application/json'},
        );
      }
      return http.Response('unexpected ${request.url.path}', 500);
    });
    final auth = AuthProvider(
      api: ApiService(baseUrl: 'http://localhost:3999', httpClient: mock),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => ConnectionProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: RpgTheme.themeDataLight,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AuthGate(),
        ),
      ),
    );
    await refreshStarted.future;
    await tester.pump();

    expect(auth.isRestoringSession, isTrue);
    expect(find.byType(BootHoneycomb), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);

    // The assertions above are the whole point: the boot/restoring frame,
    // which used to show the login screen. Now drain the held refresh —
    // ApiService bounds every call with a timeout, and a request left in
    // flight parks that timer past the widget tree's disposal.
    releaseRefresh.complete();
    // AuthScreen animates continuously, so pumpAndSettle never quiesces.
    for (var i = 0; i < 20 && auth.isRestoringSession; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
    auth.dispose();
  });

  testWidgets(
    'AuthGate swaps the boot spinner for the login screen once a failed '
    'restore resolves',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': _expiredAccessJwt,
        'refresh_token': 'opaque_refresh',
      });
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      final mock = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          refreshStarted.complete();
          await releaseRefresh.future;
          // Refresh token rejected -> the saved session cannot be restored.
          return http.Response(
            jsonEncode({'message': 'refresh token revoked'}),
            401,
            headers: {'Content-Type': 'application/json'},
          );
        }
        return http.Response('unexpected ${request.url.path}', 500);
      });
      final auth = AuthProvider(
        api: ApiService(baseUrl: 'http://localhost:3999', httpClient: mock),
      );
      addTearDown(auth.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider(create: (_) => ConnectionProvider()),
            ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ],
          child: MaterialApp(
            theme: RpgTheme.themeDataLight,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AuthGate(),
          ),
        ),
      );

      // Boot frame: refresh still pending -> spinner, login screen hidden.
      await refreshStarted.future;
      await tester.pump();
      expect(auth.isRestoringSession, isTrue);
      expect(find.byType(BootHoneycomb), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);

      // Restore resolves (refresh rejected): isRestoringSession must flip false
      // and the tree must swap the spinner for the login screen. A regression
      // that leaves the spinner up (or never resolves) fails here.
      releaseRefresh.complete();
      // AuthScreen runs continuous background animation, so pumpAndSettle would
      // never quiesce — bounded-pump until the restore future has resolved.
      for (var i = 0; i < 20 && auth.isRestoringSession; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();

      expect(auth.isRestoringSession, isFalse);
      expect(auth.isLoggedIn, isFalse);
      expect(find.byType(BootHoneycomb), findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);
    },
  );
}
