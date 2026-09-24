---
name: umbra-session-start
description: Start-of-session pickup for Umbra/Fireplace — read the baton (NEXT.md) the last session left, check branch/HEAD drift, load the traps for the area, and report where the work stands before touching anything. Use when the user says "session start" / "pick up" / "continue from the handoff", or opens a fresh session on existing work. Also the briefing for a helper agent: when delegating a slice, point it at the baton (§6) instead of retyping context.
---

# Umbra session start

Picks up work from **files**, in a new session, harness or worktree. It does not replace OMP's `/handoff`: that compacts the *current* conversation in place (same session, nothing on disk). Writer side: `umbra-session-end` step 6.

## 1. Where am I

```bash
git fetch -q && git status -sb && git log -1 --format='%h %s'
```

Every worktree (`git worktree list`) has its own baton. Never read another worktree's.

## 2. Read the baton — `.cursor/session-summaries/NEXT.md`

- **Present:** read it whole, then compare it with step 1.
  - Different branch → stop and ask.
  - HEAD moved → `git log --oneline <baton HEAD>..HEAD`; say what landed since.
  - `Uncommitted` disagrees with `git status` → say so; the shared worktree may hold someone else's edits.
  - Top `**Date:**` entry of `LATEST.md` is newer than `Written` → a later session ended without a baton; treat the baton as stale and use the fallback.
- **Missing or stale:** take the top `**Date:**` entry of `.cursor/session-summaries/LATEST.md` and the dated summary it links (`## Notes for next session`). If that points at `.planning/<task>/task_plan.md` §Handoff, read that too.

## 3. Load the area — only what the next action needs

- Every path under `Read first`.
- `grep` `docs/agents/traps.md` for the `Area` keywords.
- The tier file (`backend/CLAUDE.md` / `frontend/CLAUDE.md`) if the next action edits that tier; the AGENTS.md reading order still binds.
- CI only if the baton says a push is pending: `gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'` — never `gh run list`.

## 4. Report, then wait

At most 10 lines:

- **State:** branch, HEAD, drift since the baton, uncommitted files.
- **Next:** the baton's next action, verbatim.
- **Open:** owner-owed decisions, NOT-verified surfaces.
- **Traps:** the ones that apply to this action.

Then stop for the go-ahead, unless the user's message already said to continue. A stale baton that starts editing is worse than no baton.

## 5. Consume

Rename `NEXT.md` → `NEXT.consumed.md` (overwrite). Both are gitignored. The next fresh session falls back to LATEST instead of replaying this baton, and the consumed copy stays readable if this session dies early.

## 6. Handing a slice to a helper agent

The baton is also the briefing for subagents: the task points at it instead of retyping context.

- Give the **absolute** path of this worktree's live baton — `NEXT.consumed.md` after step 5, or `NEXT.md` once this session has written a fresh one. Subagents start in the main checkout, not in this worktree, so a relative path hands them another worktree's baton (or none).
- Tell the helper to do steps 2–3 only, from that worktree: read the baton, its `Read first` paths, and `grep docs/agents/traps.md` for its `Area` keywords. A helper never runs steps 1, 4 or 5: it does not report-and-wait, rename or rewrite the baton.
- The task text then carries only what the baton does not: the slice (files, symbols, non-goals), decisions made since the baton was written, and the acceptance check.
- Refresh a baton the session has outgrown (the next action moved on) before delegating: the helper trusts it.

## The baton — format (≤ 2 KB)

```markdown
# NEXT — <one-line goal>

**Written:** YYYY-MM-DD HH:MM · **Branch:** <branch> · **HEAD:** <short sha> · **Worktree:** <dir name>
**Area:** <traps.md group + keywords, e.g. "E2E, reactions">
**Summary:** `YYYY-MM-DD-<slug>.md` | none (mid-task)

## Next action
One concrete step — file:symbol, command, or decision. Not a menu.

## Read first
- ≤ 6 paths, each with why.

## State
- Uncommitted: <paths> | none
- Done but not in a summary (mid-task only): ≤ 4 bullets
- NOT verified: …

## Open
- Owner-owed decisions, blockers.
```

The baton says where to go, not what happened: evidence and narrative belong in the dated summary or `.planning/<task>/findings.md`.
