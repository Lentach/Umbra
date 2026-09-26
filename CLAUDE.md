---
description:
alwaysApply: true
---

# CLAUDE.md — Fireplace

**Source of truth = this root file + the two tier files + the on-demand area docs** (`docs/contracts/wire.md`, `frontend/docs/*.md`, each behind a `.omp/rules/*.md` trigger, mirrored in `.claude/rules/`). Root is cross-cutting and stays in context — read it before any Fireplace work. The tier files hold the tier-wide traps and are **not** auto-injected. Read the matching one **once, before your first change in that tier**, then keep it in context — do not re-read it on every edit:

- Changing anything under `frontend/` (Flutter/PWA/client) → read `frontend/CLAUDE.md` first.
- Changing anything under `backend/` (NestJS/Postgres/server) → read `backend/CLAUDE.md` first.
- Cross-tier or infra/deploy/docs → this root file is enough.

Keep root cross-cutting: a fact that only matters while editing Flutter or NestJS code belongs in the tier file. Rationale, history and evidence behind the rules below live in `docs/agents/reference.md`; test/CI detail in `docs/agents/testing-and-ci.md`.

## 1. Non-negotiable workflow

- Read this root file before any Fireplace app work, and the matching tier file before your first change in that tier (see the header rule). **Area docs are loaded on demand, not up front:** the wire contracts (`docs/contracts/wire.md`), E2E/storage invariants, composer/media, and passcode lock (`frontend/docs/*.md`) each have a `.omp/rules/*.md` entry naming the files that trigger them — read the doc before the first edit in such a file. When delegating, tell the subagent which of these to read — subagents do not inherit your loaded context.
- **`C:/Users/Lentach/Desktop/Fireplace` is THE working copy — but it is on `feat/passcode-lock`, NOT `master`** (`master` lives in the `fireplace-0a` worktree). The branch drifts whenever anyone pushes to master from elsewhere. Every session: `git fetch && git status -sb && git log --oneline HEAD..origin/master` FIRST; if behind, `git merge --ff-only origin/master`. Commits made here go out as `git push origin HEAD:master` then `git push origin feat/passcode-lock`. Why: `docs/agents/reference.md` "§1 Working copy".
- **PUBLIC repo** — `Lentach/Umbra` is public: treat every tracked file as world-readable. A pre-commit hook runs `gitleaks git --staged` and `scripts/verify-context-budget.mjs`; activate once per clone with `git config core.hooksPath .githooks`. Bypass only in emergencies (`--no-verify`). Write `<REDACTED>` when pasting a URL or curl; a key-NAME literal that trips a rule gets `// gitleaks:allow` on the line.
- **Session start:** read `.cursor/session-summaries/LATEST.md` (≤5 entries, ≤900 chars each), then the dated summary it links and the `docs/agents/traps.md` groups for the area you will touch. Standing warnings live in `traps.md`, one line each — never in LATEST.
- **Task end:** write `.cursor/session-summaries/YYYY-MM-DD-<slug>.md` (≤6 KB; sections `# title`, `**Date:**`, `## What was done`, `## Key files`, `## Verification`, `## Notes for next session` — the last holds owner-owed decisions, NOT-verified surfaces, and traps), append each new trap as one line to `docs/agents/traps.md`, then put a ≤900-char entry on top of LATEST and **delete the oldest**. Investigation narrative belongs in `.planning/<task>/findings.md`, not the summary. Dated summaries ARE committed. The hook enforces the caps; **never trim a fresh summary to fit — move detail to the dated file or `findings.md`.**
- For multi-step/debug/deploy-sensitive work, use persistent planning files in `.planning/<task>/` — `task_plan.md`, `findings.md`, `progress.md` live INSIDE that directory, never at the repo root. Re-read before decisions; log failed attempts. Delete `.planning/.active_plan` when the plan it names is finished, or it silently points the next session at completed work.
- Before any change: read the files you touch and trace the code paths. Code/source beats docs and old summaries.
- **Re-verify VOLATILE claims; never inherit them.** Git/branch state, what is live, versions and commits, CI or Dependabot status, test counts, generated-artifact freshness — all must come from a command you ran THIS session (incidents: reference.md). Stable facts — architecture, wire contracts, documented traps — can be trusted as written; when source and doc conflict, source wins and you fix the doc in the same commit.
- **Every code change is driven on a device before it is called done** (owner, 2026-09-24): the built app in a browser (release web against the local stack) or on an Android emulator/phone, exercising the changed path. Unit tests, CI and headless probes do not count on their own. The dated summary's Verification names what was driven; a surface no device can reach is stated as NOT verified and raised with the owner. Docs-only changes are exempt.
- Scope: change only what was asked. Fix obvious bugs in edited paths; do not add unasked features, abstractions, or cleanup crusades.
- Code, comments, commit messages, logs: English. UI strings may stay localized.
- Tone: brutally blunt — lead with the verdict, no hedging, no flattery ("great question" / "you're absolutely right" are banned). Roast bad code and time-wasting rabbit holes; speak the truth even when inconvenient.
- Auto-review/code-review subagents must use the same model class as the primary session unless the user explicitly asks for a cheaper model.
- Commits: commit at natural checkpoints and `git push` in the same checkpoint (the VM deploys via `git pull`; local-only commits block it). Small/trivial fixes can go straight to `master`; bigger/riskier work uses a feature branch + PR. Feature branches do NOT auto-deploy — the VM pulls `master`, so work goes live only after PR merge. Never merge to `master` without explicit user OK.
- **`node scripts/impact.mjs` is the inner-loop impact hint** (dependents + the tests that import them; `--ref <ref>`, `--json`). **Reachability is NOT coverage:** 3 hops, static imports only, blind to NestJS DI, the wire contracts and assets. Running the full tier suites before a commit or PR is required by project policy; nothing enforces it mechanically.
- **Never run a WHOLE-TREE formatter** (`dart format lib/`, prettier globs): CI does not enforce format and it rewrites files you never touched, burying the real diff (evidence: reference.md). Formatting the individual files you edited is fine and encouraged; there is NO rule about formatting only the lines you touched.
- **`node scripts/lint-ratchet.mjs` runs ONLY in CI**, so run it yourself before pushing backend changes; it fails the build when the warning count rises above the recorded floor. `npm run knip` (backend) is a hard CI gate — new unused file, dependency or export = red (config: reference.md "§1 knip").

## 2. Architecture map

Umbra (internal codename: Fireplace) is a production E2E encrypted chat app.

**Naming: new user-visible strings say "Umbra"; code identifiers, storage/contract names (`FireplaceE2E`, `fireplace-*`, `fireplace_messages`), repo name and domain keep "Fireplace" DELIBERATELY — do NOT "fix" them** (storage names address live user data). Full list + why: reference.md "§2 Naming".

```text
Flutter web/mobile client ⇄ NestJS backend (:3000) ⇄ PostgreSQL 16 (:5433 host)
                         REST + Socket.IO         self-hosted media volume
```

- Client: `AuthGate` → `AuthScreen` or `MainShell` → `ChatDetailScreen`; state is provider-driven. See `frontend/CLAUDE.md`.
- Backend: `AppModule` wires ~15 domain modules (auth, users, chat, messages, media, key-bundles, push, …) — authoritative full map in `backend/CLAUDE.md` §2; `ChatGateway` authenticates sockets and delegates to chat services.
- Media: current media storage is self-hosted under `/app/media` (`avatars/`, `msgs/`). Cloudinary URLs remain accepted only as legacy/backward-compatible media URLs.
- Landing page (`https://fireplace.ignorelist.com/welcome/`): **separate PUBLIC repo `Lentach/fireplaceWebsite`** (local clone `C:/Users/Lentach/Desktop/fireplace-landing`), deploys independently to `~/fireplace/landing-build/` on the same VM via its own `deploy-landing.ps1`. Not part of this repo's CI/deploys.
- Dependency questions: `node scripts/impact.mjs` (§1) and `lsp references/definition` — both languages, exact. **graphify was removed 2026-09-10**; do not reinstall until `Graphify-Labs/graphify#58` (Dart resolution) is closed with a real fix (why: reference.md).

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
- Tests: `cd backend && npm test` (1197 unit tests, 68 suites; verified by `node scripts/verify-claude-backend-test-counts.mjs`). Frontend: `cd frontend && flutter analyze --no-fatal-infos && flutter test` (2761 Flutter tests, 14 skipped; verified by `node scripts/verify-claude-frontend-test-counts.mjs`). Backend integration suites (`*.int-spec.ts`; FAIL in CI without their DB, never skip): `cd backend && BOX_IT_DATABASE_URL=postgres://postgres:postgres@localhost:5433/postgres npm run test:int`. Full-stack E2E wire harness (needs `docker-compose up` first, NOT in the fast lane): `cd frontend && flutter test test_e2e`. Counts, probes, harness setup: `docs/agents/testing-and-ci.md`.
- **The harness SQL channel needs `E2E_DB_CONTAINER`** for any stack but the dev one — otherwise `e2eSql` silently reads and WRITES the dev database (`fireplace-db-1`) and the failures look like product bugs. `staging.ps1 harness` exports it.
- **Probes that spend the shared `/auth/register` bucket stay OPT-IN** (`--dart-define=ENCRYPTION_PROOF=true`, `BOX_PROBE=true`, `RESET_PROBE=true`) and run on their own stack (CI `e2e-isolated-probes`), not in the shared `test_e2e` run. Web Lock probe: `node scripts/verify-session-lock-probe.mjs`.
- CI: `.github/workflows/ci.yml` — five jobs: `backend`, `frontend`, `session-lock`, `e2e-wire`, `e2e-isolated-probes` (steps: testing-and-ci.md). `e2e-wire` is the only automated check on the §7 wire contracts, and a wire regression **fails the CI run**. If `e2e-wire` turns flaky, restore `continue-on-error: true` deliberately and record it — never silently disable it.
- **CI is DETECTION, not prevention — there is no gate** (no branch protection on this free-plan repo, and §1 still permits small fixes straight to `master`). The rule is procedural and on you: **check the run and never merge or deploy on red.** After pushing: `gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'` — **not `gh run list --branch master`**, which returns stale rows.

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
- Android `versionCode` is internal packaging only — it is NOT the user-facing string, and `+N` never belongs in `pubspec.yaml`. `build-android.ps1` derives it and passes `--build-number`; the formula, release gates and keystore setup live in `docs/runbooks/android-release.md`.
- Env vars (incl. the `JWT_SECRET` rotation rule and the VAPID key-match footgun): see the runbook's env table.

## 6. Database and E2E safety

- Dev `docker-compose.yml`: bind-mounted backend, `NODE_ENV=development`, relaxed CORS, TypeORM auto-DDL. Prod `docker-compose.prod.yml`: `NODE_ENV=production`, restricted CORS, `synchronize` **OFF**.
- **Prod schema changes are numbered SQL files in `backend/migrations/`**, applied exactly once at boot by the migration runner; a failed migration aborts boot. Entities define the dev shape, the migration files are prod truth — full contract in `backend/CLAUDE.md` §4. Applied files are IMMUTABLE.
- **⛔ Migration `0015` is not code-reversible.** Rolling the backend image back past `0015` without touching the schema makes EVERY key-bundle and OTP upload fail with `42P10`, breaking E2E setup for everyone; if a rollback is ever unavoidable, recreate the two dropped account-wide unique constraints first. Do not deploy `0015` while a backup or a manual `psql` session holds locks. Mechanism: reference.md "§6 Migration 0015".
- Risky deploys get a staging dress rehearsal first; the canonical trigger list lives in the runbook ("Staging dress rehearsal") — do not restate it here, or the two copies drift. Skip rehearsal for UI work.
- Raw SQL must quote camelCase columns: `"deliveryStatus"`, `"createdAt"`. Casing is per entity — check, never guess.
- Backups (`./backup-db.sh`, `./setup-backup-cron.sh`, `./restore-db.sh`) are in the runbook. Dumps hold ciphertext, public keys, usernames/contact graph and password hashes — they cannot decrypt messages but are sensitive.
- **E2E invariant: the server stores Signal ciphertext and metadata, NEVER device private keys.** Device keys live in web localStorage / mobile secure storage; clearing site data, a browser-profile reset, iOS eviction or uninstalling the **mobile** app destroys them — uninstalling the PWA generally does NOT (what does and why: reference.md). **Never tell a user to uninstall or clear site data as a fix** — that is the action that loses their history (#105).

## 7. Shared wire contracts

**Moved to `docs/contracts/wire.md` (2026-09-10) — read it BEFORE touching any of:** `backend/src/chat/chat.gateway.ts`, DTOs under `backend/src/**/dto/`, `frontend/lib/services/socket_service.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/lib/providers/messaging_provider.dart`, any `@SubscribeMessage` or `socket.on(` site, or a message-envelope / key-bundle / device-list shape. The rule `wire-contracts` (`.omp/rules/wire-contracts.md`, mirrored in `.claude/rules/`) carries the same trigger list.

Index of what lives there: E2E envelope + `senderListInfo`; `socketReady`/`serverTime` clock and the fail-closed destruction law; `getServedMessageIds` reconciliation; delete/edit semantics (`editMessage` full re-fan); throttled-request answers (`rate_limited`); takeover alarm (§6.0), registration lock (§6.1), reset ceremony + REBIND (§6.2), `POST /auth/recover`; `ownKeyBundleStatus` fields; per-device key material, OTP identity pin, device-material guard (lxiv); provisioning ceremony; envelope fan-out; device revocation + session gates; reset roster teardown; login resolves the live primary; client accept-side gate.

## 8. Adding cross-tier features

- New WS event: backend DTO + service handler + `@SubscribeMessage` in `chat.gateway.ts`; frontend `SocketService` emit/listen + `ConnectionProvider` routing + provider/model updates.
- New REST endpoint: backend controller/service with `JwtAuthGuard` where needed; frontend `ApiService` call + provider/screen wiring.
- New DB column: backend entity + numbered migration in `backend/migrations/` + mapper payload + frontend model `fromJson`/`copyWith` + tests. Dev auto-DDL does not mean prod is done. Rehearse the migration on the staging stack first (§6).

## 9. Agent skills

**The skill set is `.claude/skills/` — see `docs/agents/skills-and-mcp.md`** for what loads where, the trigger routing, and the MCP inventory. `.omp/config.yml` mutes the machine-wide `~/.agents` tree for this repo, so the committed set is the whole set. **Cursor is no longer used**; `.cursor/session-summaries/` stays — it is the handoff store the pre-commit gate enforces.

### Issue tracker

Issues live in GitHub Issues (`Lentach/Umbra`) via the `gh` CLI; external PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context layout (`CONTEXT-MAP.md` → per-tier `CONTEXT.md`, `adr/` dirs): **only `CONTEXT-MAP.md` exists, and that absence is normal, not a gap to fix or flag**; `/skill:domain-modeling` is not vendored here. See `docs/agents/domain.md` and reference.md "§9".

Maintain this file by pruning. If a fact only matters while editing Flutter or NestJS code, put it in the tier file. After adding/removing backend tests, update the count in §3 so `node scripts/verify-claude-backend-test-counts.mjs` stays green.
