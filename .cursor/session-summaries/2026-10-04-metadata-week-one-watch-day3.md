# Week-one watch, day 3: box quiet and far from the band, 0 refusals; old path still only the owner's pairs

**Date:** 2026-10-04 (check at 02:31Z) · **Version:** unchanged (0.2.58) · **Tiers deployed:** none

## What was done
- Read-only prod check (E65b), recipe from `2026-10-01-deploy-0258.md` Notes, compared with day 2 (10-01 23:22Z, recorded in that summary). Day 2 was NOT skipped: it ran right after the 0.2.58 deploy.
- Health: `/version` `0.2.58 / 51ed95fa`, `/health` ok, `/version.json` 0.2.58; backend up since 10-01 20:32:02Z, healthy, 0 restarts. Disk 31 % (12 of 38 GB). Nightly backups 10-01/02/03 present, last log line `healthcheck pinged`.
- Box totals: 100 msgs (0.333 % of 30 000) and 51 MB media (4.938 % of 1 GiB). Day 2: 12 msgs / 49 MB. `box_msgs` 100 = Σ `msgCount` 100. Media: 16m×2, 4m×4, 1m×2, 256k×2, 64k×1.
- Held messages: 12 queues hold the 100; one queue holds 56, the rest ≤ 9. Oldest 10-02 15:54Z, 16 older than 24 h, first `expiresAt` 11-01 (30 d). A recipient device that has not come online since, `[INFERENCE]`: the server cannot say whose.
- Queues: 77 normal (all on probation, `probationUntil` 10-07 … 10-10), 22 request. Day 2: 58 / 16. `touchedDay` spread 09-30 … 10-04 (18 today).
- Notifiers (rows / distinct tokens): FCM 15 / 2, Apple 24 / 8, Chrome 13 / 9. Day 2 rows: FCM 13, Apple 17 / 6, Chrome 11 / 7. Apple web-push users in `web_push_subscription`: 17 (unchanged).
- Devices: 116 live, 21 with a request queue (day 2: 16, day 0: 5). 95 have not opened 0.2.53+ since the flip.
- Old path: 62 `messages` rows since the day-2 check, last 10-03 18:17Z, in 5 pairs, every one with the owner (37): 37↔63 (40), ↔62 (11), ↔49 (5), ↔90 (4), ↔100 (2). All 6 users have a live device with a request queue (37 has 2). No non-owner pair on the old path. Out-of-repo: none (nothing written on prod).

## Key files
- Edited: `.cursor/session-summaries/LATEST.md`.
- New: this summary.
- Read only (load-bearing): `2026-10-01-deploy-0258.md` (day-2 baseline, recipe), `fireplace-mp/.cursor/session-summaries/2026-09-30-metadata-week-one-watch-day{0,1}.md`.

## Verification
- CI: unchanged since `58de6091` (6/6, recorded 10-02); no code changed this session, so not re-checked.
- Logs (`docker compose -f docker-compose.prod.yml logs --timestamps backend`, 195 lines since 10-01 20:32Z): 0 `[box]` refus/fail, 0 `push refused`, 0 ERROR, 0 WARN (day 1's two `REFUSED legacy send` WARNs did not recur; the `getMessages` box-id `QueryFailedError` did not appear either).
- SQL via `ssh ubuntu@51.68.138.13` + `docker compose … exec -T db psql -U postgres -d chatdb -X` on stdin: the recipe queries, plus `box_msgs` age/per-queue spread and a per-pair old-path query (`messages` join `conversations` on `conversation_id`, `least/greatest(user_one_id, user_two_id)`, `"createdAt" > '2026-10-01 23:22'`).
- No device drive: no code changed. NOT verified: which pairs are on the box; whose device holds the 56-message queue; iOS users beyond the owner.

## Notes for next session
- Next action: day-7 watch on or after 2026-10-07, same queries. E65c: a normal queue whose `probationUntil` is ≤ today must read NULL once its owner subscribes or acks. Queues keep being created (max is 10-10 now), so "every queue NULL after 10-08" no longer holds: count `"probationUntil" <= current_date` and expect it to fall as owners open the app; the full sweep is 10-11 or later.
- **Phase 4 is NOT next after the watch.** Branch decision 83 (`feat/metadata-privacy`): 0.2.55 (H1 + the one-time password sheet, decisions 81 and 76, `POST /users/verify-password`) ships before any PR4.x, and decision 77's (O1) 6-week backstop starts at that deploy. 0.2.55 (`562ba915`, `adc54142`) is NOT on master or prod: `merge-base --is-ancestor adc54142 origin/master` fails, 0 `verify-password` hits in master's `backend/src` / `frontend/lib`. Order: merge 0.2.55 into master (it is behind 0.2.58), CI, deploy, then O1 convergence, then PR4.1/PR4.2.
- **Owner decisions 85–87 (10-04, branch `be81f7a3`):** 85 the password sheet is REQUIRED (no "Later", no snooze), so 0.2.55's `contact-backup-prompt-later` button and `snoozeContactBackupPrompt` must go before it ships; 86 no 90-day rule and no 6-week clock, the owner calls the table drop himself (show him the count of accounts with pairing rows and no backup first); 87 the PWA is a temporary iPhone-only option, native Android is the product. Order now: merge + change the sheet, CI, deploy 0.2.55, owner calls Phase 4.
- Backup on prod (10-04): 3 `contact_backups` rows, users 128, 129 (09-30) and 90 (10-03). The owner (37) has none. The restore was driven on a wiped emulator and on web (local stack, 09-20 and 09-21 summaries on the branch), never on prod.
- **Decision numbers 76–81 collide** in `docs/plans/metadata-privacy-decisions.md`: the branch has 76–84 dated 09-30 (password prompt, O1, security push, media, notice, H1, Phase 5 drop, 0.2.55 order, rest of Phase 5); master has 76–81 dated 10-01 (PWA notifications). The merge must renumber one side and its `E76a`-style references. Master's 76 (a hidden page posts its own card) overlaps branch 81 (H1): reconcile the code too.
- APK is still `0.2.53` (20053, `/version` `android`).
- Watch the 56-message queue: if it still holds on day 7, the device is gone or broken, not slow; the 11-01 expiry reaps it.
- The question still open from day 1: does a NON-owner pair ever show on the old path. Not yet.
- Still open (unchanged): users' 10-02 push reports and E84 (`wip/e84-old-path-push`), VAPID rotation, `getMessages` box-id bug to file. Phase 5 is answered on the branch (decision 82: dropped); `traps.md` Owner-owed still says unanswered, fix it at the merge.
- Traps: none new.
