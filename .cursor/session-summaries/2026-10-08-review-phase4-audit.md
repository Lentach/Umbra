# 0.2.62 independent review: 3 small fixes; Phase 4 audit finds an unrecoverable message-text purge and a staged plan

**Date:** 2026-10-08 · **Version:** 0.2.62 (unchanged) · **Tiers deployed:** both + APK (0.2.62 / `2dccae8a`, no VAPID rotation)

## What was done
- Owner asked for an independent review before the merge and a 100 % check that deleting the server friend list is safe. `code-review` skill (Standards + Spec agents) plus three audits (0.2.62 data safety, Phase 4 backend dependencies, Phase 4 client delete paths) and read-only prod `SELECT`s.
- Verdict 0.2.62: no code path deletes or shrinks data on a device. Merge `6cc7d6db` dropped no master fix (decision 88/93 files unchanged).
- DEPLOYED 05:39–05:45Z: master fast-forwarded `2f3075db → 2dccae8a` (CI 7/7 on the master push); backup `chatdb-20261008T052657Z.dump.gpg`; backend `/version` 0.2.62/2dccae8a with android 20062; web `PUBLISHED_OK` (guard: "Bundle carries the live backend's VAPID public key"), smoke 8/8 `SMOKE PASSED`; APK `/apk/umbra-0.2.62.apk` (SHA256 `5e11065b…5082d0f`, signer `8e9a6bf3…5cdf405d` = record-of-truth; VM `.env.bak.pre-apk-0.2.62`). 0 error/warn lines after the restart. Not booted on an emulator (the AVD had exited).
- Prod writes (owner OK): temporary passwords for users who forgot theirs, each with no recovery phrase, no backup row, no open identity reset. Only `users.password` replaced (bcrypt-10, `UPDATE … WHERE password = <old>` → `UPDATE 1`, stored hash re-checked); `passwordChangedAt` left NULL and no token revoked, so live sessions stay. Old hashes (0600) in `~/fireplace-backups/` for undo: user 83 noobster1122 `user83-hash-20261008T150235Z.txt`; 96 duchdupy (owner wrote "duckdupy") `user96-hash-20261008T151729Z.txt`; 101 jarekk `user101-hash-20261008T151958Z.txt`. Passwords went to the owner only, in no file.
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
- CI: 7/7 success on `2dccae8a` (branch push and master push; the deployed code).
- Flutter 3107 passed / 14 skipped; count script `--log` OK. Dart lint ratchet PASS, 3153 → 3147 (floor lowered).
- Mutants killed (concurrent-mint test): drop `_dirty = true`; restore the old `uploadNow()` return.
- Web drive, release build `review3`: bob on two origins, row deleted, both reload → sheet on both; password on A → `PUT` 200, row rev 1; password on C → `GET` 200, no `PUT`, sheet closed, line gone (old code: "could not save"). Push-off line on C: tap → subscribed, toast "Powiadomienia push włączone", line gone.
- Settings "Włącz powiadomienia push" tap: `POST /users/web-push-subscription` 201 but NO toast. Same on a build with the pre-change `settings_screen.dart` (`oldsettings`): pre-existing, not caused here, not fixed.
- Prod (read-only, 10-08): 65 friend pairs, all old-path; 72 of 75 users with friends have no backup (23 of 26 active in 30 d); 118 active devices, 95 without a request queue; 13 old-path messages since the box launch; no FK into `friend_requests`.
- NOT verified by agent: iPhone, Android (the mute refactor is unit-tested only). Prod notifications: owner confirmed "notifications seem working correctly" after the deploy; read-only at ~06:30Z: 6 users seen since 05:45Z, `web_push_subscription` 40 rows (baseline 40), 0 created after the deploy, 6 updated (same endpoints re-registered: no swap), 0 error/warn lines in 2 h.

## Notes for next session
- Next action: the cull list (decision 100) for the owner to confirm, then Phase 4 step 1. Keep `web_push_subscription` rows created after 05:45Z at 0 (baseline 40 rows); a new row from an existing user would mean a swap.
- Owner answered (decisions 97–100): merge + deploy 0.2.62 only if PWA notifications do not break, so it ships WITHOUT the VAPID rotation (90 deferred: a rotation cuts every PWA's push until the next open, an iPhone's until a tap); the staged Phase 4 plan is approved; old-path history may disappear; inactive/test accounts get culled first (threshold + list owed to the owner; prod buckets in the gap-check doc, step 0).
- Plan step 3 narrowed after review: freeze the old tables and keep the list handlers serving the frozen rows (silencing `conversationsList` would reconnect every resume); `getServedMessageIds` goes only at cut-over, after `git log -L` proves old builds read silence as "no answer".
- `mintFromPassword` comment narrowed: the owed write survives only until this session's next connect; a reload drops it (the flush half is unit-tested, not driven).
- Not changed (nit, kept as before): the `failed` push toast still appends the raw error text, in Settings and now on the chat-list line.
- Open review items not fixed (LOW/MEDIUM, owner-visible only in edge cases): the backup line can vanish while an upload is still owed (sent at next connect); Later count not reset on account switch; `verify-password` throttle is per IP, not per account; contact backup is last-writer-wins across devices (Phase 4 prerequisite).
- Recipe: Flutter toasts last 2.5 s; capture them with `page.screenshot` every 300–400 ms inside one `tab.run` and diff the hashes. `overridePermissions` must run in the same `tab.run` as the tap or it is gone.
