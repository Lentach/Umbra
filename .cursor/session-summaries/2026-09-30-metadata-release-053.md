# Release 0.2.53 live (backend, web, APK) with the box OFF; box badge survives a restart

**Date:** 2026-09-30 · **Version:** 0.2.52 → 0.2.53 · **Tiers deployed:** both + APK

## What was done
- Owner delegated the review calls ("decide for me"). Logged as decisions 70–74, OWNER (delegated). 70 supersedes 68 (row restored, marked SUPERSEDED). 71 amends 3: no OTP claimed while the box is off. 72: step B restarts twice. 73: badge persists. 74: ship as 0.2.53.
- Decisions log hygiene: E65a restored and amended by E65c (subscribe establishes). E69d: step-B rollback = fix forward only; the traps line matches.
- Decision 73: `e2e_<uid>_boxseen_v1` per-chat seen mark (sender send time, sealed on web). The first E2E-ready of a session seeds box unread from the stored rows (`applyStoredBoxLastMessages`, once per session, not per reconnect). E73a has the residuals.
- `pubspec` 0.2.53. Master = `2ed4a72b` (ff from `fireplace-0a`); `Fireplace` `feat/passcode-lock` ff'd to it.
- Prod: backup `chatdb-20260929T234156Z.dump.gpg` → backend 0.2.53/2ed4a72b (`BOX_ENABLED=false`, 0 error lines) → web (PUBLISHED_OK) → smoke 8/8.
- APK 0.2.53 (20053, SHA256 `7cc881fe…ca9c`, signer = recorded cert) at `/apk/umbra-0.2.53.apk`. VM `.env` `ANDROID_APK_*` updated (backup `.env.bak.pre-apk-0.2.53`); `/version` android block = 20053.
- Out of repo: prod test accounts `apk053t3565` (id 128), `web053t6929` (129). The emulator has the release APK (the debug g5_dan data is gone). Staging is still UP with box ON (image 36451db8). `.env.staging` ALLOWED_ORIGINS +8204 (a stray CR was fixed). Tag `pre-0.2.53-prod` → 5c18cdf0 pushed (the rollback for 0.2.53 while the box is off).

- Owner's phone: the in-app update did not land the first time (server file, checksum and signer all correct; cause on the phone, not diagnosed); a second browser download + install gave 0.2.53. Owner confirmed push on 0.2.53.
- Step B (decision 75): `BOX_ENABLED: 'true'` at d86107c1, CI 6/6 (the 7th row on 2ed4a72b was the PR-only CodeQL rollup), backup `chatdb-20260930T014422Z.dump.gpg`, deploy + second restart, smoke 8/8. Driven on prod (E75a): both directions over the box, box push with the app killed. The second restart ran with no queues, so each real pair needs one reconnect per device.

- Owner's own pair (bob208 #37 ↔ alteregobob8 #75, chat 86) still goes the OLD path after step B: 37's device 1 (legacy primary, live since 09-02) has published no request queue, so neither side is covered (decision 16; the sender's `own_uncovered` too). 3 server rows 02:50–02:51 UTC. Push worked, but via the server path. Owner asked to open that install once on 0.2.53.

- **OPEN, found after step B (owner report 03:12 UTC): PWA push is broken for box pairs.** bob208 #37 device 1 is an iPhone PWA (web.push.apple.com); alteregobob8 #75 is an Android PWA (web push sub created 03:08). After the reconnects the pair is on the box (no `messages` rows after 03:04; 17 blobs waiting on a queue with NO notifier). `box_notifiers` holds 3 rows: 2 fcm, 1 webpush (75's, 03:08); NONE for the iPhone. Hypotheses: H1, the box socket ignores backgrounding (`main_shell.dart` only sets `clientVisible`; `BoxSession` has no pause), so a hidden page (Android Chrome keeps it alive) gets and acks the blob and the box never wakes it, and no client code posts a notification for a box message; the native app works only because MIUI drops the background socket (the emulator push drive used `am kill`, not a background). H2, iOS notifier registration never completes (challenge code not reaching the page: `clients.matchAll({includeUncontrolled})` / `postMessage` across the `/web-push-scope/` scope on WebKit?), never driven on an iPhone (traps.md:304 said 'at G5').

- **iPhone cause PROVEN (owner's hacker-mode log: `05:22:18 BOX_NOTIFIER_NO_CODE {platform: webpush}`; the challenge showed as "Fireplace / new message" with the old icon = the pre-08-26 SW).** iOS never re-checks the push SW (traps.md). 18 Apple subscriptions / 17 users. Fix 0.2.54 (E75b): `registration.update()` once per page load, `SW_VERSION` + `install` skipWaiting + `sw-version` reply, `PUSH_SW` diag; backend logs a refused wake-up push with its status. Driven in Chromium on staging (release build, :8204): old SW registered → server switched to the new file → plain `register()` kept the old worker (no version answer) = red; the fixed app logged in with permission granted → worker answers 2 = green; control (old SW again, logged-out reload, fix path not run) stayed old. Android PWA (#75): a manual `web-push` of `{type:'new_message'}` to its notifier token returned 201; whether the phone showed it is unconfirmed; still open.

- **0.2.54 LIVE (80957c7f; backup `chatdb-20260930T034537Z.dump.gpg`; CI 6/6; smoke 8/8) and driven on the owner's iPhone:** `PUSH_SW {version: 2}`, `BOX_NOTIFIERS {registered: 1, owed: 1}`, Apple row in `box_notifiers` at 04:09:49 UTC, and the owner confirmed box notifications on the iPhone PWA and the native app. The Android PWA (alteregobob8) now gets the notification too, but only as a status-bar icon with no pop-up: a phone setting (MIUI floating notifications / the site's notification channel importance), not app code. APK stays 0.2.53 (web-only fix).

## Key files
- Edited: `frontend/lib/providers/conversations_provider.dart`, `frontend/lib/providers/messaging/messaging_provider.{box,actions,history}.dart`, `frontend/lib/services/encryption_service.dart`, `sealed_web_content_kv.dart`, `frontend/pubspec.yaml`, `CLAUDE.md` (3053).
- Docs: `docs/plans/metadata-privacy-decisions.md` (68, 70–74, E65c, E69d, E73a), `docs/agents/traps.md`, `wire.md`, `e2e-invariants.md`, `client-reference.md`.

## Verification
- CI: 7/7 success on `2ed4a72b` (PR #187).
- Flutter 3053/14, analyze 3156 (Dart ratchet held); badge fix: 17/17 mutants killed.
- Drives:
  - Staging web: badge 1 survives a backend reconnect and a full tab restart, 0 once opened, `messages` flat.
  - Emulator, 0.2.53 debug over RC: login and history kept. Box messages 3 and 4 (4 sent while the app was backgrounded) show badge 2 after force-stop + relaunch.
  - The FIRST box message after the upgrade lost its badge after a restart, once; not reproduced (see Notes).
- Release APK on the emulator against prod: install → register → E2E both ways with prod web → push with the app killed (`am kill`, FCM woke the process, notification "Umbra / You have a new message").
- Typing to a partly covered friend: NOT driven. The old web logged in as the same device 1, not a linked 2nd device.
- The old-web login as fay REPLACED fay's identity (`identity_change_audit` row 15, 22:35 UTC); fay's real device restored it at 23:13 (row 16). This is the known unlinked two-install thrash (runbook drill 7). The badge drives ran after 23:13.
- NOT driven on a device (tests only): decision 70's same-pass re-key on `would_replace` and the `no_anchor` handoff. Release APK smoke items 4–7 (voice/image, delete-for-everyone, link ceremony, unlinked drill) not run.
- NOT verified: owner's real phone update to 0.2.53; iOS; step B on prod.

## Notes for next session
- Next action: the owner updates their phone to 0.2.53 (in-app update prompt) and checks a push arrives. Then step B: flip `BOX_ENABLED`, restart again ~2 min later (72), never back to false (E69d), week-one `box_totals` watch (E65b), FCM check on the owner's phone (69).
- Unexplained once (E73b): the first box message after the 0.2.53 upgrade on Android read as seen after a restart. Suspect: the base mark was fixed after it arrived (the first session pass did not run before it). Watch for it; E73a already accepts pre-upgrade rows.
- Recipes: after `am start`, the first `uiautomator dump` can show the PREVIOUS window. A long-idle visible-browser tab stops painting: reload it before typing.
- Traps: added to traps.md (Android + Agent tooling).
