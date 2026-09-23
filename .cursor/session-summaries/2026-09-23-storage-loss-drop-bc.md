# Owner dropped storage-loss Parts B and C; Part A's post-T hide reverted; the cold-start own-key self-alarm is fixed

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none (owner: no deploys until the programme ends)

## What was done
- **Parts B (lever (d), password-sealed identity backup) and C (reseal re-delivery) DROPPED by the owner** ("we dont really need this, leave a, drop b and c") before any commit. The 38 uncommitted files were reverted by explicit path. The final state, plus a new-account seal fix built this session (`_sealOfferedIdentity` creates the row on a 404 when this session minted it; red-first test), is in the git-ignored `.planning/metadata-privacy/wip-partB-partC-2026-09-23.zip` (`DROPPED.txt` inside).
- `b57101e9` docs: (lxxxviii), traps, LATEST and the Part A summary now describe the code (no lever (d), no reseal; every restore runs the full teardown).
- `5e931ad0` **owner's pick (ask): show the error again.** Removed `_deadSessionFailedIds` / `_awaitsRedelivery` / `_isUnreadableHere` (all 5 sites). A post-T noSession/identityReset failure renders "Nie można odczytać" instead of vanishing while the sender sees ✓✓. A1 (list preview) and A3 (divider copy) stay.
- `ca018545` pins the list side: an unread post-T `[encrypted]` row whose attempt failed previews "Nowa wiadomość" (A-F8). The list must not blank a message the thread shows.
- `917845eb` **(lxxxix) the cold-start self-alarm:** the row ending at the install's OWN key sat persisted as the red "Nowe klucze szyfrowania na Twoim koncie" and re-loaded every reload (how it got written is not reproduced). `EncryptionService.initialize` (loaded-keys path, after the load) now retracts an alarm whose instant equals `ownIdentitySince` via `_retractOwnRowAlarm`, whatever wrote it.
- Owner dropped the rest of the follow-ups: softer pre-mint notice, the "Wiadomość zaszyfrowana" claim check, the `identity_restored` check, the live re-drive.
- PR1.1 NOT started (owner: a fresh agent picks it up). A read-only seam scout was cancelled before reporting.

## Key files
- Edited: `frontend/lib/providers/messaging_provider.dart`, `providers/messaging/messaging_provider.{decrypt,events}.dart`, `frontend/lib/services/encryption_service.dart`, `frontend/test/providers/{messaging_provider_envelope_status_test,encryption_provider_identity_reset_test}.dart`, `docs/design/multi-device.md` ((lxxxviii) A2 reverted, A1 note, new (lxxxix)), `docs/agents/traps.md`, `CLAUDE.md` (counts), LATEST + `2026-09-23-storage-loss-part-a.md`.
- Local only (git-ignored): `.planning/metadata-privacy/{storage-loss-design,task_plan,HANDOFF-2026-09-23}.md` marked superseded/dropped.

## Verification
- `5e931ad0`: new (lxxxviii) rows red on `f8a81f23`'s code (rows hidden), green after; flutter 2315/14 all passed; analyze 3163 (ratchet held); harness 46/14. It has NO CI run of its own (the `ca018545` push cancelled it); `ca018545` contains it.
- `ca018545`: A-F8 row; mutant "blank post-T rows" (`since == null`) red, file restored byte-identical; flutter 2316/14. CI 7/7 on `ca018545`.
- `917845eb`: 2 rows, red first (relaunch showed the alarm); mutants: no retraction → red, no instant match → red (the foreign alarm is swallowed); flutter 2318/14; ratchet 3163; harness 46/14 (after a backend restart: the first run hit the register 429 bucket).
- **CI on `917845eb`: 6/7** — Flutter, both E2E jobs, Web Lock, CodeQL green; **Backend tests RED** on `auth.service.spec.ts` "signs the token in a LATER second", a likely REAL `recoverPassword` race (below), not caused by this frontend-only commit.
- (lxxxix)'s red test fabricates the persisted state (`recordOwnIdentityReplaced(at)`); how the real install got it is NOT reproduced, and the live proof on origin :5621 (serve the new build on port 5621, reload, expect no banner + diag `OWN_IDENTITY_REPLACED_IS_SELF {source: keys_loaded}`) was NOT run.
- NOT verified: any live browser drive of Part A or of the alarm fix; iOS; Android; prod.

## Notes for next session
- **First: fix the `recoverPassword` second-boundary bug (unasked, own commit), then re-check CI.** `auth.service.ts:116-121` waits `nextSecondMs - Date.now()` with ONE `setTimeout`, and Node timers can fire ~1 ms before `Date.now()` reaches the target. The token is then signed in the stamp's second and is dead on arrival (`JwtStrategy` rejects `iat <= passwordChangedAt`). Fix: loop until `Date.now() >= nextSecondMs`. Red test: spy `setTimeout` to fire 1 ms early on a virtual `Date.now`.
- **Then PR1.1 (the box)**: `task_plan.md` Phase 1 + `g3-surface-designs.md` Option A + `design-candidate.md` §4.1. Migration is **0022** (runner keys on filename; the dev DB still carries a `0022_contact_backup_identity.sql` stamp and possibly an `identityBlob` column from the dropped work; both are harmless). Tests on real connections + a real Postgres (int suite + a CI Postgres service; FAIL, not skip, when `CI` is set and the DB URL is missing). ONE commit.
- Still owed to the owner, plainly: without B a wiped linking-OFF account re-mints. Contacts get the red pill and are refused on send until fingerprints match, and the first message sealed to the dead session is lost (now visible, not silent).
- Traps: appended to `docs/agents/traps.md` (the timer-early `recoverPassword` token, the bash-mangled `mklink` junction). The register 429 on a back-to-back harness run is already `traps.md:104`.
