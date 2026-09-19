# Metadata-privacy research parked; god-class refactor planned, reviewed, and handed to a fresh agent

**Date:** 2026-09-19 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- Investigated sealed sender vs the July rejection and six comparators (Signal, Threema, SimpleX, Delta Chat 2026, Session, Cwtch/Briar). Verdict: sealed sender alone is theater on a 1:1 app with a server-side `conversations` table; the real foundation is the server→transient-mailbox inversion. Research + 5-step skeleton PARKED by owner in `.planning/metadata-privacy/findings.md` (untracked; enumerates live leaks).
- Re-verified the July metadata audit against code (two scouts): FCM/web-push already content-free, reactions blinded, log caps on; still open: padding, receipts persisted, `devices.lastSeenAt` (a regression vs the audit), `pushClientState.activeConversationId`.
- Measured the codebase (frontend/lib 355 files / 85,604 lines; `EncryptionService` is ONE class 92-4657; format drift 103/355) and mapped the three god-classes by responsibility cluster.
- Refactor plan v1 → independent `reviewer` agent → v2: `.planning/refactor-godclasses/task_plan.md` (+ `findings.md`, 89 KB verbatim maps + review). PR0a knip config → PR0 dead stub + phone probe → PR0-web (owner: PWA state disposable) → PR1 tenants → PR1.5 socket registry → PR2 PlaintextRecordStore → PR3 envelope helper → min-version gate → PR-D10.
- Owner rulings recorded: composer/attachment-picker ship freeze LIFTED (`AGENTS.md:24`, `traps.md:6`, `composer-media.md:3`, both `frontend-composer-media.md` rules); `0cbf17b` revert hazard kept on the AGENTS git line (it carries the identity guard). Android first; iOS bundle id + prerequisites recorded in `docs/runbooks/android-release.md:716-721`.
- Parked metadata step 0 corrected: no server-side tombstone ledger (built and reverted, `traps.md:113`); deletes become per-device mailbox items.

## Key files
- Edited: `AGENTS.md`, `docs/agents/traps.md`, `frontend/docs/composer-media.md`, `.omp/rules/frontend-composer-media.md`, `.claude/rules/frontend-composer-media.md`, `docs/runbooks/android-release.md`.
- New (untracked by design): `.planning/refactor-godclasses/{task_plan,findings}.md`, `.planning/metadata-privacy/findings.md`.
- Read only (load-bearing): `docs/audit/2026-07-07-metadata-privacy-audit.md`, `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/encryption_provider.dart:905-1030`, `backend/src/chat/dto/chat.dto.ts:283-292`.

## Verification
- `cd backend && npm test` → 64 suites, 1164 passed (34 s). `cd frontend && flutter test` → 2215 passed, 14 skipped (4m59s). Both match `CLAUDE.md` §3. `dart format --output=none lib` → 103/355 would change (not acted on).
- `git fetch && git log HEAD..origin/master` → empty; branch at master's tip.
- NOT verified: nothing was deployed, no device or browser was driven; no code changed.

## Notes for next session
- **Fresh agent picks up `.planning/refactor-godclasses/task_plan.md` §"Handoff" — start at PR0a.** Baseline is green; every PR re-runs both suites; stage by explicit path; format only edited files.
- Owner-owed: none blocking the refactor. Before PR-D10: ship the min-version gate (decision 2a). Before metadata work: approve the inversion, receipts default, grace window, TTL read-tick.
- Traps (also in `traps.md`): scout "zero callers" claims were wrong twice — always `lsp references` before deleting; `_legacyDecryptedContentFallback` is a live Android path; Play cannot force updates; `deviceId==1` is spec policy not residue; line-anchored edits split constructs twice — re-read the region after each edit.
