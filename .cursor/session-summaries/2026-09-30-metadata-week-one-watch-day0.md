# Week-one watch, day 0: the box is quiet; only the owner's and two test accounts are on it

**Date:** 2026-09-30 · **Version:** unchanged (0.2.54) · **Tiers deployed:** none

## What was done
- Read-only prod check (E65b) at 04:36 UTC: ~3 h after step B, ~50 min after the 0.2.54 backend came up (container started 03:46:42Z, healthy, 0 restarts; `/version` 0.2.54 / 80957c7f, `/health` ok).
- `box_totals` = 0 msgs / 0 bytes and the tables agree (`box_msgs` 0, `box_media` 0): nowhere near the open band (30 000 blobs / 1 GiB).
- Backend logs since that start (158 lines): no `[box]` line at all (no `refusals`, no `web push refused`, no `fcm push refused`), no ERROR/WARN. The pre-03:46 container's logs went with the 0.2.54 recreate.
- Queues: 10 normal, all on probation (`probationUntil` 2026-10-07); 5 request. Notifiers: fcm 2, webpush 2 (1 `web.push.apple.com`: the owner's, verified 04:09:49).
- Coverage: 116 live devices, 111 with no request queue. The 5 with one: alteregobob8 #1, bob208 #1 and #11, and the two throwaway prod accounts from E75a (`apk053t3565` #1, `web053t6929` #1). No real user outside the owner has opened a 0.2.53+ client since the flip.
- iPhone rollout: `web_push_subscription` holds 18 Apple endpoints for 17 users; only the owner has a box notifier, so 16 users still owe their next open.
- Old path: 5 `messages` rows since the flip (01:44Z), all in the owner's pair (37 ↔ 75), the last at 03:04:53Z, before 0.2.54 and the iPhone's notifier; none since.
- Out-of-repo: nothing changed by this session (the throwaway prod accounts, staging and the emulator state from `2026-09-30-metadata-step-b-054.md` were not touched).

## Key files
- Edited: `.cursor/session-summaries/LATEST.md`, `docs/agents/traps.md`.
- New: this summary.
- Read only (load-bearing): `backend/src/box/box-reaper.service.ts` (`sweep` logs `[box] refusals` only when a count is non-zero), `box-push.transport.ts` (the two refused-push warns), `box.int-spec.ts` I2 column list (box schema), `docs/plans/metadata-privacy-decisions.md` E65b/E65c/E75a/E75b.

## Verification
- CI: 6/6 `ci.yml` success on `80957c7f` (last code commit, re-checked this session). `12fba7e7` and this handoff are docs-only: CodeQL only.
- Commands: `ssh ubuntu@51.68.138.13`, then `docker compose -f docker-compose.prod.yml exec -T db psql -U postgres -d chatdb -X` with the SQL on stdin; `docker logs --timestamps fireplace-backend-1 2>&1 | grep -F '[box]'`; `curl 127.0.0.1:3000/version` and `/health`. Nothing written on prod.
- No device drive: no code changed. NOT verified: that a real user's pair reaches the box (none has connected yet).

## Notes for next session
- Next action: repeat the watch once real users have opened the app (Polish evening or later), same queries, against this baseline. Signals:
  - devices with a request queue > 5, notifiers growing, Apple notifiers vs the 17 Apple users;
  - `box_totals` vs the open band; any `[box] refusals` / `push refused` line;
  - on or after 2026-10-07: a normal queue whose owner subscribed must read `probationUntil` null (E65c).
- Recipe (SQL on stdin to the psql above):
  - `select * from box_totals; select count(*) from box_msgs; select "sizeBucket", count(*) from box_media group by 1;`
  - `select kind, count(*), count(*) filter (where "probationUntil" is null) from box_queues group by kind;`
  - `select platform, count(*), count(*) filter (where token like '%web.push.apple.com%') from box_notifiers group by platform;`
  - `select count(*), count(*) filter (where "requestSid" is null) from devices where "revokedAt" is null;`
  - `select count(distinct "userId") from web_push_subscription where endpoint like '%web.push.apple.com%';`
  - `devices` has no last-seen column: "opened since the flip" shows only as a request queue.
- Open (unchanged): H1; NOT driven on a device: decision 70's same-pass re-key and `no_anchor` handoff, typing to a partly covered friend, release APK smoke items 4–7; E73b.
- OWNER-owed: drop Phase 5 (Arti, B4)? Unanswered; what to log if yes is in `2026-09-30-metadata-step-b-054.md` Notes.
- After the watch: convergence (O1 at G6), then Phase 4 (PR4.1/PR4.2 = release N+1).
- This commit was pushed to `feat/metadata-privacy` only (AGENTS.md: a non-main worktree pushes only its own branch); master reaches it by a fast-forward from its own worktree.
- Traps: Agent tooling (shared remote-tracking reflog), in traps.md.
