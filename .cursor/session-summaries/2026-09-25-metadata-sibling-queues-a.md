# Sibling queues part A is on the branch (CI 7/7), and metadata-privacy decisions now live in one tracked log

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy`, not master)

## What was done
- Owner decisions 26–29 (`task_plan.md`): the address swap goes through each device's REQUEST queue, not the link blob. One self-queue per device. No backup carries `boxsib_v1`. No auth-key escrow: a revoked device's queues are left to the 90-day reaper. `design-candidate.md` §4.2 is changed to match; nothing in §8 "parked" covers these.
- Backend `ChatSearchService.handleGetOwnRequestQueues` + gateway `getOwnRequestQueues` → `ownRequestQueues`. It serves the caller's own other live devices, claims no pre-key, and is throttled 30/15 min with its own refusal answer. A failure never comes back as an empty list.
- Client:
  - `contact_store_siblings.dart`: the `boxsib_v1` row.
  - `QueueKeys.ensureSelf`.
  - Account-bearing `BoxFrame` kinds 0x12/0x13, and `BoxInbox._intakeRequest`, which reads only frames naming our own account.
  - `queue_handoff` / `queue_handoff_ack` in `e2e_envelope.dart`.
  - `BoxSiblingSwap`, the sibling branch in `MessagingProvider.consumeBoxEntry`, and `BoxSession.takeSiblingHandoff` (store → ack → hand ours back).
- Security, found in review, each fixed test-first with a killed mutant:
  - `prekey_identity.dart`: a sibling PreKey message must carry the ACCOUNT identity key, checked before decrypt. The request queue is public and the identity store is TOFU, so a stranger's PreKey message would otherwise replace the real session.
  - The self-queue goes only to devices the own VERIFIED list names live.
  - An unreadable request-queue frame is finished, not held.
- Found by live drive 1:
  - A device on the link gate holds the PRIMARY's token, and it published its request queue as device 1, overwriting A's.
  - Fix: publish and swap wait for E2E-ready on that connect.
  - A sibling listed under our own sid is skipped.
  - A received handoff is answered with ours, which closes the primary's `devices:[]` race.

- Decision process (owner, S8): decisions are classed OWNER / ENGINEERING and batched per phase.
  - `docs/plans/metadata-privacy-decisions.md`: every decision with a unique id (D1–D12, A1–A5, B1–B4, S1–S8, 1–33) and its status; the engineering calls E1–E4; O1 open (G6 convergence).
  - `docs/plans/2026-09-25-metadata-pr31-remainder.md`: the order and every engineering call for the rest of PR3.1.
  - The owner answered O2–O5 in one pass → decisions 30–33: box total ~3 GB (2 GiB media + 60k blobs), honest 429 over the media budget, no push on the self-queue, D5 kept (one mutual switch, default OFF).
  - `AGENTS.md` names the log as the authority; master's `traps.md` points at it.
- Rebased onto master (32 MiB + nginx docs had made PR #185 `CONFLICTING`, so no PR CI ran). `--force-with-lease`; part A is now `a8a4e560`.

## Key files
- New:
  - `frontend/lib/services/box/{box_sibling_swap,box_siblings}.dart`
  - `frontend/lib/services/contacts/contact_store_siblings.dart`
  - `frontend/lib/services/encryption/prekey_identity.dart`
  - 4 test files: `contact_store_siblings_test`, `box_session_siblings_test`, `messaging_provider_box_sibling_test`, `prekey_identity_test`
- Edited:
  - `backend/src/chat/{chat.gateway.ts,guards/ws-throttler.guard.ts,services/chat-search.service{,.spec}.ts}`
  - `frontend/lib/services/box/{box_frame,box_inbox,box_session,queue_keys}.dart`
  - `contact_store.dart`, `sealed_web_content_kv.dart`, `encryption_service.dart`, `e2e_envelope.dart`
  - `connection_provider.dart`, `encryption_provider.dart`, `messaging_provider{,.box}.dart`
  - `docs/contracts/wire.md`, `frontend/docs/e2e-invariants.md`, `docs/agents/traps.md`, `CLAUDE.md` (counts)

## Verification
- Backend: jest 1197/68, count gate OK. ESLint ratchet held.
- Frontend:
  - `flutter test` 2572 passed / 14 skipped; `verify-claude-frontend-test-counts` exit 0.
  - `flutter analyze` 0 errors / 0 warnings; ratchet 3163 held.
- Mutants killed, 12, each file restored by sha1:
  - identity gate;
  - send to non-live / self;
  - hold on liveness / no-session;
  - publish gate;
  - E2E reset on disconnect;
  - own-sid skip;
  - no hand-back;
  - hand-back before ack (pinned by an exact 4-send count);
  - send on unstored;
  - always hand back.
- Drive 1 (local stack, 2 headless Chromes over CDP, account 274, link via the app UI):
  - Found the gate bug: both device rows got the same request sid, and B hit `BOX_SIBLING_DECRYPT_FAILED badMac` on its own frame.
  - Converged only after reloads.
  - A stranger's PreKey handoff was refused.
- Drive 2 (fresh build with the fixes, fresh account 278, link SAS `159 553`):
  - B sent 0 `setRequestQueue` while gated; after the link the two devices had distinct request sids.
  - Converged WITHOUT a reload. A logged `BOX_SIBLING_HANDOFF {device: 2, acked: true, handedBack: true}`; B logged `{device: 1, acked: true}`. Exactly 4 box sends and 4 queues.
  - A reload sends nothing.
  - Stranger 279 → `BOX_SIBLING_FOREIGN_IDENTITY` on both devices, and no session with it.
  - No `box_*` column names a user.
- CI on `dbe54d3a` (the rebased tip, part A included): 7/7 success. After the rebase: backend 1197, box int 27/27, box Flutter 149.
- Rebase check: `git diff 9a16a85d HEAD` over `wire.md`, `traps.md` and `LATEST.md` shows master's facts only. The first scripted resolution committed conflict markers (CRLF) in a throwaway worktree: aborted, `rr-cache` entry deleted, redone with rerere off. Nothing bad was pushed.
- NOT verified: Android and native (web only); a device linked BEFORE this build (the swap should run at its next connect; not driven); iOS.

## Notes for next session
- Owner questions go into a batched design note, never mid-slice (S8); an order or decision change is asked as "changes decision N". Part B needs none.
- Part B, in order:
  1. Sent copies over the sibling self-queues, with `_boxRoute` covering every live own device (all-or-nothing, decision 16). The envelope must name the peer so the sibling files the copy.
  2. Rotation on revoke (decision 27).
  3. Healing a sibling no-session and an age cap.
  4. Pruning revoked siblings from `boxsib_v1`.
  5. Then box push registration (decision 23).
- Live-drive recipe, since the omp browser daemon was broken this session: two Chromes, separate `--user-data-dir`, raw CDP, portrait 420x880, `display-mode: standalone` override. Traps → `docs/agents/traps.md` (5 lines).
- `docker compose up` strips the `libc` lines from `backend/package-lock.json`: restore that one file before any commit.
