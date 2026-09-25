# Box push registration (E9) is on the branch, and the box now wakes a device whose socket died with messages waiting

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none (owner: no deploy, no master push; branch only)

## What was done
- Rebased `feat/metadata-privacy` onto master `2acd49b1` (one LATEST.md line, rerere off); pushed the branch only; CI 7/7 on `4cff5883`, PR #185 MERGEABLE again.
- `box_notifiers.dart:BoxNotifiers`: a notifier on every `ContactRecord.queues` queue (never request/self: decisions 2, 32), one queue at a time (the code names no queue). Stray code → next code; `rate_limited` → `retryAfterMs`; no code or a step-1 `invalid_payload` → that target rests 15 min. Runs on box ready, store open, target change; `BoxSession` owns it.
- `contact_store_notifiers.dart`: row `e2e_<uid>_boxntf_v1` `{v, target, nids}` (target = SHA-256(platform 0x00 token)); a new target drops old nids, gone nids pruned; newer-build row stops registration; sealed on web (`boxntf_v1` family).
- `push_box_source.dart:PushBoxSource` + `web_push_bridge_web.dart`: box token `{endpoint, keys, expirationTime}` (the box parser refuses `userAgent`); SW-message streams; visibility trigger; inert without `navigator.serviceWorker`. Native: FCM token + `onMessage`, resumed only.
- `web/web-push-sw.js`: `notifier_challenge` goes to open pages and is never a "New message" card; posted-then-closed unless a visible page took it on a non-Apple endpoint (Safari revokes after 3 silent pushes).
- Backend (found live): `BoxGateway.handleDisconnect` → `BoxDelivery.detachSocket` returns the rids it owned → `BoxService.waitingNids` (unexpired messages only) → `notifier.schedule`. A dead socket was detached only at the ping timeout (~40 s) and nothing pushed what it was handed.
- Docs: wire.md (Push notifier + Client push registration), e2e-invariants (`boxntf_v1`), frontend CLAUDE.md §4 (every push posts a notification), decisions log E9, remainder plan E9, CLAUDE.md count.
- Out-of-repo: Docker Desktop started; mp stack (db :5433 + backend :3000, `BOX_ENABLED` true) left UP; local dev DB holds `e9a_170136`/`e9b_170136` (ids 282/283) + a seeded friendship; Chrome profiles `%TEMP%/e9drive-a|b` deleted.

## Key files
- Edited: `backend/src/box/{box.gateway,box-delivery.service,box.service,box.int-spec}.ts`, `frontend/lib/services/{box/box_session,contacts/contact_store,encryption/sealed_web_content_kv,web_push_bridge_web,web_push_bridge_stub}.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/web/web-push-sw.js`, `frontend/test/services/sealed_web_content_kv_test.dart`
- New: `frontend/lib/services/box/box_notifiers.dart`, `frontend/lib/services/contacts/contact_store_notifiers.dart`, `frontend/lib/services/push_box_source.dart`, `frontend/test/services/box/box_notifiers_test.dart`, `frontend/test/services/contacts/contact_store_notifiers_test.dart`
- Read only (load-bearing): `backend/src/box/{box-notifier.service,box-push.transport,box-wire}.ts`

## Verification
- CI: 7/7 success on `a06cb08c`. The code commit `a7f5e2b7` failed only "Flutter analyze and tests": the new rate-limit test flaked (its 40 ms retry fired before the first assert on the runner); margins widened in `a06cb08c`.
- flutter 2613 / 14 skipped (count gate OK via `--log`); analyze 0 errors/warnings; Dart ratchet 3163 held. Backend unit 1197/68; `tsc` clean; ESLint on the 4 box files clean; box int 27/27 (3 new tests, each red first).
- Mutants 23: 21 killed; m14 (no rerun after an overlapping trigger) survived → test "a target that changes mid-pass" added, killed; b3 (detach returns rids it lost) survived → the owner check was redundant (`release` removes lost rids) and was deleted. Also deleted as redundant: `_box.state`, top-of-pass `_live`, `code.length`, `isOwned`.
- Review (E9Review): REQUEST_CHANGES ×3 — SW guard, `invalid_payload`/no-code budget drain, expired rows in `waitingNids` — all fixed, each with a test (the SW guard by a live repro).
- Live drive (release web, installed Chrome, real Web Push via `fcm.googleapis.com`):
  - registration end to end: `BOX_NOTIFIERS {registered: 1}`, one `box_notifiers` row (webpush, normal queue); no tray card; a reload re-challenged nothing.
  - wake-up with the app gone: card "Umbra / New message" 2.7 s after a send; before the backend fix a send 10 s after leaving never rang, after it the card came when the dead socket was detached (+43.7 s).
  - `notifier_challenge` with no page open: tray empty (no "New message").
  - insecure LAN origin: pre-fix bundle threw in `BoxSession.start`; fixed bundle opened both sockets, no page error.
- NOT verified: Android/FCM (no `FIREBASE_SERVICE_ACCOUNT` locally), iOS/Safari, Firefox; the SW's show-then-close itself (only "no card left" observed); two tabs registering at once; prod (box OFF).

## Notes for next session
- Next action: decision-22 slice (plan item 3) — replies, disappearing timers and media (E17) over the box, test-first; read `docs/plans/2026-09-25-metadata-pr31-remainder.md` E17/E18 first. Item 9 (E10–E12, backend) may run beside it.
- Owner-owed: O6, O7 (before box ON). New: an Android/FCM drive of E9 needs a dev Firebase service account in `.env` (`FIREBASE_SERVICE_ACCOUNT` is empty) — or it waits for G5 on a device.
- Residual (decisions log E9): a resubscribe inside the 2.5 s coalescing still gets the wake-up push, as for `send`.
- Drive recipe (scaffold deleted): a `BOX_DRIVE` `Timer.periodic(3 s)` in `BoxSession.start` calling `_keys.createInbound(friend)` for each friend with no queue, then `_notifiers?.run()`, printing `E2eDiagLog` `BOX_NOTIF` lines. Log in by setting `localStorage['flutter.jwt_token']` to the JSON-encoded token. Subscribe in the page with `reg.pushManager.subscribe` after the worker is activated (not `serviceWorker.ready` inside `tab.run`). Send with `node -e` + `socket.io-client` from `backend/` (`send {v:1, sid, blob: 16384 B}`).
- Traps → `docs/agents/traps.md` (6 lines: Android/push ×3, Tests ×2, Agent tooling ×1).
