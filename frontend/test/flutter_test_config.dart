import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file under `test/`.
///
/// Plan C3 bundles the app's fonts (`assets/google_fonts/`), so google_fonts
/// now loads real faces in tests too. Left to itself it loads each one
/// asynchronously at first use, so the first pumps of a file would measure
/// text in the test font and later ones in Inter: layout assertions would
/// depend on test order. Loading every face up front, as the app sees them,
/// makes every test measure the same text. It is also the bundle check: with
/// runtime fetching off (as `main()` sets it), a face missing from the
/// bundle, or misnamed (the lookup is by file name, case-sensitive), fails
/// every test file here instead of rendering in the platform font.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  // Every face the app draws: Inter at the weights the theme and screens use,
  // and the Archivo 900 sign-in wordmark (auth_screen.dart).
  for (final weight in const [
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ]) {
    GoogleFonts.inter(fontWeight: weight);
  }
  GoogleFonts.archivo(fontWeight: FontWeight.w900);
  await GoogleFonts.pendingFonts();
  await testMain();
}
