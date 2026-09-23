# A fresh session now picks up from a per-worktree NEXT.md baton instead of a pasted handoff

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- New skill `.claude/skills/umbra-session-start/SKILL.md`: `git fetch`/status → read `.cursor/session-summaries/NEXT.md` → drift check (branch, `HEAD`, uncommitted, LATEST newer than baton = stale) → fallback to the top LATEST entry + its dated summary → load `Read first` + traps grep → ≤10-line report, then WAIT → rename to `NEXT.consumed.md`. It owns the baton format (≤2 KB: next action, read-first, state, open).
- `umbra-session-end` gained step 6 (write the baton last, after the push) and a header split: same conversation → OMP `/handoff` (compacts in place, no files); fresh agent mid-task → step 6 only.
- `.gitignore`: `.cursor/session-summaries/NEXT*.md` — the baton is disposable and per worktree, never committed; the context-budget gate's summary regex (`\d{4}-\d{2}-\d{2}-`) never matches it.
- Pointers: `AGENTS.md` task-end line (3 967 B on disk, index gate OK), `docs/agents/skills-and-mcp.md` (23 skills, 20 listed + table row), `VENDORED.md` repo-authored list.
- `fireplace-mp` got the skill WITHOUT touching its tracked files or the running agent: an untracked copy of `SKILL.md` (shows as `??` there; explicit-path staging keeps it out of commits). The SHARED `.git/info/exclude` carries only `/.cursor/session-summaries/NEXT*.md`, because mp's `.gitignore` predates the baton. A first cut also excluded the skill dir; reverted the same session (see Verification).

## Key files
- New: `.claude/skills/umbra-session-start/SKILL.md`
- Edited: `.claude/skills/umbra-session-end/SKILL.md`, `.gitignore`, `AGENTS.md`, `docs/agents/skills-and-mcp.md`, `.claude/skills/VENDORED.md`
- Outside git: `.git/info/exclude` (common dir, all worktrees — NEXT line only), `../fireplace-mp/.claude/skills/umbra-session-start/SKILL.md`

## Verification
- Throwaway git repo: an untracked copy IDENTICAL to an incoming tracked file aborts `git merge` ("untracked working tree files would be overwritten"); an exclude-listed copy fast-forwards. BUT the exclude is shared by every worktree, and a tracked-and-excluded file makes `git add <path>` exit 1 (it stages, warns, and breaks `git add … && git commit`), and the built-in `grep`/`glob` hid the skill in THIS checkout. Hidden-and-global lost to loud-and-local: the skill exclude line was removed; grep finds the skill again.
- `omp -p --tools read` in `fireplace-mp` lists 20 skills including `umbra-session-start`. `git ls-files` confirms 23 tracked here.
- `node scripts/verify-context-budget.mjs` (index mode) OK; `--worktree` false-blocks on `frontend/CLAUDE.md` CRLF (known trap, not this change).
- Pushed `23e86bfe` after rebasing onto origin/master (25 metadata-privacy commits had landed); `git ls-remote` shows master = `feat/passcode-lock` = `23e86bfe`.
- NOT verified: a real end→start round trip (no baton written yet); Claude Code discovery of the new skill.

## Notes for next session
- `fireplace-mp` still runs the OLD `umbra-session-end` (tracked copy, pre-step-6), so it writes no baton; its next fresh session falls back to LATEST. To get a baton there now, tell that agent at wrap-up: "also write the baton per `.claude/skills/umbra-session-start/SKILL.md` § The baton".
- Before `fireplace-mp` merges master: `rm -r .claude/skills/umbra-session-start` there. The merge aborts loudly if you forget, and it is the same file.
- `.omp/RULES.md` deliberately NOT given a "session start" line: it is re-attached every turn, so it would fire the pickup on unrelated tasks. The skill is user-invoked.
- Traps: untracked copy blocks merge; never exclude a tracked path in the shared `info/exclude` — both in `docs/agents/traps.md`.
