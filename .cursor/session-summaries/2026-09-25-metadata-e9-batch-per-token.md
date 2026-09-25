# Box push registration takes ONE challenge per push token for every queue, and blocked or former contacts get no notifier

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none (branch only; owner rule: no deploy, no push to master)

## What was done
- Owner decision 34 (wire): `registerNotifier` step 1 is `{v, platform, token}` → `{ok, state:'challenged'}`, unsigned and naming no queue; step 2 is `{v, code, queues:[{nid, sig}] 1..256}` → `{ok:true, refused:[{nid, code:'auth_failed'}]}`, each entry signed over `nid ‖ 0x02 ‖ code`. `box-wire.ts` `parseRegisterNotifier`, `BOX_NOTIFIER_BATCH_MAX`; `box-signature.ts` drops `notifierChallengeFields`.
- `box-notifier.service.ts`: pending codes keyed by SHA-256(code), 10 min, several per token (`challenge(platform, token)`, `liveChallenge(code)`, `activate(challenge, nids)`); a repeat rewrites nothing. `box.gateway.ts` refuses a dead code whole and a bad entry alone (like `subscribe`). `box.service.ts` `authKeysByNid` (batch) and `saveNotifiers`, an `INSERT … SELECT` from `box_queues` that skips a queue deleted after its signature was checked.
- Client: `BoxClient.challengeNotifier(platform, token)` / `activateNotifiers(code, queues)`; `NotifierState` and `notifierChallengeFields` removed. `BoxNotifiers` collects the owed queues, sends ONE challenge per pass, activates 256 to a frame and records each frame (`ContactStore.markNotifiers`, batch). A first frame refused `auth_failed` = a stray code, so it awaits the next code. A nid refused in a batch is gone and is not offered again by that instance (each offer costs a push).
- Owner decision 35: `BoxNotifiers` skips `blocked` and `former` records. Retiring self-queues are pinned excluded.
- Docs: wire.md (verbs, signatures, push notifier, client registration), decisions log (34/35 DONE, new E9a, E9's registration part superseded), `e2e-invariants.md`, root `CLAUDE.md` test count 2613 → 2616.

## Key files
- Edited: `backend/src/box/{box-notifier.service,box-wire,box-signature,box.gateway,box.service,box.constants}.ts` + `box-wire.spec`, `box-signature.spec`, `box.int-spec`; `frontend/lib/services/box/{box_client,box_notifiers,box_wire}.dart`, `frontend/lib/services/contacts/contact_store_notifiers.dart` + tests `box_notifiers_test`, `box_wire_test` (vector re-made from server code), `contact_store_notifiers_test`; `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md`, `frontend/docs/e2e-invariants.md`, `CLAUDE.md`.

## Verification
- Red first: 4 parser cases and 5 notifier int tests failed before the backend change; the 2 decision-35 client tests failed before the filter while the other 234 passed.
- Backend: `tsc` clean; unit 1197/68; box int 31/31 (new: batch with a forged entry refused alone, whole-frame refusal of an unpushed code, idempotent repeat, a code that survives a reconnect AND a stranger's second challenge); ESLint 0 errors; lint ratchet held (850); `verify-box-imports` OK.
- Frontend: `flutter analyze` 0 errors/warnings, Dart ratchet held (3163); box + contacts 236/236. The 257-queue case sends frames of 256 + 1 under one code.
- Wire vector: the `registerNotifier` entry was re-made with `src/box/box-signature.ts`; the same key's `subscribe` signature equals the stored one (key derivation control).
- Headless round trip (throwaway, deleted): real `BoxClient` + `BoxNotifiers` against the real `BoxModule` + Postgres with a recording transport. Result: 1 `notifier_challenge`, rows for the 2 friends only (blocked and deleted queues absent), a second pass pushed nothing.
- DEVICE DRIVE (mp `AGENTS.md:20`): release web of `4cbb0dc2` plus a throwaway `BOX_DRIVE` scaffold (restored by `git checkout`, bundle deleted), installed Chrome on `localhost:8080`, mp stack, account 284 with friends 285–287.
  - Scaffold minted a real queue per friend. B blocked 287 over the account socket; after a reload, 287 was `blocked` and kept its queue.
  - Then notification permission was granted and a real Web Push subscription made on `fcm.googleapis.com`. Result: `BOX_NOTIFIERS {registered: 2, owed: 2}`, two `box_notifiers` rows (285, 286) on one webpush token, and none for 287.
  - A visible reload (after restoring the minimized window; the first reload read `hidden` and proved nothing) re-registered nothing: the rewritten `BOX_DRIVE_STATE` had no `BOX_NOTIFIERS` line and `verifiedAt` stayed unchanged. (The backend logs only FAILED challenge pushes, so a push count is not evidence.)
- CI on `4cbb0dc2`: 6/7; "Flutter analyze and tests" failed ONLY at the count gate (2613 documented vs 2616). CI on `80a891d5` (the count fix): 7/7 success.
- NOT verified: the wake-up push after this change (flush code unchanged, rows proven); Android/FCM (G5, decision 36), iOS/Safari, Firefox; prod (box OFF).

## Notes for next session
- Next: the decision-22 slice (disappearing timers, replies and media move to the box).
- Owner-owed: O6, O7 (before box ON); the old `new_message` SW path skipping the banner on Apple endpoints is still not raised.
- Traps → `docs/agents/traps.md` (3 lines: Deploy/CI ×1, Agent tooling ×2).
