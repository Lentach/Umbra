# Umbra agent workflow 2.0

**Date:** 2026-09-10. Proposal, not yet applied. Supersedes the tooling half of `.planning/tooling-audit/` (2026-07-27, gitignored) — that audit ranked *tools*; this one measures the *workflow* those tools sit in, six weeks and 100 sessions later.

## 0. Verdict in one paragraph

The workflow is not short of tools; it is drowning in context and ceremony. A frontend session pays **~55k tokens of instruction files before reading one line of code — injected in Claude Code; in OMP the same files are *reads* that `AGENTS.md` mandates, since OMP injects only `AGENTS.md` (§1a, corrected 2026-09-10)** (root `CLAUDE.md` 13k, `frontend/CLAUDE.md` 21k, `LATEST.md` 9k, deploy rule 5k, Dart MCP schemas ~2k, 18 skill descriptions ~0.5k). **38% of all commits since the last audit are `docs` commits and 49% touch session summaries.** The tools installed to make work faster go uncalled by agents — Dart MCP **0/100 sessions** (mount verified working this session; the tier doc never names it), `impact.mjs` **1/100**, graphify output **0/100**, skills **2/100** — while the things that *are* pulling weight run from hooks and CI, invisible to mention-counts (gitleaks 1 mention, every commit). The July cull was written and never executed, and most of it is Claude-Code-only hygiene worth **0 OMP tokens**. Workflow 2.0 is three moves: (1) cut the always-on context by ~70% with progressive disclosure — that is where the tokens are; (2) make the handoff ritual a bounded, validated template instead of a growing essay; (3) delete dead tooling, put the Dart MCP on a hard 30-session probation with routing fixed, and ship exactly one new skill (the hook-enforced one).

## 1. Measurements (this session, `2026-09-10`)

### 1a. Always-on context per request

| File | Tokens (chars/4) | Loaded when |
|---|---|---|
| `CLAUDE.md` (root) | **12,987** | every Claude Code request; **in OMP: NOT injected** — `AGENTS.md` shadows it at depth 0 (`omp://context-files.md`, proven 2026-09-10 by the harness research, `docs/research/2026-09-agent-harness-practice.md` §1), so it is a *deliberate read* that `AGENTS.md` mandates |
| — of which §7 *Shared wire contracts* | **8,120** (62%) | with the root file, incl. pure UI/docs work |
| `frontend/CLAUDE.md` | **21,043** | every frontend session |
| — §5 *E2E and local storage invariants* | 6,579 | |
| — §10 *Passcode Lock* | 5,870 | |
| — §7 *Composer, media, platform gotchas* | 3,000 | |
| `backend/CLAUDE.md` | 5,067 | backend sessions |
| `.cursor/session-summaries/LATEST.md` | **9,223** | session start (mandated) |
| — of which the "rotated-out warnings" banner (lines 6–63) | ~2,500 | defeats the 5-entry cap by design |
| `.cursor/rules/production-vm-deploy.mdc` | 4,759 | keyword-triggered (fine) |
| Dart MCP tool schemas (13 tools, OMP `.omp/mcp.json`) | ~2,000 [INFERENCE] | every OMP request |
| Skill descriptions — **OMP mounts 18** of the 37 dirs in `~/.claude/skills/` (the 18 that appear in the OMP system prompt) | ~450 [INFERENCE] | every OMP request |
| 8 Claude Code plugins (`~/.claude/plugins/`) | **0 in OMP** — plugins are Claude-Code-only; `~/.omp/agent/` has no `skills/`/`agents/` dir and `config.yml` has no plugin keys | Claude Code sessions only |

Frontend session floor ≈ **55k tokens in Claude Code**. **In OMP the always-on layer is only `AGENTS.md` (~0.3k) + the rulebook listing + skill/MCP metadata; the root and tier files are reads the agent makes because `AGENTS.md` tells it to** — the 55k is still what an obedient agent *consumes* before code, but the mechanism is instruction, not injection (correction 2026-09-10, after the harness research). Published 2026 guidance converges on ≤200–250 lines / ≤5% of context for the always-on file and "every rule needs an enforcement layer or an *advisory* tag" (sources §7). Root `CLAUDE.md` is 170 lines but 52 KB because lines are 800-char paragraphs.

### 1b. What the last 100 sessions actually used — two signals, not one

Mention-counts measure what summaries *narrate*. `gitleaks` shows 1 mention yet runs on every commit. So each candidate carries a **hard signal** (hook / CI / mount, checked this session) beside the narrative count; nothing is marked dead on the narrative count alone.

| Thing | Sessions mentioning | Hard signal (verified 2026-09-10) | Cost it carries |
|---|---|---|---|
| lint-ratchet | 51 | CI `ci.yml:107` | none. **Earning its keep.** |
| post-deploy smoke | 47 | invoked by `deploy-web.ps1` | none. **Earning its keep.** |
| test-count verifiers | 28 | CI `ci.yml:92,143` | none |
| gitleaks | 1 | `.githooks/pre-commit:16` on every commit | none. **Keep — proof that mentions ≠ execution.** |
| session-lock probe | — | CI `ci.yml:183` | none |
| `.planning/<task>/` | 24 | — | none |
| subagents | 29 | — | model cost (see §5) |
| CDP two-Chrome drive | 16 | — | recipe lives only in a session summary |
| browser tool | 13 | native device | |
| mutant falsification (F-numbers) | 8 | — | none — discipline, keep |
| **Dart MCP** (`hot_reload`, `widget_inspector`…) | **0** | **mounted and working**: `roots add` + `analyze_files lib/main.dart` → "No errors" through the configured `.omp/mcp.json` this session | ~2k tokens/request; **0 agent calls in 100 sessions** |
| **`impact.mjs`** | **1** | CI self-test `ci.yml:82` (proves the *tool*, not its use) | none, but root §1 sells it as "the inner-loop hint" |
| **graphify** | **0** | post-commit hook runs the rebuild; **`GRAPH_REPORT.md` read by an agent: 0 mentions**; root §2 itself rates its Dart edges 0.5% precision | rebuild after every code commit, 76 MB |
| **context7** | **1** | Claude Code plugin only; not in either OMP `mcp.json` | 0 in OMP; past key leak |
| **skills (`skill://`, `/tdd`, …)** | **2** | 18 mounted in OMP (see 1a) | ~450 tokens/request in OMP |
| `osv-scanner` / `trivy` | 0 | CLI on PATH, not in hook/CI | none — situational, fine |

### 1c. Commit mix since 2026-07-28 (587 commits)

`docs` 225 · `fix` 114 · `feat` 70 · `chore` 40 · `test` 22 · `release` 16. **289 commits touch `.cursor/session-summaries/`.** Dated summaries run 6–21 KB each; the last 12 average 11 KB. Each one is written by the most expensive model in the config at the end of a long context.

### 1d. Config drift vs the July audit

- Cull list (`ralph-loop`, `skill-creator`, `frontend-design`, one `playwright`, 14 dead skills) — **not executed**: `~/.claude/plugins/installed_plugins.json` still lists all 8 plugins; `~/.claude/skills/` still holds `migrate-to-shoehorn`, `scaffold-exercises`, `obsidian-vault`, `setup-pre-commit`, `ask-matt`, `teach`, `writing-*`, `setup-matt-pocock-skills`.
- `@playwright/mcp` still in `~/.omp/agent/mcp.json` *and* as a Claude plugin, alongside the native `browser` device (triple redundancy, unchanged).
- Model roles (`~/.omp/agent/config.yml`): `smol`, `tiny`, `designer`, `vision`, `plan` = **Opus 4.8**; `task` = **Opus 5 high**; `advisor` = Opus 5. There is no cheap tier at all — every `scout`, every `completion(model="smol")`, every mechanical `sonic` item runs on Opus.
- `frontend/CLAUDE.md:225` still says `flutter run -d chrome → screenshot (browser tool)`; the word "mcp" does not appear in either tier doc. Flutter on this box is **3.44.6** — agentic hot reload via Dart MCP is available and unrouted.

## 2. What is useless — delete

| Item | Evidence | Action |
|---|---|---|
| graphify + post-commit/post-checkout hooks | **REMOVED 2026-09-10.** Re-measured against the graph it rebuilt on the last commit (11,773 nodes / 15,382 edges): **Dart import edges 1.8% precision / 4.3% recall** (2,430 graph edges vs 1,003 real imports, 43 correct — it emits `auth_form.dart → voice_message_content.dart`); TS 100% / 89.7% but redundant with `impact.mjs` + `lsp`. `GRAPH_REPORT.md` read in 0/100 sessions. Popular for good reason on TS-shaped repos; broken on this repo's Dart half. Reinstall only when `Graphify-Labs/graphify#58` closes with real Dart resolution | done: `graphify hook uninstall`, both hook files `git rm`'d (the post-commit guard existed only to throttle graphify), `graphify-out/` deleted (76 MB), `.gitignore` entry dropped, root §1 line removed, root §2 rewritten with today's numbers |
| `ralph-loop`, `skill-creator`, `frontend-design`, `code-simplifier` plugins | Claude-Code-only, **0 OMP tokens** — removal is a safety/hygiene win, not a token win: `ralph-loop` registers a Stop hook that re-drives past a finish; `frontend-design` needs a counter-instruction in the tier doc | uninstall |
| `playwright` plugin **and** `@playwright/mcp` in `~/.omp/agent/mcp.json` | native `browser` device does the job; sessions use CDP directly for Flutter. The OMP entry is the one that costs schema tokens | remove both |
| `context7` plugin | Claude-Code-only (0 OMP tokens); 1/100; hosted; past key leak | uninstall; `read <url>` covers docs |
| Third-party skills in `~/.claude/skills/` (37 dirs) | **OMP mounts 18 of them** (`code-review`, `codebase-design`, `design-an-interface`, `diagnosing-bugs`, `domain-modeling`, `git-guardrails-claude-code`, `grilling`, `migrate-to-shoehorn`, `obsidian-vault`, `planning-with-files`, `prototype`, `qa`, `request-refactor-plan`, `research`, `resolving-merge-conflicts`, `scaffold-exercises`, `setup-pre-commit`, `tdd`); the other 19 (`ask-matt`, `teach`, `writing-*`, `wizard`, `to-spec`, …) already cost 0 in OMP. Narrative use 2/100 | delete the 19 unmounted (Claude Code hygiene, 0 OMP tokens) **and** the 6 mounted-but-foreign ones: `migrate-to-shoehorn`, `scaffold-exercises`, `obsidian-vault`, `setup-pre-commit` (would break `.githooks/`), `qa`, `request-refactor-plan` (both upstream-deprecated). OMP: 18 → 12 descriptions, ~150 tokens/request — small; the plugin/skill cull is mostly *not* a token story |
| `LATEST.md` banner (lines 6–63) | 2.5k tokens of prose about entries that were rotated *out* — it is the cap's escape hatch and it grows every rotation | replace with a one-line pointer to `docs/agents/traps.md` (§4) |
| `LATEST.md` deploy-state ledger (line 65) | a 1,300-char running list of every 0.2.x CI run id | keep only: live version + commit per tier, last green CI id, date |
| `docs/agents/domain.md`, `CONTEXT-MAP.md` lazy-creation note (root §9) | root says "their absence is normal" — a paragraph explaining a thing that does not exist | delete paragraph; the `domain-modeling` skill already knows |
| `impact.mjs` as "the inner-loop hint" (root §1) | 1/100 despite the sell; agents use `lsp references` + `grep` | demote to one line in the tier docs' Commands; keep the CI self-test |

Keep, unchanged: `.githooks/pre-commit` (gitleaks + LATEST cap), lint ratchet, smoke wired into `deploy-web.ps1`, test-count verifiers, `.planning/<task>/`, mutant falsification, backups chain, Dependabot.

## 3. Context budget redesign (the big token win)

Principle: **the always-on file holds only rules that change a decision on every task. Everything else is loaded when its trigger fires.** Same rule the tier split already follows — applied one level deeper.

### 3a. Root `CLAUDE.md` → ≤ 3,500 tokens

| Section today | Tokens | Goes to |
|---|---|---|
| §1 Non-negotiable workflow (1,628) | trim to ~700 | history paragraphs ("worktree zoo consolidated 2026-07-22", "the word budgets are gone… three sessions burned") → `docs/agents/traps.md` |
| §2 Architecture (677) | keep ~400 | graphify paragraph deleted; landing-repo detail → one line |
| §3 Local commands (647) | keep ~400 | test-count sentences stay (verifiers read them) |
| §4 Deploy (387) | keep | already a pointer to the rule |
| §5 Version, §6 DB/E2E (932) | keep ~700 | migration `0015` essay → `backend/CLAUDE.md` §4 (backend-only fact) |
| **§7 Wire contracts (8,120)** | **→ `docs/contracts/wire.md`**, keep a 10-line index | load-on-demand rule: *touching `chat.gateway.ts`, the box gateway (`backend/src/box/**`), `socket_service.dart`, `connection_provider.dart` (and its parts under `frontend/lib/providers/connection/**`), any DTO under `backend/src/**/dto`, or `messaging_provider.dart` (and its parts under `frontend/lib/providers/messaging/**`) → read `docs/contracts/wire.md` first.* Enforced by a `.omp/rules/wire-contracts.md` rule with those globs, so it auto-attaches exactly when relevant. |
| §8, §9 (385) | keep §8; §9 shrinks to two lines | |

`docs/contracts/wire.md` becomes the *canonical* place for the §7 paragraphs — same text, moved, not rewritten. `docs/design/multi-device.md` §12 amendments keep pointing at it.

### 3b. `frontend/CLAUDE.md` → ≤ 6,000 tokens

| Section | Goes to | Trigger |
|---|---|---|
| §5 E2E & local storage (6,579) | `frontend/docs/e2e-invariants.md` | rule glob `frontend/lib/services/e2e*/**`, `**/signal*/**`, `**/key_*`, `**/identity*` |
| §10 Passcode lock (5,870) | `frontend/docs/passcode.md` | rule glob `**/passcode*/**`, `**/lock_*` |
| §7 Composer/media (3,000) | `frontend/docs/composer.md` | rule glob `**/chat_input_bar*`, `**/composer*`, `**/attach*`, `**/media*` — and this is where the *"nothing ships in the composer without a green repro and owner OK"* rule lives, next to the code it guards |
| §6 Messaging contracts (2,132) | stays (cross-cutting for any chat screen) | |
| §1 Commands (1,563) | trim to the commands; the E2E harness ratchet-order essay → `frontend/docs/e2e-harness.md` | |

Backend at 5k is acceptable; move the `0015` migration essay in from root and it stays under 6k.

### 3c. Session-start read → `LATEST.md` ≤ 2,500 tokens

Enforced by the hook (§6): 5 entries, each ≤ 900 chars, plus a ≤ 400-char deploy-state line. Everything longer is in the dated file the entry links.

Net effect: frontend session floor **~55k → ~17k tokens** (root 3.5k + frontend 6k + LATEST 2.5k + rules on demand + ~1k skills/MCP). Every session gets ~38k tokens of working room back, and the wire contracts stop competing for attention on a copy-change.

## 4. Handoff ritual 2.0

Today: each session writes an 11 KB essay, rewrites a 37 KB `LATEST.md`, and the "rotated-out" material migrates into an ever-growing banner. The signal (traps, owner decisions, open asks) is buried in narrative.

New shape — three files with three different lifetimes:

1. **`docs/agents/traps.md`** — *permanent, one line per trap, grouped by area*, each line `- **<trap>** — <one sentence> (<dated-summary link>)`. This is where banner content and the "Traps:" bullets of every entry go. An agent touching an area greps it. Cap: none, but one line each.
2. **`.cursor/session-summaries/YYYY-MM-DD-<slug>.md`** — *per-session, fixed template, ≤ 6 KB* (hook-enforced, §6):
   ```
   # <title>
   **Date:** … **Version:** <before → after> **Tiers deployed:** web|backend|both|none
   ## What was done     (≤ 8 bullets, what changed, file:symbol)
   ## Key files
   ## Verification      (commands run + result lines, mutants killed, live drive summary)
   ## Notes for next session   (owner decisions owed, NOT-verified surfaces, traps — each trap ALSO appended to docs/agents/traps.md)
   ```
   No narrative of the investigation — that is what `.planning/<task>/findings.md` is for when a task spans sessions.
3. **`LATEST.md`** — *5 entries × ≤ 900 chars*: date · version · one-sentence outcome · open asks · link. One deploy-state line at the top. No banner.

Rule: **the summary is written by the `umbra-session-end` skill (§5b) which runs the validator** — the hook is the enforcement, the skill is the ergonomics.

## 5. Tooling 2.0

### 5a. MCP

| Server | Decision | Why |
|---|---|---|
| **Dart MCP** (`.omp/mcp.json`) | **keep on probation, and route it** | The July audit's exit criterion — *"if after two weeks it is not being called, remove it"* — is 6 weeks past and technically met: 0 agent calls. Two facts argue for one more, bounded, try instead of removal now: (1) **the mount works** — verified 2026-09-10 with `roots add` + `analyze_files lib/main.dart` → "No errors"; the July mount was never verified, so nobody knew; (2) **the tier doc never names the tool** (`frontend/CLAUDE.md:225` says `flutter run → screenshot`), so the zero measures routing, not value. Flutter here is 3.44.6 (`sdk: ^3.10.7` is a floor, not a pin), so agentic hot reload needs no SDK bump. **Binary mismatch to resolve first:** the mount is the pub-cache `dart_mcp_server.bat` **1.1.0**; the SDK-bundled `dart mcp-server` is **0.1.4** — the articles describe the latter's tool set; keep 1.1.0 (newer), but record it. Rewrite `frontend/CLAUDE.md` §9 loop as `launch via hub (background) → edit → mcp hot_reload → get_runtime_errors → browser screenshot`. **Probation: 30 sessions after the routing lands; if `grep -l 'hot_reload\|mcp__dart' summaries` is still 0 → delete the `.omp/mcp.json` entry, no further debate.** |
| `@playwright/mcp` | remove | native `browser` device |
| GitHub MCP | do not add | `gh` CLI + `issue://`/`pr://` readers already cover it with zero schema cost and no untrusted-text injection |
| Postgres MCP | do not add | `docker exec … psql` in sessions works; the reference server is archived |
| chrome-devtools-mcp | situational only | perf investigations; not standing |

The 2026 ecosystem trend is remote OAuth MCPs for SaaS (GitHub, Linear, Notion, Supabase…); none of those is in this stack. The correct MCP count for Umbra is **one**.

### 5b. Skills — one now, the rest stay as doc sections until a session reaches for them

The strongest evidence in this document is that **38 skills went unused across 226 sessions** and skills score 2/100 since July. Shipping five speculative project skills risks the same fate. Rule: **a new skill ships only when its trigger is mechanically enforced** — a hook or CI check that fails without it. Everything else is a section in an already-loaded doc, promoted to a skill only after a session is observed reaching for it.

| Skill | Ships now? | Enforcement |
|---|---|---|
| `umbra-session-end` (`.claude/skills/umbra-session-end/SKILL.md`, committed — OMP discovers project `.claude/skills` at priority 80 and Claude Code discovers nothing else, so one file serves both) | **yes** | `.githooks/pre-commit` runs `scripts/verify-context-budget.mjs` (§6); a summary that misses the template or budget cannot be committed, so the skill is the ergonomic path to a green commit |
| Flutter live-verify loop (Dart MCP hot reload + the two-isolated-Chromes CDP recipe from `2026-09-08-session-c7-final-review.md`) | **no — becomes `frontend/CLAUDE.md` §9 text** | that section is already auto-loaded for frontend work; a skill would add a description line for a thing the tier doc must say anyway |
| Release checklist (PATCH bump → push → `gh api …/commits/master/check-runs`, never `gh run list` → backend first → `deploy-web.ps1` → smoke) | **no — already covered** | `.cursor/rules/production-vm-deploy.mdc` auto-attaches on deploy keywords; add the check-runs line there |
| Mutant falsification (F-numbers) | **no — doc section** | 8/100 sessions do it unprompted from the tier doc; not broken |
| Wire-change steps | **no — doc section** | root §8 + the §3a glob rule loading `docs/contracts/wire.md` is the enforcement |
| Incident recipe (nginx/audit-log timeline) | **no — `docs/agents/traps.md` entry** | promote only if a second incident session reaches for it |

Keep from the mounted set: `diagnosing-bugs`, `tdd`, `code-review`, `planning-with-files`, `resolving-merge-conflicts`, `research`, `git-guardrails-claude-code`, `domain-modeling`, `codebase-design`, `prototype`, `grilling`, `design-an-interface` (upstream-deprecated but the only interface-design skill; drop if unused by the probation review). Delete the 6 mounted-but-foreign (§2). Net in OMP: 18 → 12 descriptions.

### 5c. Model roles (`~/.omp/agent/config.yml`) — owner decision 2026-09-10

Two-tier split, settled in one exchange: **Opus 5 for every role that reasons about the codebase; a cheap model for one-shot mechanical work.** Rationale: the measured token drain is the docs (§1a), not the roles; a cheap scout that misreads the codebase costs a whole round-trip (the 08-26 fabricated-compliance incident is that failure mode); but `smol`/`tiny` serve `completion(model="smol")` classification and `sonic` items, where Opus is pure cost with no quality delta. Uniform Opus 5 on `task`/`slow`/`plan`/`advisor` also makes root §1:31 ("review subagents use the same model class as the primary") hold by construction — no clause needed.

```yaml
modelRoles:
  default:  anthropic/claude-fable-5-1:high              # unchanged — the owner's main model
  commit:   anthropic/claude-haiku-4-5-20251001:medium   # unchanged
  smol:     anthropic/claude-haiku-4-5-20251001:medium   # was Opus 4.8 — small tasks stay cheap
  tiny:     anthropic/claude-haiku-4-5-20251001:medium   # was Opus 4.8
  task:     anthropic/claude-opus-5:high                 # already
  advisor:  anthropic/claude-opus-5:medium               # already
  slow:     anthropic/claude-opus-5:medium               # was Opus 4.8
  plan:     anthropic/claude-opus-5                      # was Opus 4.8
  designer: anthropic/claude-opus-5:medium               # was Opus 4.8
  vision:   anthropic/claude-opus-5:medium               # was Opus 4.8
```

Ids verified against `~/.omp/agent/models.db` (`claude-opus-5`, `claude-haiku-4-5-20251001` present). Net change: four Opus 4.8 roles up to Opus 5, two down to Haiku.

### 5d. Memory — decision recorded 2026-09-10

OMP `memory.backend` / `autolearn` / managed skills stay OFF. They are machine-local (`~/.omp/agent`), extraction is priced at the `default` role on startup, subagents skip them, and a public repo cannot see them. `traps.md` + `LATEST.md` is the same vendor-endorsed structured-note-taking pattern (Anthropic, *Effective context engineering*) with repo-wide reach. Re-litigate only if a second machine joins. Source: `docs/research/2026-09-agent-harness-practice.md` §5.

### 5e. CLI tools — no additions

`gitleaks`, `osv-scanner`, `trivy` are installed and situational. Nothing surveyed this session changes the July verdicts (GitHub MCP, Sentry, SonarQube, knip, artillery all still C/B for the stated reasons). The one structural gap the July audit named — error tracking (GlitchTip) — remains the E2E-audit owner's call and is out of scope here.

## 6. Enforcement layer (a rule without one is a wish)

Add `scripts/verify-context-budget.mjs`, wired into `.githooks/pre-commit` next to the LATEST cap:

| Check | Limit | Fails commit when |
|---|---|---|
| `CLAUDE.md` bytes | 24,000 (post-migration size 20.4 KB; §3a's 3.5k-token target = ~14 KB is the *next* ratchet step once §1/§6 history paragraphs move to `traps.md`) | exceeded |
| `frontend/CLAUDE.md` bytes | 28,000 (post-migration 23.7 KB) | exceeded |
| `backend/CLAUDE.md` bytes | 26,000 | exceeded |
| `LATEST.md` entries | 5 (existing) | exceeded |
| `LATEST.md` per-entry chars | 900 advertised; **hook fails at 1,000** (100 chars slack for links) | exceeded |
| `LATEST.md` total bytes | 10,000 | exceeded |
| new dated summary bytes | 6 KB advertised; **hook fails at 8,000** (slack for proof tables) — applies to added AND modified summaries | exceeded |
| new dated summary sections | `## What was done`, `## Key files`, `## Verification`, `## Notes for next session` (the headings root §1 has always required; the Done/Proof/Open/Traps draft was dropped 2026-09-10 to keep one template) | missing |

Ratchet semantics like `lint-ratchet.mjs`: the limits are set at the *post-migration* sizes, so the check is green the day it lands and can only bite on regrowth. Tags in the docs: every rule that has no hook/CI/verifier behind it is marked `(advisory)` so readers know which sentences are enforced.

## 7. Sequenced plan

Each batch independently reversible; nothing later depends on earlier.

| # | Batch | Touches | Risk |
|---|---|---|---|
| 1 | **Cull** — 4 plugins, 25 skills (19 unmounted + 6 mounted), `@playwright/mcp`; ~~graphify hook + dir~~ **graphify half DONE 2026-09-10** | machine config; ~~`.githooks/post-commit`, root §1/§2~~ done | none; hard signals checked in §1b. Token win in OMP ≈ 0.5k/request; the rest is hygiene/safety |
| 2 | **Route Dart MCP + start probation** — rewrite `frontend/CLAUDE.md` §9 loop (hot reload + CDP recipe as text, no skill); record the 1.1.0-vs-0.1.4 binary choice in that same §9 paragraph (`.omp/mcp.json` is strict JSON with a `$schema` — no comments) | one tier section | none; probation clock starts here |
| 3 | **Split root §7 → `docs/contracts/wire.md`** + `.omp/rules/wire-contracts.md` glob rule | root, new file, new rule | low: text moves verbatim; verify with `git diff --stat` that root shrinks by ~32 KB and the new file grows by the same |
| 4 | **Split frontend §5/§7/§10** into `frontend/docs/*.md` + glob rules | tier file, 3 new files, 3 rules | low, same verbatim-move check |
| 5 | **Handoff 2.0** — `traps.md` seeded from the LATEST banner + last 30 summaries' "Traps" bullets; template; `umbra-session-end` skill; `verify-session-summary.mjs` + budget verifier in pre-commit | hook, scripts, LATEST rewrite | medium: hook edits need owner OK; first run rewrites LATEST |
| 6 | **Model roles** — `slow`/`plan`/`designer`/`vision` → Opus 5; `smol`/`tiny` → Haiku (§5c); `default`/`commit`/`task`/`advisor` untouched | user config only | none; owner decided 2026-09-10 |
| 7 | Nothing. The four deferred skills (`release`, `falsify`, `wire-change`, `incident`) stay as doc sections until a session is observed reaching for them (§5b) | — | — |

### Batch 8 — from the 2026-09 research (`docs/research/`), each its own session with its own proof

Applied 2026-09-10 (harness fixes 1,2,3,4,6,9,10,11 from `2026-09-agent-harness-practice.md` §9): `AGENTS.md` now carries the hard rules (it is the only file OMP injects); `.omp/rules/*.md` for the four area docs, **in the explicit form `condition: ".*"` + `scope: "tool:edit(<glob>), tool:write(<glob>), …"`** — the documented `condition:` file-glob shorthand did NOT register from a YAML list (probe: 2 edits on `chat.gateway.ts`, 0 injections); the explicit scope form fired on the first edit (`ttsr_injection` → `injectedRules: ["wire-contracts"]`, `docs/contracts/wire.md` delivered in the tool result). Fires at edit time, reaches subagents; `.cursor/rules` globs as YAML arrays; caps reconciled with §6; skill moved to `.claude/skills/` (both harnesses discover it); one summary template; memory decision recorded (§5d); "always-on" framing corrected (§1a).

| # | Add | Why (evidence in the research file) | Gate |
|---|---|---|---|
| ~~8.1~~ | **DONE 2026-09-10 — pinned via `flutter-version-file: frontend/pubspec.yaml` + `environment.flutter: 3.44.6`** (all four jobs; CI run resolved `stable-3.44.6-x64` @ `ee80f08bbf`, identical to the box; 6/6 green). The **3.47** move is now a one-line pubspec edit when Widget Previewer is wanted | CI floats to Dart 3.13.3, box is 3.12.2 — a tool with a floor between them passes CI and fails locally (`very_good_analysis` 11 is that case today). 3.47 also makes **Widget Previewer** stable (`@Preview` replaces booting the app to eyeball a widget) | `flutter --version` both sides equal; `.widget_preview/` gitignored |
| 8.2 | **ANDROID DONE 2026-09-12, web open — `patrol` 4.9.0 exact + `patrol_cli` 4.7.0 (declared-compatible pair), `patrol:` block (`test_directory: integration_test`), `PatrolJUnitRunner` + orchestrator 1.5.1 in `build.gradle.kts`, `androidTest/.../MainActivityTest.java`; `**/test_bundle.dart`, `.patrol.env`, `frontend/{playwright-report,test-results}/` gitignored.** `integration_test/patrol_harness_test.dart` (framework-only, per upstream `patrol-setup` skill) is 1/1 green on the Pixel_7 AVD. The existing `testWidgets` device files are NOT patrol tests: `identity_recovery_durability_device_test.dart` under `patrol test` sat in "Executing tests" until a 2 400 s timeout — they stay on `flutter test integration_test -d`. Web: `patrol test -d chrome` built + served the bundle and installed Playwright/Chromium, but `globalSetup` (`web_runner/tests/setup.ts:44` sets `PATROL_TESTS` from `window.__patrol__getTests()`) got nothing → `Total: 0`, exit 1; that attempt overlapped the Android build of the same bundle file, so a serial retry is the next step, not a verdict | only surveyed E2E tool covering web AND Android | Android: `Test summary: Total 1 / Successful 1` (2 m 29 s incl. gradle). Web: not green |
| ~~8.3~~ | **DONE 2026-09-12 — `knip` 6.35.1 exact in `backend/`, `npm run knip` (`--include files,dependencies`), `backend/knip.json` lists the one-shot `scripts/*.ts` as entries; hard CI gate after the lint ratchet.** First pass: 2 files (entries, kept) + 5 Nest-starter devDeps removed (`@eslint/eslintrc`, `@types/supertest`, `supertest`, `source-map-support`, `ts-loader` — none referenced outside package.json). Same commit: `overrides.multer=$multer` + `multer ^2.3.0` closes the 4 open Dependabot alerts on the copy nested under `@nestjs/platform-express` (pins 2.2.0 exactly, even at 12.0.1); 62/62 suites, 1119 tests, ratchet held at 898 | ISC, first-class Nest plugin so DI providers are not false positives | knip exit 0; `npm ci`/`nest build`/`npm test`/ratchet all exit 0 unpiped |
| ~~8.4~~ | **DONE 2026-09-12 — `docker-compose.prod.yml` db `command:` preloads `pg_stat_statements` (`max=1000`, `track=top`); applied on the VM by `git pull` + `up -d --no-deps db` + `docker restart fireplace-backend-1` (db-only recreate, backend image untouched: `/version` still `0.2.35 / e6ccae0a`), then `CREATE EXTENSION` in `chatdb`.** Command shape proven first on a throwaway `postgres:16-alpine` locally | bundled in PG16; ~1 MB shared memory; no egress | `SHOW shared_preload_libraries` → `pg_stat_statements`; `SELECT … FROM pg_stat_statements LIMIT 1` returns a row; `/health` ok inside and outside |
| 8.5 | **CONFIG DONE 2026-09-12 — `renovate.json` transcribes every `dependabot.yml` rule with its reason (validated `renovate-config-validator --strict` on 44.82.1; SDK pins matched by `matchPackageNames: [dart, flutter]` + datasources, since pub extracts them with no depType).** Remaining owner step: install the Mend Renovate GitHub App on `Lentach/Umbra`; delete `.github/dependabot.yml` in the PR that merges the first green Renovate PR. Both files stay in sync until then | `enabled:false` rules evaluate BEFORE grouping and its pub manager runs `flutter pub upgrade`, so #157/#169/#171/#173 cannot recur | first Renovate PR merges green; `dependabot.yml` deleted in the same PR |
| ~~8.6~~ | **DONE 2026-09-12 — `very_good_analysis: 10.3.0` (exact) as the `analysis_options.yaml` base; `strict-casts`/`strict-inference` off (11 errors + 59 warnings, all `dynamic` into typed crypto params — E2EE-path code, fixed under the area doc later), `strict-raw-types` on (5 `Map` raw types typed in `test_e2e`); `always_use_package_imports`/`public_member_api_docs`/`lines_longer_than_80_chars` off as recorded conventions. `scripts/dart-lint-ratchet.mjs` + `dart-lint-baseline.json` (3 175 infos, measured twice on a clean `cc6c888` worktree — the main checkout flapped ±30 because a concurrent session was editing `chat_input_bar.dart`) as a CI step after analyze** | `async_return_with_no_await` and the `unawaited_futures`/`discarded_futures` pair are the rules this codebase wants | `flutter analyze --no-fatal-infos` exit 0; ratchet PASS ×2; forced `catch (e)` + `print` probe FAIL +1 |
| ~~8.7~~ | **DONE 2026-09-12 — `diagnosing-bugs` (8 529 B, `## Redact` present) + `scripts/hitl-loop.template.sh` and `grilling` (1 987 B) re-pulled into `~/.agents/skills/` from `mattpocock/skills@3cca18b368`; `dart-test-fundamentals`, `dart-matcher-best-practices`, `dart-test-coverage`, `profile-dart-code` (SKILL.md + scripts, no evals/examples) into repo `.claude/skills/` from `kevmoo/dash_skills@ea5aa807`** | on-disk `diagnosing-bugs` was missing the redaction section | `grep -n Redact` shows it at line 12 |
| ~~8.8~~ | **DONE 2026-09-12 — `scripts/smoke/artillery-socket.{yml,mjs}`, artillery 2.0.34 exact in the smoke package, `npm run socket [target]`.** Runner mints one JWT (register-or-login locally, login-only on prod) and passes it as `FP_SMOKE_TOKEN`: the launcher templates `config.socketio` before workers start and the socketio engine connects before the first flow step, so a processor cannot inject the token (probed: `beforeScenario`, `function` step, `before` hook all arrive at `auth: {}`). Scenario: connect → `getConversations` → exact `conversationsList [[]]` (the engine validates a `response` immediately only on an exact `data` match; the gateway emits, it does not ack). `plugins.ensure` makes thresholds set the exit code | built-in `socketio` engine; k6 closed #1306 without it | local docker backend: 5/5 VUs, p95 76 ms, exit 0; bogus token: 5 failed, exit 1 |
| ~~8.9~~ | **DONE 2026-09-12 — `typescript` semver-major ignored in BOTH `dependabot.yml` (active) and `renovate.json` (successor)** | `typescript-eslint` 8.70 peers `<6.1.0` — TS7 silently strands every type-aware lint | rule present in both files |
| ~~8.10~~ | **DONE 2026-09-12 — `.omp/RULES.md` (7 lines), `.omp/hooks/pre/guard.ts` (`tool_call` block on `git commit --no-verify`/`-n` and `gh run list`), Claude Code mirror `.claude/hooks/guard.mjs` + `.claude/settings.json` PreToolUse, `.claude/rules/{wire-contracts,frontend-e2e-invariants,frontend-composer-media,frontend-passcode-lock}.md` with `paths:` (generated from the `.cursor/rules` globs); `.gitignore` un-ignores `.omp/hooks/` + `.omp/RULES.md`** | complements, not replacements, for the git gate | both guards block the 3 forbidden forms and allow `git commit -m ok` / `gh api` in a dry run (stub `pi` for OMP, stdin JSON for Claude Code); `rule://RULES` needs a fresh session to verify |

Explicitly NOT, with the reason in the research: NestJS Observe/MCP (paid tier, egress, 4 GB), maestro (web Beta, fixed viewport, needs `Semantics` edits), DCM (50k-LOC free tier < 55.8k in `lib/` alone), docker scout (needs login + uploads), alchemist (6 months silent), Developer Knowledge MCP (all queries to Google), Postgres MCPs (`docker exec psql`), chrome-devtools-mcp standing (58 schemas, telemetry), Vitest migration (runner-agnostic APIs, zero correctness gain), superpowers (its `.pi` extension imports a package OMP lacks), OMP memory backends (§5d).

Measure after 30 sessions: session-start token floor (target ≤ 17k), Dart MCP usage (target > 0 or remove), `docs` share of commits (target < 20%), average dated-summary size (target ≤ 6 KB).

### Applied 2026-09-10 (owner: "yes remove and do 3 small ones")

| Change | Files | Proof |
|---|---|---|
| graphify removed (see §2 row) | `.githooks/post-commit`, `.githooks/post-checkout` deleted; `graphify-out/` deleted; `.gitignore`; root `CLAUDE.md` §1 (line dropped), §2 (rewritten with today's numbers) | `graphify hook uninstall` reported both hooks removed; `git status` shows `D` on both files |
| gitleaks call modernised | `.githooks/pre-commit`: `gitleaks protect --staged` → `gitleaks git --staged` (both the check and the `-v` report), comment updated to PUBLIC repo + current date | `gitleaks git --staged --redact` → "no leaks found", exit 0, on 8.30.1 |
| CI check command corrected | root `CLAUDE.md` §3 and a new preflight block at the top of `.cursor/rules/production-vm-deploy.mdc`: `gh api repos/Lentach/Umbra/commits/master/check-runs --jq …`, explicitly **not** `gh run list --branch master` | command run live → `Analyze (actions) success` for current master |
| `.planning/` root tidied | 67 loose `scr*/sl*/g*/lab*.png`, `rec.mp4`, two `deploy-*.log` moved to `.planning/_loose-screenshots-pre-2026-09/` (gitignored dir — moved, not deleted). Root now holds only `START-HERE.md` + one diff txt. No `.active_plan` was present | `ls .planning` |

### Applied 2026-09-10 (batches 3–5, owner: "every agent has a wall of text to read on session start")

root `CLAUDE.md` §7 → `docs/contracts/wire.md`; `frontend/CLAUDE.md` §5/§7/§10 → `frontend/docs/{e2e-invariants,composer-media,passcode-lock}.md`. All four moves scripted and **md5-verified byte-identical** against `HEAD`; each old section is now a 3-line stub naming the trigger files. Four `.cursor/rules/*.mdc` rulebook entries (`wire-contracts`, `frontend-e2e-invariants`, `frontend-composer-media`, `frontend-passcode-lock`) with `description` + `globs`, same shape as the deploy rule. LATEST rewritten: no banner, one deploy-state line, 5 entries ≤900 chars; the banner's standing warnings → `docs/agents/traps.md` (one line each, 8 groups, every line links its dated file). Root §1 handoff bullets rewritten to the new contract. `scripts/verify-context-budget.mjs` (ratchet caps on root/tier bytes, LATEST entries/length/banner, new-summary size + sections) wired into `.githooks/pre-commit` gate 2, replacing the shell entry count. **Floor: always-on 6.6k tokens (was ~27k), frontend session 12.5k (was ~48k); on-demand docs 3–8k each.**

### Accuracy audit 2026-09-10 (owner: "check if knowledge is actually accurate with the actual code")

Six parallel auditors, one file each, code-only evidence (session summaries and the multi-device spec explicitly excluded), edits in place, headings frozen.

| File | Claims | Corrected |
|---|---|---|
| `docs/contracts/wire.md` | 61 | 9 |
| `frontend/docs/e2e-invariants.md` | 108 | 8 |
| `frontend/docs/composer-media.md` | 108 | 4 |
| `frontend/docs/passcode-lock.md` | 95 | 2 |
| `backend/CLAUDE.md` | 97 | 9 |
| root + `frontend/CLAUDE.md` remainder | 105 | 10 |

- **Notable corrections:** Notable corrections: envelope carries `mediaWidth/Height/ThumbHash`; enrolled accounts get NO signature path on identity change ((liv)); `sendToken` IS minted and sent by the app (doc said it wasn't); `authorizedBy` has `'unlocked'|'restore'` and restore also tears down; `setDisappearingTimer` has its own `rate_limited` event; `onlineUsers` map is retired (rooms are presence); Node 22 not 20; delete-account revokes refresh tokens FIRST; `GIPHY_API_KEY`/VAPID have NO embedded fallback; `connect(userId, token, …)` arg order; 5 CI jobs incl. `e2e-isolated-probes`; five themes incl. `cosmic`; link ceremony is also passcode-exempt. **Dead globs found and fixed** in two rules + two stubs (`**/key_*`, `**/prekey*`, `**/lock_*`, `**/wake*` matched nothing; replaced with real paths).
- **Source-side rot the audit found (docs now right, CODE COMMENTS wrong — not fixed, out of scope):** the `chat-key-exchange.service.ts:534-546` "back to back" and `:651` "72 h" snippets no longer exist after the batch-4 split (RESOLVED); `identity-reset.service.ts:67-70,138` says "72 h" in prose while the constant is 6 h; the "hold-to-record" wording on a tap-only recorder (README and `frontend/docs/composer-media.md` fixed in batch 5, TD-15) STILL stands in two composer-file comments, `chat_input_bar.dart:1582-1583` and `hex_send_button.dart:13`, which need the owner's OK; `build-android.ps1:109` warns about an "embedded fallback key" that does not exist; `encryption_service.dart:4224` claims `DualStorage.readAll()` merges both storages. Also: two `contact_*` migrations (0009/0010) + `CONTACT_INBOX_KEY` env existed with no backend module reading them (the env lines left `docker-compose.prod.yml` in batch 2).
- **Unverifiable by design:** absolute test counts (suites not run — verifier regexes confirmed armed), version/date provenance inside docs, prod observations.

Full reports with every file:line: `agent://AuditWire`, `agent://AuditE2E`, `agent://AuditComposer`, `agent://AuditPasscode`, `agent://AuditBackendTier`, `agent://AuditRootAndFrontendTier` (session-local; the transcripts are under `history://`).

## 8. Sources (web, this session)

- dart.dev — *Dart and Flutter MCP server* (tool buckets: project / test / runtime / hot reload): https://dart.dev/tools/mcp-server
- Dart blog — *Announcing Dart 3.12*, agentic hot reload via DTD auto-discovery: https://dart.dev/blog/announcing-dart-3-12
- AgentLint — *CLAUDE.md best practices 2026* (≤250 lines; every rule falsifiable; every rule needs an enforcement layer or an advisory tag): https://www.agentlint.app/blog/claude-md-best-practices-2026/
- SmartScope — hooks for enforcement / skills for contextual knowledge / subagents for delegation / short CLAUDE.md for always-on: https://smartscope.blog/en/generative-ai/claude/claude-code-best-practices-advanced-2026/
- MindStudio — progressive disclosure for agent skills: https://www.mindstudio.ai/blog/progressive-disclosure-ai-agents-context-management
- Tembo / Firecrawl 2026 MCP surveys (baseline = GitHub, filesystem, Playwright, Context7, tracker; trend to remote OAuth servers): https://www.tembo.io/blog/best-mcp-servers · https://www.firecrawl.dev/blog/best-mcp-servers-for-developers
- Practical DevSecOps — MCP security statistics 2026 (untrusted-text injection is the top reported MCP risk class): https://www.practical-devsecops.com/mcp-security-statistics-2026-report/
- OMP harness docs (`omp://config-usage.md`, `omp://skills.md`, `omp://context-files.md`, `omp://rulebook-matching-pipeline.md`): project skills discovered at `.claude/skills/` (priority 80) and `.omp/skills/`; edit-time rules at `.omp/rules/*.md` via `condition:` file globs; `AGENTS.md` shadows root `CLAUDE.md` at depth 0; MCP at `.omp/mcp.json`.
