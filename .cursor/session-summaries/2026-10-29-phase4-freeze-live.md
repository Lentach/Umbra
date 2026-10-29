# Phase 4 step 3 LIVE: prod refuses new old-path messages, friend requests and chats

**Date:** 2026-10-29 · **Version:** unchanged (backend 0.2.72, `e45825e8` → `41117d8b`) · **Tiers deployed:** backend

## What was done
- Pair tests closed (E111c-r2, `metadata-privacy-decisions.md`):
  - The owner sent SaraLee (63) and BestiaBestia (85) a message from bob208 (37), and both replied.
  - `messages_id_seq.last_value` read 26956 at 00:27Z, flat since 10-20 17:01.
  - All three accounts' request queues were subscribed on 10-28 UTC (`box_queues."touchedDay"` joined on `devices."requestSid"`).
  - bob208's durable log reads `BOX_ROUTES {friends: 25, routed: 25, owed: 0}` through 10-29.
- Freeze date gate corrected: the "no earlier than 10-30" in the 10-27/10-28 notes had no source. E111c-r already had the 7 quiet days met on 10-27. Fixed in `2026-10-28-relogin-both-diagnosis.md` (`06caa52f`).
- The owner said "go". `docker-compose.prod.yml` `LEGACY_WRITES_FROZEN: 'true'` (`41117d8b`); the docs moved with it in the same commit:
  - `backend/CLAUDE.md`;
  - `docs/contracts/wire.md` "Old-path freeze";
  - plan step 3 in `2026-10-08-friend-row-gap-check.md`;
  - E111a.
- Prod: backup `chatdb-20261029T003919Z.dump.gpg` (with env and media), then `./deploy-backend.sh`.
- Out-of-repo: none (the prod VM was deployed as above; no services left running).

## Key files
- Edited: `docker-compose.prod.yml`, `backend/CLAUDE.md`, `docs/contracts/wire.md`, `docs/plans/2026-10-08-friend-row-gap-check.md`, `docs/plans/metadata-privacy-decisions.md` (E111a, E111c-r2), `2026-10-28-relogin-both-diagnosis.md`.
- Read only: `backend/src/chat/utils/legacy-freeze.ts`, `backend/src/box/entities/box-queue.entity.ts` (`touchedDay` = UTC day of the owner's last subscribe), `frontend/lib/services/box/box_friend_handoff.dart:252-271` (`BOX_ROUTES`).

## Verification
- CI: green 6/6 on `41117d8b` (Analyze, Flutter analyze and tests, E2E isolated probes, wire harness, Web Lock probe, Backend tests).
- No code changed: no ratchets or tests run locally.
- Prod after the deploy:
  - `/version` = 0.2.72 / 41117d8b, android 20072;
  - `/health` ok, container healthy;
  - `printenv LEGACY_WRITES_FROZEN` → `true`, `BOX_ENABLED` → `true`;
  - 0 `error|exception` lines in the 3 minutes after start;
  - counter 26956.
- NOT verified: a send on prod after the flip, from the owner's device (asked of him); the 0.2.72 APK on a real phone.

## Notes for next session
- Next: the 1–2 week watch (from 10-29). Meanwhile build the step 4 server half test-first. Spec: `2026-10-08-friend-row-gap-check.md` §"What remains for step 4's server half":
  1. Silence `friendsList`, `conversationsList`, `getServedMessageIds` (never `[]`).
  2. `getDeviceList(s)`: answer only the caller, and drop the friend/conversation entitlement (`chat-device-list.service.ts:275-293`).

  Rehearse on staging before the owner's go; it ships no earlier than 11-05.
- Watch signal: a refused old-path send writes nothing and logs nothing on the server, and the counter cannot move. A pair still stuck on the old path shows only as a user report of red "Ponów". Undo = `'false'` + `./deploy-backend.sh`.
- Owner-owed:
  - one message from his device after the flip, to confirm ✓;
  - the step 4 go;
  - copying `backup.pass` off the VM.
- Re-login-both: still PARKED (decision 124).
- Traps: the refusal is silent server-side (added to `traps.md`, Deploy group).
