# Week-one watch, day 1: real users are on the box; the two v10 refusals are the owner's own bounce-and-resend

**Date:** 2026-09-30 (check at 21:38Z, 17 h after day 0) · **Version:** unchanged (0.2.54) · **Tiers deployed:** none

## What was done
- Read-only prod check, same recipe as day 0. Backend `0.2.54 / 80957c7f` healthy, 0 restarts, `/health` ok.
- `box_totals` 93 msgs / 22 020 096 bytes (day 0: 0); `box_media` 3 blobs (1m, 4m, 16m buckets one each). Far from the open band (30 000 blobs / 1 GiB).
- Queues: 36 normal (all on probation, 0 with `probationUntil` null, correct before 2026-10-07), 13 request (day 0: 10 and 5).
- Notifiers: fcm 3, webpush 19 (13 `web.push.apple.com`). Day 0: fcm 2, webpush 2 (1 Apple).
- Devices: 116 live, 103 with no request queue. A request queue is the only trace of "opened a 0.2.53+ client since the flip", so **the 103 have not yet opened 0.2.53/0.2.54**. 0.2.55 is not deployed and is not involved.
- Logs: no `[box] refusals`, no `push refused`, no ERROR. Two WARNs: `[send] REFUSED legacy send to an enrolled party staleVersions=v10` at 04:49:47Z and 16:13:28Z.
- Old path: 60 `messages` rows since 01:44Z (day 0: 5), last 20:50:15Z.

## Findings (what the numbers mean)
- **Old-path rows by pair:** all 60 are in 7 pairs, and every pair has user 37 (the owner) on one side (54/48/96/92/90/101/83 → 37, 13/13/10/7/5/5/5 msgs). Both sides of every pair have a live device with a request queue (37 has two). So a request queue on both ends does NOT put a pair on the box: the pair also needs its contact exchange. Expected only as "not yet paired", NOT as "not yet upgraded".
- **The two refusals:** "enrolled" in that log line means a signed device list (multi-device), not a box queue (`chat-message.service.ts` ~L420: a legacy single-ciphertext send to a party with a device list bounces `deviceListStale` with both lists, and the client resends as a fan-out). Each refusal is followed 181 ms (16:13:28.919 → 16:13:29.109) and 211 ms (04:49:47.027 → 04:49:47.238) later by a `messages` row from **user 37 to 101, and from 37 to 48**. So the senders are the owner's own device, and nothing was dropped. The logs carry no user id and refused sends write no row, so the sender is identified from the timing match: `[INFERENCE]`, strong, not proven.
- **Apple users:** `box_notifiers` has no user link by design, so "users who still owe an open" is not derivable. 13 Apple notifiers vs 17 Apple-subscribed users counts notifiers, not users; an earlier "~4 of 17 owe" figure was wrong and is withdrawn.

## Key files
- Edited: `.cursor/session-summaries/LATEST.md`. New: this summary.
- Read only (load-bearing): `backend/src/chat/services/chat-message.service.ts` ~L385-436 (refusal), `2026-09-30-metadata-week-one-watch-day0.md` (baseline).

## Verification
- Commands as day 0 (ssh + psql on stdin, `docker logs | grep`, `curl /version`, `/health`), plus a per-pair query over `messages` joined to `conversations` with live request-queue device counts. Nothing written on prod.
- NOT verified: which contact pairs are on the box (the server cannot say); the sender of the two refusals beyond the timing match; `probationUntil` null after 2026-10-07; iOS pairs.

## Notes for next session
- Next watch: on or after 2026-10-07 for probation null (E65c), same queries. Signals: request-queue devices (13 of 116) and Apple notifiers growing; `box_totals` vs the band; any `[box] refusals` / `push refused`.
- 60 old-path rows all involve the owner: the pairs are the owner's test contacts. Expect old-path rows to stay until PR4.x; the question to ask is whether a NON-owner pair ever appears.
- Still owner-owed: the 0.2.55 deploy go-ahead, Phase 5 drop, princepolo's logout cause, the receipts default-on question.
