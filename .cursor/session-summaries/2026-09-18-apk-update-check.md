# Sideloaded Android users now learn a newer APK exists, and the update path is proven on a device

**Date:** 2026-09-18 · **Version:** unchanged (`0.2.50` web live; APK channel unpublished) · **Tiers deployed:** none

## What was done
- `backend/src/version/version.controller.ts`: `GET /version` gained an `android` block (`versionCode`/`versionName`/`url`) read from `ANDROID_APK_VERSION_CODE|_VERSION_NAME|_URL` via `androidRelease()`. All three required and the code must parse as a positive integer, else `null` — a prompt without a URL cannot be acted on. Deliberately NOT the `version` field beside it: the web tier deploys alone (`0.2.50` was a web-only boot loader), so driving the prompt off served semver would nag every APK user.
- `backend/src/config/env.validation.ts`: the three vars declared `@IsOptional() @IsString()` — `validateSync` runs `skipMissingProperties: false`, so a declared-but-unset var would abort boot, and they are unset on prod until an APK is published.
- `frontend/lib/services/apk_update_service.dart` (new): `check()` returns `ApkRelease?`. Silence is the default off Android, with no channel, half-filled channel, network failure, unparsable installed `buildNumber`, or an already-dismissed build. `dismiss(code)` is per-build, so a LATER release still prompts.
- `frontend/lib/screens/settings_screen.dart`: `_buildApkUpdateCard` above the version footer, theme tokens only, keys `settings-apk-update-{card,later,download}`; `apkUpdateService` constructor seam for tests. Body carries the uninstall warning — that is the moment a user reaches for the one action that destroys their keys.
- l10n `updateAvailable{Title,Body,Download,Later}` (pl/en). `CLAUDE.md` §3: 1159→1164 backend, 2197→2210 Flutter.
- Merged `feat/reaction-tokens` (PR #179) and released it as `0.2.49 / ac2fd98a`; migration `0018` applied on prod after `./backup-db.sh`.

## Key files
- Edited: `version.controller{,.spec}.ts`, `env.validation.ts`, `settings_screen.dart`, 5 l10n files, `CLAUDE.md`, `docs/agents/traps.md`.
- New: `apk_update_service.dart`, `apk_update_service_test.dart`, `settings_screen_apk_update_test.dart`.
- Read only (load-bearing): `app_version_info.dart`, `docs/runbooks/android-release.md` §465-476, `rule://production-vm-deploy`, `skill://{dart-modern-features,dart-test-fundamentals,flutter-frontend-design}`.

## Verification
- Backend **1164/64**, `tsc` exit 0. Frontend **2210 passed / 14 skipped** (+13). Both count verifiers OK. Both ratchets PASS (backend errors 898→897; dart infos held at 3166).
- Mutant: `published.versionCode <= installed` → `<` killed "stays silent when the published build is the installed one". Restored.
- Live, no mocks: second backend on `:3010` with the channel set served the `android` block while the dev stack on `:3000` served `null`; the REAL `ApkUpdateService` over real sockets gave 5/5 (offer, current, no-channel, dismissed, connection-refused); the real widget rendered from `:3010` in Chrome and the card vanished on Later.
- **Android emulator, release-signed, full cycle.** APK A `20049/0.2.49` cert `8e9a6bf3…cdf405d` = the runbook record-of-truth. Registered `proofuser1` (dev DB row 244). Settings on 20049 showed the card ("Dostępna jest wersja 0.2.50", Pobierz/Później), footer `0.2.49 · proofA`. `adb install -r` APK B → Success, `versionCode=20050`, `firstInstallTime=06:33:13` UNCHANGED with `lastUpdateTime=06:41:57` (the runbook's in-place-upgrade evidence). Relaunch: **still logged in**, chats screen, no login prompt. Card gone, footer `0.2.50 · proofB`.
- **The signature trap reproduced live:** the first install refused with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` against the emulator's debug-signed `0.2.48` — exactly what a friend's phone does if the cert ever changes.
- **NOT verified:** no E2E MESSAGE was sent before the update, so "old messages still decrypt after `install -r`" is inferred from the surviving session, not observed. iOS, prod APK channel (`ANDROID_APK_*` unset on the VM), and a physical phone are all untested.
- CI **6/6 on `6a9475ab`**. `git push origin master` from a `feat/passcode-lock` worktree pushed the STALE local `master` ref and printed success while the commit stayed local — caught only by re-reading `ls-remote`.

## Notes for next session
- Owner-owed: **PEPK vs sideload-forever** (now demonstrated, not just described); set `ANDROID_APK_*` on the VM when a download link exists; whether the card should also appear at launch (Settings-only means friends may never see it).
- Reactions still open: `incomplete_fanout` refusal, dropping the legacy emoji branch (closes D10), same-epoch top-up.
- Cleanup owed: emulator holds `proofuser1` + APK B; `local/apk-proof/` holds both APKs; dev DB row 244.
- Traps (also in `docs/agents/traps.md`): FLAG_SECURE zeroes `screencap` on release builds; a Play-image AVD refuses `adb root`; `git push origin master` from a branch worktree pushes the wrong ref.
