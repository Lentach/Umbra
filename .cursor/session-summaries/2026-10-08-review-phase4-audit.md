# 0.2.62 independent review: 3 small fixes; Phase 4 audit finds an unrecoverable message-text purge and a staged plan

**Date:** 2026-10-08 · **Version:** 0.2.62 (unchanged) · **Tiers deployed:** none

## What was done
- Owner asked for an independent review before the merge and a 100 % check that deleting the server friend list is safe. `code-review` skill (Standards + Spec agents) plus three audits (0.2.62 data safety, Phase 4 backend dependencies, Phase 4 client delete paths) and read-only prod `SELECT`s.
- Verdict 0.2.62: no code path deletes or shrinks data on a device. Merge `6cc7d6db` dropped no master fix (decision 88/93 files unchanged).
- Fix: `ContactBackupService.mintFromPassword` returns true when a row another device minted meanwhile was opened, and marks this device's view owed (`_dirty`). It used to say "could not save" while the backup existed.
- Fix: `widgets/web_push_request_feedback.dart` `showWebPushRequestFeedback`, shared by Settings and the chat list's push-off line. The line used to show "Failed to enable push: " for `noChange`/`unsupported`/`requiresStandalone`.
- `messaging_provider.box.dart` H1 mute check uses `getConversationById` (repo pattern).
- Runbook rotation (`.omp/rules/production-vm-deploy.md`): recreate the inbox container after its `.env` change; tell users on rotation day (box messages expire unread after 30 d); no rollback to an old-key bundle.
- Phase 4: `docs/plans/2026-10-08-friend-row-gap-check.md` rewritten as the full audit + staged plan; trap added. It corrects its first version: an empty `friendsList` deletes nothing; a partial one does; path A (plaintext reconcile) was missed.
- Out-of-repo: CDP Chrome on 9333 relaunched (tabs `?devA` 127.0.0.1:8091 bob, `?devB` 127.0.0.1:8093 ana, `?devC` localhost:8091 bob 2nd device); local bob `contact_backups` row deleted and re-minted; `frontend/build/web` rebuilt (`GIT_COMMIT=review3`, pair B). Nothing written on prod.

## Key files
- Edited: `contact_backup_service.dart`, `contact_backup_service_test.dart`, `settings_screen.dart`, `conversations_screen.dart`, `messaging_provider.box.dart`, `production-vm-deploy.md`, `traps.md`, `2026-10-08-friend-row-gap-check.md`, `scripts/dart-lint-baseline.json`.
- New: `frontend/lib/widgets/web_push_request_feedback.dart`.
- Read only (load-bearing): `encryption_provider.dart:1411-1456` (reconcile purge), `messages.service.ts:356-368`, `friends_provider.dart:183-199, 634-657`.

## Verification
- CI: see the follow-up line in Notes (PR #198 head after this commit).
- Flutter 3107 passed / 14 skipped; count script `--log` OK. Dart lint ratchet PASS, 3153 → 3147 (floor lowered).
- CI: 7/7 success on `1ecfd91b` (contains code commit `97e02c2e`; PR #198 head).
- Web drive, release build `review3`: bob on two origins, row deleted, both reload → sheet on both; password on A → `PUT` 200, row rev 1; password on C → `GET` 200, no `PUT`, sheet closed, line gone (old code: "could not save"). Push-off line on C: tap → subscribed, toast "Powiadomienia push włączone", line gone.
- Settings "Włącz powiadomienia push" tap: `POST /users/web-push-subscription` 201 but NO toast. Same on a build with the pre-change `settings_screen.dart` (`oldsettings`): pre-existing, not caused here, not fixed.
- Prod (read-only, 10-08): 65 friend pairs, all old-path; 72 of 75 users with friends have no backup (23 of 26 active in 30 d); 118 active devices, 95 without a request queue; 13 old-path messages since the box launch; no FK into `friend_requests`.
- NOT verified: iPhone, Android (the mute refactor is unit-tested only), prod.

## Notes for next session
- Next action: owner's go for merge + deploy (unchanged gate-B plan in `NEXT.md`). Phase 4: owner reads the staged plan in the gap-check doc; nothing is deleted on prod before step 1 of it ships.
- Owner-owed: must old-path history stay readable after Phase 4 (needs local rendering)? Accept that accounts which never ran 0.2.52+ lose their friends when `friend_requests` drops?
- Open review items not fixed (LOW/MEDIUM, owner-visible only in edge cases): the backup line can vanish while an upload is still owed (sent at next connect); Later count not reset on account switch; `verify-password` throttle is per IP, not per account; contact backup is last-writer-wins across devices (Phase 4 prerequisite).
- Recipe: Flutter toasts last 2.5 s; capture them with `page.screenshot` every 300–400 ms inside one `tab.run` and diff the hashes. `overridePermissions` must run in the same `tab.run` as the tap or it is gone.
