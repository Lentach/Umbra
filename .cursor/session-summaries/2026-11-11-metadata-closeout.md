# Metadata-privacy series closed out: decision 139 recorded, METADATA.md rewritten to the box-only server

**Date:** 2026-11-11 · **Version:** unchanged (0.2.82 live) · **Tiers deployed:** none

## What was done
- `docs/plans/metadata-privacy-decisions.md`: new OWNER decision 139 (PR #243, `7b924a05`).
  - The series closes once release B (decision 138's avatar deletion, ≥ 12-08) is live and verified.
  - Decisions 90, 105/110 and 124 become ordinary backlog items.
  - Owner: "yes im agree", then "close up the whole thing".
- `docs/METADATA.md` rewritten to match the code since 0.2.76. It still described the dropped `messages`/`conversations`/`friend_requests`/`blocked_users`/`message_envelopes`/`fcm_tokens` tables. It now covers:
  - what the server cannot see;
  - the tables it does keep, taken from the backend entities and migrations (`box_*`, `devices`, keys, sessions, `contact_backups`, `secret_notes`, the old photos until release B);
  - the accepted residuals with their decision ids: IP and timing (R82), handle lookups (53/56/120), request queue ↔ device (I2b, decision 1), one device's queues grouped by its push token (E9), a shared attachment linking its receivers (44), the revoked-check timing (131), and push providers.
- `contact_messages` / `contact_push_subscriptions` (migrations 0009/0010) are listed as tables no backend code reads or writes; checked by grep of `backend/src`.
- Out-of-repo: none.

## Key files
- Edited: `docs/METADATA.md`, `docs/plans/metadata-privacy-decisions.md`.
- Read only: `backend/src/box/entities/*.entity.ts`, `backend/src/users/{user,profile-photo}.entity.ts`, `backend/migrations/0009_*.sql`, `0010_*.sql`, `docs/contracts/wire.md` (I2b, E9, push payloads).

## Verification
- CI: docs-only. PR #243 ran CodeQL + Analyze (actions), both success; this commit's PR is docs-only too.
- The table list matches `\dt` on a fresh local stack built from master in the 0.2.82 session. Each column claim was read from its entity file.
- No code changed, so nothing was driven on a device.

## Notes for next session
- Next action: none in the metadata series until release B (`docs/plans/2026-11-08-e2e-profile-photos.md`, on or after 2026-12-08). After release B lands, drop the "Old profile photos" row from `docs/METADATA.md`. The owner wants to work on something new next.
- Owner-owed: the Settings footer for 0.2.82; deleting the throwaway prod accounts (list in `NEXT.md`); do83rman's iPhone log; Dependabot minimatch; `backup.pass` off the VM; EN/PL release notes.
- Backlog (decision 139): 90 VAPID rotation, 105/110 PWA retirement count, 124 both-friends-relogin loss.
- Possible cleanup, owner's call: drop the unused `contact_messages` / `contact_push_subscriptions` tables (it needs a migration).
