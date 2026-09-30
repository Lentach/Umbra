# 0.2.55 built on the branch: H1 local notification + one-time password sheet that mints the contact backup

**Date:** 2026-09-30 · **Version:** 0.2.54 → 0.2.55 (pubspec only) · **Tiers deployed:** none

## What was done
- H1 (decision 81): `services/box_hidden_notifier.dart` `BoxHiddenNotifier.notifyIfHidden`, called from `MessagingBox._storeBoxMessage`'s `!alreadyShown` branch for a peer message. "Hidden" is read at the message: web `document.visibilityState`, Android `lifecycleState != resumed`; never `ConversationsProvider.isClientVisible` (starts `true` on every connect).
- H1 card: local, content-free ("Umbra" / "You have a new message"), tag `box-message`. Web: `WebPushBridge.showBoxMessageCard` through the push SW registration (no SW change, `SW_VERSION` stays 2). Android: `showBoxMessageLocalNotification` (id `0x40000003`, channel `fireplace_messages`).
- Decision 76: `ContactBackupService.awaitsPasswordToMint` (GET answered 404, no password) and `mintFromPassword` (login resolve again, then `uploadNow`); `AuthProvider.confirmPasswordForContactBackup` verifies the password first, so a wrong one mints nothing.
- New backend route `POST /users/verify-password` (`users.controller.ts`, `VerifyPasswordDto`, `UsersService.verifyPassword`): 200 `{ok:true}` / 401, creates no session, 10/h per IP. `/auth/login` could not serve: it issues a session, and on a linked device the primary's. Contract in `docs/contracts/wire.md`.
- UI: `widgets/contact_backup_password_sheet.dart` (glass sheet, obscured field, "Później"/"Potwierdź"), opened by `ConversationsScreen._offerContactBackupPrompt` once per app open; snooze 3 days (`SettingsProvider.snoozeContactBackupPrompt`, pref `contact_backup_prompt_snoozed_at_<uid>`) for any exit but a saved backup; pl + en ARB keys `contactBackupPrompt*`.
- Docs: decisions log E81a, E76a; `e2e-invariants.md` bullet; traps (H1 closed, mint trap updated); root `CLAUDE.md` counts (Flutter 3063/14, Jest 1229/69).
- Out-of-repo: none. Drives used throwaway accounts (deleted) and a temporary Node proxy (stopped).

## Key files
- Edited: `messaging_provider.box.dart`, `messaging_provider.dart`, `android_fcm_local_notifications.dart`, `web_push_bridge_{web,stub}.dart`, `contact_backup_service.dart`, `auth_provider.dart`, `settings_provider.dart`, `api_service.dart`, `conversations_screen.dart`, `users.controller.ts`, `users.service.ts`, `user.dto.ts`, `pubspec.yaml`.
- New: `box_hidden_notifier.dart`, `contact_backup_prompt.dart`, `contact_backup_password_sheet.dart`, `users.service.verify-password.spec.ts`, three Flutter test files.
- Read only (load-bearing): `docs/plans/metadata-privacy-decisions.md` decisions 76, 77, 81; `refresh-tokens.service.ts`.

## Verification
- CI: `NOT RUN on 562ba915 (code) and c5917b15 (H1): bare branch push, no PR`. The last green master code commit is `80957c7f`.
- Flutter full suite `+3063 ~14` (log fed to `verify-claude-frontend-test-counts.mjs --log`: OK); Dart ratchet PASS at the 3156 baseline; Jest 69 suites / 1229 tests; `tsc --noEmit` clean.
- New tests: `messaging_provider_box_test.dart` (H1 hidden posts one, visible posts none), `contact_backup_service_test.dart` `mintFromPassword` (3), `auth_provider_contact_backup_prompt_test.dart` (wrong password mints nothing, failed check is not "wrong", snooze boundary), the sheet widget test (stale error clears). No mutants run.
- H1 drives on the dev stack: web Chrome (visible 0 cards; hidden 1, replaced by the next; reconnect while hidden 1; tap focuses) and the Pixel_7 debug APK (foreground 0; backgrounded with the process alive 1 and replaced; after a backend restart while hidden 1; tap returns to the chat list). Card text has no sender or chat.
- Prompt drives: web (all five themes, en + pl, tap-outside and swipe-down snooze, 4-day expiry returns it) and the Pixel_7 (IME open, Confirm reachable). Empty, wrong (no row, no new `refresh_tokens`), right (one `contact_backups` row with a `password` wrap, no sheet after restart). Two findings fixed after the drives: a stale error stayed while typing, and the long error was cut off (`errorMaxLines: 3`). The body text now uses `onSurface` (the muted token was low-contrast on the grey glass of the light and teal themes). That last change and the two fixes were NOT re-driven on a device; the widget test covers the stale error.
- NOT verified: iOS, prod, a real phone, the Android release build.

## Notes for next session
- Next action: get CI on the branch (open a PR or merge to master from `fireplace-0a`, never push `HEAD:master` from this worktree), then, with the owner's OK, deploy backend AND web (the route must be live before the web build asks for it) and the APK 0.2.55. Decision 77's 6-week clock starts at that deploy. Before the backend restart, back up the DB.
- Re-drive the final sheet on a device after the deploy build (error clearing, `errorMaxLines`, body contrast).
- Owner-owed: Phase 5 drop go-ahead; princepolo's logout cause (ask when, which browser, whether history survived).
- Web limit: a web page RELOADED while hidden paints no frame, so its box session never starts; only the server wake-up push card shows until it is shown.
- `POST /users/verify-password` uses the global per-IP throttle: unauthenticated calls spend the 10/h too, and on dev the emulator and host share one IP.
- PR4.1/PR4.2 follow (no backfill, keep a security-only push table, wire the storage-loss screen). Week-one watch continues (`2026-09-30-metadata-week-one-watch-day0.md`).
- Traps: H1 trap closed and the mint trap updated in `traps.md` (already committed).
