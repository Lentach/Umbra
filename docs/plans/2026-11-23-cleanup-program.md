# Cleanup program: audit, then make Umbra clean before "Signal grade" (agent brief, 2026-11-23)

Status: NOT STARTED. Owner decisions taken 2026-11-23 are in §2; anything not listed there is OWNER-class and gets asked.

This file is the PROMPT for the lead agent that runs the program. Read it whole, then follow it.

---

## 1. Your role

You are the lead engineer of a FEATURE FREEZE. No new features ship until the owner ends this program. Your job:

1. Audit the whole app.
2. Get the owner's decisions on what you found.
3. Clean it up in small, proven, reversible steps: dead code, duplicates, giant files, races, bugs, drifted docs.

Umbra is a private E2E messenger (Flutter client for Android and web/PWA, NestJS backend, Postgres, the anonymous "box" relay). A cleanup that silently breaks decryption or loses a message is worse than no cleanup. When in doubt, do less and prove more.

Start with the `umbra-session-start` skill. End every session with `umbra-session-end`. Read `AGENTS.md`, root `CLAUDE.md`, the tier `CLAUDE.md` of whatever you touch, `docs/agents/traps.md`, `frontend/docs/e2e-invariants.md` and `docs/plans/metadata-privacy-decisions.md`. They bind you.

## 2. Owner decisions (2026-11-23)

- **The PWA stays, frozen.** All of the owner's real users are on the PWA; only 2 testers use the Android app.
  - The web build comes from the SAME Flutter code, so shared fixes reach it automatically. Every release still runs `deploy-web.ps1` and is driven on the web too.
  - Frozen means no web-only polish or redesign. Real bugs and races in web paths ARE fixed.
  - Tag web-only code in the audit (`[web-only: retire with §7]`, `docs/plans/2026-11-16-security-hardening.md` §7) so it can be cut later. Do not delete it now.
  - Never change the wire protocol in a way the web build cannot speak.
- **Encryption layer: audit only.** `frontend/lib/services/encryption_service.dart`, `providers/encryption_provider.dart`, `services/encryption/**` and the vendored `third_party/libsignal_protocol_dart` get findings, dead-code removal (proven unused) and race fixes with repro tests.
  - No redesign, no splitting into new modules. The redesign belongs to B6 (official libsignal), which is NOT part of this program.
- **Bug fixes are allowed** in this program, each with a failing test or a device repro first.
- **Releases:** a few batched "cleanup releases", not one per PR.
- **Approvals:** the owner gives ONE OK per batch. You must have proven each PR of the batch works on a device (Android emulator AND the test phone, AND the web build for shared or web paths) before you ask.
- **Issue #274 is the first investigation** (§5, Phase 0).

## 3. Hard rules (break one = stop and ask)

- **Two kinds of change, never mixed:** a STRUCTURAL change (move, rename, split, delete proven-dead code) changes no behaviour. A BEHAVIOURAL change fixes a bug or race. Never in one commit, and preferably not in one PR.
- **Structural proof:**
  - A move, rename or split: the same suite is green before and after, with the same test count; no test edits beyond imports.
  - A deletion of proven-dead code: the count drops by exactly the tests that covered the removed symbols, listed by name in the commit; every other test stays green and unchanged.
- **"Dead" needs evidence:**
  - a tool flag (knip, `dart analyze` unused-element hints, a coverage hole);
  - AND no reference found by LSP find-references;
  - AND no dynamic use: wire event names, ARB keys, platform channels, JS interop, service worker messages, persisted storage keys, migrations.
  - Persisted keys and wire names are NEVER dead while an old client or old stored data may hold them.
- **Races:** first write a test that FAILS on the race (fake clock, a controlled `Completer`, interleaved futures, or an integration test on real Postgres). Then fix. Then show the test green. No fix by inspection alone.
- **Never touch:** migrations already applied; `BOX_ENABLED`; the PEPK keystore; prod data except through the runbooks. Never run `git revert 0cbf17b`.
  - Composer and attachment-picker changes need a green repro AND the owner's explicit OK (`frontend/docs/composer-media.md`).
- **Privacy:** metadata-privacy decisions stand. No new log of ids, no new server-side field, no new third-party call without an OWNER decision.
- **Repo workflow** (root `CLAUDE.md`): worktree `../fireplace-<slug>` per PR, explicit-path staging, version bump inside the release PR, CI via `gh api …/check-runs` only. Code wins over docs: fix the doc in the same commit.
- **Test pruning:** delete wiring/echo tests only when the behaviour they guard is covered elsewhere, and name that test in the commit. Update the `CLAUDE.md` §3 counts.
- **Lint ratchets never rise.** Lower them when you pay debt (`--update`).

## 4. How to work

- **Plan file:** `.planning/cleanup/` is your memory across sessions:
  - `findings.md`: every finding, one row each;
  - `batches.md`: what is in each batch and its proof;
  - `metrics.md`: before/after sizes, counts, lint.
- **Model class:** scouts and reviewers (the `code-review` subagents) run on the same model class as you, the lead; never a cheaper one for audit or review.
- **Delegate the audit, never the decisions.** Use read-only `scout` agents, one per area (§6), in parallel. Each returns findings in the §5 format with file:symbol evidence.
  - Execution stays with you, or with one task agent per PR on disjoint files.
  - Subagents start blank in the main checkout: give them the ABSOLUTE worktree path, the traps for their area, and only their slice.
- **Review:** before asking for a batch OK, run the `code-review` skill (two axes: standards + spec = this file and the findings) on the batch.
- **Device drives:** debug builds against a local stack for every PR. A release build against prod only for the batch release (runbook `.omp/rules/production-vm-deploy.md`). The test phone, its PINs and the emulator rules are in `docs/agents/traps.md` and the session summaries.

## 5. Phases

### Phase 0 — Baseline and #274 (no refactor)
- Record in `metrics.md`: lines per file (top 30 per tier), test counts, lint counts (Dart ratchet, backend ESLint), knip output, `dart analyze` unused hints, and coverage per directory (`dart-test-coverage` skill; backend `npm run test:cov`).
- Investigate issue #274, mute vs notifications. The owner saw the mute icon still shown while a notification from that muted user arrived.
  - Find which notification path ignores mute: web push service worker card, page `local-card`, native FCM wake-up / `BoxHiddenNotifier`. Find whether "Delete here" drops mute state.
  - Repro on the PWA first (that is where the users are), then Android. File the root cause on the issue.
  - The fix ships in the first cleanup batch.

### Phase 1 — Audit (READ-ONLY, no edits)
Each finding is one row: `id | area | kind | file:symbol | evidence | risk (P0-P3) | proposed fix | structural/behavioural | web-only?`.

Kinds:
- `RACE`: check-then-act across an `await`; shared mutable state written from two async paths; a timer or stream callback after dispose; a reconnect overlapping an in-flight operation; Postgres paths outside the lock order in the `box.service.ts` header; in-memory server maps.
- `DEAD`: unused code, flags, fallbacks for clients nobody runs any more, and comments describing removed paths.
- `DUP`: the same logic twice.
- `GIANT`: a file over ~800 lines or a class with several reasons to change. Propose a split with named seams (`codebase-design` skill).
- `BUG`: behaviour against `wire.md`, `e2e-invariants.md` or a decision.
- `DRIFT`: docs saying something the code does not do.
- `TEST`: tests that pin wording or wiring, or duplicate coverage.

Then write `docs/plans/2026-11-xx-cleanup-audit.md`: a summary table by area and risk, the top 10 risks in plain language, and the proposed batches.

**STOP: owner triage.** Ask with short `ask` forms (preselected recommendation, plain words, batched by area). Only OWNER-class items go to the owner; engineering calls get logged as E-rows.

### Phase 2 — Execution, in this order, as batches
1. P0/P1 bugs and races (each with its failing test), starting with the #274 fix.
2. Dead code and dead fallbacks (structural).
3. Duplicates (structural).
4. Giant-file splits outside the encryption layer (structural, one file per PR): `messaging_provider.box.dart`, `connection_provider.dart`, `chat_input_bar.dart` (composer rule!), `contact_network_view.dart`, `link_ceremony_controller.dart`, `box_session.dart`, backend `chat-key-exchange.service.ts`. Re-measure before you start; the list moves.
5. Test pruning and doc drift.

Each batch ends with a cleanup release: bump, merge, CI, backup with offsite, deploy, release APK drive on emulator + phone, web drive, smoke, then `umbra-session-end`.

### Phase 3 — Signal-grade readiness report
Not a refactor: a document for the owner, `docs/plans/2026-1x-signal-grade-gap.md`. What still separates Umbra from Signal-grade:
- B6 (official libsignal through FFI, PQXDH), and how that interacts with a web client that cannot use FFI;
- the remaining hardening items;
- the threat model and an invariants list;
- reproducible builds;
- external audit readiness.

## 6. Audit areas (one scout each)

1. Encryption and sessions: `encryption_service.dart`, `encryption_provider.dart`, `services/encryption/**`, vendored libsignal patches. Audit only.
2. Box send/receive: `providers/messaging/*box*`, `services/box/**`, the inbox journal, the outbox, device pause, receipts, relay, sync.
3. Connection lifecycle: `connection_provider.dart`, `socket_service`, reconnect, `socketReady`, background/resume, timers.
4. Contacts, first contact, device lists, device linking and recovery: `first_contact`, `contacts/**`, `device_list/**`, `device_link/**`, `auth_provider.dart`.
5. UI and composer: `chat_detail_screen`, `chat_input_bar*`, media/voice/video, notifications and mute (#274).
6. Web-only: `web/web-push-sw.js`, IndexedDB, web key wrapping, multi-tab. Tag `[web-only]`.
7. Backend: `chat/**`, `key-bundles/**`, `box/**`, `auth/**`, crons, gateway maps, migrations vs entities.
8. Tests and docs: duplicate or wiring tests, `CLAUDE.md`/`wire.md`/runtime-reference drift.
9. Tests, as their own area (owner addendum, 2026-11-23; results go to `findings.md` with kind `TEST`):
   1. **Skips.** List all 16 from the runner's output (`flutter test --reporter json`, entries with `skipped: true`), never from a grep. Then:
      - `session_cross_context_lock_web_test.dart` (`skip: kIsWeb`, a platform skip) guards the PWA's Web Lock: NEVER delete it. Run it with `flutter test --platform chrome` and check whether the CI probe job (`.github/workflows/ci.yml`, `session-lock`) fully covers it.
      - `encryption_b3_impersonation_test.dart` (`_skip = 'B3 red test…'`): B3 shipped in 0.2.91, so the skip is stale. Unskip first; every test still red becomes a finding (E143g, the decision-37 re-key gate, is not built).
      - Every other skip: fix it, or delete it with a written reason.
   2. **Tests of removed features** (65 files mention legacy / old path / pre-box): keep the ones guarding old data still held by installs or the server; delete the ones testing code that no longer exists.
   3. **Wording, wiring and duplicate tests:** list each with the test that already covers the same behaviour.
   4. **Mutation sampling** on the risky areas (box send/receive, first contact, device lists, connection lifecycle): record survivors by id. A survivor is a missing test (add it) or dead code (delete it).
   5. Record the 10 slowest test files and the CI time, before and after.
   - Pruning follows §3: a deleted test names the test that covers its behaviour, and the `CLAUDE.md` §3 counts are updated.

## 7. Obligations that run during the freeze

- **Prod stays watched.** The healthchecks.io check "Umbra box full" emails the owner when the box passes 50 % or the backend stops checking in. If it fires, follow `.omp/rules/production-vm-deploy.md` "Box flood" before any cleanup work.
- **Release B (avatar file deletion, `docs/plans/2026-11-08-e2e-profile-photos.md` "Release B") is due on or after 2026-12-08.** It is already-decided work, not a new feature: ship it as its own batch or inside a cleanup release, with the owner's OK.
- **Security fixes are always allowed.** Open Dependabot alert (2026-11-23): one HIGH, `@azure/msal-node` in `scripts/smoke/package-lock.json` (dev tooling, not shipped). Fold it into the first batch.
- **Parked, not in this program:** the new app name and domain move, the Play items (decision 146), the Play Console account, O7/O6 (plan D2), E143g. Do not start them; list them in the Phase 3 report.
- **Leftovers to clean when possible:** the folder `C:/Users/olek2/Desktop/fireplace-b7` (locked `frontend/`, delete after a reboot), and the exited Docker projects `fireplace-b7` and `fireplace-gallery`.

## 8. Done means

- Every P0/P1 finding fixed or explicitly accepted by the owner. No file outside the encryption layer over ~1 000 lines without a recorded reason. Knip and the Dart unused hints are clean. Ratchets are lowered, not raised.
- Before/after metrics in `metrics.md`; every batch released and driven on Android and web; the Signal-grade gap report delivered.
- The owner says the freeze is over. You do not decide that.
