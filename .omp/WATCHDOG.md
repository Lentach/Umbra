# Fireplace (Umbra) — advisor review priorities

Production E2E-encrypted chat: Flutter client, NestJS backend, Postgres. `AGENTS.md`, root `CLAUDE.md`, the tier files and `.omp/RULES.md` are the agent's rulebook; flag breaches of them. Before raising a note about a file, read the current file: the agent may already have changed it.

## Blockers (flag at once)
- **Public repo** (`Lentach/Umbra`): a secret, token, key, real user data or a non-`<REDACTED>` credential URL in any tracked file, commit message or pasted curl.
- **Prod**: `docker compose down -v`, `volume rm`, bare `up -d`, or telling a user to clear site data. A prod deploy without green CI on the exact commit (`gh api repos/Lentach/Umbra/commits/master/check-runs`; never `gh run list`).
- Merging to `master` without the owner's explicit OK in the chat; `git commit --no-verify`; `git revert 0cbf17b`.
- A composer / attachment-picker change without a green repro AND the owner's explicit OK.
- Renaming storage or contract identifiers (`FireplaceE2E`, `fireplace-*`, `fireplace_messages`): they address live user data.
- A change to a wire contract (`docs/contracts/wire.md`) on one tier only.

## Workflow (flag when skipped)
- Session start: `git fetch && git status -sb && git log --oneline HEAD..origin/master` before work; volatile claims (branch state, what is live, versions, CI, test counts) re-verified this session, never inherited from docs or summaries.
- The tier file (`frontend/CLAUDE.md` / `backend/CLAUDE.md`) read before the first change in that tier; the area doc a `.omp/rules/` entry names read before that edit.
- Code wins over docs: a doc the change makes stale is fixed in the same commit.
- Every code change is driven on a device (release web against the local stack, or an Android emulator/phone) before it is called done; unit tests and CI alone don't count. A surface nothing could drive is stated as NOT verified.
- Before a backend push: full `npm test`, `node scripts/lint-ratchet.mjs` (CI-only otherwise), `npm run knip`. Frontend: `flutter analyze --no-fatal-infos && flutter test`.
- Shared worktree: stage by explicit path only; commits pushed in the same checkpoint (the VM deploys by `git pull`).
- No whole-tree formatter runs (`dart format lib/`, prettier globs); format only the files edited.
- Scope: only what was asked; no unasked features, abstractions or cleanup crusades.
- Review subagents use the same model class as the primary session unless the owner asked for a cheaper one.
- Task end: the dated summary, traps, LATEST entry (`umbra-session-end`).
