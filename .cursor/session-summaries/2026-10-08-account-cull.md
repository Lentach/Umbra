# 79 inactive and test accounts deleted on prod (decision 100); 40 accounts remain

**Date:** 2026-10-08 · **Version:** unchanged (0.2.63) · **Tiers deployed:** none (prod data write)

## What was done
- Owner picked from the full list (by last refresh): every account with no live session (54), every account last seen before 2026-06-24 (12), and every account marked as a test account (13: `rbandr1808`, `rbweb1808`, `apk053t3565`, `web053t6929`, `vnitdesk1-3,5,6`, `vnitdroid1`, `test_apk_release`, `test_apk_receiver`, `probeA8308`; `vnitdesk4`, `test_web_sender`, `test` were already in the first group). 79 ids; the 40 kept are everything seen since 06-24 that is not a test account.
- Deleted in ONE transaction, mirroring `UsersService.deleteAccount` (no password exists for an admin delete): guards first (exactly 79 ids, all exist, none of the 40 kept ids, none of the non-test accounts seen after 07-01), then `messages` of their conversations (envelopes cascade), their `conversations` (reaction keys, prefs cascade), their `friend_requests`, then `users` (devices, tokens, key bundles, OTPs, push rows, backups, recovery keys, photos cascade). `conversations`/`messages` FKs to `users` are NO ACTION, hence the explicit order.
- Avatar files of the deleted accounts unlinked inside the backend container after the commit (4 deleted, 2 already gone; each checked unreferenced first). Old message media under `msgs/` goes with the nightly media sweep (R79).
- Out-of-repo: backup `chatdb-20261008T183741Z.dump.gpg` taken right before; the id list and avatar keys were not kept on disk.

## Key files
- Edited: `docs/plans/metadata-privacy-decisions.md` (100 → DONE), `docs/plans/2026-10-08-friend-row-gap-check.md` (step 0 done), LATEST.
- Read only (load-bearing): `backend/src/users/users.service.ts` `deleteAccount`, `backend/src/media/local-storage.service.ts` `deleteFile`, prod `pg_constraint`.

## Verification
- CI: NOT RUN for this session's commits (docs only); the deployed code is unchanged at `3df3e092` (CI green).
- Dry run (read-only) before: 79 victims, 26 conversations, 22 messages, 27 friend rows, 77 devices, 4 backups; only 2 kept users lose a friend (bob208 loses 2 of 32).
- After: users 119 → 40, friend pairs 65 → 38, conversations 64 → 38, messages 126, backups 6, devices 44, `web_push_subscription` 36; 0 backend error/warn lines in 10 min.

## Notes for next session
- Next action: read-only check of `contact_backups` for 83, 96, 101 (temporary passwords), then Phase 4 step 1 (`docs/plans/2026-10-08-friend-row-gap-check.md`).
- Kept accounts' devices drop the deleted friends as contacts at their next `friendsList` and purge the text of those chats (owner accepted, decision 100).
- Recipe for a later cull: the guards + delete order above, inside `BEGIN … COMMIT` with `psql -v ON_ERROR_STOP=1`; backup first; avatars via the backend container with the `deleteFile` containment check.
