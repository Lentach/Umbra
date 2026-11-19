import 'package:fireplace/config/app_version_info.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/chat_background_preference.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/connection_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/passcode_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/settings_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/appearance_preview.dart';
import 'package:fireplace/widgets/local_node_core.dart';
import 'package:fireplace/widgets/settings_console.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../support/passcode_fakes.dart';

Widget _host({
  Size size = const Size(390, 844),
  double textScale = 1,
  ThemeData? theme,
  // Seeds the PROVIDER's theme, which is what drives
  // `resolvedChatBackground` — distinct from `theme`, which is only the
  // ambient ThemeData. Cosmic is the one preference that resolves to a
  // non-plain background, so it is what makes the "no background in the hex"
  // assertion able to fail.
  String? themePreference,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => ConnectionProvider()),
      ChangeNotifierProvider(create: (_) => EncryptionProvider()),
      ChangeNotifierProvider(
        create: (_) =>
            SettingsProvider(initialThemePreference: themePreference),
      ),
      // The SECURITY section carries the Passcode Lock row.
      ChangeNotifierProvider(
        create: (_) => PasscodeProvider(
          store: MemoryPasscodeStore(),
          kdf: FakePasscodeKdf(),
        ),
      ),
    ],
    child: MaterialApp(
      theme: theme ?? RpgTheme.themeDataLight,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: const SettingsScreen(),
        ),
      ),
    ),
  );
}

class _FakeUrlLauncher extends UrlLauncherPlatform {
  String? launchedUrl;
  LaunchOptions? launchOptions;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    launchOptions = options;
    return true;
  }
}

Widget _settingsApp({Locale locale = const Locale('en')}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => ConnectionProvider()),
      ChangeNotifierProvider(create: (_) => EncryptionProvider()),
      ChangeNotifierProvider(create: (_) => SettingsProvider()),
      // The SECURITY section carries the Passcode Lock row.
      ChangeNotifierProvider(
        create: (_) => PasscodeProvider(
          store: MemoryPasscodeStore(),
          kdf: FakePasscodeKdf(),
        ),
      ),
    ],
    child: MaterialApp(
      theme: RpgTheme.themeDataLight,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SettingsScreen(),
    ),
  );
}

void main() {
  group('Settings console', () {
    testWidgets('the local node is the shared core, not a bare avatar', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      // The SAME widget the Contacts honeycomb core uses. If Settings ever
      // grows its own copy, the two drift and the tabs stop matching.
      expect(find.byType(LocalNodeCore), findsOneWidget);
      expect(find.text('LOCAL NODE'), findsOneWidget);
    });

    testWidgets('every section caption is upper-cased by the widget', (
      tester,
    ) async {
      // The Privacy screen reuses a screen TITLE as a caption
      // (`Privacy & Safety`) next to captions that come from already-caps
      // section keys (`SECURITY`), which put mixed casing on one rail. The
      // widget normalises so no call site can reintroduce it.
      await tester.pumpWidget(
        MaterialApp(
          theme: RpgTheme.themeDataLight,
          home: const Scaffold(
            body: SettingsSectionCaption(label: 'Privacy & Safety'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PRIVACY & SAFETY'), findsOneWidget);
      expect(find.text('Privacy & Safety'), findsNothing);
    });

    testWidgets('the Appearance row previews the theme without clipping it', (
      tester,
    ) async {
      // Two owner-reported bugs live here, one per axis, both caused by
      // `_AppearancePreviewScene` using ABSOLUTE insets while only bubble
      // WIDTH scales with the box.
      // Cosmic on purpose: it is the one preference whose
      // `resolvedChatBackground` is NOT plain, so passing the resolved value
      // through to the hex (the bug) makes the background assertion below
      // fail instead of silently agreeing.
      await tester.pumpWidget(_host(themePreference: 'cosmic'));
      await tester.pumpAndSettle();

      final preview = tester.widget<AppearancePreview>(
        find.byType(AppearancePreview),
      );

      // WIDTH — the miniature was drawn at 92 and centre-cropped to the 38px
      // terminal to hide its own border, which threw away precisely the
      // `left: 8` / `right: 8` strips that carry both bubble colours:
      // "most of the hex is on background color with little visible chat
      // bubble". Matching the terminal keeps the scene whole sideways, and
      // dropping the border removes the reason the crop existed.
      expect(preview.width, kConsoleHexWidth);
      expect(
        preview.showBorder,
        isFalse,
        reason: 'the hex terminal already paints a ring',
      );

      // HEIGHT — shrinking to the terminal's own 44 slid the composer bar up
      // through the lower bubble and painted over it: "green/blue bubble is
      // covered by bottom block". The bar spans `height - 13 .. height - 6`,
      // so it clears the bubble only while that top stays below
      // kPreviewContentBottom. Asserted as the INVARIANT, not as a literal,
      // so retuning either the height or the scene's insets still fails
      // loudly instead of silently re-covering the bubble.
      expect(
        preview.height - kPreviewComposerBottom - kPreviewComposerHeight,
        greaterThanOrEqualTo(kPreviewContentBottom),
        reason: 'the composer bar overlaps the lower bubble',
      );

      // BACKGROUND — owner call: "background in appearance hex is not really
      // needed". It also keeps the miniature on ONE geometry: the `glyphs`
      // layer renders its scene at 2x and FittedBoxes it back down, halving
      // every absolute offset, which would leave the bubbles half-height and
      // high in the terminal and silently invalidate the centring above.
      expect(
        preview.background,
        ChatBackgroundLayer.plain,
        reason:
            'the hex must not take a background layer that rescales '
            'the scene out from under the alignment maths',
      );
    });

    testWidgets('rows are console rows with no chevrons', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.byType(SettingsConsoleRow), findsWidgets);
      // The row IS the affordance. A chevron on every row was the Material
      // settings-list tell we removed.
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.text('PREFERENCES'), findsOneWidget);
      expect(find.text('SECURITY'), findsOneWidget);

      // The ListView is lazy, so SESSION is not an element until it scrolls in.
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('SESSION'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('only the destructive row carries the filled wash', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      // Delete/Log out live in SESSION, below the fold of a lazy ListView
      // ((lxxix) added the key-change warnings row above them).
      await tester.drag(find.byType(ListView), const Offset(0, -560));
      await tester.pumpAndSettle();

      final rows = tester
          .widgetList<SettingsConsoleRow>(find.byType(SettingsConsoleRow))
          .toList();
      final danger = rows
          .where((r) => r.edge == ConsoleRowEdge.danger)
          .toList();
      final accent = rows
          .where((r) => r.edge == ConsoleRowEdge.accent)
          .toList();

      // Exactly one destructive row (delete account). Log out is marked but
      // must NOT be washed: on the light themes `primary` is nearly the same
      // ember as `error`, so washing both merged them into one alarm block.
      expect(danger, hasLength(1));
      expect(accent, hasLength(1));

      Color? washOf(SettingsConsoleRow row) {
        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byWidget(row),
                matching: find.byType(Container),
              )
              .first,
        );
        return (container.decoration as BoxDecoration?)?.color;
      }

      expect(washOf(danger.single), isNotNull);
      expect(washOf(accent.single), isNull);
    });

    testWidgets('survives 320px at a 1.6 text scale without overflowing', (
      tester,
    ) async {
      // The language row's trailing chips are not flexible, so full language
      // names here used to crush the title into one letter per line. Same
      // viewport the Chats row-weight contracts are pinned at.
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(size: const Size(320, 700), textScale: 1.6),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('PL'), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
      // Not just "no overflow": a starved Expanded can wrap instead of
      // overflowing, which is the one-letter-per-line failure this test is
      // named for. Pin that the title still gets a usable line.
      expect(tester.getSize(find.text('Language')).width, greaterThan(80));
    });
  });

  group('Settings version footer', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
      AppVersionInfo.debugResetForTest();
      PackageInfo.setMockInitialValues(
        appName: 'fireplace',
        packageName: 'com.fireplace.app',
        version: '0.0.2',
        buildNumber: '42',
        buildSignature: '',
      );
    });

    testWidgets('SettingsScreen shows app version footer line', (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider(create: (_) => ConnectionProvider()),
            ChangeNotifierProvider(create: (_) => EncryptionProvider()),
            ChangeNotifierProvider(create: (_) => SettingsProvider()),
            // The SECURITY section carries the Passcode Lock row.
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
            home: const SettingsScreen(),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      final listView = find.byType(ListView);
      await tester.drag(listView, const Offset(0, -800));
      await tester.pumpAndSettle();

      expect(find.textContaining('0.0.2'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
      // The footer is `version · gitCommit`; a bare 'dev' also matches copy
      // that says "device".
      expect(find.textContaining('· dev'), findsOneWidget);
    });
  });

  group('Settings scroll physics and About link', () {
    testWidgets('SettingsScreen uses ClampingScrollPhysics for its ListView', (
      tester,
    ) async {
      await tester.pumpWidget(_settingsApp());

      await tester.pump();

      final listView = tester.widget<ListView>(find.byType(ListView).first);
      expect(listView.physics, isA<ClampingScrollPhysics>());
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byType(AppearancePreview), findsOneWidget);
      expect(find.text('Theme'), findsNothing);
      expect(find.text('Chat background'), findsNothing);
      expect(find.text('Starfield background'), findsNothing);
    });

    testWidgets('SettingsScreen shows a compact localized About link', (
      tester,
    ) async {
      final previousLauncher = UrlLauncherPlatform.instance;
      final fakeLauncher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = fakeLauncher;
      addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

      await tester.pumpWidget(_settingsApp());
      await tester.pump();

      final link = find.byKey(const Key('settings-about-fireplace-link'));
      await tester.scrollUntilVisible(
        link,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      await tester.pump();

      expect(find.text('About'), findsOneWidget);
      expect(tester.widget<InkWell>(link).onTap, isNotNull);
      await tester.tap(link);
      await tester.pump();
      expect(
        fakeLauncher.launchedUrl,
        'https://fireplace.ignorelist.com/welcome/',
      );
      expect(
        fakeLauncher.launchOptions?.mode,
        PreferredLaunchMode.externalApplication,
      );
      expect(
        find.descendant(
          of: link,
          matching: find.byIcon(Icons.north_east_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: link, matching: find.byIcon(Icons.public)),
        findsNothing,
      );
      expect(
        find.descendant(of: link, matching: find.byIcon(Icons.palette)),
        findsNothing,
      );
      expect(
        find.descendant(of: link, matching: find.byIcon(Icons.auto_awesome)),
        findsNothing,
      );
      expect(
        find.descendant(of: link, matching: find.byIcon(Icons.star)),
        findsNothing,
      );

      await tester.pumpWidget(_settingsApp(locale: const Locale('pl')));
      await tester.pump();
      await tester.scrollUntilVisible(
        link,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('O projekcie'), findsOneWidget);
    });
  });
}
