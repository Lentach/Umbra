import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'glass_theme.dart';
import 'cosmic_theme.dart';

/// Theme-specific colors for chat UI. Use via `Theme.of(context).extension<FireplaceColors>()!`
class FireplaceColors extends ThemeExtension<FireplaceColors> {
  final Color inputBg;
  final Color convItemBorder;
  final Color convItemBg;
  final Color messagesAreaBg;
  final Color mineMsgBg;
  final Color theirsMsgBg;
  final Color settingsTileBg;
  final Color settingsTileBorder;
  final Color tabBorder;
  final Color borderColor;
  final Color mutedText;

  const FireplaceColors({
    required this.inputBg,
    required this.convItemBorder,
    required this.convItemBg,
    required this.messagesAreaBg,
    required this.mineMsgBg,
    required this.theirsMsgBg,
    required this.settingsTileBg,
    required this.settingsTileBorder,
    required this.tabBorder,
    required this.borderColor,
    required this.mutedText,
  });

  static FireplaceColors of(BuildContext context) =>
      Theme.of(context).extension<FireplaceColors>()!;

  @override
  FireplaceColors copyWith({
    Color? inputBg,
    Color? convItemBorder,
    Color? convItemBg,
    Color? messagesAreaBg,
    Color? mineMsgBg,
    Color? theirsMsgBg,
    Color? settingsTileBg,
    Color? settingsTileBorder,
    Color? tabBorder,
    Color? borderColor,
    Color? mutedText,
  }) => FireplaceColors(
    inputBg: inputBg ?? this.inputBg,
    convItemBorder: convItemBorder ?? this.convItemBorder,
    convItemBg: convItemBg ?? this.convItemBg,
    messagesAreaBg: messagesAreaBg ?? this.messagesAreaBg,
    mineMsgBg: mineMsgBg ?? this.mineMsgBg,
    theirsMsgBg: theirsMsgBg ?? this.theirsMsgBg,
    settingsTileBg: settingsTileBg ?? this.settingsTileBg,
    settingsTileBorder: settingsTileBorder ?? this.settingsTileBorder,
    tabBorder: tabBorder ?? this.tabBorder,
    borderColor: borderColor ?? this.borderColor,
    mutedText: mutedText ?? this.mutedText,
  );

  @override
  FireplaceColors lerp(
    covariant ThemeExtension<FireplaceColors>? other,
    double t,
  ) {
    if (other is! FireplaceColors) return this;
    return FireplaceColors(
      inputBg: Color.lerp(inputBg, other.inputBg, t)!,
      convItemBorder: Color.lerp(convItemBorder, other.convItemBorder, t)!,
      convItemBg: Color.lerp(convItemBg, other.convItemBg, t)!,
      messagesAreaBg: Color.lerp(messagesAreaBg, other.messagesAreaBg, t)!,
      mineMsgBg: Color.lerp(mineMsgBg, other.mineMsgBg, t)!,
      theirsMsgBg: Color.lerp(theirsMsgBg, other.theirsMsgBg, t)!,
      settingsTileBg: Color.lerp(settingsTileBg, other.settingsTileBg, t)!,
      settingsTileBorder: Color.lerp(
        settingsTileBorder,
        other.settingsTileBorder,
        t,
      )!,
      tabBorder: Color.lerp(tabBorder, other.tabBorder, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
    );
  }
}

class RpgTheme {
  static const Color boxBg = Color(0xFF0F0F3D);
  static const Color textColor = Color(0xFFE0E0E0);
  static const Color mutedText = Color(0xFF6A6AB0);
  static const Color errorColor = Color(0xFFFF4444);
  // Light-theme destructive red (warm brick; ~5.9:1 on white both directions).
  static const Color errorColorLight = Color(0xFFC0392B);
  static const Color successColor = Color(0xFF44FF44);
  // Light-theme success green (green-800; ~6.4:1 on white, ~5.9:1 on the
  // Hot Stone paper #F7F4F0). The neon successColor is dark-surface-only.
  static const Color successColorLight = Color(0xFF166534);

  // Telegram-style blue theme (default dark) – official Telegram colors
  // Background: #17212B, accent: #2AABEE, sent bubble: #2481CC, received: #2B2B2B
  static const Color backgroundBlue = Color(0xFF17212B);
  static const Color boxBgBlue = Color(0xFF1E2D3A);
  static const Color inputBgBlue = Color(0xFF1E2D3A);
  static const Color textColorBlue = Color(0xFFE4E4E4);
  // SPEC.md §4 blue off-glass muted. The former 0xFF8A8A8A was a drift from the
  // accepted spec and measured only 4.08:1 on the opaque row fill 0xFF1E2D3A —
  // under the 4.5:1 gate. This value measures 4.85:1 on that fill and 5.6:1 on the
  // messages-area background.
  static const Color mutedTextBlue = Color(0xFF8A9BA8);
  static const Color messagesAreaBgBlue = Color(0xFF17212B);
  static const Color mineMsgBgBlue = Color(
    0xFF2481CC,
  ); // sent bubble (Telegram blue, slightly darker for dark mode)
  static const Color theirsMsgBgBlue = Color(
    0xFF2B2B2B,
  ); // received bubble (dark gray)
  static const Color accentBlue = Color(0xFF2AABEE); // Telegram official blue
  static const Color accentBlueDark = Color(0xFF229ED9); // alternative/hover
  static const Color borderBlue = Color(0xFF3D5A6B);
  static const Color buttonBgBlue = Color(0xFF2AABEE);
  static const Color activeTabBgBlue = Color(0xFF1E3A4A);
  static const Color tabBorderBlue = Color(0xFF3D5A6B);
  static const Color convItemBorderBlue = Color(0xFF2B3B45);
  static const Color convItemBgBlue = Color(0xFF1E2D3A);
  static const Color timeColorBlue = Color(0xFF8A9BA8);
  static Color get settingsTileBgBlue => accentBlue.withValues(alpha: 0.12);
  static const Color settingsTileBorderBlue = Color(0xFF3D5A6B);

  // Dark mode – primary accent, borders, muted (Wire-style dark gray theme uses these)
  static const Color accentDark = Color(0xFFFF6666);
  static const Color borderDark = Color(0xFFCC5555);
  static const Color mutedDark = Color(0xFF9A8A8A);
  static const Color buttonBgDark = Color(0xFF8A3333);
  static const Color activeTabBgDark = Color(0xFF3D2525);
  static const Color tabBorderDark = Color(0xFF8A5555);
  static const Color convItemBorderDark = Color(0xFF5A3535);
  static const Color convItemBgDark = Color(0xFF1E1515);
  static const Color timeColorDark = Color(0xFF9A7A7A);
  static Color get settingsTileBgDark => accentDark.withValues(alpha: 0.1);
  static const Color settingsTileBorderDark = accentDark;

  // Dark gray theme (Wire-style) – neutral grays
  static const Color backgroundDarkGray = Color(0xFF17181A);
  static const Color boxBgDarkGray = Color(0xFF25262B);
  static const Color inputBgDarkGray = Color(0xFF1E1F23);
  static const Color textColorDarkGray = Color(0xFFF5F5F5);
  static const Color accentDarkGray = Color(0xFF5C9EAD);
  static const Color mutedDarkGray = Color(0xFF949798);
  static const Color convItemBorderDarkGray = Color(0xFF34383B);
  static const Color convItemBgDarkGray = Color(0xFF1E1F23);
  static const Color tabBorderDarkGray = Color(0xFF34383B);
  static const Color messagesAreaBgDarkGray = Color(0xFF17181A);
  static const Color mineMsgBgDarkGray = Color(0xFF2A4A5A);
  static const Color theirsMsgBgDarkGray = Color(0xFF25262B);
  static const Color activeTabBgDarkGray = Color(0xFF2C2E33);
  static const Color timeColorDarkGray = Color(0xFF949798);
  static const Color settingsTileBorderDarkGray = Color(0xFF5C9EAD);

  // Light theme — warm paper neutrals + ember accent (Fireplace brand, not Slack purple)
  static const Color primaryLight = Color(
    0xFFC2410C,
  ); // orange-700, white onPrimary
  static const Color primaryLightHover = Color(0xFF9A3412); // orange-800
  static const Color backgroundLight = Color(0xFFF7F4F0);
  static const Color boxBgLight = Color(0xFFFFFFFF);
  static const Color chatAreaBgLight = Color(0xFFFAF8F5);
  static const Color textColorLight = Color(0xFF1C1917); // warm near-black
  static const Color textSecondaryLight = Color(0xFF57534E); // stone-600
  static const Color mutedTextLight = Color(0xFF78716C); // stone-500
  static const Color labelTextLight = Color(0xFF57534E);
  static const Color inputBgLight = Color(0xFFF5F0EB);
  static const Color tabBorderLight = Color(0xFFE8E3DC);
  static const Color activeTabBgLight = Color(0xFFF0E8E0);
  static const Color buttonBgLight = primaryLight;
  static const Color convItemBgLight = Color(0xFFFAF6F2);
  static const Color convItemBorderLight = Color(0xFFE8E3DC);
  static const Color messagesAreaBgLight = Color(0xFFFAF8F5);
  // Sent = warm tint (not solid primary): dark text + delivery ticks stay visible.
  // Received = neutral warm gray (no purple tint).
  static const Color mineMsgBgLight = Color(0xFFFFE4D6); // orange-100
  static const Color theirsMsgBgLight = Color(0xFFE7E5E4);
  static const Color timeColorLight = Color(0xFF57534E);

  // Teal + stone (modern light): same accent family as dark-gray #5C9EAD, deeper teal on UI chrome.
  static const Color primaryTealStone = Color(0xFF0F766E); // teal-700
  static const Color secondaryTealStone = Color(0xFF0D9488); // teal-600
  static const Color backgroundTealStone = Color(0xFFFAFAF9); // stone-50
  static const Color surfaceTealStone = Color(0xFFFFFFFF);
  static const Color textColorTealStone = Color(0xFF1C1917); // stone-900
  static const Color borderTealStone = Color(0xFFE7E5E4); // stone-200
  static const Color mutedTealStone = Color(0xFF78716C); // stone-500
  static const Color inputBgTealStone = Color(0xFFF5F5F4); // stone-100
  static const Color convItemBgTealStone = Color(0xFFFAFAF9);
  static const Color messagesAreaTealStone = Color(0xFFFAFAF9);
  static const Color mineMsgBgTealStone = secondaryTealStone;
  static const Color theirsMsgBgTealStone = borderTealStone;
  static const Color activeTabBgTealStone = Color(0xFFF0FDFA); // teal-50
  static const Color settingsTileBorderTealStone = borderTealStone;

  // Cosmic (dark) — from the landing starfield hero
  // (landing/src/styles/landing.css :root/.phone/.enc). Site-EXACT: accent
  // #8fd8ff (--ice), blue #1d6fd6 (--blue + .me), text #eef6fb (--txt), input
  // #0b1017 (--ink), conv bg #0a0f16 (.phone .screen), borders #1a2531 (.bar),
  // theirs #16222e (.them). DERIVED for app-only chrome the site has no
  // equivalent for (appbar/scaffold/active-tab/muted): extrapolated from the
  // site's near-#000 space + ink, contrast-gated — NOT 1:1.
  static const Color accentCosmic = Color(0xFF8FD8FF); // --ice (site)
  static const Color secondaryCosmic = Color(0xFF1D6FD6); // --blue (site)
  static const Color backgroundCosmic = Color(
    0xFF05070D,
  ); // derived: deep space chrome
  static const Color surfaceCosmic = Color(
    0xFF0F1926,
  ); // derived: appbar/card lift
  static const Color messagesAreaBgCosmic = Color(
    0xFF04060C,
  ); // derived: near-#000 starfield base
  static const Color textColorCosmic = Color(0xFFEEF6FB); // --txt (site)
  static const Color mutedTextCosmic = Color(
    0xFF859096,
  ); // derived: txt·.55 flattened on base, ≥4.5:1
  static const Color mineMsgBgCosmic = Color(
    0xFF1D6FD6,
  ); // .phone .me (site; white 4.95:1)
  static const Color theirsMsgBgCosmic = Color(
    0xFF16222E,
  ); // .phone .them (site)
  static const Color inputBgCosmic = Color(0xFF0B1017); // --ink (site)
  static const Color tabBorderCosmic = Color(
    0xFF1A2531,
  ); // .phone .bar border (site)
  static const Color convItemBgCosmic = Color(
    0xFF0A0F16,
  ); // .phone .screen (site)
  static const Color convItemBorderCosmic = Color(
    0xFF1A2531,
  ); // .phone .bar border (site)
  static const Color activeTabBgCosmic = Color(
    0xFF12283A,
  ); // derived: ice-tinted selection
  static const Color settingsTileBorderCosmic = Color(
    0xFF1A2531,
  ); // .bar border (site)

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Clock label for message bubbles (server sends UTC; show device-local).
  static String formatMessageClock(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  /// Time + disappearing-message countdown on bubbles.
  /// Blue (Telegram) theme only: light meta on sent bubbles; `mutedText` on received.
  /// Dark gray / light themes keep the legacy single meta color (unchanged).
  static Color messageBubbleMetaColor(
    BuildContext context, {
    required bool isMine,
    required String themePreference,
  }) {
    if (themePreference == 'blue' ||
        themePreference == 'teal' ||
        themePreference == 'cosmic') {
      if (isMine) {
        return isDark(context)
            ? Colors.white.withValues(alpha: 0.86)
            : Colors.white.withValues(alpha: 0.9);
      }
      return FireplaceColors.of(context).mutedText;
    }
    final dark = isDark(context);
    return dark ? timeColorDark : textSecondaryLight;
  }

  /// Hearth Fade / disappearing-messages accent (composer banner, timer sheet hero,
  /// list arc). Light = ember orange; teal = [primaryTealStone]; dark/blue per theme.
  static Color ephemeralAccent(
    BuildContext context, {
    required String themePreference,
  }) {
    switch (themePreference) {
      case 'teal':
        return primaryTealStone;
      case 'light':
        return primaryLight;
      case 'blue':
        return accentBlue;
      case 'dark':
        return accentDarkGray;
      case 'cosmic':
        return accentCosmic;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  /// Delivery checkmarks: pale icons on dark sent bubbles (dark/blue + teal);
  /// light (ember) sent tint uses stone + ember read via [themePreference] `light`.
  static (Color pendingOrSent, Color read) messageBubbleDeliveryTickColors(
    BuildContext context, {
    required bool isMine,
    required String themePreference,
  }) {
    if (isMine &&
        themePreference == 'light' &&
        Theme.of(context).brightness == Brightness.light) {
      return (textSecondaryLight, primaryLight);
    }
    if (isMine && themePreference == 'teal') {
      return (
        Colors.white.withValues(alpha: 0.88),
        const Color(0xFFCCFBF1), // teal-100, read state on teal bubble
      );
    }
    return (const Color(0xFFE0E0E0), const Color(0xFF64B5F6));
  }

  static Color primaryColor(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static Color surfaceColor(BuildContext context) =>
      isDark(context) ? boxBg : boxBgLight;

  /// App chrome (AppBar, main tab headers): matches `bodyFont` / list typography (Inter).
  static TextStyle screenHeaderTitle({
    required Color color,
    double fontSize = 18,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: -0.25,
    );
  }

  static TextStyle bodyFont({
    double fontSize = 14,
    Color color = textColor,
    FontWeight fontWeight = FontWeight.normal,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
    );
  }

  /// White or black — whichever is WCAG-readable on [bg]. White wins only when
  /// it clears 4.5:1; bright accents (#2AABEE, #5C9EAD, #0D9488) get black.
  /// Exact contrast math on purpose: Flutter's estimateBrightnessForColor uses
  /// a laxer threshold and keeps white on fills where it fails 4.5:1.
  static Color readableOn(Color bg) {
    final whiteContrast = 1.05 / (bg.computeLuminance() + 0.05);
    return whiteContrast >= 4.5 ? Colors.white : Colors.black;
  }

  /// Blue theme – Telegram-style (dark blue background, blue accent + sent bubbles).
  static ThemeData get themeDataBlue => _buildTheme(_blueSpec);

  /// Dark gray theme – Wire-style neutral.
  static ThemeData get themeDataDarkGray => _buildTheme(_darkGraySpec);

  /// Light theme – warm paper neutrals + ember accent (Fireplace brand).
  static ThemeData get themeDataLight => _buildTheme(_lightSpec);

  /// Teal + stone – light modern messenger (stone neutrals, teal accent).
  static ThemeData get themeDataTealStone => _buildTheme(_tealStoneSpec);

  /// Cosmic – dark starfield (ported from the landing hero); ice accent.
  static ThemeData get themeDataCosmic => _buildTheme(_cosmicSpec);

  // ── Theme factory ────────────────────────────────────────────────────────
  // The four themes share one structure and differ only by a color set
  // ([_ThemeSpec]). Non-color metrics (radii, padding, font sizes/weights) live
  // here once. Golden-locked field-by-field per theme in
  // test/theme/rpg_theme_golden_test.dart.
  static ThemeData _buildTheme(_ThemeSpec s) {
    final base = s.brightness == Brightness.dark
        ? ThemeData.dark()
        : ThemeData.light();
    // Destructive red per brightness: #FF4444 needs a dark backdrop; on light
    // surfaces it fails contrast (~3.1:1), so light themes get brick red.
    final errorC = s.brightness == Brightness.dark
        ? errorColor
        : errorColorLight;
    final scheme = s.brightness == Brightness.dark
        ? ColorScheme.dark(
            primary: s.primary,
            secondary: s.secondary,
            surface: s.surface,
            error: errorC,
            onPrimary: s.onPrimary,
            onSecondary: s.onSecondary,
            onSurface: s.onSurface,
            // Bright #FF4444 fill needs a DARK label (white on it is ~3.4:1).
            onError: Colors.black,
          )
        : ColorScheme.light(
            primary: s.primary,
            secondary: s.secondary,
            surface: s.surface,
            error: errorC,
            onPrimary: s.onPrimary,
            onSecondary: s.onSecondary,
            onSurface: s.onSurface,
            onError: Colors.white,
          );
    final fc = s.fireplace;
    return base.copyWith(
      scaffoldBackgroundColor: s.background,
      colorScheme: scheme,
      popupMenuTheme: PopupMenuThemeData(
        color: s.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: s.surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: s.primary,
          letterSpacing: -0.25,
        ),
        iconTheme: IconThemeData(color: s.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fc.inputBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: fc.tabBorder, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: fc.tabBorder, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: s.primary, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: errorC, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        hintStyle: GoogleFonts.inter(color: s.hint, fontSize: 14),
        labelStyle: GoogleFonts.inter(color: s.label, fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: s.buttonBg,
          foregroundColor: readableOn(s.buttonBg),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: s.buttonSide, width: 2),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: s.primary,
          textStyle: GoogleFonts.inter(fontSize: 14),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: s.fab,
        foregroundColor: readableOn(s.fab),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        tileColor: Colors.transparent,
        selectedTileColor: s.selectedTile,
      ),
      dividerTheme: DividerThemeData(color: fc.convItemBorder, thickness: 1),
      textTheme: TextTheme(
        bodyLarge: GoogleFonts.inter(color: s.onSurface, fontSize: 16),
        bodyMedium: GoogleFonts.inter(color: s.onSurface, fontSize: 14),
        bodySmall: GoogleFonts.inter(color: fc.mutedText, fontSize: 12),
        titleLarge: GoogleFonts.inter(
          color: s.primary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.25,
        ),
        titleMedium: GoogleFonts.inter(
          color: s.onSurface,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: GoogleFonts.inter(
          color: s.onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        labelLarge: GoogleFonts.inter(
          color: s.onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      extensions: [fc, s.glass, if (s.backdrop != null) s.backdrop!],
    );
  }

  static const _ThemeSpec _blueSpec = _ThemeSpec(
    brightness: Brightness.dark,
    background: backgroundBlue,
    primary: accentBlue,
    secondary: accentBlueDark,
    surface: boxBgBlue,
    // Telegram-blue accents are too bright for white (2.6:1 / 3.0:1).
    onPrimary: Colors.black,
    onSecondary: Colors.black,
    onSurface: textColorBlue,
    hint: mutedTextBlue,
    label: mutedTextBlue,
    buttonBg: buttonBgBlue,
    buttonSide: accentBlue,
    fab: accentBlue,
    selectedTile: activeTabBgBlue,
    fireplace: FireplaceColors(
      inputBg: inputBgBlue,
      convItemBorder: convItemBorderBlue,
      convItemBg: convItemBgBlue,
      messagesAreaBg: messagesAreaBgBlue,
      mineMsgBg: mineMsgBgBlue,
      theirsMsgBg: theirsMsgBgBlue,
      settingsTileBg: boxBgBlue,
      settingsTileBorder: settingsTileBorderBlue,
      tabBorder: tabBorderBlue,
      borderColor: borderBlue,
      mutedText: mutedTextBlue,
    ),
    glass: GlassTheme.blue,
  );

  static const _ThemeSpec _darkGraySpec = _ThemeSpec(
    brightness: Brightness.dark,
    background: backgroundDarkGray,
    primary: accentDarkGray,
    secondary: accentDarkGray,
    surface: boxBgDarkGray,
    onPrimary: backgroundDarkGray,
    onSecondary: backgroundDarkGray,
    onSurface: textColorDarkGray,
    hint: mutedDarkGray,
    label: mutedDarkGray,
    buttonBg: accentDarkGray,
    buttonSide: accentDarkGray,
    fab: accentDarkGray,
    selectedTile: activeTabBgDarkGray,
    fireplace: FireplaceColors(
      inputBg: inputBgDarkGray,
      convItemBorder: convItemBorderDarkGray,
      convItemBg: convItemBgDarkGray,
      messagesAreaBg: messagesAreaBgDarkGray,
      mineMsgBg: mineMsgBgDarkGray,
      theirsMsgBg: theirsMsgBgDarkGray,
      settingsTileBg: Color(0xFF25262B),
      settingsTileBorder: settingsTileBorderDarkGray,
      tabBorder: tabBorderDarkGray,
      borderColor: accentDarkGray,
      mutedText: mutedDarkGray,
    ),
    glass: GlassTheme.dark,
  );

  static const _ThemeSpec _lightSpec = _ThemeSpec(
    brightness: Brightness.light,
    background: backgroundLight,
    primary: primaryLight,
    secondary: primaryLightHover,
    surface: boxBgLight,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: textColorLight,
    hint: mutedTextLight,
    label: labelTextLight,
    buttonBg: primaryLight,
    buttonSide: primaryLight,
    fab: primaryLight,
    selectedTile: activeTabBgLight,
    fireplace: FireplaceColors(
      inputBg: inputBgLight,
      convItemBorder: convItemBorderLight,
      convItemBg: convItemBgLight,
      messagesAreaBg: messagesAreaBgLight,
      mineMsgBg: mineMsgBgLight,
      theirsMsgBg: theirsMsgBgLight,
      settingsTileBg: boxBgLight,
      settingsTileBorder: convItemBorderLight,
      tabBorder: tabBorderLight,
      borderColor: primaryLight,
      mutedText: textSecondaryLight,
    ),
    glass: GlassTheme.light,
  );

  static const _ThemeSpec _tealStoneSpec = _ThemeSpec(
    brightness: Brightness.light,
    background: backgroundTealStone,
    primary: primaryTealStone,
    secondary: secondaryTealStone,
    surface: surfaceTealStone,
    onPrimary: Colors.white,
    onSecondary: Colors.black,
    onSurface: textColorTealStone,
    hint: mutedTealStone,
    label: mutedTealStone,
    buttonBg: secondaryTealStone,
    buttonSide: secondaryTealStone,
    fab: secondaryTealStone,
    selectedTile: activeTabBgTealStone,
    fireplace: FireplaceColors(
      inputBg: inputBgTealStone,
      convItemBorder: borderTealStone,
      convItemBg: convItemBgTealStone,
      messagesAreaBg: messagesAreaTealStone,
      mineMsgBg: mineMsgBgTealStone,
      theirsMsgBg: theirsMsgBgTealStone,
      settingsTileBg: surfaceTealStone,
      settingsTileBorder: settingsTileBorderTealStone,
      tabBorder: borderTealStone,
      borderColor: primaryTealStone,
      mutedText: mutedTealStone,
    ),
    glass: GlassTheme.teal,
  );

  static const _ThemeSpec _cosmicSpec = _ThemeSpec(
    brightness: Brightness.dark,
    background: backgroundCosmic,
    primary: accentCosmic,
    secondary: secondaryCosmic,
    surface: surfaceCosmic,
    // Ice #8FD8FF is too bright for white (1.6:1) → black foreground.
    onPrimary: Colors.black,
    onSecondary: Colors.white, // white on #1D6FD6 is 4.95:1
    onSurface: textColorCosmic,
    hint: mutedTextCosmic,
    label: mutedTextCosmic,
    buttonBg: accentCosmic,
    buttonSide: accentCosmic,
    fab: accentCosmic,
    selectedTile: activeTabBgCosmic,
    fireplace: FireplaceColors(
      inputBg: inputBgCosmic,
      convItemBorder: convItemBorderCosmic,
      convItemBg: convItemBgCosmic,
      messagesAreaBg: messagesAreaBgCosmic,
      mineMsgBg: mineMsgBgCosmic,
      theirsMsgBg: theirsMsgBgCosmic,
      settingsTileBg: surfaceCosmic,
      settingsTileBorder: settingsTileBorderCosmic,
      tabBorder: tabBorderCosmic,
      borderColor: secondaryCosmic,
      mutedText: mutedTextCosmic,
    ),
    glass: GlassTheme.cosmic,
    backdrop: CosmicBackdrop.starfield,
  );

  static InputDecoration rpgInputDecoration({
    String? hintText,
    IconData? prefixIcon,
    BuildContext? context,
  }) {
    final iconColor = context != null
        ? (Theme.of(context).extension<FireplaceColors>()?.mutedText ??
              (isDark(context) ? mutedDark : textSecondaryLight))
        : mutedText;
    return InputDecoration(
      hintText: hintText,
      prefixIcon: prefixIcon != null
          ? Icon(prefixIcon, color: iconColor, size: 20)
          : null,
    );
  }
}

/// Immutable per-theme color set consumed by [RpgTheme._buildTheme]. Holds only
/// what differs between the four themes; shared structure/metrics live in the
/// factory. Field-by-field golden-locked in test/theme/rpg_theme_golden_test.dart.
class _ThemeSpec {
  final Brightness brightness;
  final Color background;
  final Color primary;
  final Color secondary;
  final Color surface;
  final Color onPrimary;
  final Color onSecondary;
  final Color onSurface;
  final Color hint;
  final Color label;
  final Color buttonBg;
  final Color buttonSide;
  final Color fab;
  final Color selectedTile;
  final FireplaceColors fireplace;
  final GlassTheme glass;
  final CosmicBackdrop? backdrop;

  const _ThemeSpec({
    required this.brightness,
    required this.background,
    required this.primary,
    required this.secondary,
    required this.surface,
    required this.onPrimary,
    required this.onSecondary,
    required this.onSurface,
    required this.hint,
    required this.label,
    required this.buttonBg,
    required this.buttonSide,
    required this.fab,
    required this.selectedTile,
    required this.fireplace,
    required this.glass,
    this.backdrop,
  });
}
