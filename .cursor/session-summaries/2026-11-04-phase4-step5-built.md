# Phase 4 step 5 built and rehearsed: old server path dropped, revoked device ends its own wake-ups

**Date:** 2026-11-04 · **Version:** unchanged (0.2.73 live; no bump) · **Tiers deployed:** none

## What was done
- Owner decisions 126–131 (decisions log; master's #208 took 125 first, so this branch's ids moved up by one): `blocked_users` drops (126), attachment notice in release notes (127), archive to owner's PC (128), own branch + staging rehearsal + separate go (129), a revoked closed device ends its own wake-ups (130, supersedes 125's server teardown), paced to one check per device per 24 h (131).
- Server (`feat/phase4-step5`): migration `0027_phase4_step5_drop_old_tables.sql` drops 9 tables + 3 enums; old chat/friends/block/reaction/account-push modules, `/media/upload`, `/media/msgs`, the msgs/ sweep and both `LEGACY_*` flags removed; `getDeviceList(s)` own id only; link-preview moved to `backend/src/link-preview/` (E126a).
- Client: contact store is the only source of friends/blocks/requests/chats; every send over the box (no route = red, retryable); block/unfriend/timer device-only; clear-chat copy says "here" (owner OK); Android box card opens the app (owner OK) (E126b).
- Decision 130 (E130a): `/auth/refresh` answers a revoked device's kept refresh row `401 Device revoked`; `RevokedWakeUpCheck` (Android background isolate) and `web-push-sw.js` (`SW_VERSION` 4) drop the push registration on that answer only; the box drops the notifier on `gone`.
- Merged master's #208 review 2 (`a745e4d9`): its server notifier teardown and `PushService.registerAgain` removed (they join through the dropped tables), the rest of #208 kept.
- Out-of-repo: `%TEMP%/p4s5/compose.override.yml` (dev stack project `p4s5`, ports 3100/5434, stopped); `%TEMP%/s5reh` keeps rehearsal screenshots and scripts only (decrypted dumps deleted); Docker Desktop restarted twice after it quit by itself.

## Key files
- New: `backend/migrations/0027_phase4_step5_drop_old_tables.sql`, `backend/src/link-preview/*`, `frontend/lib/services/wake_up_revocation_check.dart`, `wake_session_{web,stub}.dart`, `frontend/test/support/{chat_seed,contact_seed,box_send_harness}.dart`.
- Edited: `backend/src/auth/{auth,refresh-tokens}.service.ts`, `chat-device-revocation.service.ts`, `chat.gateway.ts`, `users.service.ts`, `friends_provider.dart`, `conversations_provider.dart`, `connection_provider.dart`, `messaging_provider.*.dart`, `encryption_provider.dart`, `push_service.dart`, `web/web-push-sw.js`.
- Docs: `docs/contracts/wire.md` (step 5, decision 130 bullets), `backend/CLAUDE.md`, `frontend/CLAUDE.md`, `frontend/docs/e2e-invariants.md`, gap-check doc step 5 line.

## Verification
- CI: 7/7 green on `e86da5f9` (merge of master `b5afc1e8`, #208 final code; PR #210 MERGEABLE). That merge removed #208 review 3's `box-notifier-teardown.ts` + its int test and `ConnectionProvider`'s `pushService` seam (served only the `registerAgain` test), kept the rest; one restore test now seeds the account first (step 5 asks `getDeviceList` for the own id only). Local: jest 785/47, int 58/2, flutter test 3001 (14 skipped), analyze 0 errors/warnings, lint 269/74.
- Merged build drives (11-05, `e86da5f9`): web — an account with pre-merge data kept its chats across the bundle update; invite + accept, text both ways, block (device-only list), account delete; 0 backend ERROR. Merged release APK (runbook gate 2) — revoked + closed: one card, `stopped`, backend `device_revoked`, next send not delivered, notifier row gone; live + closed: `notRevoked`, notifier kept, app opened signed in with the message. Drive APK and throwaway key deleted from both output paths after.
- Merge `a745e4d9`: backend build + jest 785/47; flutter analyze no errors/warnings (2494 infos, baseline); flutter test 2994, 14 skipped; backend lint ratchet at 269/74.
- Prod read-only (decision 86), re-run 11-05: 23 accounts in 25 pairs; 2 without a contact backup (benz93, jarekk; waived, 119); `blocked_users` 0, `fcm_token` 2, `web_push_subscription` 30, `messages` 49 rows, 0 pending requests; `msgs/` 4.6 MB (2 files).
- Dev web drive (`88d24ddd`, ports 3100/8320/8321): box invite/accept, text both ways, image, 1 h timer on both, reload keeps chat, block (device-only list), account delete; 0 ERROR/WARN.
- Decision 130 drive (real Chrome + real Web Push): revoked closed device asked once, got `Device revoked`, unsubscribed; box notifier rows 1→0 on the next send; a live closed device asked once and kept push.
- Staging rehearsal (`chatdb-20261104T040002Z`, baseline `352278a1` → `a745e4d9`): 0027 applied in 216 ms, /health gap 7.7 s, 0 ERROR; old 0.2.73 tabs and step-5 clients both ways; timer, block/unblock, unfriend, wipe+restore, account delete, mixed versions; native APK on Pixel_7 both ways; executed rollback (pg_restore) in 35 s, 0027 re-applied 203 ms.
- Android decision 130 drive (11-05; release APK of `cfc968db` signed with a throwaway key, Pixel_7 Play image, p4s5 stack with the VM's Firebase key passed inline and dropped after, web friend sending real box messages; revoke = the `devices.revokedAt` stamp): revoked + closed → one card, `[wake-up] revoked-device check: stopped`, backend `device_revoked source=refresh_endpoint`; next send not delivered, FCM notifier row deleted, message kept in the queue. Live + closed → `notRevoked`, notifier kept; next wake `throttled`; app opened signed in with both messages. Seen once: on a fresh emulator boot the first notifier pass after an accept registered nothing (park); a relaunch registered within 10 s, the second account within 5 s (pre-existing E9 behaviour).
- Archive procedure (schema-only dump + data-only dump of the nine tables) restored rows and enum values on a scratch Postgres 16.
- NOT verified: iOS PWA, prod.

## Notes for next session
- Next action: once #208 ships 0.2.74 (its pubspec bump lands on master), merge master once more (expect only the version line + docs), bump `pubspec.yaml` to 0.2.75, CI green, then ask the owner for the go per the runbook. Gates 1 (code), 2 (Android) and 3 (count) are done.
- Deploy runbook: `docs/runbooks/phase4-step5-deploy.md` (gates, archive commands, backup, order, `msgs/` removal, release notes EN/PL, rollback). Android gate (decision 130) PASSED 11-05.
- Then the deploy (owner's go, decision 129), per the runbook.
- Owner 11-05 (decisions 132–135): ship 0.2.74 now; step 5 no sooner than 24 h after 0.2.74 is verified; release notes as written; archive to `Desktop\umbra-archive-step5`; unblock only lifts the block. Owner-owed: the step 5 go itself.
- Open: rehearsal pair C lost messages (`DECRYPT_FAIL InvalidKeyIdException`) after the machine drop; three clean reruns passed, [INFERENCE] a damaged key store; watch for it. After unfriend/block of the last chat the "?" screen stays open (pre-existing auto-pop rule).
- Recipes: dev stack `docker compose -p p4s5 -f docker-compose.yml -f %TEMP%/p4s5/compose.override.yml up -d`; web drive in the eval `browser` needs `flt-semantics-placeholder` click and `page.bringToFront()` before typing; real Web Push needs real Chrome + `--dart-define=WEB_PUSH_VAPID_PUBLIC_KEY`.
- Traps: `git worktree remove --force` follows a junction (traps.md, Agent tooling).
