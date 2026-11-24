# 0.2.95 live: cleanup batch 1b (nine client races fixed behind failing tests, one parked)

**Date:** 2026-11-24 · **Version:** 0.2.94 → 0.2.95 · **Tiers deployed:** both + APK

## What was done
- **CONN-01** `connection_provider.dart`: `disconnect()` and `dispose()` bump `_connectGeneration`, so a `connect()` parked on an await opens no socket afterwards.
- **CONN-06**: `initializeE2E` starts in the `socketReady` handler (was transport connect); `_retryContactStore` gates on `_accountReady`. Cost accepted (audit EC-11): no ready, no E2E init.
- **CONT-01** `messaging_provider.first_contact.dart`: a failed request send retires nothing once the peer's crossing request made them friends; it waits for a crossing in flight (`_crossingsInFlight`) first.
- **CONT-02** `auth_provider.dart`: `_sessionEpoch` (bumped by logout, `_clearLocalAuthState`, `adoptProvisionedSession`); a refresh from an older epoch is dropped and never joined.
- **CONT-05** `link_ceremony_controller.dart`: blob handlers run one at a time across ceremonies (`_blobRuns`); an abort during adopt or passcode wrap stays aborted and discards what the adopt landed.
- **BOX-01** `box_inbox.dart`: a delivery whose intake throws goes back into `_held`, unacked, and is retried on the next drain. **BOX-02 parked** (EC-12): subscribe is always ordered after the store write.
- **Composer** (owner OK for these three): UI-06 `sendPickedFiles` queues a second pick behind the first; UI-05 `_sendStaged` sends the caption only to the chat it started in (switch: back in the field, owner chose to keep that; composer gone: sent if that chat is still active, else the "interrupted" toast); UI-07 `sendVideo` catches a throw (`uploadFailed` toast, batch goes on).
- PR #277 merged (`6c37b151`). Docs: traps, `frontend/CLAUDE.md`, `composer-media.md`, audit EC-11/12 and status.
- **Out of repo:**
  - VM `.env` `ANDROID_APK_*` = 20095 (backup `.env.bak.pre-apk-0.2.95`); `~/fireplace/apk/umbra-0.2.95.apk`; PC copy `Desktop/umbra-0.2.95.apk`.
  - Xiaomi `f849cc68`: owner OK'd the wipe again; it now holds the 0.2.95 release app, logged out, screen timeout back to 1 min. Emulator: app uninstalled, stopped.
  - Throwaways `rel95e`/`rel95p` (ids 183–184) deleted through the app after backup `chatdb-20261124T014151Z` (offsite 3/3). Users: 31.
  - Worktrees `fireplace-1b*` and branches removed; local stack `fp1b` removed; drive Chrome profile left in `.planning/cleanup/drive/chrome1b`.

## Key files
- Edited: the seven source files above, `providers/messaging_provider.dart` (one field), `encryption_provider.dart` (comments only), `CLAUDE.md` (3474/16), `pubspec.yaml`.
- New tests: `test/providers/auth_provider_logout_refresh_race_test.dart`, `test/services/device_link/blob_single_flight_test.dart`; extended: `connection_provider_lifecycle_test`, `contact_store_hydration_test`, `device_material_mismatch_test`, `messaging_provider_box_first_contact_test`, `box_inbox_test`, `chat_input_bar_attachment_test`.
- Proof table, review triage, drive log: `.planning/cleanup/batches.md` (gitignored).

## Verification
- CI: 13/13 on PR head `2ff66abb`; on master `6c37b151` every listed row `success` (12 rows, no CodeQL row on the merge commit), checked by API.
- Flutter: 3474 passed, 16 skipped (+24). Analyze: no warning or error. Dart ratchet 2479 locally vs floor 2478; master `45ce133c` read 2479 too in the same session, so no new info. Backend untouched; backend gates not run locally (CI backend job green).
- Red first: every fix's test was reported red by its agent before the fix (lines in `batches.md`); the lead did not re-run the red states.
- Two-axis review (`reviewer` agents): no blocker; taken: CONT-05 across ceremonies, CONT-01 crossing window, CONN-06 retry gate and stale tests/comments, CONT-02 rebind and stale flight, UI-05 unmount, UI-06 early check. Not taken: listed in `batches.md`.
- **Local drive** (release web, debug APK, local stack; web + emulator + Xiaomi):
  - crossed requests tapped at once → both friends; text both ways on fresh accounts;
  - logout stays logged out after reload / cold start; login restores chats and messaging;
  - two picks on a slow uplink arrive in pick order (web → emulator, emulator → web with a 30 s video first);
  - caption case in the split view as built;
  - full device link: codes matched (716 460), web became device #3, a friend's message reached both devices.
- **Live drive** (0.2.95 release APK, emulator + Xiaomi, throwaways): request + accept, text both ways, video + photo then a second pick in order, Xiaomi logout / cold start / login then a new message arrived.
- Deploy: backup offsite 3/3 → backend → web SMOKE PASSED → APK published, URL hash = `f08eae70…91af`, smoke PASSED again.
- NOT verified on a device (tests only; need a fault or sub-second timing): logout while a connect is parked; refresh in flight at logout; duplicate blob / abort mid-adopt; intake throw; video send throw; composer popped mid-send; a send failing while a crossing is mid-accept. On live the crossed request did not cross (the phone's tap sent nothing; it accepted normally). Web on live beyond the smoke; iOS.

## Notes for next session
- Next action: batch 1c (audit §5): BOX-03, BOX-05/06, BE-03, BE-06, BE-08, CONT-09, WEB-01, WEB-05, BE-05 (check prod for duplicate names first; any found goes back to the owner), BE-20 + BE-29 (decision 150), remaining P2 races. Same method: one worktree per slice, failing test first, two-axis review, drive, one owner OK.
- Owner-owed: none. Release B due on or after 12-08.
- Known residue, by design: CONT-01's final `retireFirstContact` is not inside the store lock; a caption held back on a chat switch sits in the shared field (owner: keep).
- Recipes: `.planning/cleanup/batches.md` "1b drive" (rect clicks, file chooser, synthetic paste, throttling, link ceremony order).
- Traps (also in `traps.md`):
  - a second login on an account with linking off replaces device 1's identity;
  - `_blobRuns` and `_crossingsInFlight` are chains: a new await lengthens both;
  - a test-zone Completer never completes from real async in `testWidgets`;
  - web drive: click by rect, intercept the file chooser;
  - the phone notes file: use its `Unlock:` line, not a digit grep.
