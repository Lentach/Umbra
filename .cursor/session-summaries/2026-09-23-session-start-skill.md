# A fresh session now picks up from a per-worktree NEXT.md baton instead of a pasted handoff

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- New skill `.claude/skills/umbra-session-start/SKILL.md`: `git fetch`/status → read `.cursor/session-summaries/NEXT.md` → drift check (branch, `HEAD`, uncommitted, LATEST newer than baton = stale) → fallback to the top LATEST entry + its dated summary → load `Read first` + traps grep → ≤10-line report, then WAIT → rename to `NEXT.consumed.md`. It owns the baton format (≤2 KB: next action, read-first, state, open).
- `umbra-session-end` gained step 6 (write the baton last, after the push) and a header split: same conversation → OMP `/handoff` (compacts in place, no files); fresh agent mid-task → step 6 only.
- `.gitignore`: `.cursor/session-summaries/NEXT*.md` — the baton is disposable and per worktree, never committed; the context-budget gate's summary regex (`\d{4}-\d{2}-\d{2}-`) never matches it.
- Pointers: `AGENTS.md` task-end line (3 967 B on disk, index gate OK), `docs/agents/skills-and-mcp.md` (23 skills, 20 listed + table row), `VENDORED.md` repo-authored list.
- `fireplace-mp` got the skill WITHOUT touching its tracked files or the running agent: untracked copy of `SKILL.md` + three lines in the SHARED `.git/info/exclude` (`/.claude/skills/umbra-session-start/`, `/.cursor/session-summaries/NEXT*.md`). `git -C ../fireplace-mp status --porcelain` stays empty.

## Key files
- New: `.claude/skills/umbra-session-start/SKILL.md`
- Edited: `.claude/skills/umbra-session-end/SKILL.md`, `.gitignore`, `AGENTS.md`, `docs/agents/skills-and-mcp.md`, `.claude/skills/VENDORED.md`
- Outside git: `.git/info/exclude` (common dir, all worktrees), `../fireplace-mp/.claude/skills/umbra-session-start/SKILL.md`

## Verification
- Throwaway git repo: an untracked copy IDENTICAL to an incoming tracked file aborts `git merge` ("untracked working tree files would be overwritten"); the same copy listed in `info/exclude` fast-forwards cleanly. That is why the exclude lines exist.
- `omp -p --tools read` in `fireplace-mp` lists 20 skills including `umbra-session-start` — OMP discovers an exclude-ignored skill dir.
- `node scripts/verify-context-budget.mjs` (index mode) OK; `--worktree` false-blocks on `frontend/CLAUDE.md` CRLF (known trap, not this change).
- Pushed `23e86bfe` after rebasing onto origin/master (25 metadata-privacy commits had landed); `git ls-remote` shows master = `feat/passcode-lock` = `23e86bfe`.
- NOT verified: a real end→start round trip (no baton written yet); Claude Code discovery of the new skill.

## Notes for next session
- `fireplace-mp` still runs the OLD `umbra-session-end` (tracked copy, pre-step-6), so it writes no baton; its next fresh session falls back to LATEST. To get a baton there now, tell that agent at wrap-up: "also write the baton per `.claude/skills/umbra-session-start/SKILL.md` § The baton".
- Once every worktree has merged master past `23e86bfe`: delete the untracked `fireplace-mp` copy's exclude line (`/.claude/skills/umbra-session-start/`) from `.git/info/exclude`.
- Traps: untracked-copy-blocks-merge; `glob` hides exclude-listed tracked files — both in `docs/agents/traps.md`.
