# Root CLAUDE.md reference — rationale, history, evidence

On-demand companion to root `CLAUDE.md`. The rules themselves stay in `CLAUDE.md` as one-liners
with a pointer here; this file holds the WHY — incident narratives, measurements, history and
configuration detail moved out on 2026-09-24 to keep the always-read file under its byte cap.
Headings are prefixed with the root section they belong to. Test/CI detail lives in
`docs/agents/testing-and-ci.md`.

## §1 Working copy and branch drift

`C:/Users/Lentach/Desktop/Fireplace` is on `feat/passcode-lock` because `master` is checked out in
the `fireplace-0a` worktree, so it cannot be checked out here — `git worktree list`. The branch is
kept AT master's tip by convention, not by git: it drifts the moment anyone pushes to master from
elsewhere (it did on 2026-09-10 while a concurrent session shipped 0.2.37/0.2.38). Hence the
every-session `git fetch && git status -sb && git log --oneline HEAD..origin/master` and the
`git merge --ff-only origin/master` when behind.

## §1 Public repo and the pre-commit hook

`Lentach/Umbra` has been PUBLIC since 2026-08-18 (`gh repo view --json isPrivate` → `false`). The
pre-commit hook's `gitleaks git --staged` is gitleaks 8.30.1 on the dev PC, with a regex fallback
elsewhere. gitleaks is not a substitute for care — hence `<REDACTED>` in pasted URLs/curls and
`// gitleaks:allow` on key-NAME literals that trip a rule.

## §1 Volatile claims — why they are never inherited

This repo has been confidently wrong on exactly the volatile categories: a graph reported fresh but
built from a stale commit; an alert recorded as fixed when the lockfile was half-upgraded; a handoff
pointing at a file whose first line reads SUPERSEDED.

## §1 scripts/impact.mjs

`node scripts/impact.mjs` reports who depends on what you changed, plus the tests that import it,
in ~0.6s. `--ref <ref>` for a branch, `--json` for machine use. Import resolution is exact (1639
specifiers, 0 unresolved; conditional Dart imports, bare same-dir specifiers, untracked files,
deletions). Reachability is NOT coverage: 3 hops, static imports only, blind to NestJS DI, the wire
contracts (`docs/contracts/wire.md`) and assets.

## §1 Whole-tree formatter — the evidence

This tree predates Dart 3 tall style and CI does not enforce format, so a whole-tree formatter
rewrites files you never touched and buries the real diff. Measured 2026-09-13:
`cd frontend && dart format --output=none lib` reports 345 files, 99 would change (the check is
non-writing; re-measure before quoting). It has already cost this repo a 70-file reformat, a
`main_shell.dart` that had to stay byte-identical to master, and a 3-line change that came out +61.
The former rule about formatting only the lines you touched was removed 2026-09-13 (owner's call —
unenforceable, and it pushed agents into hand-formatting).

## §1 knip configuration

`npm run knip` (backend) runs knip defaults since 2026-09-19: files, dependencies, exports, types,
duplicates. `backend/knip.json` lists the one-shot `scripts/*.ts` as entries and sets
`ignoreExportsUsedInFile`: a constant exported for tests but used in its own file is fine; a symbol
nothing uses is not.

## §2 Naming — Umbra vs Fireplace

The user-facing brand is "Umbra" since 0.1.20 (PR #152); "Fireplace" lives on as the internal
codename. Kept DELIBERATELY under the old name: all code identifiers (`FireplaceApp`,
`FireplaceColors`, pubspec `name: fireplace`, `package:fireplace/` imports), storage/contract names
(secure-storage `FireplaceE2E`, IndexedDB `fireplace-push`/`fireplace-boot-marker`, Web Lock
`fireplace-e2e-*`, Android channel `fireplace_messages`), the repo name, and the domain. Why:
storage names are addresses of live user data (renaming `FireplaceE2E` = identity churn for every
user), bundle/application ids are installed-app identity, and identifier renames are blame pollution
for zero user value. New internal identifiers may use either name, favoring consistency with their
surroundings.

## §2 Landing page history

The landing page was extracted from `landing/` into its own repo on 2026-07-22 with git history;
the owner renamed that repo from `fireplace-landing` to `Lentach/fireplaceWebsite` the same day
(local clone still `C:/Users/Lentach/Desktop/fireplace-landing`). It is an Astro static site with
its own `CLAUDE.md` and `deploy-landing.ps1`.

## §2 Why graphify was removed

graphify was removed 2026-09-10: re-measured against its own rebuilt graph, Dart import edges were
1.8% precision / 4.3% recall (TS was 100% / 89.7%, but redundant with `scripts/impact.mjs` and
`lsp references/definition`); its `GRAPH_REPORT.md` was read in 0 of the 100 sessions since July.

## §6 Migration 0015 — the mechanism

`0015` DROPS the account-wide `UNIQUE("userId")` on `key_bundles` and `UNIQUE("userId","keyId")`
on `one_time_pre_keys` in favour of the per-device ones. The pre-Phase-1 backend upserts with
`ON CONFLICT ("userId")` / `("userId","keyId")`, and Postgres needs a matching unique index for
that — so rolling the backend image back past `0015` without touching the schema makes EVERY
key-bundle and OTP upload fail with `42P10`, breaking E2E setup for everyone until you roll forward
again. Recreating the two old constraints before a rollback is safe while every row is
`deviceId = 1`. The `0015` boot itself pauses while the partial index on `messages` builds under a
write-blocking lock; the runner's `lock_timeout` aborts the boot rather than queueing behind a long
transaction — hence no deploy while a backup or a manual `psql` session holds locks.

## §6 What actually destroys device keys

Device keys live in web localStorage / mobile secure storage. Destroyed by: clearing site data, a
browser-profile reset, iOS storage eviction, or uninstalling the MOBILE app. Uninstalling the PWA
generally does NOT — it removes the shortcut, not the origin's storage, and
`navigator.storage.persist()` (`main.dart`) asks the browser to exempt that origin from eviction.
Deleting the account does not wipe local keys either; it only makes them useless. The earlier
wording of the root rule pointed users straight at the key-destroying action (#105).

## §9 Cursor removal and the domain-doc layout

Cursor is no longer used: `.cursor/rules/` was removed 2026-09-14 (its one unique file became
`.omp/rules/production-vm-deploy.md`). `.cursor/session-summaries/` is unrelated to Cursor and
stays.

Multi-context layout: `CONTEXT-MAP.md` at the root (778 B, tracked) points to `backend/CONTEXT.md`
and `frontend/CONTEXT.md`; system-wide ADRs would go in `docs/adr/`, context-scoped ones in
`backend/docs/adr/` and `frontend/docs/adr/`. Verified 2026-09-14: only `CONTEXT-MAP.md` exists —
both `CONTEXT.md` files and all three `adr/` dirs are absent. They would only appear if we
deliberately adopt that layout; the `domain-modeling` skill that used to create them is NOT vendored
here (`.claude/skills/VENDORED.md` says why), so `/skill:domain-modeling` does not resolve.
