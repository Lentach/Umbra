# Testing and CI reference

On-demand detail for root `CLAUDE.md` §3 (Tests and CI bullets point here). The parsed test-count
sentences (`N unit tests, N suites` / `N Flutter tests, N skipped`) stay in root `CLAUDE.md` — the
`scripts/verify-claude-*-test-counts.mjs` verifiers read them there, never here. Every count below is
a VOLATILE claim: re-measure before quoting.

## Backend integration suites

`*.int-spec.ts`, each on a fresh Postgres DB migrated 0001…latest; they FAIL in CI without their DB,
never skip. Run: `cd backend && BOX_IT_DATABASE_URL=postgres://postgres:postgres@localhost:5433/postgres npm run test:int`
— 26 tests (box 23 over real sockets, first-contact device SQL 3).

## Full-stack E2E wire harness (`test_e2e`)

Needs `docker-compose up` first; NOT in the fast lane (`test_e2e` is a sibling of `test/`).
`cd frontend && flutter test test_e2e` — 47 passed / 16 skipped, MEASURED locally 2026-09-24 (the
16 = the 9 pre-existing opt-ins + the 5 of the gated encryption proof + the 2 of the gated box round
trip).

### The SQL channel and `E2E_DB_CONTAINER`

`e2eSql` defaults to `fireplace-db-1` (the dev stack), so a run against any other stack without
`E2E_DB_CONTAINER` silently reads and WRITES the dev database while the stack under test never
moves — `registration_lock_test` then fails with `existing`/`cooldown` mismatches that look like
product bugs (hit 2026-09-18; `staging.ps1 harness` now exports it; CI resolves the container
dynamically).

### Gated probes (not in the shared run)

These spend the shared `/auth/register` bucket, so they are opt-in and run on the
`e2e-isolated-probes` stack (CI job of the same name):

- `encryption_proof_test.dart` — 5 tests, gated on `--dart-define=ENCRYPTION_PROOF=true`. Its 2
  registrations tipped the shared `/auth/register` bucket into a 429 on `f86a43de`. See
  `frontend/CLAUDE.md` §1.
- `box_roundtrip_test.dart` (metadata-privacy PR1.3) — gated on `--dart-define=BOX_PROBE=true`.
- The §6.2 reset teardown + falsification 12 probe —
  `flutter test test_e2e/identity_reset_teardown_test.dart --dart-define=RESET_PROBE=true`.
- The enrolled-lock probe also runs in that job.

Origin-wide Web Lock probe: `node scripts/verify-session-lock-probe.mjs` (also the `session-lock`
CI job).

## CI jobs (`.github/workflows/ci.yml`)

- `backend` — impact self-test, jest, backend count verifier, box import-graph checker
  `scripts/verify-box-imports.mjs` (I1), box integration suite against a Postgres service
  container, no-account-id log checker `scripts/verify-no-user-logs.mjs`, lint ratchet, knip.
- `frontend` — analyze, flutter test, frontend count verifier.
- `session-lock` — Web Lock probe in headless Chrome.
- `e2e-wire` — full-stack harness against a real backend + Postgres.
- `e2e-isolated-probes` — the opt-in reset, enrolled-lock, encryption-proof and box round-trip
  probes on their own stack.

### `e2e-wire` history

`e2e-wire` is the only automated check on the root §7 wire contracts. It caught two
disaster-recovery bugs on its first two runs; its `continue-on-error` was removed after 5
consecutive greens, so a wire regression now fails the CI run.

## Why CI is detection, not a gate

Branch protection is a paid feature and the API returns 403 on this free-plan repo (PUBLIC since
2026-08-18 — `gh repo view --json isPrivate` → false, re-verified 2026-09-05), so nothing
mechanically blocks a push or a merge. `gh run list --branch master` returned weeks-old rows twice
(2026-09-08) — hence the commit-scoped `gh api .../commits/master/check-runs` query.
