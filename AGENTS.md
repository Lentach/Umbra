# AGENTS.md — Fireplace (Umbra)

The only project file Oh-My-Pi injects (it shadows root `CLAUDE.md`), so every line here is load-bearing; everything else is a deliberate read.

## Read, in order

1. Root `CLAUDE.md` — workflow, architecture, deploy safety, version contract.
2. The tier file before your first change in that tier: `backend/CLAUDE.md` or `frontend/CLAUDE.md`.
3. `.cursor/session-summaries/LATEST.md`, then `grep docs/agents/traps.md` for your area (standing warnings, one line each).
4. Area docs load as edit-time rules (`.omp/rules/`, mirrored in `.claude/rules/`): read the doc a rule names before that edit.
5. Skills: `.claude/skills/` IS the set (`.omp/config.yml` mutes `~/.agents`); map + MCP: `docs/agents/skills-and-mcp.md`. Triggers: broken/slow → `diagnosing-bugs` · "review since X" → `code-review` · stress-test a plan → `grilling` · module shape → `codebase-design`, `design-an-interface` · docs/API facts → `research` · open design question → `prototype` · merge/rebase → `resolving-merge-conflicts` · file it → `qa`, `request-refactor-plan` · `/skill:` only → `triage`, `to-spec`, `to-tickets`.
6. Delegating? Subagents start blank, in the main checkout: give the ABSOLUTE path of this worktree's baton + its traps (`umbra-session-start` §6), then only the slice.

## Non-negotiable (details: root `CLAUDE.md` §1, §4, §6)

- Code wins over docs: fix the doc in the same commit. Re-verify volatile claims (branch, versions, CI, counts) with a command run THIS session.
- Main checkout is on `feat/passcode-lock` (`master` = `fireplace-0a`): `git fetch && git status -sb` first; push `HEAD:master`, then the branch; any other worktree pushes only its own branch. Shared worktree: stage by explicit path, never `git add -A`; never `git revert 0cbf17b`.
- Change only what was asked. Composer/attachment picker: read `frontend/docs/composer-media.md` first; keep a repro.
- Metadata-privacy decisions: `docs/plans/metadata-privacy-decisions.md` is the authority. Read it before asking or answering; ask the owner only OWNER-class questions, batched per phase (S8).
- **Every code change is driven on a device before it is "done"**: built app in a browser or Android emulator/phone, on the changed path. Tests, CI and headless probes do not count.
- Never `--no-verify` (pre-commit: gitleaks + context budget). Never trim a fresh summary to fit — move detail out.
- Prod: CI green first (`gh api repos/Lentach/Umbra/commits/master/check-runs`, never `gh run list`). Never `docker compose down -v` / `volume rm` / bare `up -d`. Never tell a user to clear site data.
- Task end: `umbra-session-end`; fresh session: `umbra-session-start`.

Keep this file under 3 000 bytes (the gate is 4 000): hard rules + pointers only. New facts go to `CLAUDE.md`, a tier file, an area doc, or `traps.md`.
