// Visual harness for the real SettingsScreen (not part of flutter test).
// Sibling of contact_network_preview.dart / glass_preview.dart.
//
// Run: flutter run -d web-server --web-port 8097 \
//        -t tool/preview/settings_preview.dart
// Params: ?theme=cosmic|blue|dark|light|teal&locale=en|pl&textScale=1.6
//
// Mounts the REAL screen against seeded providers, so the console rows, the
// local-node core and the bus are reviewable without a backend.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// (the harness seeds providers through their @visibleForTesting seams)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';

void main() => runApp(const SettingsPreviewApp());

ThemeData _theme(String name) => switch (name) {
  'cosmic' => RpgTheme.themeDataCosmic,
  'blue' => RpgTheme.themeDataBlue,
  'light' => RpgTheme.themeDataLight,
  'teal' => RpgTheme.themeDataTealStone,
  _ => RpgTheme.themeDataDarkGray,
};

class SettingsPreviewApp extends StatelessWidget {
  const SettingsPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final query = Uri.base.queryParameters;
    final themeName = query['theme'] ?? 'cosmic';
    final textScale = double.tryParse(query['textScale'] ?? '') ?? 1;

    String b64(Map<String, Object> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final auth = AuthProvider()
      ..setAccessTokenForTest(
        '${b64({'alg': 'none'})}.'
        '${b64({'sub': 700, 'username': 'Marta', 'tag': '0007', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.x',
      );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => ConnectionProvider()),
        ChangeNotifierProvider(create: (_) => EncryptionProvider()),
        ChangeNotifierProvider(
          // Seeded from ?theme= so the Appearance row's summary agrees with
          // the surface it is drawn on.
          create: (_) => SettingsProvider(initialThemePreference: themeName),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(themeName),
        locale: Locale(query['locale'] ?? 'en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const SettingsScreen(),
      ),
    );
  }
}
