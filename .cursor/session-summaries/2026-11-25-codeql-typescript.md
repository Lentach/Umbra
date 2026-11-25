# CodeQL now scans the TypeScript and JavaScript code; first run triaged, no open alert

**Date:** 2026-11-25 · **Version:** unchanged (0.2.103) · **Tiers deployed:** none

## What was done
- CodeQL default setup changed from `["actions"]` to `actions` + `javascript-typescript` (`PATCH repos/Lentach/Umbra/code-scanning/default-setup`, setup run 45510303527 green). It is a repo setting; there is no CodeQL workflow file.
- First scan on `021c329b`: 87 rules, 4 results, none in `backend/src` or `frontend/web`. All four dismissed with a written reason: alerts 5-7 `js/path-injection` in `scripts/verify-session-lock-probe.mjs` (loopback CI probe server, path normalized and refused outside the frontend directory), alert 4 `js/insecure-randomness` in `scripts/smoke/artillery-socket.mjs` (throwaway load-test username, non-prod only). Open alerts: 0.
- PR #302 (docs only, merged on the owner's word, master `bb6288ee`): gap report §4.2 and the audit-readiness row; trap on pinning the language list.
- Out of repo: the GitHub code-scanning setting and the four alert dismissals.

## Key files
- Edited: `docs/plans/2026-11-24-signal-grade-gap.md`, `docs/agents/traps.md`. No code.
- Read only: `scripts/verify-session-lock-probe.mjs:81-103`, `scripts/smoke/artillery-socket.mjs:31-41`, `.github/workflows/ci.yml` (`paths-ignore`).

## Verification
- PR head `b85b547d`: `Analyze (actions)`, `Analyze (javascript-typescript)`, `CodeQL`, `Secret scan (gitleaks)`, all success. Master `bb6288ee`: the same without `CodeQL`, all success. `ci.yml` skips docs-only changes, so no test job ran on either, as designed.
- No review agent on the dismissals: they rest on a read of the flagged lines.
- No device drive, no deploy: no shipped code changed.

## Notes for next session
- **Next action:** CI-built APK with a published checksum (gap report §4.4 step 1). Signing is an owner question: the release keystore and its passwords go nowhere without the owner's decision.
- Not observed yet: check totals for a code change. Expected one more row than before (PR head 14, master 13) because of `Analyze (javascript-typescript)`; confirm by row names on the first code PR.
- The default query suite is in use; `security-extended` was not tried.
- A merge to master needs the owner's explicit word in chat, docs-only PRs included.
- Owner-owed: `SECURITY.md` contact address; re-read of the changed privacy-policy drafts; a lawyer on the licence; BE-12; UI-16/UI-17; composer split (UI-28); TD-07.
- After that: B7 tail (behavioural, own release 0.2.104).
