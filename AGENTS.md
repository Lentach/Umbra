# AGENTS.md — Fireplace (Umbra)

Universal agent entrypoint. **In Oh-My-Pi this is the ONLY project file injected automatically** (it shadows root `CLAUDE.md` at the same depth — `omp://context-files.md`). Everything below is therefore load-bearing; everything else is a deliberate read.

## Read, in order

1. Root `CLAUDE.md` — workflow, architecture, deploy safety, version contract.
2. The tier file before your first change in that tier: `backend/CLAUDE.md` or `frontend/CLAUDE.md`.
3. `.cursor/session-summaries/LATEST.md` (5 entries), then `grep docs/agents/traps.md` for the area you will touch — standing warnings live there, one line each.
4. Area docs, before the first edit in a matching file (an edit-time rule fires in OMP from `.omp/rules/`; Claude Code sees the same list in `.claude/rules/`):
   - `docs/contracts/wire.md` — `chat.gateway.ts`, `**/dto/**`, `key-bundles/` (incl. devices), `auth/`, `socket_service.dart`, `connection_provider.dart`, `messaging_provider.dart`
   - `frontend/docs/e2e-invariants.md` — `services/encryption/**`, `encryption_service.dart`, `device_list/`, `device_link/`, `recovery_phrase.dart`, `encryption_provider.dart`
   - `frontend/docs/composer-media.md` — `chat_input_bar*`, `composer*`, `chat_action_tiles.dart`, `web_file_input.dart`, `widgets/message/**`
   - `frontend/docs/passcode-lock.md` — `**/passcode*`, `privacy_curtain*`, `content_key_wrap.dart`, `web/index.html`
   - `skill://flutter-frontend-design` — any visual Flutter change: `frontend/lib/{widgets,screens,theme}/`
5. Skills: **`.claude/skills/` IS the set** — `.omp/config.yml` mutes `~/.agents`, so every worktree inherits the same set. Add skills there. Map + MCP: `docs/agents/skills-and-mcp.md`.
   - By trigger: broken/slow → `diagnosing-bugs` · "review since X" → `code-review` · stress-test a plan → `grilling` · module shape → `codebase-design`, `design-an-interface` · docs/API facts → `research` · open design question → `prototype` · merge/rebase → `resolving-merge-conflicts` · file it → `qa`, `request-refactor-plan` · `/skill:` only → `triage`, `to-spec`, `to-tickets`. Flutter visuals, Dart idioms and tests fire from `.omp/rules/`.
6. Delegating? Subagents start blank, in the main checkout: give the ABSOLUTE path of this worktree's baton + its traps (`umbra-session-start` §6), then only the slice.

## Non-negotiable (details in root `CLAUDE.md` §1, §4, §6)

- Code wins over docs. When they disagree, fix the doc in the same commit. Re-verify volatile claims (branch, versions, CI, counts) with a command you ran THIS session.
- **This checkout is on `feat/passcode-lock`; `master` lives in the `fireplace-0a` worktree.** `git fetch && git status -sb` first. Push as `git push origin HEAD:master`, then the branch. **The worktree is shared — stage by explicit path, never `git add -A`; never `git revert 0cbf17b`** (see `traps.md`).
- Change only what was asked. Composer/attachment picker: read `frontend/docs/composer-media.md` first, keep a repro for behaviour changes.
- **Every code change is driven on a device before it is "done"**: built app in a browser or Android emulator/phone, on the changed path. Tests/CI/headless probes do not count. The summary names what was driven.
- Pre-commit runs `gitleaks git --staged` and `scripts/verify-context-budget.mjs`. Never `--no-verify`. Never trim a fresh summary to fit — move detail out.
- Prod: deploy is split (web from the PC, backend on the VM); CI must be green first — `gh api repos/Lentach/Umbra/commits/master/check-runs`, **never `gh run list`**. Never `docker compose down -v` / `volume rm` / bare `up -d` on prod. Never tell a user to clear site data.
- Task end: skill `umbra-session-end` (summary ≤6 KB, traps, LATEST rotation); fresh session: `umbra-session-start`.

Maintain this file as the always-on layer: ≤40 lines, hard rules + pointers only. New facts go in `CLAUDE.md`, a tier file, an area doc, or `traps.md`.
