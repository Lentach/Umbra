// Glyph sheet (not part of `flutter test`).
//
// Run: flutter run -d web-server --web-port 8098 \
//        -t tool/preview/console_glyph_sheet.dart
// Params: ?theme=cosmic|blue|dark|light|teal
//
// Renders the Settings console glyph set big enough to judge the drawing,
// then the same glyphs in real rows at the size they actually ship at.
//
// The strip at the bottom is the honest view. A blow-up flatters fine
// line-work exactly where it fails on a phone, and this project already
// shipped one design that passed three themes in render and was wrong in the
// owner's hand — so the device still decides.
import 'package:flutter/material.dart';

import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/settings_console.dart';

void main() => runApp(const GlyphSheetApp());

ThemeData _theme(String name) => switch (name) {
  'cosmic' => RpgTheme.themeDataCosmic,
  'blue' => RpgTheme.themeDataBlue,
  'light' => RpgTheme.themeDataLight,
  'teal' => RpgTheme.themeDataTealStone,
  _ => RpgTheme.themeDataDarkGray,
};

/// Rows the owner actually sees, so the set is judged in context and not as
/// an isolated art object.
const _contextRows = <(ConsoleGlyph, String, String?, ConsoleRowEdge)>[
  (ConsoleGlyph.appearance, 'Appearance', 'Cosmic', ConsoleRowEdge.none),
  (ConsoleGlyph.language, 'Language', null, ConsoleRowEdge.none),
  (ConsoleGlyph.privacy, 'Privacy & Safety', null, ConsoleRowEdge.none),
  (ConsoleGlyph.blocked, 'Blocked', null, ConsoleRowEdge.none),
  (ConsoleGlyph.devices, 'Devices', 'Web Browser', ConsoleRowEdge.none),
  (
    ConsoleGlyph.push,
    'Enable notifications',
    'Get notified when a message arrives',
    ConsoleRowEdge.none,
  ),
  (ConsoleGlyph.password, 'Reset password', null, ConsoleRowEdge.none),
  (ConsoleGlyph.deleteNode, 'Delete account', null, ConsoleRowEdge.danger),
  (ConsoleGlyph.logout, 'Log out', null, ConsoleRowEdge.accent),
];

class GlyphSheetApp extends StatelessWidget {
  const GlyphSheetApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeName = Uri.base.queryParameters['theme'] ?? 'cosmic';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(themeName),
      home: _Sheet(themeName: themeName),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.themeName});

  final String themeName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SETTINGS CONSOLE GLYPHS — ${themeName.toUpperCase()}',
              style: RpgTheme.bodyFont(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ).copyWith(letterSpacing: 2),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 18,
              children: [
                for (final glyph in ConsoleGlyph.values) _Cell(glyph: glyph),
              ],
            ),
            const SizedBox(height: 40),
            Text(
              'TRUE SIZE — HOW IT ACTUALLY SHIPS',
              style: RpgTheme.bodyFont(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurfaceVariant,
              ).copyWith(letterSpacing: 1.6),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 390,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in _contextRows)
                    SettingsConsoleRow(
                      glyph: row.$1,
                      title: row.$2,
                      subtitle: row.$3,
                      edge: row.$4,
                      onTap: () {},
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.glyph});

  final ConsoleGlyph glyph;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 128,
      child: Column(
        children: [
          ConsoleHexIcon(glyph: glyph, height: 96),
          const SizedBox(height: 8),
          Text(
            glyph.name,
            textAlign: TextAlign.center,
            style: RpgTheme.bodyFont(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
