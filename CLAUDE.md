---
description:
alwaysApply: true
---

# CLAUDE.md — Fireplace

**Source of truth = this root file + the two tier files + the on-demand area docs** (`docs/contracts/wire.md`, `frontend/docs/*.md`, each behind a `.omp/rules/*.md` trigger, mirrored in `.claude/rules/`). Root is cross-cutting and stays in context — read it before any Fireplace work. The tier files hold the tier-wide traps and are **not** auto-injected. Read the matching one **once, before your first change in that tier**, then keep it in context — do not re-read it on every edit:

- Changing anything under `frontend/` (Flutter/PWA/client) → read `frontend/CLAUDE.md` first.
- Changing anything under `backend/` (NestJS/Postgres/server) → read `backend/CLAUDE.md` first.
- Cross-tier or infra/deploy/docs → this root file is enough.

Keep root cross-cutting: if a fact only matters while editing Flutter or NestJS code, it belongs in the tier file, not here. Do not turn root back into a junk drawer.

## 1. Non-negotiable workflow

- Read this root file before any Fireplace app work, and the matching tier file before your first change in that tier (see the header rule). **Area docs are loaded on demand, not up front:** the wire contracts (`docs/contracts/wire.md`), E2E/storage invariants, composer/media, and passcode lock (`frontend/docs/*.md`) each have a `.omp/rules/*.md` entry naming the files that trigger them — read the doc before the first edit in such a file. When delegating, tell the subagent which of these to read — subagents do not inherit your loaded context.
- **`C:/Users/Lentach/Desktop/Fireplace` is THE working copy — but it is on `feat/passcode-lock`, NOT `master`** (`master` is checked out in the `fireplace-0a` worktree, so it cannot be checked out here — `git worktree list`). The branch is kept AT master's tip by convention, not by git: **it drifts the moment anyone pushes to master from elsewhere** (it did on 2026-09-10 while a concurrent session shipped 0.2.37/0.2.38). Every session: `git fetch && git status -sb && git log --oneline HEAD..origin/master` FIRST; if behind, `git merge --ff-only origin/master`. Commits made here go out as `git push origin HEAD:master` then `git push origin feat/passcode-lock`. The landing page lives in its own repo: `Desktop/fireplace-landing` (`Lentach/fireplaceWebsite`).
- **PUBLIC repo** — `Lentach/Umbra` is public (since 2026-08-18; `gh repo view --json isPrivate` → `false`). Treat every tracked file as world-readable. A pre-commit hook runs `gitleaks git --staged` (8.30.1 on the dev PC; regex fallback elsewhere) and `scripts/verify-context-budget.mjs`; activate once per clone with `git config core.hooksPath .githooks`. Bypass only in emergencies (`--no-verify`). gitleaks is not a substitute for care: write `<REDACTED>` when pasting a URL or curl; a key-NAME literal that trips a rule gets `// gitleaks:allow` on the line.
- **Session start:** read `.cursor/session-summaries/LATEST.md` (≤5 entries, ≤900 chars each), then `grep docs/agents/traps.md` for the area you will touch. Standing warnings live in `traps.md`, one line each — never in LATEST.
- **Task end:** write `.cursor/session-summaries/YYYY-MM-DD-<slug>.md` (≤6 KB; sections `# title`, `**Date:**`, `## What was done`, `## Key files`, `## Verification`, `## Notes for next session` — the last holds owner-owed decisions, NOT-verified surfaces, and traps), append each new trap as one line to `docs/agents/traps.md`, then put a ≤900-char entry on top of LATEST and **delete the oldest**. Investigation narrative belongs in `.planning/<task>/findings.md`, not the summary. Dated summaries ARE committed. The hook enforces the caps; **never trim a fresh summary to fit — move detail to the dated file or `findings.md`.**
- For multi-step/debug/deploy-sensitive work, use persistent planning files in `.planning/<task>/` — `task_plan.md`, `findings.md`, `progress.md` live INSIDE that directory, never at the repo root. Re-read before decisions; log failed attempts. Delete `.planning/.active_plan` when the plan it names is finished, or it silently points the next session at completed work.
- Before any change: read the files you touch and trace the code paths. Code/source beats docs and old summaries.
- **Re-verify VOLATILE claims; never inherit them.** Git/branch state, what is live, versions and commits, CI or Dependabot status, test counts, generated-artifact freshness — all must come from a command you ran THIS session. This repo has been confidently wrong on exactly these (a graph reported fresh but built from a stale commit; an alert recorded as fixed when the lockfile was half-upgraded; a handoff pointing at a file whose first line reads SUPERSEDED). Stable facts — architecture, wire contracts, documented traps — can be trusted as written; when source and doc conflict, source wins and you fix the doc in the same commit.
- Scope: change only what was asked. Fix obvious bugs in edited paths; do not add unasked features, abstractions, or cleanup crusades.
- Code, comments, commit messages, logs: English. UI strings may stay localized.
- Tone: brutally blunt — lead with the verdict, no hedging, no flattery ("great question" / "you're absolutely right" are banned). Roast bad code and time-wasting rabbit holes; speak the truth even when inconvenient.
- Auto-review/code-review subagents must use the same model class as the primary session unless the user explicitly asks for a cheaper model.
- Commits: commit at natural checkpoints and `git push` in the same checkpoint (the VM deploys via `git pull`; local-only commits block it). Small/trivial fixes can go straight to `master`; bigger/riskier work uses a feature branch + PR. Feature branches do NOT auto-deploy — the VM pulls `master`, so work goes live only after PR merge. Never merge to `master` without explicit user OK.
- **`node scripts/impact.mjs` is the inner-loop impact hint** — who depends on what you changed, plus the tests that import it, in ~0.6s. `--ref <ref>` for a branch, `--json` for machine use. Import resolution is exact (1639 specifiers, 0 unresolved; conditional Dart imports, bare same-dir specifiers, untracked files, deletions). **Reachability is NOT coverage:** 3 hops, static imports only, blind to NestJS DI, the wire contracts (`docs/contracts/wire.md`) and assets. Running the full tier suites before a commit or PR is required by project policy; nothing enforces it mechanically.
- **Never run a WHOLE-TREE formatter** (`dart format lib/`, prettier globs): this tree predates Dart 3 tall style and CI does not enforce format, so it rewrites files you never touched and buries the real diff — **measured 2026-09-13: `cd frontend && dart format --output=none lib` reports 345 files, 99 would change** (the check is non-writing; re-measure before quoting). It has already cost this repo a 70-file reformat, a `main_shell.dart` that had to stay byte-identical to master, and a 3-line change that came out +61. Formatting the individual files you edited is fine and encouraged; there is NO rule about formatting only the lines you touched (removed 2026-09-13, owner's call — unenforceable, and it pushed agents into hand-formatting).
- **`node scripts/lint-ratchet.mjs` runs ONLY in CI**, so run it yourself before pushing backend changes; it fails the build when the warning count rises above the recorded floor. `npm run knip` (backend, knip defaults since 2026-09-19: files, dependencies, exports, types, duplicates) is a hard CI gate — new unused file, dependency or export = red; `backend/knip.json` lists the one-shot `scripts/*.ts` as entries and sets `ignoreExportsUsedInFile` (a constant exported for tests but used in its own file is fine; a symbol nothing uses is not).

## 2. Architecture map

Umbra (internal codename: Fireplace) is a production E2E encrypted chat app.

**Naming: the user-facing brand is "Umbra" (since 0.1.20, PR #152); "Fireplace" lives on as the internal codename.** All code identifiers (`FireplaceApp`, `FireplaceColors`, pubspec `name: fireplace`, `package:fireplace/` imports), storage/contract names (secure-storage `FireplaceE2E`, IndexedDB `fireplace-push`/`fireplace-boot-marker`, Web Lock `fireplace-e2e-*`, Android channel `fireplace_messages`), repo name, and the domain keep the old name DELIBERATELY. Do NOT "fix" them: storage names are addresses of live user data (renaming `FireplaceE2E` = identity churn for every user), bundle/application ids are installed-app identity, and identifier renames are blame pollution for zero user value. New user-visible strings say Umbra; new internal identifiers may use either, favoring consistency with their surroundings.

```text
Flutter web/mobile client ⇄ NestJS backend (:3000) ⇄ PostgreSQL 16 (:5433 host)
                         REST + Socket.IO         self-hosted media volume
```

- Client: `AuthGate` → `AuthScreen` or `MainShell` → `ChatDetailScreen`; state is provider-driven. See `frontend/CLAUDE.md`.
- Backend: `AppModule` wires ~15 domain modules (auth, users, chat, messages, media, key-bundles, push, …) — authoritative full map in `backend/CLAUDE.md` §2; `ChatGateway` authenticates sockets and delegates to chat services.
- Media: current media storage is self-hosted under `/app/media` (`avatars/`, `msgs/`). Cloudinary URLs remain accepted only as legacy/backward-compatible media URLs.
- Landing page (`https://fireplace.ignorelist.com/welcome/`): **separate PUBLIC repo `Lentach/fireplaceWebsite`** (extracted from `landing/` 2026-07-22 with git history; owner renamed it from `fireplace-landing` the same day; local clone `C:/Users/Lentach/Desktop/fireplace-landing`). Astro static site, own `CLAUDE.md` + `deploy-landing.ps1`, deploys independently to `~/fireplace/landing-build/` on the same VM. Not part of this repo's CI/deploys.
- Dependency questions: `node scripts/impact.mjs` (§1) and `lsp references/definition` — both languages, exact. **graphify was removed 2026-09-10**: re-measured against its own rebuilt graph, Dart import edges were 1.8% precision / 4.3% recall (TS was 100% / 89.7%, but redundant with the two tools above); its `GRAPH_REPORT.md` was read in 0 of the 100 sessions since July. Do not reinstall until `Graphify-Labs/graphify#58` (Dart resolution) is closed with a real fix.

## 3. Local commands

```bash
# Terminal 1: backend + DB for local dev
docker-compose up

# Terminal 2: Flutter web
cd frontend && flutter run -d chrome
```

- Ports: backend `:3000`, DB host `:5433 -> :5432`, Flutter web random unless specified.
- Before local start on Windows if stale node processes bite: `taskkill //F //IM node.exe`.
- Phone on WiFi: `cd frontend && .\run_web_for_phone.ps1`, or `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080 --dart-define=BASE_URL=http://YOUR_PC_IP:3000`.
- Tests: `cd backend && npm test` (1139 unit tests, 64 suites; verified by `node scripts/verify-claude-backend-test-counts.mjs`). Frontend: `cd frontend && flutter analyze --no-fatal-infos && flutter test` (2215 Flutter tests, 14 skipped; verified by `node scripts/verify-claude-frontend-test-counts.mjs`). Full-stack E2E wire harness (needs `docker-compose up` first, NOT in the fast lane): `cd frontend && flutter test test_e2e` — 46 passed / 14 skipped, MEASURED locally 2026-09-18 (the 14 = the 9 pre-existing opt-ins + the 5 of the gated encryption proof). **The SQL channel needs `E2E_DB_CONTAINER`**: `e2eSql` defaults to `fireplace-db-1` (the dev stack), so a run against any other stack silently reads and WRITES the dev database while the stack under test never moves — `registration_lock_test` then fails with `existing`/`cooldown` mismatches that look like product bugs (hit 2026-09-18; `staging.ps1 harness` now exports it). `encryption_proof_test.dart` is NOT in this run: its 5 tests are gated on `--dart-define=ENCRYPTION_PROOF=true` and run on the `e2e-isolated-probes` stack, because its 2 registrations tipped the shared `/auth/register` bucket into a 429 on `f86a43de` (CI resolves the container dynamically); see `frontend/CLAUDE.md` §1 and the `e2e-wire` CI job below. Origin-wide Web Lock probe: `node scripts/verify-session-lock-probe.mjs` (also a CI job). **The §6.2 reset teardown + falsification 12 probe is OPT-IN** — `flutter test test_e2e/identity_reset_teardown_test.dart --dart-define=RESET_PROBE=true` — because it spends the shared `/auth/register` bucket; it runs in CI as its own `e2e-isolated-probes` job.
- CI: `.github/workflows/ci.yml` — five jobs: `backend` (impact self-test, jest, backend count verifier, no-account-id log checker `scripts/verify-no-user-logs.mjs`, lint ratchet, knip), `frontend` (analyze, flutter test, frontend count verifier), `session-lock` (Web Lock probe in headless Chrome), `e2e-wire` (full-stack harness against a real backend + Postgres), and `e2e-isolated-probes` (the opt-in reset + enrolled-lock probes on their own stack). `e2e-wire` is the only automated check on the §7 wire contracts; it caught two disaster-recovery bugs on its first two runs and its `continue-on-error` was removed after 5 consecutive greens, so a wire regression now **fails the CI run**.
- **CI is DETECTION, not prevention — there is no gate.** Branch protection is a paid feature and the API returns 403 on this free-plan repo (PUBLIC since 2026-08-18 — `gh repo view --json isPrivate` → false, re-verified 2026-09-05), so nothing mechanically blocks a push or a merge, and §1 still permits small fixes straight to `master`. The rule is procedural and on you: **check the run and never merge or deploy on red.** After pushing: `gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'` — **not `gh run list --branch master`**, which returned weeks-old rows twice (2026-09-08). If `e2e-wire` turns flaky, restore `continue-on-error: true` deliberately and record it — never silently disable it.

## 4. Production deploy and safety

Production: `https://fireplace.ignorelist.com`, **OVH VPS** `ubuntu@51.68.138.13` (Warszawa, key-only SSH), repo `~/fireplace`. GCP was fully decommissioned 2026-07-14 — treat any `gcloud` instruction in older docs as historical.

**Deploy is SPLIT** because the VM cannot compile Flutter web without OOM:

- Frontend, from the PC: `git pull ; .\deploy-web.ps1`
- Backend, on the VM: `cd ~/fireplace && ./deploy-backend.sh`
- Verify: `cd scripts/smoke && node post-deploy-smoke.mjs`

**➡ Everything else — script internals, staging rehearsal, backups/restore, the env-var table, branch testing, VM logs — is in `.omp/rules/production-vm-deploy.md` (`rule://production-vm-deploy`). Read it before any non-trivial prod op.**

Non-negotiable, because each one is silent or irreversible:

- **Trust `gitCommit`, never semver alone.** Flutter happily serves cached code under a bumped version. `/version.json` (frontend) and `/version` (backend) are the truth; `git log` is not.
- **After a frontend deploy the user must fully close + reopen the PWA. NEVER uninstall or clear site data** — that destroys local E2E Signal keys with no recovery.
- **Never run `docker compose down -v`, `docker volume rm`, or `prune --volumes` on prod.** `pgdata` and `media_storage` are user data.
- **Never run a bare `docker compose -f docker-compose.prod.yml up -d`** — without the exported `APP_VERSION`/`GIT_COMMIT` it silently recreates the backend as `0.0.1/unknown`.
- **Never build Flutter web on the VM**, and never use the legacy all-in-one `deploy.sh`.

## 5. Version contract

- The user-visible version is semver from `frontend/pubspec.yaml` ONLY: `0.0.x`, **never** a `+build` suffix anywhere. "Bump by +1" means the PATCH segment (`0.0.1` → `0.0.2`), not `+1` appended. Production releases bump PATCH and state the new version in the commit message; docs/session-only edits do not bump. Minor/major only on explicit ask.
- Settings footer shows `version · gitCommit · buildTime`; backend `GET /version` returns the same triple from `APP_VERSION`/`GIT_COMMIT`/`BUILD_TIME` injected by the deploy scripts.
- Android `versionCode` is internal packaging only — it is NOT the user-facing string, and `+N` never belongs in `pubspec.yaml`. `build-android.ps1` derives it as `major*1_000_000 + minor*10_000 + patch` and passes `--build-number`; Android release gates + keystore setup live in `docs/runbooks/android-release.md`.
- Env vars (incl. the `JWT_SECRET` rotation rule and the VAPID key-match footgun): see the runbook's env table.

## 6. Database and E2E safety

- Dev `docker-compose.yml`: bind-mounted backend, `NODE_ENV=development`, relaxed CORS, TypeORM auto-DDL. Prod `docker-compose.prod.yml`: `NODE_ENV=production`, restricted CORS, `synchronize` **OFF**.
- **Prod schema changes are numbered SQL files in `backend/migrations/`**, applied exactly once at boot by the migration runner; a failed migration aborts boot. Entities define the dev shape, the migration files are prod truth — full contract in `backend/CLAUDE.md` §4. Applied files are IMMUTABLE.
- **⛔ Migration `0015` is not code-reversible.** It DROPS the account-wide `UNIQUE("userId")` on `key_bundles` and `UNIQUE("userId","keyId")` on `one_time_pre_keys` in favour of the per-device ones. The pre-Phase-1 backend upserts with `ON CONFLICT ("userId")` / `("userId","keyId")`, and Postgres needs a matching unique index for that — so rolling the backend image back past `0015` without touching the schema makes EVERY key-bundle and OTP upload fail with `42P10`, breaking E2E setup for everyone until you roll forward again. If a rollback is ever unavoidable, recreate the two old constraints first (safe while every row is `deviceId = 1`). Expect the `0015` boot itself to pause while the partial index on `messages` builds under a write-blocking lock; the runner's `lock_timeout` aborts the boot rather than queueing behind a long transaction, so do not deploy while a backup or a manual `psql` session holds locks.
- Risky deploys get a staging dress rehearsal first; the canonical trigger list lives in the runbook ("Staging dress rehearsal") — do not restate it here, or the two copies drift. Skip rehearsal for UI work.
- Raw SQL must quote camelCase columns: `"deliveryStatus"`, `"createdAt"`. Casing is per entity — check, never guess.
- Backups (`./backup-db.sh`, `./setup-backup-cron.sh`, `./restore-db.sh`) are in the runbook. Dumps hold ciphertext, public keys, usernames/contact graph and password hashes — they cannot decrypt messages but are sensitive.
- **E2E invariant: the server stores Signal ciphertext and metadata, NEVER device private keys.** Device keys live in web localStorage / mobile secure storage. What actually destroys them: clearing site data, a browser-profile reset, iOS storage eviction, or uninstalling the **mobile** app. **Uninstalling the PWA generally does NOT** — it removes the shortcut, not the origin's storage, and `navigator.storage.persist()` (`main.dart`) asks the browser to exempt that origin from eviction. Deleting the account does not wipe local keys either; it only makes them useless. **Never tell a user to uninstall or clear site data as a fix** — that is the action that loses their history, and the previous wording here pointed straight at it (#105).

## 7. Shared wire contracts

**Moved to `docs/contracts/wire.md` (2026-09-10) — read it BEFORE touching any of:** `backend/src/chat/chat.gateway.ts`, DTOs under `backend/src/**/dto/`, `frontend/lib/services/socket_service.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/lib/providers/messaging_provider.dart`, any `@SubscribeMessage` or `socket.on(` site, or a message-envelope / key-bundle / device-list shape. The rule `wire-contracts` (`.omp/rules/wire-contracts.md`, mirrored in `.claude/rules/`) carries the same trigger list.

Index of what lives there: E2E envelope + `senderListInfo`; `socketReady`/`serverTime` clock and the fail-closed destruction law; `getServedMessageIds` reconciliation; delete/edit semantics (`editMessage` full re-fan); throttled-request answers (`rate_limited`); takeover alarm (§6.0), registration lock (§6.1), reset ceremony + REBIND (§6.2), `POST /auth/recover`; `ownKeyBundleStatus` fields; per-device key material, OTP identity pin, device-material guard (lxiv); provisioning ceremony; envelope fan-out; device revocation + session gates; reset roster teardown; login resolves the live primary; client accept-side gate.

## 8. Adding cross-tier features

- New WS event: backend DTO + service handler + `@SubscribeMessage` in `chat.gateway.ts`; frontend `SocketService` emit/listen + `ConnectionProvider` routing + provider/model updates.
- New REST endpoint: backend controller/service with `JwtAuthGuard` where needed; frontend `ApiService` call + provider/screen wiring.
- New DB column: backend entity + numbered migration in `backend/migrations/` + mapper payload + frontend model `fromJson`/`copyWith` + tests. Dev auto-DDL does not mean prod is done. Rehearse the migration on the staging stack first (§6).

## 9. Agent skills

**The skill set is `.claude/skills/` — see `docs/agents/skills-and-mcp.md`** for what loads where, the trigger routing, and the MCP inventory. `.omp/config.yml` mutes the machine-wide `~/.agents` tree for this repo, so the committed set is the whole set. **Cursor is no longer used:** `.cursor/rules/` was removed 2026-09-14 (its one unique file became `.omp/rules/production-vm-deploy.md`); `.cursor/session-summaries/` is unrelated to Cursor and stays — it is the handoff store the pre-commit gate enforces.

### Issue tracker

Issues live in GitHub Issues (`Lentach/Umbra`) via the `gh` CLI; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context: `CONTEXT-MAP.md` at the root (778 B, tracked) points to `backend/CONTEXT.md` and `frontend/CONTEXT.md`; system-wide ADRs would go in `docs/adr/`, context-scoped ones in `backend/docs/adr/` and `frontend/docs/adr/`. **Verified 2026-09-14: only `CONTEXT-MAP.md` exists — both `CONTEXT.md` files and all three `adr/` dirs are absent, and that absence is normal, not a gap to fix or flag.** They would only appear if we deliberately adopt that layout; the `domain-modeling` skill that used to create them is NOT vendored here (`.claude/skills/VENDORED.md` says why), so `/skill:domain-modeling` does not resolve in this repo. See `docs/agents/domain.md`.

Maintain this file by pruning. If a fact only matters while editing Flutter or NestJS code, put it in the tier file. After adding/removing backend tests, update the count in §3 so `node scripts/verify-claude-backend-test-counts.mjs` stays green.