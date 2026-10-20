# Ketokeczup (user 54) given an owner-chosen temporary password on prod; sessions kept

**Date:** 2026-10-21 · **Version:** unchanged (0.2.67) · **Tiers deployed:** none (one prod data write)

## What was done
- Prod (owner's request, owner-chosen password, 2026-10-20 22:38Z UTC): `users.password` for user 54 `Ketokeczup#6087` replaced by a bcrypt-10 hash made inside `fireplace-backend-1`, the hash-only recipe of 10-08/10-16: `UPDATE … WHERE id = 54 AND password = <old>` → `UPDATE 1`.
  - `passwordChangedAt` NOT stamped (still `2026-08-23 18:14:41`), no refresh token revoked: his 3 rows stay, one slid 2026-10-20 21:20Z, so his device stays signed in.
  - Old hash (0600) for undo: `~/fireplace-backups/user54-hash-20261020T223844Z.txt`. Password given to the owner only, in no file.
- Preflight (the recipe's conditions, all held): no `recovery_keys` row, no `contact_backups` row, no `identity_reset_requests` row for 54.
- Out-of-repo: none besides the write and the backup file above. Temp script `/tmp/reset54.sh` on the VM deleted after the run.

## Key files
- Edited: this summary, LATEST, `docs/agents/traps.md` (one Agent-tooling line).
- Read only (load-bearing): `backend/src/auth/auth.service.ts:58` (login = `bcrypt.compare(password, user.password)`), `backend/src/auth/password.constants.ts` (`PASSWORD_REGEX`: upper+lower+digit; the password passes), `2026-10-08-review-phase4-audit.md` (recipe).

## Verification
- CI: NOT RUN: docs-only push. Deployed code unchanged at `28ac55af` (CI green).
- In-container `bcrypt.compare(<new password>, <stored hash>)` → `true`: the exact check `POST /auth/login` runs. No probe login (it would mint a refresh row on his account).
- After: user 54 still holds 3 refresh rows, `passwordChangedAt` unchanged.
- NOT verified: Ketokeczup typing it on his own device.

## Notes for next session
- Next action: unchanged from the 10-20 decision-104 entry (Phase 4 step 1 hardening release).
- Owner follow-up: Ketokeczup should type the new password into Settings → "Chroń swoje kontakty" on his ALREADY signed-in device; that mints his contact backup (he had none, E95b). Not a fresh login on a new install: an unenrolled account re-mints device 1 (E38c for his friends).
- Undo: write the saved hash back with the same `WHERE password = <current>` guard.
- Trap: `ssh host 'bash -s'` with a `docker compose exec -T` inside: the exec reads the rest of the script from stdin, so the script stops there and exits 0 with no output. Also appended to `traps.md`.
