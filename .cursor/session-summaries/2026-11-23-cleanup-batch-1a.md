# 0.2.94 live: cleanup batch 1a (mute fixes for #274, two server races, download host rule, missing guard tests)

**Date:** 2026-11-23 · **Version:** 0.2.93 → 0.2.94 · **Tiers deployed:** both + APK

## What was done
- **#274, F-003:** `ConversationsProvider.isChatMuted` reads the mute from the contact record when a chat has no row (deleted on this device); `postHiddenArrivalCard` and `MessagingBox._storeBoxMessage` use it.
- **#274, F-002 (decision 149, E149a):** `services/wake_up_mute.dart`; the provider writes prefs `wake_all_muted_v1` (`forever` / first mute end / absent) on every chat change and on going to the background; `firebaseMessagingBackgroundHandler` shows no card while it holds. A pending request that holds a queue counts as not muted. Android only.
- **UI-02:** `FileMessageContent` sends a keyless row through `loadDecryptedMediaBytes` (host rule); `downloadFile` deleted in its own structural commit. **UI-01:** `snackbarChatHistoryDeleted` EN/PL.
- **BE-01:** `key-bundles.service.ts` one-time pre-key claim gets `FOR UPDATE SKIP LOCKED`. **BE-02:** `box.gateway.ts:subscribe` attaches only `if (client.connected)`.
- **Tests only:** MF-01/02/03/06/07, MB-3 (with probe step), MC-02/03/03a-c/09/W5/W1.
- Dependabot #172: `@azure/msal-node` 7.2.3 (lock only). Issue #274 closed with the limits stated.
- PR #276 merged (`c073bdfc`), released. Docs: decision log E149a, audit status line, `testing-and-ci.md` int counts.
- **Out of repo:**
  - VM: `.env` `ANDROID_APK_*` = 20094 (backup `.env.bak.pre-apk-0.2.94`); `~/fireplace/apk/umbra-0.2.94.apk`; PC copy `C:/Users/olek2/Desktop/umbra-0.2.94.apk`.
  - Xiaomi `f849cc68`: its 0.2.93 install and that account's local data were removed on the owner's word; it now holds the 0.2.94 release app, logged out. Screen timeout set to 1 min (I had raised it).
  - Emulator `umbra_drive`: app uninstalled, emulator stopped.
  - Throwaways `rel94e`/`rel94p` (ids 181–182) deleted through the app after backup `chatdb-20261123T222908Z` (offsite 3/3). Users: 31.
  - Worktrees `fireplace-1a*` and their branches removed; local stacks removed (`down -v`); drive Chrome profile left in `.planning/cleanup/drive/chrome1a`.

## Key files
- Edited: `frontend/lib/providers/conversations_provider.dart`, `providers/messaging/messaging_provider.box.dart`, `services/android_fcm_local_notifications.dart`, `main.dart`, `widgets/message/file_message_content.dart`, `utils/download_utils_{io,web}.dart`, `l10n/*`, `backend/src/key-bundles/key-bundles.service.ts`, `backend/src/box/box.gateway.ts`, `CLAUDE.md` (900/53, 3450/16), `pubspec.yaml`.
- New: `frontend/lib/services/wake_up_mute.dart`, `test/services/wake_up_mute_test.dart`, `test/widgets/message/file_message_content_test.dart`, `test/providers/connection_provider_lifecycle_test.dart`, `backend/src/key-bundles/key-bundles.service.int-spec.ts`, `backend/src/box/box.gateway.spec.ts`, this file.
- Proof table per item: `.planning/cleanup/batches.md` (gitignored).

## Verification
- CI: 13/13 on `3f8d7157` (PR head); on master `c073bdfc` every row `success`, checked by API.
- Counts: backend 900 unit / 53 suites, 77 int; Flutter 3450 passed, 16 skipped. Backend ESLint at baseline, knip clean. Dart ratchet: 2479 locally on master and on the branch alike (known local +1); CI analyze green.
- Red first: card posted for a muted hidden chat; foreign host fetched; same pre-key served three times; `onEnqueued` true for a dead socket. Every MF/MB/MC test was seen red under its mutant (no survivor left among the P1 ids).
- Two-axis review (`reviewer` agents). Fixed: stale "all muted" with a pending request, failed prefs write never retried, native-card test, MB-3 probe step, BE-02 positive control, int count line, mixed commit split. Not taken: listed in `batches.md`.
- **Local drive** (release web build, debug APK, local stack), web + emulator + Xiaomi:
  - muted + deleted chat with the app in the background: no card; same chat un-muted: card (web and Xiaomi);
  - prefs flag `forever`, 1 h mute = exact end time, gone after un-mute, gone after Home with a pending request;
  - clear-chat toast text; keyed file download with matching bytes.
- **Live drive** (0.2.94 release APK on emulator and Xiaomi, throwaway accounts, real FCM, app killed):
  - not muted: wake-up, card posted (both devices);
  - only chat muted: wake-up received (`FLTFireMsgReceiver` in logcat), no new card (`when=` unchanged), message present on open (both devices).
- Deploy: backup offsite 3/3 → `deploy-backend.sh` → `deploy-web.ps1` SMOKE PASSED → APK published, URL hash = `81a7303d…a8bd`, smoke PASSED again.
- NOT verified: web on live beyond the smoke (web paths were driven on the same code locally); iOS; a keyless old-path file on a real account; MIUI battery-saver killing wake-ups after hours.

## Notes for next session
- Next action: batch 1b (audit doc §5): CONN-01, CONN-06, CONT-01, CONT-02, CONT-05, BOX-01, BOX-02, UI-05/06/07 (composer OK given for these three), each behind a failing test; start with CONN-01, whose guards now have tests (MC-03).
- Owner-owed: none. Release B due on or after 12-08.
- Costs of decision 149 as built, told to the owner: all-muted silences everything on friend queues while closed; FCM may slow wake-ups for an app that often shows nothing.
- Leftovers: folder `Desktop/fireplace-b7`, exited Docker projects `fireplace-b7`, `fireplace-drive`.
- Recipes: `.planning/cleanup/batches.md` (web by semantics, two-window background, `adbui.py`), `findings.md` (web push).
- Traps (also in `traps.md`):
  - int-specs hit whatever Postgres is on 5433;
  - the FCM handler cannot be driven locally;
  - a wake-up card count proves nothing on a second run, compare `when=`;
  - a local APK on the Xiaomi means wiping its live install;
  - Flutter web by semantics + `Input.insertText`;
  - relay tabs never report hidden, use two windows;
  - `git reset --hard` under a bind mount restarts the dev backend;
  - "Filename too long" on worktree removal.
