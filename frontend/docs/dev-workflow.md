# Frontend dev workflow reference

Detail relocated from `frontend/CLAUDE.md` §1 (Commands) on 2026-09-24 to keep that file under its context budget. Each heading below is the target of a one-line rule in `frontend/CLAUDE.md` §1; the rule there binds, this file explains it. Text is moved verbatim unless noted.

## Targeted test examples

```powershell
cd frontend
flutter test test/utils/instant_opaque_route_test.dart
flutter test test/services/api_service_media_url_test.dart
flutter test test/providers/message_editing_test.dart
```

## Test-run cost curve

**Test-run cost curve (measured 2026-07-27 on the dev PC) — pick the right scope, and never a file list:**

| Scope | Tests | Wall |
|---|---|---|
| one file | 1 | **7 s** |
| one directory (`test/utils`) | 175 | **21 s** |
| full suite (`flutter test`) | 960 | **170–310 s** |
| **45 explicit files on one command line** | ~45 | **timed out past 11 min — ≥5× the FULL suite** |

`flutter test` appears to pay a compile cost **per argument** rather than once per run, so a
long explicit file list is pathologically slow: running *everything* is dramatically faster
than running a "smart" subset. Iterate on one file or one directory, then run the full suite
before a commit or PR (still required by project policy).

**Do NOT build a "run only the affected tests" runner on top of `scripts/impact.mjs`.** It was
tried and measured on 2026-07-27 and it is strictly worse than `flutter test`. `impact.mjs`'s
test list is for knowing *what you touched*, never for feeding to `flutter test`.

## E2E wire harness

Full-stack E2E wire harness (`test_e2e/` — a sibling of `test/`, so the DEFAULT suite never picks it up; needs a live backend). As of 2026-07-27 it runs in CI as the `e2e-wire` job against a real Postgres + backend, and a failure now turns the CI run red (it is no longer `continue-on-error`). It is the only automated check that client and server still agree on the wire — it caught two disaster-recovery bugs on its first two runs. Red is not a mechanical gate on this repo, so check the run yourself. Locally:

```powershell
docker-compose up            # repo root, separate terminal
cd frontend
flutter test test_e2e
```

Two headless accounts run the REAL `ApiService`+`SocketService`+`EncryptionService` (real libsignal) against the local backend: register → WS key upload → friendship → conversation → PreKey(3:)/whisper(2:) round trips → mid-conversation session rebuild → edit → reactions, asserting decryption both ends. Fresh accounts every run BY DESIGN (server keeps old unused OTPs oldest-first; reuse ⇒ phantom bad-MAC). Register throttle 10/hr/IP is in-memory — `docker compose restart backend` resets it. The harness resets the flutter_test binding's HTTP-blocking `HttpOverrides` globally (`enableRealNetwork()`); found the burned-but-never-served OTP backend bug on its first run.

## On-device acceptance

On-device acceptance (`integration_test/` — also a sibling of `test/`, so the default suite never
picks it up; needs a running emulator or phone, and CANNOT run in CI). Four files; two carry the
E2E-critical reasons to exist:

- `native_content_store_device_test.dart` (8 tests) — the encrypted content store. The only check
  that exercises the REAL Android Keystore, the REAL SQLCipher `.so` from the APK and the REAL
  native webcrypto — the host VM has no webcrypto native (no MSVC), so those crypto assertions are
  `skip`ped in `flutter test` and only run here. Re-run after touching anything under
  `lib/services/encryption/`, `auth_token_store.dart`, or the audio seal path. **Destructive and
  LAST on purpose:** its final test destroys every content key in the real Keystore.
- `identity_recovery_durability_device_test.dart` (4 tests) — amendments (xlviii)/(xlix). Every
  property it asserts is a PERSISTENCE property, and the unit suite proves them against
  `SharedPreferences.setMockInitialValues`, an in-memory map that cannot fail the way a device
  fails. It constructs `EncryptionService` TWICE over the same on-device storage; the second
  construction is the relaunch. Re-run after touching the persisted session-rebuild intent, the
  identity-warning set, or the device-list rollback pin.
- `video_probe_device_test.dart` (3 tests) + `video_transcode_device_test.dart` (2 tests) — the
  native video probe and the MediaCodec transcode, both fed a real container pushed to
  `/data/local/tmp/clip.mp4`; an absent fixture SKIPS rather than fails.

```powershell
cd frontend
flutter test integration_test -d <deviceId>   # 17 tests, ~2-9 min incl. the gradle build
# or one file:
flutter test integration_test/identity_recovery_durability_device_test.dart -d <deviceId>
```

## Patrol

Patrol (`patrol` 4.9.0 + `patrol_cli` 4.7.0, since 2026-09-12) is wired for Android: `PatrolJUnitRunner` +
orchestrator in `android/app/build.gradle.kts`, `androidTest/.../MainActivityTest.java`, `patrol:` block in
`pubspec.yaml` (`test_directory: integration_test`). Only `patrolTest(...)` files run under it —
`integration_test/patrol_harness_test.dart` is the framework-only self-test (green on the Pixel_7 AVD, 1/1).
The four `testWidgets` device files above are NOT ported: under `patrol test` the run sat in "Executing
tests" for 40 min; keep `flutter test integration_test -d`. Web leg (`-d chrome`) NOT green after two
attempts: run 1 (concurrent with the Android build) served the bundle but Playwright listed 0 tests
(`web_runner/tests/setup.ts` got no `__patrol__getTests`); run 2 (serial) hung 100 min at `npx playwright
install chromium`. Owner stopped further runs — treat as owner-owed, not a pending retry. Needs `ANDROID_HOME`
and `<sdk>/platform-tools` on PATH; `patrol.bat` lives in `%LOCALAPPDATA%\Pub\Cache\bin`.

## Local devices

- Android emulator: `cd frontend && flutter run -d <deviceId> --dart-define=BASE_URL=http://10.0.2.2:3000`.
- Phone on WiFi: `cd frontend && .\run_web_for_phone.ps1` (serves `0.0.0.0:8080`, sets `BASE_URL=http://<HostIP>:3000`, includes git/build dart-defines).
- Low-space Android builds: `cd frontend && .\run_android_on_x.ps1`; requires `X:` drive, redirects Gradle/temp/build dirs, runs `patch_webcrypto_16k.ps1`.

## Android release APK

- **Android RELEASE APK: `.\build-android.ps1` from the repo root** (runbook: `docs/runbooks/android-release.md`). Gates: Gradle throws AT EXECUTION TIME on exactly `packageRelease`/`packageReleaseBundle` without `android/key.properties` (covers task-name-free `gradlew build`/`assemble`; exact names because `packageReleaseResources` feeds lintRelease/testReleaseUnitTest), and the release `signingConfig` is NULL without a keystore — a missed path yields an inert UNSIGNED apk, never debug-signed; `apksigner` rejects a debug cert (keytool can't read v2/v3-only signatures at minSdk 24); `scripts/verify-apk-16k.mjs` fails the build if any 64-bit `.so` in the APK lacks 16KB-aligned PT_LOAD segments (falsification harness: `verify-apk-16k.selftest.mjs`). versionCode = `major*1_000_000 + minor*10_000 + patch` via `--build-number`. `allowBackup=false` + `res/xml/data_extraction_rules.xml` are dual-purpose (plaintext-prefs leak AND the restore-blob-without-Keystore-key corruption) — never relax.

## Gradle cache corruption

- Gradle cache corruption: set `$env:GRADLE_USER_HOME='D:\gradle-home'`, run `gradlew.bat --stop`, delete the broken `%USERPROFILE%\.gradle\caches\<version>` dir, then `flutter clean` + rebuild. `flutter clean` alone is not enough.

## Production web deploy

```powershell
# from repo root on the PC, not the VM
git pull ; .\deploy-web.ps1
```

`deploy-web.ps1` runs `flutter clean`, then `flutter build web --release --no-wasm-dry-run --no-web-resources-cdn` with `BASE_URL`, `GIT_COMMIT`, `BUILD_TIME`, `WEB_PUSH_VAPID_PUBLIC_KEY`, `GIPHY_API_KEY`; publishes by atomic swap to VM `frontend-build/`; verifies `/version.json` and backend `/version`. Never run `flutter build web` on the 2 GB VM.
