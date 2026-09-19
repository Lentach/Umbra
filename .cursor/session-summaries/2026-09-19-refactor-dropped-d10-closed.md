# God-class refactor re-verified and DROPPED by the owner; D10 closed (reactions token-only); knip sees exports

**Date:** 2026-09-19 · **Version:** unchanged (0.2.51; backend-only change, NOT deployed) · **Tiers deployed:** none

## What was done
- Refactor plan v2 (`.planning/refactor-godclasses/task_plan.md`) re-verified against live code by five read-only scouts (reports archived verbatim in `findings.md` §"Verification pass 2"). Three claims died: the socket-registry PR is net 20–55 lines not "hundreds" (70 `on()` sites, 58 one-liners); knip's default includes turn CI red on 24 transitive `socket.io` imports; the PR1 seam is just `ContentKv` (`authoritativeSnapshot()`/`reload()` are interface members, `_rawRecord`/`_recordKeys` pure). v3 written, then the **owner dropped the whole refactor**: zero user value, risk concentrated in the 2026-07-29 incident code, blame loss, and not a prerequisite for the parked metadata work. `task_plan.md` now opens with a DROPPED banner and stays as a verified map of the code.
- `backend/src/chat/dto/chat.dto.ts`: `AddReactionDto`/`RemoveReactionDto` accept the 22-char token ONLY (`REACTION_EMOJI_GRAPHEME` + `REACTION_VALUE_REGEX` deleted). D10 CLOSED: fleet is phone 0.2.51 + PWA 0.2.50, both ≥ 0.2.49. Spec: 10 emoji-accept rows ×2 events → 3 representative refusals; `chat-reaction.service.spec.ts` drives a token. Jest 1164 → 1140.
- `backend/package.json:24` `knip` runs with defaults; `knip.json` `ignoreExportsUsedInFile: true`; `socket.io ^4.8.3` listed (24 direct imports, was transitive); dead `socketsForUser` deleted (`user-room.ts`); `RECOVERY_MIN_AGE_MS` gets its own literal (knip "duplicate export"; spec `identity-reset.service.spec.ts:683-687` still pins equality). `npm run knip` exit 0. Lint-ratchet floor 898 → 897.
- Docs: `docs/contracts/wire.md:52` reactions contract (token only, old rows readable/removable), `docs/design/reaction-privacy.md` §3.3 CLOSED + row 8 DONE, root `CLAUDE.md` §1 knip sentence + §3 count 1140.
- BUILT AND REVERTED on the owner's word: a hard min-version gate (`/version.android.minVersionCode` + full-screen `UpdateRequiredGate` under `PasscodeGate`, rendered light+dark on web). Owner: a forced block is wrong while he is the only tester; the existing banner is enough; Play testing tracks will auto-update once a developer account exists. Nothing of it is in the tree.

## Key files
- Edited: `backend/src/chat/dto/chat.dto.ts`, `chat.dto.spec.ts`, `backend/src/chat/services/chat-reaction.service.{ts,spec.ts}`, `backend/src/chat/utils/user-room.ts`, `backend/src/key-bundles/identity-reset.service.ts`, `backend/package.json`, `backend/package-lock.json`, `backend/knip.json`, `scripts/lint-baseline.json`, `CLAUDE.md`, `docs/contracts/wire.md`, `docs/design/reaction-privacy.md`.
- Untracked (by design): `.planning/refactor-godclasses/task_plan.md` (v3 + DROPPED banner), `findings.md` (+55 KB verification pass).
- Read only (load-bearing): `frontend/lib/services/encryption_service.dart:149-247` (the seam), `frontend/lib/providers/connection_provider.dart:947-1313`, `backend/src/version/version.controller.ts`, `frontend/lib/services/apk_update_service.dart`.

## Verification
- `cd backend && npm test` → 64 suites, 1140 passed; `node scripts/verify-claude-backend-test-counts.mjs --log …` → OK (1140/64); `npm run knip` exit 0; `npm run build` exit 0; `node scripts/lint-ratchet.mjs` PASS 898→897, floor updated.
- `git log HEAD..origin/master` empty at session start (branch at master's tip, `cae3cfea`).
- NOT verified: prod. The D10 change is committed, NOT deployed — `./deploy-backend.sh` on the VM is owed; after it, a reaction from any client < 0.2.49 is refused (none exist).
- Frontend: untouched by the surviving commit (the reverted gate's files were `git checkout`ed; `flutter test` NOT re-run because nothing under `frontend/` changed — `git status` clean there).

## Notes for next session
- Owner: deploy the backend (`deploy-backend.sh`) to make D10 live; `/version` semantics unchanged.
- Owner-owed: nothing from the refactor — it is dropped. If metadata work resumes and a step needs to change the plaintext store, extract `PlaintextRecordStore` THEN, per `task_plan.md` §PR2 (the verified cluster map is still accurate as of this session).
- The metadata-privacy conversation continues with the previous agent; `.planning/metadata-privacy/findings.md` step 0 is the resolved text (NO tombstones; delete = mailbox item).
- Traps (also in `docs/agents/traps.md`): refactor dropped, don't restart it; socket registry net ≤55 lines; knip defaults + transitive `socket.io`; reactions token-only; `hub start flutter` needs `cmd /c` on Windows; forced-update gate rejected by owner during the testing phase.
