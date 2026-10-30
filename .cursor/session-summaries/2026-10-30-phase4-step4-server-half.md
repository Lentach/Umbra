# Phase 4 step 4 server half BUILT behind `LEGACY_LISTS_SILENT` (prod pinned off); rehearsed on staging

**Date:** 2026-10-30 · **Version:** unchanged (0.2.72) · **Tiers deployed:** none

## What was done
- Day-after freeze check (10-30 02:08Z): backend `41117d8b` healthy with 0 restarts, flag on, 0 errors or warnings in 36 h, counter 26956, nightly backup with offsite copy 3/3.
- The 483 `box_msgs` rows: nothing new since 10-21 on the stuck ones, count falling (490 → 483).
  - 275 sit in one FCM device's 16 queues (10-16..10-21; subscribed 10-28, nothing taken). Its token matches no `fcm_token` row (checked as a yes/no, decision 81), so the owner is unknown.
  - 30-day TTL; first expiries 11-01. Nothing else is blocked: the delivery window is per socket, and the open band is 30 000.
- `legacy-freeze.ts` `legacyListsSilent`, with `LEGACY_LISTS_SILENT` validated in `env.validation.ts`. Boot refuses `'true'` unless `LEGACY_WRITES_FROZEN='true'` (reviewer P3: `deviceListStale` on an open path).
- Gated sites, all silence and never `[]`:
  - `chat-friend-request.service.ts` `emitFriendsListToBoth`, `emitConversationsListToBoth`, `handleGetFriends`;
  - `chat-conversation.service.ts` start (`openConversation` only), `getConversations`, delete (`conversationDeleted` only);
  - `chat-message.service.ts` `getServedMessageIds`;
  - `chat-device-list.service.ts` `mayReadDeviceList`: self only.
- Compose: dev `${LEGACY_LISTS_SILENT:-false}`, staging `${STAGING_LEGACY_LISTS_SILENT:-false}`, prod pinned `'false'`.
- Docs: `wire.md` "List silence"; `backend/CLAUDE.md`; plan §"What remains for step 4's server half" (BUILT, reach check, rehearsal); decisions E124a; root `CLAUDE.md` count 1263/71.
- Out-of-repo:
  - `.env.staging` gained `STAGING_LEGACY_LISTS_SILENT=false`; frozen left `true`.
  - Staging stack `down` (volumes kept). Docker Desktop is running.
  - The CDP Chrome (port 9461) and the `s4web` static server (8301/8302) were still running at write time.
  - `%TEMP%/s4web`, `%TEMP%/s4logs`, `%TEMP%/s4probe.cjs`, `%TEMP%/s4up.ps1` are left behind.

## Key files
- Edited: the four services and their specs, `legacy-freeze.ts`, `env.validation.ts`, the three compose files, `wire.md`, the plan, the decisions log, `CLAUDE.md`, `backend/CLAUDE.md`.
- New: `backend/src/config/env.validation.spec.ts`.
- Read only: `connection_provider.dart:990-1030, 1124-1185` (served-ids null purges nothing; resume probe counts `serverTime`), `box-delivery.service.ts`, `box_inbox.dart`.

## Verification
- CI: green 6/6 on `248059e8`.
- Backend 71 suites / 1263 tests. ESLint ratchet held at 850/147 (+2 `unbound-method` in my spec, fixed). `tsc` clean, knip clean, no-user-logs OK.
- Mutants: each of the 8 gates removed in turn; all 8 killed.
- Reviewer subagent: no P0–P2. P3 fixed: the boot guard; tests run in the prod combination; the invitation-chat test; the `openConversation` id is asserted.
- Reach check (read-only prod, decision 122): 21/23 accepted-pair accounts have opened since 0.2.70. The two that have not: benz93 (waived) and goonboy (48, last 10-21; friends bob208 and alteregobob8). 0 live devices without a queue.
- Staging rehearsal (prod compose, working-tree backend, web build of `0f9517d7`, freeze on). Every item is in plan §"What remains…": pre-box pair, box pair, re-login, delete chat, unfriend, account delete, raw probe, resume, rollback, boot guard. Counter flat at 26855.
- NOT verified: native APK under silence; builds ≤ 0.2.69 (must update); prod (nothing deployed).

## Notes for next session
- Next: the owner's go, not before ~11-05 (one week of freeze watch). Before it, ask who goonboy is. Then:
  1. Commit flipping `docker-compose.prod.yml` `LEGACY_LISTS_SILENT: 'true'`.
  2. CI green, then a backup.
  3. `./deploy-backend.sh`.
  4. Verify `printenv`, `/version`, 0 errors, and a probe that `getFriends` gets no answer.
  5. The owner sends a message both ways.
- Code can ship with the flag `'false'` any time; it is a no-op until the flip.
- Owner-owed:
  - the step 4 go;
  - who goonboy is;
  - `backup.pass` off the VM.
- Found, pre-existing since the freeze, not blocking (delayed, not lost): delete a pre-box chat, then the friend's next message shows only after the next app start.
- Recipes:
  - `%TEMP%/s4up.ps1` clears the inherited env and runs `staging.ps1 up`.
  - Login field coordinates on this build: (210,435), (210,498), button (210,564).
  - Swipe-delete = `G.drag(n,380,y,40)`.
  - A real resume: `Browser.setWindowBounds` minimized → normal. `Page.setWebLifecycleState frozen` kills the sockets, so it is not a resume test.
- Traps: inherited `ALLOWED_ORIGINS` shadows `.env.staging` (added to traps.md, Deploy).
