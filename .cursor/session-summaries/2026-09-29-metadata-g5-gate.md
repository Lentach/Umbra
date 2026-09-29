# G5 passed: gate review fixed, field-version upgrade rehearsed, release N step A live (0.2.52, box OFF)

**Date:** 2026-09-29 · **Version:** 0.2.51 → 0.2.52 · **Tiers deployed:** both (backend + web; APK NOT yet)

## What was done
- G5 gate review of `14c1f22d..7096a5f8` (4 agents: deploy compat, box security, spec, standards). No BLOCKER for step A; MAJORs fixed in `3b470dac` (5 fix agents + 1 review, P3 folded):
  - E64a kept first-contact frames byte-capped; E64b journal bounded + revoked/absent origin finished; E64c carried list I7-verified before it can spend a lookup; E64d box-action seal throw reverts; E64e `BoxClient` 15-min retry on `Invalid namespace`; E64f history import re-ids local ids (one `allocateLocalIds` block, tombstones read once); E64g web seals `boxact/boxlists/boxdel`; E64h ack exemption for in-flight ids, `live` only on normal queues.
  - Owner said "decide for me": decisions 64–69 are agent calls on the owner's behalf (log section "G5 decisions"): residuals 57–60 re-signed; 65 reserved ceiling band (migration 0026 `probationUntil`, E65a); 66 `searchUsers` `[]` for server friends while box off; 67 receipts row hidden until on the box; 68 request-queue frames never time a server call, friend re-key window 30 d; 69 FCM checked on the owner's phone after step B.
- `5c18cdf0` release commit 0.2.52; master fast-forwarded to it from `fireplace-0a`. Backup tags pushed: `pre-release-n-master` (2acd49b1), `pre-release-n-prod-backend` (14c1f22d), `pre-release-n-prod-web` (d37e2dcc).
- Prod: backup `chatdb-20260929T185318Z.dump.gpg` (+media, env) → `deploy-backend.sh` (0023–0026 applied, `BOX_ENABLED=false`, BoxModule skipped, 0 error lines) → `deploy-web.ps1` from `fireplace-0a` (PUBLISHED_OK; its smoke gate exits 1 there, no playwright) → smoke from `Fireplace`.
- Out of repo: `.env.staging` ALLOWED_ORIGINS gained `127.0.0.1:8201-8203` (mp + `fp-g5-master`); `fp-g5-master` left detached at 8b5c7378; `fireplace-0a` master now at 5c18cdf0; staging stack down (volumes kept, holds g5_* accounts); Pixel_7 AVD holds g5_dan on the RC debug APK; `%TEMP%/g5/` holds the builds.

## Key files
- Edited: `backend/src/box/{box.service,box.gateway,box-delivery.service,box-throttler.guard,box.constants,box.module}.ts`, `backend/src/chat/services/chat-search.service.ts`, `frontend/lib/services/{box/*,backup/history_backup_service,contacts/contact_store_inbox,device_list/device_list_cache,encryption/sealed_web_content_kv,encryption_service}.dart`, `frontend/lib/providers/messaging/messaging_provider.{box,box_actions,first_contact}.dart`, `frontend/lib/screens/{privacy_safety,storage_loss}_screen.dart`, docs (decisions log, wire.md, e2e-invariants, traps, CLAUDE.md counts), `frontend/pubspec.yaml`.
- New: `backend/migrations/0026_box_queues_probation.sql`, 3 test files.

## Verification
- CI: 7/7 success on `3b470dac` and on `5c18cdf0` (= master tip; the master push created no extra run, the PR run is the same SHA).
- Local: Jest 1222/68, box int 49, flutter 3017 (14 skipped), analyze 0 errors/warnings, Dart ratchet 3156 held, ESLint ratchet 850 held, knip/verify-no-user-logs/verify-box-imports clean. Fix agents: every new rule mutant-killed except noted survivors (dead guard removed; cache generation check kept).
- Staging rehearsal (prod image, own volume): master backend+clients (g5_ada APK / g5_bea web) → branch backend box off (0023–0026 applied): old web + old APK chat both ways, old web search for a friend = "Nie znaleziono" (66) → branch clients installed OVER (`install -r`, same origin): login + history kept, 1 box attempt then silence for 110 s (E64e), receipts row absent (67) → box ON: handoff, box both ways, `messages` count unchanged, `box_*` columns hold no user id.
- Field-version path (advisory): web `d37e2dcc` (g5_cara) + APK `8b5c7378` (g5_dan) with history incl. a voice note → RC `5c18cdf0` over both: login + history kept, chat box-off both ways; box ON: box both ways, `messages` 96 → 96.
- Prod smoke 8/8 PASS `--commit 5c18cdf0`.
- NOT verified: release-signed APK (not built); FCM; iOS; prod push after deploy on a real device; import remap/kept caps/carried list only by unit tests.

## Notes for next session
- Next action: publish the 0.2.52 APK (APK last). Keystore lives ONLY in the main checkout `Desktop/Fireplace` (feat/passcode-lock, still at 2acd49b1): ff that branch to master, `build-android.ps1`, scp to `~/fireplace/apk/umbra-0.2.52.apk`, set `ANDROID_APK_*` in VM `.env` to 20052, `deploy-backend.sh`, check `/version` android block.
- Step B (box ON in prod) is a separate owner-visible step: needs a reviewed compose change of `BOX_ENABLED`, then FCM check on the owner's phone (decision 69).
- Owner (delegated at G5, may overrule before step B): decisions 64–69. Owner check on prod: background the app a minute, send one message, push must arrive.
- Rollback for step A: redeploy tags above (migrations 0023–0026 are add-only; previous backend runs on them).
- Traps: `docs/agents/traps.md` (deferred re-key window line, E20c line, BoxClient cadence line, import line).
