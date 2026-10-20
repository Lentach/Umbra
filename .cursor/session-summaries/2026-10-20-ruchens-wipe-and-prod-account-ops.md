# Silent box loss after a PWA storage wipe investigated (cause open); benz93 reset and ruchens69 deleted on prod

**Date:** 2026-10-20 · **Version:** unchanged (0.2.67) · **Tiers deployed:** none (prod data writes)

## What was done
- Decision 104 plan doc (`docs/plans/2026-10-17-decision-104-unsent-box-messages.md`) settled:
  - the store is one key per tempId `e2e_<uid>_boxunsent_v1_<tempId>`, registered in the web `_familyKey` AND `NativeContentStore.isSealedKey`, so a removal is shredded;
  - ttl expiry, logout sweep and catch-up exclusion added; tests to write first listed.
  - `af979f78` (drop `isSealedKey`) was wrong and is reverted by `5ffc4266`.
- Found, not fixed: `boxact_v1` holds edit text but is not in `isSealedKey` (Android residue gap), logged in the plan doc.
- Prod: benz93 (user 86) password set to the owner's temporary value, mirroring `UsersService.setPassword` (bcrypt 10 inside the backend container, all refresh tokens deleted, `passwordChangedAt` stamped). A probe login's token was deleted after.
- Prod: ruchens69 (user 90) deleted at the owner's request, through `DELETE /users/account` (a random one-time password was set first, so the real `deleteAccount` path ran). Backup taken right before.
- Investigation of bob208 → ruchens69 box messages shown ✓ but never received (no code change; findings under Notes).
- Out-of-repo: backup `chatdb-20261020T170150Z.dump.gpg` (+ media, env) in `~/fireplace-backups/`. No services left running by this session; the dev stack `fireplace` is still up from earlier.

## Key files
- Edited: `docs/plans/2026-10-17-decision-104-unsent-box-messages.md`, `docs/agents/traps.md`, this summary, LATEST.
- Read only (load-bearing): `messaging_provider.box.dart` (`_boxRoute` :1874, decision-88 handoff take :1070-1153, `_readFriendHandoff` :232), `contact_backup_service.dart` (no-op gate :475-501, restore seed :677-684), `contact_record.dart` `toBackupJson`, `friends_provider.dart:184`, `signal_stores.dart` `isTrustedIdentity`, `users.service.ts` `setPassword`/`deleteAccount`.

## Verification
- CI: NOT RUN on `1aa1c3d0` and later: docs-only pushes (CodeQL only). Deployed code unchanged at `28ac55af` (CI green).
- benz93: in-container `bcrypt.compare` → true; `POST /auth/login` → 201; DB in UTC, stamp before `now()`; 0 tokens left.
- ruchens69: login 201, delete 200 `Account deleted successfully`; after: no users/devices/tokens/key_bundles/contact_backups rows for 90; 23 users; 0 backend error lines.
- NOT verified: benz93 logging in on his own device; the native APK on ruchens's phone.

## Notes for next session
- Next action: build decision 104 test-first (`docs/plans/2026-10-17-decision-104-unsent-box-messages.md`): the rerun of its §"Before building" first, then the listed tests red, then the store. Decision 105 (owner, 10-20): no PWA storage-wipe work; after 104, finish Phase 4, then prepare the Android release, whose prep includes one reinstall test (a friend's messages must still arrive).
- Findings (10-20, prod read-only + both diag logs):
  - user 90 re-minted 6 times in 17 days (`identity_change_audit` 10-03 … 10-20), each a full PWA storage wipe (phone storage full);
  - bob's device logged `PEER_IDENTITY_CHANGED {peerId: 90}` with no `source` at 16:13:18 local. That suggests a receive under the new key, but a send-side session build is not fully ruled out;
  - queue `13fd904b…` got its first message 7 s later and held 12 unread to 18:43 local. It is a candidate for his new queue, unproven;
  - his live log showed no `BOX_*` line after `SOCKET_READY` and no list fetch for 37. The lead: the restored PWA's box receive never starts. NOT confirmed;
  - his contact backup stayed rev 3 (10-09); that is by design (restores never upload), not evidence.
- Owner-owed: the old ruchens69 is a box friend (`boxOrigin`), which `friends_provider.dart:184` never sweeps. bob208 must remove it by hand before befriending the new account.
- Owner-owed (carried): the `getMessages` local-id fix (`connection_provider.dart:833`, `:1124`); the same-origin re-link bug. Phase 4: 101–103 are built (0.2.66, rows now DONE). What remains of step 1 (`2026-10-08-friend-row-gap-check.md` §Safer plan) is the client hardening release:
  - stop deleting on absence (`friends_provider.dart:196` `_unlisted` still returns null for a server friend without queues);
  - carry chat id, request-queue addresses and the device list in the contact backup;
  - merge the backup on a 409;
  - send the app version at connect.
  - Then steps 2–5 (measure, freeze, cut over, archive + drop).
- Shelved by decision 105: the PWA wipe repro (recipe: wipe a test user's web storage, restore, send to it, watch the restored side for `BOX_*` after `SOCKET_READY`). Reopens only if the Android reinstall test fails.
- Prod facts 10-20: benz93 (86) still has device 1 without a request queue (the only one on prod); last old-path message 10-11.
- Traps: two lines added to `traps.md` (E2E).
