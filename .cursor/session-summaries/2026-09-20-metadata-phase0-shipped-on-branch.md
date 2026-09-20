# Metadata privacy Phase 0 on `feat/metadata-privacy` (PR #181): no presence clocks, no note owner, no account id in any log; nginx logs off live

**Date:** 2026-09-20 · **Version:** unchanged (backend code on the branch only; nginx change live) · **Tiers deployed:** none (nginx vhost config only)

## What was done
- `infra/nginx/fireplace.conf`: `access_log off` + `error_log … crit` in both server blocks, applied LIVE (`f3eaafe3`, `b4e1e2c2` on master; comment residuals `3419e040` on the branch). Backups `~/nginx-fireplace.bak.1789858515/.1789859216`.
- Worktree `C:/Users/Lentach/Desktop/fireplace-mp` = `feat/metadata-privacy` off master; draft PR #181 gives the branch CI (`ci.yml` triggers on `pull_request`). Master is untouched; merge = fast-forward at gate G0 after owner OK.
- `788fbe07` PR0.1: `devices.lastSeenAt` dropped (migration 0019); `DevicesService.touch` → `ensureRow` = one `INSERT … ON CONFLICT DO NOTHING` for device 1 only (still the only creator of a legacy row; `isRevoked` never denies on a missing row); provisioning/reset-roster inserts no longer stamp a clock.
- `f34ad83e` PR0.3: `secret_notes.creatorId` + FK dropped (migration 0020); `SecretNotesService.create(ciphertext, ttl)`. Behaviour change: account deletion no longer cascades into notes; ≤24h TTL bounds them.
- `2ff62540`/`f0d6da5b`/`5637cc73` PR0.4: 147 log strings across ~30 files stripped of userId/username/identifier AND sender↔recipient pairs; `scripts/verify-no-user-logs.mjs` (identifier-based, case-insensitive, regex-literal aware, self-test, `// log-guard: key` opt-out on 8 non-log literals) wired into the backend CI job. `key_bundles.updatedAt` no longer re-stamped on every connect (`skipUpdateIfNoValuesChanged`).
- Two independent reviews (`reviewer`: APPROVE-WITH-EDITS; `security-reviewer`: REQUEST-CHANGES) — every finding folded: recoverPassword failures carry `reason=unknown_account|wrong_phrase`; docs/METADATA.md now states exactly what step 0 closed and which activity timestamps remain; multi-device.md §4/§12 + spec line; backend/CLAUDE.md FK/0002-reversal note; root CLAUDE.md count 1139 + CI step list.
- Plan `.planning/metadata-privacy/task_plan.md` §5 operating procedure written (worktree, proof ladder, gates G0–G6); the copy in `fireplace-mp` is canonical, the old checkout's copy deleted.

## Key files
- Edited: `backend/src/key-bundles/{device.entity,devices.service,devices.service.spec,key-bundles.service,key-bundles.service.spec,device-list.service,identity-reset.service,reset-roster.service}.ts`, `backend/src/chat/chat.gateway.ts`, `backend/src/chat/services/{chat-message,chat-provisioning,chat-key-exchange,chat-device-list,chat-device-revocation,chat-friend-request,chat-conversation,chat-reaction-key}.service.ts`, `backend/src/chat/guards/ws-throttler.guard.ts`, `backend/src/auth/auth.service.ts`, `backend/src/secret-notes/*`, `backend/src/blocked/blocked.service.ts`, `backend/src/users/{users.service,users.controller}.ts`, `.github/workflows/ci.yml`, `CLAUDE.md`, `backend/CLAUDE.md`, `docs/METADATA.md`, `docs/design/multi-device.md`, `infra/nginx/fireplace.conf`.
- New: `backend/migrations/0019_drop_devices_last_seen.sql`, `0020_drop_secret_notes_creator.sql`, `scripts/verify-no-user-logs.mjs`. Next migration number: **0021**.
- Read only (load-bearing): `backend/src/database/migration-runner.ts`, `backend/src/main.ts:10-21`, `frontend/test_e2e/support/e2e_test_client.dart`, `.planning/metadata-privacy/{design-candidate,task_plan}.md` (untracked).

## Verification
- `cd backend && npm test`: 64 suites / 1139 tests on every commit (was 1140; 5 touch tests → 4 ensureRow tests). Count guard OK. Lint ratchet real errors 897 → 891, formatting 157 → 153. knip clean. Log guard: 106 → 0 (v1), then 49 → 0 (v2) with self-test OK.
- Local stack (fresh DB): runner applied 0001…0020; `devices` = `userId,deviceId,name,platform,isPrimary,addedAt,revokedAt`; `secret_notes` = `id,token,ciphertext,expiresAt,createdAt`; `fk_secret_notes_creator` gone.
- `flutter test test_e2e` against the migrated stack: 46 passed / 14 skipped (4 clean runs); 15 device rows / 9 accounts, 0 `ensureRow` failures; live container log during the run: 0 id-bearing lines.
- Throwaway probe (deleted): same device, reconnect + identical bundle → `key_bundles.updatedAt` unchanged (`03:31:46.415091` twice); changed bundle → moved.
- CI on PR tip `5637cc73`: 7/7 success (backend, flutter, session-lock, e2e-wire, e2e-isolated, CodeQL, actions).
- Live nginx: only delta vs backup = the directives; `/apk/` block intact; `/health` 200; access.log flat (8870 → 8870 over 6 requests); a `/apk/` 403 no longer grows error.log (1 → 1); VM file byte-identical to the branch.
- NOT verified: production backend (Phase 0 code not deployed); the send-refusal / block-delete-failure log branches are unit-covered only; Android/iOS untouched.

## Notes for next session
- Owner-owed: **G0** — fast-forward master to the branch tip + `./deploy-backend.sh` on the VM (bundles the D10 backend deploy owed since 09-19), or hold. Then G1 brainstorm (ContactStore schema, two competing shapes) before PR2.2. Full handoff prompt was given in chat; plan order in `task_plan.md` §2/§5.
- Residuals stated in code/docs: main-context nginx `error_log` (level `error`) still names client IPs on connection-phase errors; refresh-token expiry slide ≈ daily last-active; envelope delivered/read stamps — all fall with the queue cutover.
- Traps (also in `docs/agents/traps.md`): dev `nest --watch` DOES recompile on this box; register bucket exhausts after two harness runs; `npm ci` rewrites package-lock; regex sweeps damage code; prettier at hunks only; specs pin log text; a column write may double as an existence probe; relative paths from the wrong worktree.
