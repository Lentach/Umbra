import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Set by CI (`.github/workflows/ci.yml`, job `frontend-tests`), which builds
/// the native library with `dart run webcrypto:setup` before the services leg.
const requireNativeWebcryptoEnv = 'REQUIRE_NATIVE_WEBCRYPTO';

/// Call when a real-crypto test finds the native webcrypto library missing,
/// then `return`.
///
/// On a developer machine the test is reported as skipped (the Windows dev box
/// has no MSVC toolchain to build the library). When
/// [requireNativeWebcryptoEnv] is `1` the test FAILS instead, so in CI these
/// tests can only pass or fail: a runner image that loses the library turns
/// the leg red instead of quietly moving tests to "skipped".
///
/// Pass the exception the availability probe caught as [error]: with the
/// library present a genuine crypto failure must not be reported as a missing
/// library without showing the real cause.
void skipWithoutNativeWebcrypto([Object? error]) {
  final cause = error == null ? '' : ' Cause: $error';
  if (Platform.environment[requireNativeWebcryptoEnv] == '1') {
    fail(
      'webcrypto native unavailable, and $requireNativeWebcryptoEnv=1 forbids '
      'skipping: run `dart run webcrypto:setup` in frontend/ before the '
      'tests.$cause',
    );
  }
  markTestSkipped('webcrypto native unavailable.$cause');
}
