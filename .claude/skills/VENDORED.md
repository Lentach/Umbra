# Vendored skills — this directory IS Fireplace's skill set

`.omp/config.yml` sets `skills.enableAgentsUser: false`, so in this repo an OMP agent sees **only** what
lives here. Everything an agent may need is therefore committed: it travels to every worktree and every
machine, and depends on nobody's home directory. Add a skill here, not to `~/.agents/skills`.
Full map, verdicts and the MCP inventory: `docs/agents/skills-and-mcp.md`.

## Apache-2.0 — `kevmoo/dash_skills`

Copied verbatim (SKILL.md plus each skill's `scripts/`; `evals/` omitted) from
https://github.com/kevmoo/dash_skills at commit `38dce749552380f618791d05686494d2a60c593a` (2026-09-13):
`dart-test-fundamentals`, `dart-matcher-best-practices`, `dart-test-coverage`, `profile-dart-code`,
`dart-modern-features`, `dart-seal-type-hierarchies`.
License text: `LICENSE.dash_skills.txt`. Re-pull by SHA (no release tags upstream); `renovate.json` ignores
`**/.claude/skills/**`. The first four were previously pinned at `ea5aa807…` and were re-pulled at the SHA
above in the same pass that added the last two. Upstream uses a non-spec `key_features:` frontmatter key and
omits `license:` on some skills — harmless for OMP/Claude Code, but it blocks a claude.ai/Skills-API upload.

## MIT — `mattpocock/skills`

Copied from the `npx skills add mattpocock/skills` install in `~/.agents/skills` (installed
2026-07-09; provenance per file in `~/.agents/.skill-lock.json`), verbatim except for the two local
modifications recorded below:
`code-review`, `codebase-design`, `design-an-interface`, `diagnosing-bugs`, `grilling`, `prototype`, `qa`,
`request-refactor-plan`, `research`, `resolving-merge-conflicts`, `tdd`, `to-spec`, `to-tickets`, `triage`.
License text: `LICENSE.mattpocock-skills.txt` (Copyright (c) 2026 Matt Pocock).

`design-an-interface`, `qa` and `request-refactor-plan` were installed from upstream's `skills/deprecated/`
and no longer exist upstream — `npx skills update` 404s on them, so these copies are ours to maintain.
`to-spec`, `to-tickets` and `triage` carry `disable-model-invocation: true`: hidden from the model's skill
list, invoked deliberately with `/skill:<name>`. Their prerequisites are satisfied here —
`docs/agents/issue-tracker.md` (GitHub via `gh`), `docs/agents/triage-labels.md`, and all five labels
(`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) exist in `Lentach/Umbra`.

**Local modifications — re-apply these after any re-pull:**

| File | Upstream line | Changed to | Why |
|---|---|---|---|
| `triage/SKILL.md` (step 4, ~L76) | "run the `/grilling` and `/domain-modeling` skills together" | invokes `/skill:grilling` only, with a note that `domain-modeling` is not vendored and this repo has no `CONTEXT.md`/`docs/adr/` | `domain-modeling` is deliberately not vendored and `.omp/config.yml` mutes `~/.agents`, so the command cannot resolve here |
| `to-tickets/SKILL.md` (~L113) | "Work the frontier one ticket at a time with `/implement`" | "Work the frontier one ticket at a time" + a note that `implement` is not vendored | same reason; `implement` is a 16-line stub from a pipeline we do not run |

Both files carry `disable-model-invocation: true`, so a human runs them deliberately — which is exactly the
path that would have hit the dead command. Re-check the divergence set with
`for d in <the 14 names>; do diff -rq ~/.agents/skills/$d .claude/skills/$d; done`: run 2026-09-14 it reported
`to-tickets` and `triage` only, every other MIT copy byte-identical to the install.

Deliberately NOT vendored: `setup-pre-commit` (npm/Husky only — ignores `frontend/`, and `.githooks/pre-commit`
already owns this), `git-guardrails-claude-code` (superseded by `.claude/hooks/guard.mjs` + `.omp/hooks/pre/guard.ts`),
`wizard` (writes `.env` + GH Actions secrets), `setup-matt-pocock-skills` (already run here 2026-07;
re-running would rewrite `CLAUDE.md`), `domain-modeling`/`improve-codebase-architecture`/`grill-with-docs`
(want a `CONTEXT.md`/`docs/adr/` layout this monorepo has not chosen), `migrate-to-shoehorn`/`scaffold-exercises`/
`obsidian-vault`/`edit-article`/`writing-*` (TypeScript-only, course authoring, or article work),
`ask-matt`/`handoff`/`claude-handoff`/`grill-me`/`implement`/`loop-me`/`teach` (duplicates of `umbra-session-end`,
OMP's own `task`/`hub` fan-out, or stubs from a pipeline we don't run), and `planning-with-files`
(the installed copy is a `.Codex`-mangled find-replace; `todo` + `.planning/<task>/findings.md` cover it).

## Repo-authored

`umbra-session-end` — the handoff contract enforced by `scripts/verify-context-budget.mjs`.

`umbra-session-start` — the reader of the `NEXT.md` baton `umbra-session-end` writes; owns the baton format.

`flutter-frontend-design` — authored locally on this box (mtime 2026-07-14) and absent from
`~/.agents/.skill-lock.json`, so from neither `mattpocock/skills` nor `dash_skills`; origin otherwise
unrecorded and it carries no upstream license note. It was stranded in `~/.claude/skills/`, which OMP does
not load (foreign user-level providers are opt-in — `omp://skills.md` "Source toggles and filtering"), so it
went unused for two months. Delete any `~/.claude/skills/flutter-frontend-design/` copy: in Claude Code
personal beats project, so a stale home copy would win over this one.
