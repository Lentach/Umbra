# A reset started from the link gate now completes (#207)

**Date:** 2026-11-02 · **Version:** unchanged (0.2.72) · **Tiers deployed:** none

## What was done
- Cause (#207): the server spends a completed §6.2 ceremony only on an upload of a DIFFERENT identity, and no gate state made one.
  - Keyless install: the (lxxi)/(lxxiii) guard refused to mint while the lock was armed — it had no "completed ceremony" case.
  - (lxiv) stale-material install: `_initializeE2EInner` returned at the mismatch gate before any publish.
  - Lock-refused install: re-sent its identity only on the next connect.
  - `identityResetCompleted` was read only by the refresh timer. So "Rozpocznij reset" ran its delay and then nothing happened.
- `encryption_service.dart`: `ServerIdentityGuard.resetCompleted`; `exists && linkingEnabled && resetCompleted` → `_mintForCompletedReset` (Web Lock `fireplace-e2e-reset-mint-<uid>`, store re-read under it: a second tab loads the first tab's identity). Residue discard + mint split into `_discardResidueAndMint`. New `disposeMismatchedMaterialForReset` (same lock; re-confirms the stamp; PROVEN wipe or nothing; content store untouched).
- `encryption_provider.dart`: `onOwnKeyBundleStatus` passes `resetCompleted`; `_hydrateIdentityResetState` 'completed' → `_maybeSpendCompletedReset` (keyless/mismatch gate → `_spendCompletedResetOnGate` re-runs init; lock-refused + initialized → re-sends the bundle at once).
- Docs: `frontend/docs/e2e-invariants.md` new bullet; `CLAUDE.md` 3307 Flutter tests; stale comment in `initialize` ("no bundle" meant a completed reset) fixed.
- Issue #207 filed earlier this session, fix commented. Earlier the same day: #205 review follow-up `99445dfc` (see `2026-11-02-step4-live-and-gated-box.md`).
- Out-of-repo: none left running (dev stack stopped, Chrome killed, `%TEMP%/w207` worktree removed, package-lock restored). Dev DB: w205q386 (282) now on primary device 7, devices 1/2/5 revoked.

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/encryption_provider.dart`, `frontend/docs/e2e-invariants.md`, `CLAUDE.md`, `docs/agents/traps.md`.
- New: `frontend/test/providers/identity_reset_spend_test.dart` (7 tests).
- Read only (load-bearing): `backend/src/key-bundles/identity-reset.service.ts` (`getStatusForUser` reports `completed` only while unspent and < 24 h), `chat-key-exchange.service.ts` `handleCheckOwnKeyBundle`, `connection_provider.dart` `_adoptReboundSession`, `docs/design/multi-device.md` (lxxii)/(lxxiii).

## Verification
- CI: green 6/6 on `4212d169` (Analyze, Backend tests, Flutter analyze and tests, E2E wire harness, E2E isolated probes, E2E session Web Lock probe).
- Red first: the new test file went 3 red / 2 green before the fix (keyless completed, completion-while-gated, mismatch completed).
- Flutter full suite 3307 / 14 skipped, EXIT 0; `verify-claude-frontend-test-counts` OK; Dart lint ratchet 3131 = baseline; `test/providers test/services` 2216 passed.
- Mutants (all killed): M1 no spend trigger in hydrate (3 red), M2 no lock-refused re-send (1 red), M3 no store re-read under the lock (sibling-tab test red), M4 guard ignores `resetCompleted` (4 red). Untested by a mutant: the stamp re-check inside `disposeMismatchedMaterialForReset`.
- Live drive, dev web build of the fix (`%TEMP%/w207build.ps1`), frozen+silent+box backend, NO scripted spend:
  - Keyless: new origin :8310, password login w205q386 → keyless gate → "Rozpocznij reset" → "Nie mam go" → deadline aged by SQL → real sweep `completed` at 47 s → consumed at 53 s. Device 5 primary, JWT deviceId 5, 20 OTPs, `RESET_REENROLL_PROMOTED`, shell shown.
  - Stale material: old primary origin :8306 (logged out `refresh_invalid_after_access_401`) → password login → "Klucze tutaj są nieaktualne" gate → reset → completed 31 s, consumed 60 s. `RESET_STALE_MATERIAL_DISPOSED`, `IDENTITY_MINTED reason identity-reset-completed`, device 7 primary, identity changed; the :8310 tab was signed out "To urządzenie usunięto z konta".
- NOT verified: Android (the lock is a pass-through there; one context), iOS, prod, two gated tabs at once (unit-tested only), a message exchange after the recovery.

## Notes for next session
- Next action: ask the owner for ONE deploy OK covering #205 + #207 (CI is green on `4212d169`; backend first: backup, `deploy-backend.sh`; then `deploy-web.ps1` + smoke; then a new APK with a version bump); close #205 and #207 after.
- Owner-owed: that deploy OK; whether to run a read-only prod query for `identity_reset_requests` rows `completed` and unspent (anyone stuck by #207 now); the step-4 both-ways message; `backup.pass` off the VM.
- Residuals of #207:
  - two DIFFERENT gated installs of one account both spend; the first upload wins, the other is signed out by the teardown (same as today's lock-refused path);
  - between the mint and the rebind the box may start on the pre-reset device id for about a second.
- Open: #206 (offline-revoked device reads its queues first), #204, step 5 after a few days of step 4.
- Recipe: `%TEMP%/w207build.ps1` (HEAD + copied files → release web build in `%TEMP%/w207`), `serve-multi.mjs "<dir>=8306,8310"` (one arg per dir, comma ports), `G.tokLogin(name, 'q')` (accts key, not username), age `identity_reset_requests."deadlineAt"` and let the sweep complete it.
- Traps: see `docs/agents/traps.md` E2E (reset is spent only by a different identity) and Agent tooling (truncated read lines).
