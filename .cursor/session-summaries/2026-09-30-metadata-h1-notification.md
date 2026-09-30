# 0.2.55 built on the branch: H1 local notification + one-time password sheet that mints the contact backup

**Date:** 2026-09-30 · **Version:** 0.2.54 → 0.2.55 (pubspec only) · **Tiers deployed:** none

## What was done
- H1 (decision 81): `services/box_hidden_notifier.dart` `BoxHiddenNotifier.notifyIfHidden`, called from `MessagingBox._storeBoxMessage`'s `!alreadyShown` branch for a peer message in an unmuted chat. "Hidden" is read at the message (web `document.visibilityState`, Android `lifecycleState != resumed`), never `ConversationsProvider.isClientVisible`.
- H1 card: local, content-free ("Umbra" / "You have a new message"), tag `box-message`, at most one alert per 10 s (`alertWindow`: a drained backlog buzzes once). Web: `WebPushBridge.showBoxMessageCard` via the push SW registration, closing the old card first (iOS); no SW change. Android: `showBoxMessageLocalNotification` (id `0x40000003`).
- Decision 76: `ContactBackupService.awaitsPasswordToMint` + `mintFromPassword`; `AuthProvider.confirmPasswordForContactBackup` verifies the password first, so a wrong one mints nothing. Copy no longer claims "the server cannot read it".
- New route `POST /users/verify-password` (`users.controller.ts`, `VerifyPasswordDto`, `UsersService.verifyPassword`): 200 `{ok:true}`; wrong password is **403 `wrong_password`** (401 is the guard's expired token, which the client refreshes on); no session, 10/h per IP. Contract in `docs/contracts/wire.md`.
- `ContactBackupService.flushPending`, called by `ConnectionProvider` after the restore: a password login that minted now PUTs at once. Before, an account whose graph never changed never got a row and met the sheet on its next cold start.
- UI: `widgets/contact_backup_password_sheet.dart`, opened by `ConversationsScreen._offerContactBackupPrompt` once per app open; any exit but a saved backup snoozes 3 days; errors clear on typing, wrap to 3 lines; pl + en keys `contactBackupPrompt*`.
- Docs: decisions E81a, E76a; `e2e-invariants.md`; traps; root `CLAUDE.md` counts (Flutter 3070/14, Jest 1229/69).
- Out-of-repo: the Android drive uninstalled the prod-signed 0.2.53 APK from the emulator. Prod still holds that test install's device row (`apk053t3565`, device 1, live, WITH a request queue), so it does not skew the "live devices without a request queue" count; it is a stale live device. Throwaway accounts and proxies were deleted.

## Key files
- Edited: `messaging_provider.box.dart`, `messaging_provider.dart`, `connection_provider.dart`, `android_fcm_local_notifications.dart`, `web_push_bridge_{web,stub}.dart`, `contact_backup_service.dart`, `auth_provider.dart`, `settings_provider.dart`, `api_service.dart`, `conversations_screen.dart`, `users.{controller,service}.ts`, `user.dto.ts`, `pubspec.yaml`.
- New: `box_hidden_notifier.dart`, `contact_backup_prompt.dart`, `contact_backup_password_sheet.dart`, `users.service.verify-password.spec.ts`, three Flutter test files.
- Read only (load-bearing): decisions 76, 77, 81; `refresh-tokens.service.ts`.

## Verification
- CI: `NOT RUN on the code commits: bare branch push, no PR`. Last green master code commit `80957c7f`.
- Flutter full suite `+3070 ~14`, count gate OK via `--log`; Dart ratchet PASS at 3156; Jest 69 suites / 1229; `tsc --noEmit` clean.
- Mutants: dropping the sender and mute guard at the H1 hook failed the sibling-copy and muted-chat tests (both killed); the re-store and burst tests pin the `alreadyShown` placement and the window.
- Drives, dev stack, final code: web Chrome and Pixel_7 debug APK. Sheet: empty / wrong (403) / expired (401, generic text) / 429 (two-line text) / right; error clears on typing; body contrast 7.6:1 light and 7.8:1 teal (was 3.3 and 2.1); a login-form login PUTs a row about 2-8 s later and a cold start shows no sheet. H1: visible 0; hidden 1; 4 messages in 7 s = 1 alert; a message after the window alerts again; muted chat 0, unmuted returns; web closes the old card before showing.
- NOT verified: iOS, prod, a real phone, the release APK, the five-theme pass after the contrast change (only light and teal re-measured).

## Notes for next session
- Next action: get CI on the branch (open a PR, or merge to master from `fireplace-0a`; never `HEAD:master` from this worktree). With the owner's OK, back up the DB, deploy backend AND web together (the route must be live first), then build the APK with `build-android.ps1` WITHOUT `-SkipClean` (the debug builds left a poisoned `GeneratedPluginRegistrant`). Decision 77's 6-week clock starts at the deploy.
- Owner-owed: deploy go-ahead; Phase 5 drop; princepolo's logout cause.
- Web limit: a web page RELOADED while hidden paints no frame, so only the server wake-up card shows until it is shown.
- `verify-password` uses the global per-IP throttle: unauthenticated calls spend the 10/h, and on dev the emulator and host share an IP.
- PR4.1/PR4.2 follow; PR4.2 must wire the storage-loss screen. Week-one watch continues.
- Traps: in `traps.md` (H1 closed, mint trap, 403 vs 401, login mint flush).
