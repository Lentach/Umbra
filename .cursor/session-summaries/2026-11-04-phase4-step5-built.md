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
- CI: NOT RUN on `a745e4d9`: PR #210 conflicts with master again (#208 review 3, `a56e382d`); only CodeQL ran.
- Merge `a745e4d9`: backend build + jest 785/47; flutter analyze no errors/warnings (2494 infos, baseline); flutter test 2994, 14 skipped; backend lint ratchet at 269/74.
- Prod read-only (decision 86): 23 accounts in 25 pairs; 2 without a contact backup (benz93, jarekk; waived, 119); `blocked_users` 0 rows; `msgs/` 4.6 MB.
- Dev web drive (`88d24ddd`, ports 3100/8320/8321): box invite/accept, text both ways, image, 1 h timer on both, reload keeps chat, block (device-only list), account delete; 0 ERROR/WARN.
- Decision 130 drive (real Chrome + real Web Push): revoked closed device asked once, got `Device revoked`, unsubscribed; box notifier rows 1→0 on the next send; a live closed device asked once and kept push.
- Staging rehearsal (`chatdb-20261104T040002Z`, baseline `352278a1` → `a745e4d9`): 0027 applied in 216 ms, /health gap 7.7 s, 0 ERROR; old 0.2.73 tabs and step-5 clients both ways; timer, block/unblock, unfriend, wipe+restore, account delete, mixed versions; native APK on Pixel_7 both ways; executed rollback (pg_restore) in 35 s, 0027 re-applied 203 ms.
- NOT verified: Android FCM background isolate + `deleteToken` (no FCM credentials on dev), iOS PWA, prod.

## Notes for next session
- Next action: when #208 is closed (0.2.74 shipped), merge master into `feat/phase4-step5` again (review 3 adds `box-notifier-teardown.ts` to the teardown step 5 removes), rerun both suites, get CI green on PR #210.
- GATE before the deploy (decision 130: "built and driven before the step 5 deploy"; AGENTS.md device rule): drive the ANDROID revoke path, unit-tested only so far (`RevokedWakeUpCheck` in the FCM background isolate reading `AuthTokenStore`/Keystore, then `deleteToken`).
  - Option 1 (proves the whole chain, preferred): staging stack with the VM's `FIREBASE_SERVICE_ACCOUNT` passed inline on `up` (never written to a file or committed; drop it after), an APK whose `google-services.json` matches that Firebase project, `BASE_URL=http://127.0.0.1:3100`, `adb reverse`, Pixel_7. Link it as a second device, enable push, close the app, revoke it from the primary, have a friend with a stale list send (drop its box frames during the revoke, as the decision 130 web drive did). Pass: one card, `/auth/refresh` 401 `Device revoked` in the backend log, the app's FCM token deleted, its `box_notifiers` rows gone after the next send, no second card. Negative: a live closed device keeps its token.
  - Option 2 (handler only, no prod secret): a non-Play Google APIs AVD with `adb root`, inject the box data message (`am broadcast -a com.google.android.c2dm.intent.RECEIVE` to the app with `type=new_message`), and check the probe and the `deleteToken` call in logcat; the box `gone` step stays unproven.
  - Until it passes, the owner is told the Android revoke path is unit-tested only.
- Then the deploy (owner's go, decision 129): archive the nine tables + `msgs/` gpg-encrypted and scp to the owner's PC (128), backup, `deploy-backend.sh` (0027 at boot), web, APK with release notes naming the attachment deletion (127), remove `msgs/` from the media volume after /health.
- Owner-owed: the step 5 go; whether unblock should re-invite (today it only clears the block, as for box friends).
- Open: rehearsal pair C lost messages (`DECRYPT_FAIL InvalidKeyIdException`) after the machine drop; three clean reruns passed, [INFERENCE] a damaged key store; watch for it. After unfriend/block of the last chat the "?" screen stays open (pre-existing auto-pop rule).
- Recipes: dev stack `docker compose -p p4s5 -f docker-compose.yml -f %TEMP%/p4s5/compose.override.yml up -d`; web drive in the eval `browser` needs `flt-semantics-placeholder` click and `page.bringToFront()` before typing; real Web Push needs real Chrome + `--dart-define=WEB_PUSH_VAPID_PUBLIC_KEY`.
- Traps: `git worktree remove --force` follows a junction (traps.md, Agent tooling).
