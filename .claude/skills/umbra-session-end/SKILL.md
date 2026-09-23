---
name: umbra-session-end
description: End-of-task handoff for Umbra/Fireplace — write the dated session summary, append traps, rotate LATEST.md, pass the pre-commit context-budget gate, and leave the NEXT.md baton for a fresh session. Use when wrapping up, when the user says "session summary" / "handoff" / "wrap up", or before the final commit of any task.
---

# Umbra session end

The handoff is three files with three lifetimes, plus a disposable baton for the next session. `.githooks/pre-commit` runs `scripts/verify-context-budget.mjs` and REFUSES the commit if any cap below is broken — this skill is the path to a green commit, not a suggestion.

- **Staying in the same conversation?** OMP `/handoff [focus]` compacts it in place; nothing here is needed.
- **Handing to a fresh agent mid-task (context full, nothing to commit)?** Do step 6 only.

## 1. Dated summary — `.cursor/session-summaries/YYYY-MM-DD-<slug>.md` (≤ 8 000 bytes hard, aim ≤ 6 KB)

Exact template (the four `##` headings are checked by the hook on NEW files):

```markdown
# <one-line title: what changed, not what you did>

**Date:** YYYY-MM-DD · **Version:** <before → after, or "unchanged"> · **Tiers deployed:** web | backend | both | none

## What was done
- ≤ 8 bullets. Each names the file:symbol and the observable change. No narrative of the investigation.

## Key files
- Edited: …
- New: …
- Read only (load-bearing): …

## Verification
- Commands run + their result lines (test counts, smoke result, CI run id). Mutants: F-number, substitution, killed/survived.
- Live drives: what was driven, on which build, what was observed. Say NOT-verified surfaces explicitly (iOS, Android, prod).

## Notes for next session
- Owner-owed decisions.
- NOT-verified surfaces.
- Traps: one line each, ALSO appended to docs/agents/traps.md (step 2).
```

Investigation narrative, dead ends, and long evidence go to `.planning/<task>/findings.md` (multi-session work) or the task's design doc — never the summary. If the file is over the cap, move detail out; never raise the cap.

## 2. Traps — `docs/agents/traps.md`

For every trap in step 1, append ONE line under the matching `##` group (Composer / Deploy / Tests / E2E / Auth / Android / Agent tooling / Handoff / Owner-owed):

```markdown
- **<trap in ≤ 15 words>** — <one sentence of consequence or rule> (`YYYY-MM-DD-<slug>.md`).
```

Standing warnings live here and nowhere else. Never put them in LATEST.

## 3. LATEST — `.cursor/session-summaries/LATEST.md`

- Update the single **DEPLOY STATE** line only if a deploy happened (version · short SHA · CI run id · smoke result per tier).
- Put a new entry on TOP, ≤ 900 chars (hook hard-fails at 1 000): `**Date:** YYYY-MM-DD — **<verdict sentence>.** <2–4 sentences: what shipped, proof, what is open>. ➡ \`YYYY-MM-DD-<slug>.md\`.`
- **Delete the oldest entry** so five remain. Before deleting, confirm its traps are already in `traps.md` (they should be — step 2 of that session). No blockquote banner, ever.

## 4. Gate, then commit

```bash
node scripts/verify-context-budget.mjs --worktree   # fast local check
git add <files> && git commit                        # pre-commit re-runs it on the staged tree
```

If it blocks: the message names the file and the cap. Move content, do not trim evidence and do not `--no-verify`.

## 5. Push in the same checkpoint

Root `CLAUDE.md` §1: commit and `git push` together (the VM deploys via `git pull`). After pushing, CI status is `gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'` — never `gh run list`.

## 6. Baton — `.cursor/session-summaries/NEXT.md` (gitignored, one per worktree)

Write it last, after the push, so `HEAD` is the pushed SHA (mid-task: the current SHA, uncommitted paths listed). Format: `.claude/skills/umbra-session-start/SKILL.md` § The baton. Overwrite any previous `NEXT.md`. No concrete next action → write none; the next session falls back to LATEST.

Then tell the user: open a fresh session in this worktree and say "umbra session start".
