import 'package:fireplace/theme/rpg_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Plan C3: `main()` turns google_fonts' runtime fetching off, so a face
/// missing from `assets/google_fonts/` (or misnamed: the lookup is by file
/// name, case-sensitive) is not fetched but fails, and the text falls back to
/// the platform font.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('every face the app draws loads from the bundle, never the network', () async {
    // The theme's own styles (text theme, app bar, inputs, buttons)...
    expect(
      RpgTheme.themeDataLight.textTheme.bodyMedium?.fontFamily,
      startsWith('Inter'),
    );
    // ...every weight the screens pass to bodyFont / screenHeaderTitle...
    for (final weight in const [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
      FontWeight.w800,
    ]) {
      RpgTheme.bodyFont(fontWeight: weight);
    }
    // ...and the sign-in wordmark (auth_screen.dart).
    GoogleFonts.archivo(fontWeight: FontWeight.w900);

    await expectLater(GoogleFonts.pendingFonts(), completes);
  });
}
