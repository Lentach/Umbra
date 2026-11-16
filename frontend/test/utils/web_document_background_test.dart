import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/utils/web_document_background.dart';

void main() {
  group('webDocumentBackgroundCss', () {
    test('drops the alpha channel (document backgrounds are opaque)', () {
      // Same RGB as the dark scaffold but half-transparent -> alpha ignored.
      expect(webDocumentBackgroundCss(const Color(0x8017181A)), '#17181a');
      expect(webDocumentBackgroundCss(const Color(0x00FFFFFF)), '#ffffff');
    });

    test('zero-pads to six lowercase hex digits', () {
      expect(webDocumentBackgroundCss(const Color(0xFF00010A)), '#00010a');
      expect(webDocumentBackgroundCss(const Color(0xFF0000FF)), '#0000ff');
    });

    // The real contract: web/index.html paints the document for FIRST PAINT
    // (before Flutter boots) and must match the DEFAULT theme scaffold —
    // Hot Stone ('light', warm paper) since 2026-07-28 — otherwise the
    // Android keyboard-hide reclaimed strip flashes the wrong color. Parse
    // the actual file so drift on either side breaks the test. CSS hex is
    // case-insensitive, so compare lowercased.
    test(
        'index.html first-paint background matches the default Hot Stone scaffold',
        () {
      final html = File('web/index.html').readAsStringSync();
      final match =
          RegExp(r'background-color:\s*(#[0-9a-fA-F]{6})').firstMatch(html);
      expect(
        match,
        isNotNull,
        reason: 'index.html must ship a static html/body background-color',
      );
      final indexCss = match!.group(1)!.toLowerCase();

      expect(indexCss, webDocumentBackgroundCss(RpgTheme.backgroundLight));
      expect(indexCss, '#f7f4f0'); // documented default (Hot Stone)
    });

    // Same contract for the PWA manifest: background_color paints the splash
    // and theme_color the Android task-switcher/browser chrome. index.html's
    // test alone missed these on the 2026-07-28 default flip — assert both so
    // the next default change cannot ship a dark splash into a light app.
    test('manifest.json splash colors match the default Hot Stone scaffold',
        () {
      final manifest = File('web/manifest.json').readAsStringSync();
      final expected = webDocumentBackgroundCss(RpgTheme.backgroundLight);
      for (final key in ['background_color', 'theme_color']) {
        final match = RegExp(
          '"$key":\\s*"(#[0-9a-fA-F]{6})"',
        ).firstMatch(manifest);
        expect(match, isNotNull, reason: 'manifest.json must declare $key');
        expect(
          match!.group(1)!.toLowerCase(),
          expected,
          reason: '$key must match the default theme scaffold',
        );
      }
    });

    // The pre-paint bootstrap script maps each saved theme to its scaffold
    // hex so returning users don't flash the fresh-install default during
    // bundle load. Those hexes are hand-copied into index.html — assert each
    // against the real RpgTheme scaffold so palette drift breaks the build.
    // Also assert the script never uses !important: the runtime sync writes
    // INLINE styles, and an author !important rule would beat them.
    test('index.html bootstrap theme map matches RpgTheme scaffolds', () {
      final html = File('web/index.html').readAsStringSync();
      final expected = <String, Color>{
        'dark': RpgTheme.backgroundDarkGray,
        'blue': RpgTheme.backgroundBlue,
        'cosmic': RpgTheme.backgroundCosmic,
        'teal': RpgTheme.backgroundTealStone,
        'light': RpgTheme.backgroundLight,
      };
      for (final entry in expected.entries) {
        final match = RegExp(
          "${entry.key}:\\s*'(#[0-9a-fA-F]{6})'",
        ).firstMatch(html);
        expect(
          match,
          isNotNull,
          reason: 'bootstrap script must map theme "${entry.key}"',
        );
        expect(
          match!.group(1)!.toLowerCase(),
          webDocumentBackgroundCss(entry.value),
          reason: '"${entry.key}" bootstrap hex drifted from RpgTheme',
        );
      }
      // The script must mirror the Dart legacy ladder: the migration never
      // writes theme_preference back, so dark_mode_preference-only devices
      // exist indefinitely and would otherwise flash the fresh-install
      // default.
      expect(
        html.contains('flutter.dark_mode_preference'),
        isTrue,
        reason: 'bootstrap script must honor the legacy theme key',
      );
      // Match the CSS-rule shape only (the script's own comment may MENTION
      // the flag): an author !important background rule would beat the
      // runtime INLINE theme sync and pin the bootstrap color forever.
      expect(
        RegExp(r'background-color[^;}]*!important').hasMatch(html),
        isFalse,
        reason: 'author !important would beat the runtime inline theme sync',
      );
    });

    // The privacy curtain's padlock is stroked in the theme accent at boot,
    // from a second hand-copied map. Same drift risk, same pin — and the
    // curtain must exist, be hidden by default, and sit above everything.
    test('index.html curtain accent map matches RpgTheme.ephemeralAccent', () {
      final html = File('web/index.html').readAsStringSync();
      final block = RegExp(r'var accents = \{([^}]*)\}').firstMatch(html);
      expect(block, isNotNull, reason: 'curtain script must define accents');
      final expected = <String, Color>{
        'dark': RpgTheme.accentDarkGray,
        'blue': RpgTheme.accentBlue,
        'cosmic': RpgTheme.accentCosmic,
        'teal': RpgTheme.primaryTealStone,
        'light': RpgTheme.primaryLight,
      };
      for (final entry in expected.entries) {
        final match = RegExp(
          "${entry.key}:\\s*'(#[0-9a-fA-F]{6})'",
        ).firstMatch(block!.group(1)!);
        expect(match, isNotNull, reason: 'accents must map "${entry.key}"');
        expect(
          match!.group(1)!.toLowerCase(),
          webDocumentBackgroundCss(entry.value),
          reason: '"${entry.key}" curtain accent drifted from RpgTheme',
        );
      }
      expect(html, contains('id="fp-curtain"'));
      expect(
        RegExp(r'#fp-curtain\s*\{[^}]*display:\s*none').hasMatch(html),
        isTrue,
        reason: 'the curtain is hidden until blur/boot shows it',
      );
      expect(html, contains("localStorage.getItem('flutter.passcode_enabled')"));
    });
  });

  // Native launch splashes must be pinned to the Hot Stone paper scaffold
  // (the default theme since 2026-07-28). Before this, drawable-v21 used
  // ?android:colorBackground — which follows OS dark mode — so dark-mode
  // devices flashed a dark splash straight into the always-light front door.
  // Parse the real resource files so drift on any side breaks the build.
  group('native launch backgrounds', () {
    test('Android colors.xml pins hot_stone_paper to the light scaffold', () {
      final xml = File(
        'android/app/src/main/res/values/colors.xml',
      ).readAsStringSync();
      final match = RegExp(
        r'<color name="hot_stone_paper">(#[0-9a-fA-F]{6})</color>',
      ).firstMatch(xml);
      expect(match, isNotNull, reason: 'hot_stone_paper resource must exist');
      expect(
        match!.group(1)!.toLowerCase(),
        webDocumentBackgroundCss(RpgTheme.backgroundLight),
      );
    });

    test('both Android launch backgrounds reference hot_stone_paper', () {
      for (final path in [
        'android/app/src/main/res/drawable/launch_background.xml',
        'android/app/src/main/res/drawable-v21/launch_background.xml',
      ]) {
        final xml = File(path).readAsStringSync();
        expect(
          xml.contains('android:drawable="@color/hot_stone_paper"'),
          isTrue,
          reason: '$path must pin the splash to the paper color '
              '(?android:colorBackground follows OS dark mode)',
        );
      }
    });

    test('iOS LaunchScreen background is the Hot Stone paper', () {
      final storyboard = File(
        'ios/Runner/Base.lproj/LaunchScreen.storyboard',
      ).readAsStringSync();
      final match = RegExp(
        r'<color key="backgroundColor" red="([\d.]+)" green="([\d.]+)" '
        r'blue="([\d.]+)"',
      ).firstMatch(storyboard);
      expect(match, isNotNull, reason: 'LaunchScreen must set backgroundColor');
      final r = (double.parse(match!.group(1)!) * 255).round();
      final g = (double.parse(match.group(2)!) * 255).round();
      final b = (double.parse(match.group(3)!) * 255).round();
      expect((r, g, b), (0xF7, 0xF4, 0xF0));
    });
  });
}
