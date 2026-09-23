# Skills + MCP — the contract

Rewritten 2026-09-14 after the audit. One rule to remember: **`.claude/skills/` IS this repo's skill set.** Nothing an agent needs lives in a home directory, so it travels to every worktree and every clone.

## 1. How it is wired

| Layer | File | Effect |
|---|---|---|
| The set | `.claude/skills/*/SKILL.md` | 23 skills (20 listed + 3 `/skill:`-only). Tracked → every worktree gets them |
| The gate | `.omp/config.yml` → `skills.enableAgentsUser: false` | Mutes the machine-wide `~/.agents/skills` tree **for this repo only**; other repos on the box keep it. Project config is merged over global (`omp://settings.md` § Precedence) and is loaded from the CWD's `.omp/` — **always start `omp` at the repo root** |
| Tracked-ness | `.gitignore` → `!.omp/config.yml` | Without this negation the gate is machine-local and `fireplace-0a` / future worktrees silently differ. `git check-ignore -v .omp/config.yml` must print the `!` line |
| Routing | `.omp/rules/*.md` (+ `.claude/rules/*.md`) | Edit-time triggers: the rule fires when a matching file is edited and names the skill to read |
| Always-on | `AGENTS.md` item 5 | Trigger list for the conversational skills (bug → `diagnosing-bugs`, "review since X" → `code-review`, …) |

Harness coverage: **OMP** reads `.claude/skills` (project root) + `.omp/rules` + `.claude/rules`; **Claude Code** reads `.claude/skills` + `.claude/rules`. **Cursor is no longer used — `.cursor/rules/` was deleted 2026-09-14.** Of the five files git had tracked there, four were exact name-duplicates of `.omp/rules` entries (three more `.mdc` mirrors were created earlier in the same session and never committed) (rule dedup is by name, and the native provider outranks the cursor provider, so OMP already discarded them); the eighth, `production-vm-deploy`, was the only unique one and moved to `.omp/rules/production-vm-deploy.md` with its frontmatter unchanged — description-only, so it stays a rulebook entry reachable as `rule://production-vm-deploy`. `.cursor/session-summaries/` has nothing to do with Cursor: it is the handoff store hardwired into `scripts/verify-context-budget.mjs`, `umbra-session-end`, `AGENTS.md`, root `CLAUDE.md` and CI's `paths-ignore`, with 340 files behind it. It stays.

**The gate does not cover Claude Code**, and there **personal beats project** — a `~/.claude/skills/<name>` entry shadows the committed copy of the same name. So the eight junctions that pointed at vendored skills (`code-review`, `codebase-design`, `diagnosing-bugs`, `grilling`, `prototype`, `research`, `resolving-merge-conflicts`, `tdd`) were removed from `~/.claude/skills` on 2026-09-14 — link only, targets untouched. Two junctions remain there deliberately, `domain-modeling` and `git-guardrails-claude-code`: not vendored here, useful in other repos. Never vendor a skill into this repo while a same-named entry survives in `~/.claude/skills`, or Claude Code will quietly use the home copy. Full snapshot of the home tree before any of this: `~/.agents/skills-snapshot-2026-09-14.tar.gz` (38 dirs + `.skill-lock.json`), which matters because seven of those skills are 404 upstream and cannot be re-pulled.

**Why this shape.** Before the audit, 51 skill dirs existed across three trees and only 23 reached the model, because of two filters worth knowing:

1. `disable-model-invocation: true` → loaded but omitted from the prompt list, still reachable via `skill://<name>` and `/skill:<name>` (`omp://skills.md` § System prompt exposure). 21 of the 39 `~/.agents` skills carry it; upstream means them as slash-invoked entry points.
2. `enabledProviders` defaults to `[]` → foreign **user-level** roots (`~/.claude/skills`, Codex) contribute **nothing** to OMP, while project roots load anyway (`omp://settings.md`). That is how a locally authored Flutter design skill sat unused in `~/.claude/skills` for two months.

Verified after the change: a fresh headless session (`omp -p --tools read`) lists exactly the 19 in-repo listed skills — no `obsidian-vault`, `scaffold-exercises`, `migrate-to-shoehorn`, `setup-pre-commit`, `git-guardrails-claude-code` — and the `dart` MCP route still mounts.

## 2. The set

| Skill | Fires when | Source |
|---|---|---|
| `flutter-frontend-design` | Any visual Flutter change — widget, screen, dialog, animation, theme, "polish this" | repo-authored |
| `dart-test-fundamentals`, `dart-matcher-best-practices` | Writing/fixing Dart tests | dash_skills |
| `dart-test-coverage` | "What isn't tested?" | dash_skills |
| `dart-modern-features` | Non-visual Dart — records, patterns, switch expressions, class modifiers | dash_skills |
| `dart-seal-type-hierarchies` | A closed hierarchy gets switched over (message kinds, key-bundle/device state, decryption verdicts) | dash_skills |
| `profile-dart-code` | CPU profiling a Dart CLI via VM Service | dash_skills |
| `diagnosing-bugs` | Something broken/throwing/slow; matches the repo's reproduce → fix → confirm rule | Pocock |
| `tdd` | Backend Jest work (`tests.md`/`mocking.md` are Jest-shaped) | Pocock |
| `code-review` | "Review since X" — two parallel sub-agents, Standards + Spec | Pocock |
| `resolving-merge-conflicts` | Mid-merge/rebase in this shared worktree | Pocock |
| `grilling` | Stress-testing a plan before building it | Pocock |
| `codebase-design`, `design-an-interface` | Module shape, seams, "design it twice" | Pocock |
| `research` | Docs/API facts from primary sources | Pocock |
| `prototype` | Throwaway code to answer a design question | Pocock |
| `qa`, `request-refactor-plan` | Turning a conversation into GitHub issues via `gh` | Pocock |
| `triage`, `to-spec`, `to-tickets` | **`/skill:` only** (hidden). Prerequisites verified present: `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, and all five labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) exist in `Lentach/Umbra` | Pocock |
| `umbra-session-end` | Task end — the handoff the pre-commit gate enforces | repo-authored |
| `umbra-session-start` | Fresh session on existing work — reads the per-worktree `NEXT.md` baton `umbra-session-end` step 6 leaves (falls back to LATEST), checks drift, reports, waits. OMP `/handoff` is the in-conversation alternative | repo-authored |

Licenses travel with the copies: `.claude/skills/LICENSE.dash_skills.txt` (Apache-2.0), `.claude/skills/LICENSE.mattpocock-skills.txt` (MIT). Provenance, SHAs and the not-vendored list: `.claude/skills/VENDORED.md`.

## 3. Routing rules

| Rule | Scope | Points at |
|---|---|---|
| `frontend-flutter-design` | `frontend/lib/{widgets,screens,theme}/**` | `flutter-frontend-design`; defers to `frontend/docs/composer-media.md` in the keyboard-adjacent do-not-animate zone |
| `frontend-dart-idioms` | `frontend/lib/{models,services,providers,utils,constants}/**` | `dart-modern-features`, `dart-seal-type-hierarchies` |
| `tests-and-coverage` | `frontend/test/**`, `**/*_test.dart`, `backend/**/*.spec.ts`, `backend/test/**` | `dart-test-*` for Dart, `tdd` for Jest, plus the repo's test bar |

An OMP edit-time rule needs `condition: ".*"` **and** an explicit `scope: "tool:edit(<glob>), tool:write(<glob>)"`; the YAML-list `condition:` shorthand registers nothing. A rule with a `description` and no condition lands in the rulebook instead (listed by name, body read via `rule://`) — that is how `production-vm-deploy` works. Mirror every file-triggered rule into both trees (`.omp/rules`, `.claude/rules`); a single-tree rule silently does not fire for the other harness.

## 4. MCP

`.omp/mcp.json` holds three servers; only `dart` is on.

| Server | State | Notes |
|---|---|---|
| **dart** (first-party `dart_mcp_server`) | **on** | DTD/VM-service introspection, hot reload, widget inspector, analyzer diagnostics — the shell cannot reach these. `--disable pub_dev_search` is the only flag that does anything; `create_project` is already off upstream and `flutter_driver_user_journey_test` is not a tool in this server, so both former flags were dropped. Optional `--enable run_tests` for structured test output |
| **chrome-devtools** ([Google, Apache-2.0](https://github.com/ChromeDevTools/chrome-devtools-mcp)) | committed, `enabled: false` | Turn on with `/mcp enable chrome-devtools` for PWA/perf work: Lighthouse, DevTools traces, source-mapped console, 13 heap tools, `install_pwa`/`launch_pwa`. Pinned `@1.9.0` (verified installable); `--isolated --no-usage-statistics --no-performance-crux` because telemetry is on by default and traces can reach Google CrUX. **Dev targets only** — it reads DOM/heap/network, i.e. decrypted conversations. Off by default so ~26 tool schemas don't tax every turn |
| **github** ([GitHub, MIT](https://github.com/github/github-mcp-server)) | committed, `enabled: false` | `/mcp enable github` after exporting a fine-grained, single-repo, read-only PAT as `GITHUB_PERSONAL_ACCESS_TOKEN` — the `docker run -e VAR` form inherits it from the environment, so **no token is ever committed**. `GITHUB_READ_ONLY=true` is a strict filter that beats every other setting, so an injected "merge this" cannot execute; toolsets limited to `actions,pull_requests,issues` |

Deliberately not wired: **Playwright MCP** (redundant with the built-in Chromium tool; upstream itself now points coding agents at Playwright CLI + skills), **Prisma MCP** (its DB tools only manage Prisma-hosted Postgres), **`crystaldba/postgres-mcp`** (wants a live `DATABASE_URI` on the dev box and a prod `shared_preload_libraries` change — revisit in `--access-mode=restricted` against a dev DB when there is a real slow query), **Redis MCP**, **Docker MCP Gateway**, **Sentry MCP** (we run no Sentry), **Context7** (third-party re-hosted docs with a no-accuracy/no-security disclaimer; first-party [Google Developer Knowledge MCP](https://developers.google.com/knowledge/mcp) if ever wanted), and the **Filesystem/Fetch/Git/Time/Memory/Sequential-Thinking** reference servers (weaker than built-ins; `Memory` competes with `umbra-session-end`).

**Never wire anything from [`modelcontextprotocol/servers-archived`](https://github.com/modelcontextprotocol/servers-archived)** — postgres, github, puppeteer, redis, sentry, slack, sqlite, gitlab, gdrive, google-maps, brave-search, everart, aws-kb. That repo states no security updates will ever be issued, and the *active* servers repo's own "Getting Started" block still shows the archived `server-github`/`server-postgres` entries, which is what tutorials copy.

Constraints that bind this product: Anthropic "does not security-audit or manage any MCP server"; any server returning external content (issue bodies, workflow logs, page content) is a prompt-injection channel; stdio servers run with our privileges and `npx -y …@latest` re-executes third-party code per launch, hence the pin. **Never expose:** prod `DATABASE_URI`/Redis creds (rows are E2EE, metadata is not), VPS `.env`/deploy keys, or an authenticated production Fireplace browser session.

## 5. Maintaining it

- **Add a skill:** `.claude/skills/<name>/SKILL.md` with `name` + `description` frontmatter, one level deep (nested paths are not discovered). Record provenance and license in `VENDORED.md`. If it should fire on file edits, add the rule to all three trees.
- **Update dash_skills:** re-pull by SHA (no release tags) and bump the SHA in `VENDORED.md`.
- **Update Pocock skills:** `npx skills update` in `~/.agents`, then re-copy. It 404s on `design-an-interface`, `qa`, `request-refactor-plan` — upstream deleted those, so our copies are the maintained ones.
- **Cost discipline:** ~100 tokens of metadata per listed skill on every turn, listing budget ≈1% of context, least-invoked descriptions dropped first on overflow. A skill that never fires makes the ones that do harder to find. Hidden (`disable-model-invocation: true`) skills cost nothing in the list.
- **Machine hygiene (optional, outside the repo):** `~/.agents/skills` still holds 38 skills for other projects. The gate makes them irrelevant here. Two were deleted outright as actively harmful: the `.Codex`-mangled `planning-with-files` (its body asserted "Codex shipped three new turn-loop primitives" and cited `anthropics/Codex` issues) and the stale `~/.claude/skills/flutter-frontend-design` (personal beats project in Claude Code, so it would have won over the committed copy).

## 6. Review round, 2026-09-14 — what was wrong

Two `reviewer` subagents audited this change before it was staged; both returned "incorrect". Fixed in the same pass:

| Finding | Fix |
|---|---|
| `README.md:205` and `deploy.sh:14` still pointed at the deleted `.cursor/rules/production-vm-deploy.mdc` | repointed to `.omp/rules/production-vm-deploy.md` |
| `tests-and-coverage` had two globs matching **0 files** (`frontend/lib/**/*_test.dart`; `backend/test/` does not exist) and missed `frontend/test_e2e/` (12 files) + `frontend/integration_test/` (5) | globs replaced with `frontend/{test,test_e2e,integration_test}/**` + `backend/**/*.spec.ts` |
| both new `.claude/rules` mirrors told Claude Code to read `skill://…`, an OMP-only URL scheme | rewritten as `.claude/skills/<name>/SKILL.md` |
| `github` MCP entry passed `-e GITHUB_PERSONAL_ACCESS_TOKEN` with no matching `env` key, so it would 401 on first enable | added the documented self-named indirection `"GITHUB_PERSONAL_ACCESS_TOKEN": "GITHUB_PERSONAL_ACCESS_TOKEN"` (variable name, not a secret) |
| the new blanket globs stack 2–3 TTSR rules on files owned by the narrow area rules (27 composer files, 32 service files, 2 files matching three rules) | precedence notes added to both new rules naming `frontend-e2e-invariants`, `frontend-passcode-lock`, `wire-contracts`, `frontend-composer-media` as owners |
| vendored `triage`/`to-tickets` invoked `/domain-modeling` and `/implement`, which the gate makes unreachable | both lines rewritten in our copies (policy: these copies are ours to maintain) |
| `frontend/lib/config/` and the `lib` root files were uncovered by any rule | added `frontend/lib/config/**` + `frontend/lib/*.dart` |
| the moved runbook was the only rule file with CRLF | normalised to LF; now byte-identical to the deleted original (19 974 B) |

False claims the docs-accuracy pass caught, also corrected: `LATEST.md`'s DEPLOY STATE still asserted 0.2.41 while prod answers `0.2.46 / 43481643` (verified by `curl /version` + `/version.json`); the `.cursor/rules` deletion is **5 tracked files (4 duplicates + the moved runbook)**, not 8/7 — three further `.mdc` mirrors were written earlier in the same session and never committed; `VENDORED.md` claimed "SKILL.md only" though each skill's `scripts/` came too; and the summary claimed the snapshot was taken before the home-tree deletions when it was taken after.

Verified TRUE by review, do not re-check: the 22/19/3 skill split, the 6-dash/14-Pocock/2-repo provenance, the dash SHA `38dce749` (files md5-identical to upstream), both LICENSE texts, that `design-an-interface`/`qa`/`request-refactor-plan` are genuinely gone upstream, all five triage labels, the runbook move, and every `skill://`/`rule://` target resolving.

## 7. Corrections to the background research

Two findings in the background research were wrong and are corrected here: the five triage labels **do** exist in `Lentach/Umbra`, and `docs/agents/{issue-tracker,triage-labels,domain}.md` are already present — `setup-matt-pocock-skills` was run here around 2026-07, which is why `code-review`, `triage`, `to-spec` and `to-tickets` are usable rather than blocked. Do **not** re-run that setup skill: it rewrites `CLAUDE.md`. The ecosystem survey behind §4 (superpowers, anthropics/skills, awesome-* indexes, the verified absence of any NestJS/Prisma/Socket.IO skill collection) stands.
