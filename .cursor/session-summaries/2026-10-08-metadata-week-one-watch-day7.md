# Week-one watch, day 7+: box quiet, the 56-message queue drained, 5 of 119 accounts have a contact backup

**Date:** 2026-10-08 (check at 2026-10-07 23:10Z) · **Version:** unchanged (0.2.61) · **Tiers deployed:** none

## What was done
- Read-only prod check, the day-3 recipe. Backend `/version` 0.2.61 / 7d8f37ca, `/health` ok, 0 restarts, 0 ERROR/WARN, no `[box]` refusal lines.
- Box 25 msgs / 86 MB (0.08 % / 8.4 % of the open band); `box_msgs` = Σ `msgCount`; 0 expired rows unreaped. The 56-message queue of day 3 drained (max now 5).
- Queues: 60 of 88 normal queues on probation; 8 are past their probation date and not cleared. 23 of 118 live devices have a request queue.
- Old path since day 3: only 37↔90 (9 rows) and 37↔93 (5 rows), both the owner's pairs.
- Prod counts: 119 accounts; active 7/30/90 d = 20/28/51. Active 30 d by platform: iPhone PWA 11, Android PWA 10, native Android 3, no push 4.
- `contact_backups`: 5 rows (users 128, 129, 130, 131, 90; 130/131 are the restore-test accounts). The owner (37) has none; his last password login was 09-14. 65 accepted pairs; 72 of the 75 accounts in the friend graph have no backup.
- 104 `platform = 'legacy'` devices are migration 0015's backfilled primaries (one per account), not stale extras: auto-unlinking stale devices would not lower the request-queue count.

## Key files
- New: this summary. Read only: the day-3 summary (`2026-10-04-metadata-week-one-watch-day3.md`, recipe and baseline).

## Verification
- ssh + psql on stdin, `docker logs | grep`, `curl /version`, `/health`. Nothing written on prod.
- NOT verified: why 8 queues past their probation date are not cleared.

## Notes for next session
- The backup ask in 0.2.62 (decisions 94/95) is what raises the 5; re-count `contact_backups` a week after the deploy, and check `"userId" = 37`.
- The 8 uncleared probation queues: look at the probation reaper before Phase 4.
