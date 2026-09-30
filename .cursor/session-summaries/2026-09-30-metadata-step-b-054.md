# Box ON in prod (step B); iOS push SW forced to update (0.2.54)

**Date:** 2026-09-30 · **Version:** 0.2.53 → 0.2.54 · **Tiers deployed:** both (APK stays 0.2.53)

## What was done
- Owner's phone updated to 0.2.53 (the in-app install did not land the first time; the file, checksum and signer were correct; a second browser download installed it). Push confirmed.
- Step B (decision 75, supersedes S3): `docker-compose.prod.yml` `BOX_ENABLED: 'true'` at `d86107c1`, then a plain restart ~2 min later (72). One-way (E69d). Docs: `runtime-reference.md`, `wire.md`.
- Found after step B: PWA push broken for box pairs.
  - The owner's own pair (bob208 #37 ↔ alteregobob8 #75) stayed on the old path until bob208's device 1 (an iPhone PWA, live since 09-02) connected.
  - That iPhone never registered a box notifier (`BOX_NOTIFIER_NO_CODE`). It ran the pre-08-26 push SW: iOS never re-checks it (traps.md).
- 0.2.54 (`80957c7f`, E75b):
  - `web-push-sw.js`: `SW_VERSION` 2, `install` skipWaiting, a `sw-version` reply.
  - `web_push_bridge_web.dart` `_registerServiceWorker`: `registration.update()` once per page load (not on the tap-to-subscribe path), `PUSH_SW {version}` diag.
  - `box-push.transport.ts`: warns on a refused wake-up push (status/code only).
- Out of repo: backups `chatdb-20260930T014422Z` and `…T034537Z`. A throwaway staging account `swfix<6 digits>`. The Pixel_7 emulator is UP with the release APK (`apk053t3565`). The managed browser has the prod `web053t6929` tab. Staging is UP with the box ON. `frontend/build/web` holds a staging-URL build.

## Key files
- Edited: `docker-compose.prod.yml`, `frontend/web/web-push-sw.js`, `frontend/lib/services/web_push_bridge_web.dart`, `backend/src/box/box-push.transport.ts`, `frontend/pubspec.yaml`.
- Docs: `metadata-privacy-decisions.md` (75, S3 superseded, E75a, E75b), `traps.md`, `wire.md`, `backend/docs/runtime-reference.md`.

## Verification
- CI: 6/6 success on `d86107c1` and on `80957c7f` (the 7th row on 2ed4a72b was the PR-only CodeQL rollup).
- Backend `npm test -- src/box` 17/17; `flutter test test/services` 1037 passed / 14 skipped; analyze on the bridge: only pre-existing infos. Smoke 8/8 after both deploys.
- Step B driven on prod (E75a): `apk053t3565` (release APK on the emulator) ↔ `web053t6929` (web). One text each way over the box, chat 132 `messages` flat. With the app killed (`am kill`), a box message gave a fresh FCM notification and was delivered on reopen.
- SW fix driven in Chromium on staging (release build, :8204): the old SW registered, then a plain `register()` kept it (red); the fixed app, logged in with permission, got version 2 (green); a logged-out reload kept the old one (control).
- Owner's iPhone on 0.2.54: `PUSH_SW {version: 2}`, `BOX_NOTIFIERS {registered: 1, owed: 1}`, and a `web.push.apple.com` row in `box_notifiers` at 04:09:49 UTC. The owner confirmed box notifications on the iPhone PWA, the Android app and the Android PWA. The Android PWA first showed only a status-bar icon; after the owner changed the phone settings it works [INFERENCE: MIUI floating notifications; not observed].
- NOT driven on a device: decision 70's same-pass re-key and `no_anchor` handoff; typing to a partly covered friend; release APK smoke items 4–7.

## Notes for next session
- Next action: week-one watch (E65b): `box_totals`, BoxReaper `[box] refusals send:ceiling=` lines, and the new `[box] web push refused` / `fcm push refused` lines. Nothing else is owed on step B.
- OPEN (H1): a hidden but still-connected page (an Android PWA in the background) gets a box blob in-band and acks it, and nothing posts a card. The box wakes only an unsubscribed queue or a detached socket. Do NOT close the box socket on hide without the decisions log (a new visibility signal to the box, likely OWNER-class). The privacy-neutral option is a local content-free card when a box message is journaled while the page is hidden.
- The 16 other iPhone users get the new SW only when they next open the app: track `web.push.apple.com` rows in `box_notifiers` over the next days. E73b (a lost badge after the first upgrade session) is still unexplained. The week-one watch runs only if someone opens a session; nothing runs in between.
- Metadata plan position (`.planning/metadata-privacy/task_plan.md:37-38`): release N is done. Next: convergence (O1, owner decision at G6: when the old tables may go), then Phase 4 = PR4.1 backend (drop `messages`/`conversations`/`friends`…, ~12.7k lines) + PR4.2 frontend = release N+1. Arti stays Phase 5. Bump `SW_VERSION` with every `web-push-sw.js` change.
- Real pairs move onto the box only after BOTH devices have been online once AND reconnected once: the second restart ran with 0 queues.
- Traps: in traps.md (iOS push SW).
