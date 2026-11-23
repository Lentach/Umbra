# Cleanup program Phase 0 + 1: baseline, #274 root cause, read-only audit, owner triage

**Date:** 2026-11-23 · **Version:** unchanged (0.2.93) · **Tiers deployed:** none

## What was done
- No code changed. Phase 0 baseline and Phase 1 audit of `master` `ff4e9146` per `docs/plans/2026-11-23-cleanup-program.md`.
- `docs/plans/2026-11-23-cleanup-audit.md` (new): findings by area and risk, top 10 risks, batches 1a..5, E-rows EC-1..10, owner answers O-1..10.
- #274 root cause posted on the issue and the issue retitled: closed-app notification paths ignore mute (`web-push-sw.js:handleBoxWakeUp`, `firebaseMessagingBackgroundHandler`); "Delete here" does not drop the mute.
- `docs/plans/metadata-privacy-decisions.md`: decisions 149 (mute while closed: web left as is, Android silent only when every chat is muted) and 150 (no identity-key prefixes in logs; 30-day pruning of old identity-change and finished reset rows, newest change row per account kept).
- `docs/plans/2026-11-23-cleanup-program.md` §6 item 9: the owner's TEST addendum.
- `docs/agents/traps.md`: 5 new lines (Tests ×3, Agent tooling ×2).
- Out of repo: gitignored `.planning/cleanup/` holds `findings.md`, `metrics.md`, `scouts/*.md` (13 reports), `raw/` logs, `drive/serve.mjs`. Docker project `cleanup274` was removed with its volumes (throwaway local stack). Mutation worktrees `fireplace-mut-{dl,fc,box,conn}` removed. `frontend/build/web` holds a bundle built for `localhost:3000`: never publish it by hand.

## Key files
- Edited: `docs/plans/2026-11-23-cleanup-program.md`, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`, `.cursor/session-summaries/LATEST.md`
- New: `docs/plans/2026-11-23-cleanup-audit.md`, this file
- Read only (load-bearing): `frontend/web/web-push-sw.js`, `frontend/lib/services/android_fcm_local_notifications.dart`, `frontend/lib/providers/messaging/messaging_provider.box.dart`, `backend/src/key-bundles/key-bundles.service.ts`, `.github/workflows/ci.yml`

## Verification
- CI: 12/12 on `49a0d64e` (last code commit, re-checked 11-23). This session's commits are docs-only.
- Baseline on `ff4e9146`: backend 898 unit / 75 int; Flutter 3402 passed, 16 skipped, 79 s wall on an idle PC; Dart analyze 2479 infos (ratchet floor 2478, known local +1); backend ESLint at floor; knip clean; coverage Flutter 82.0 %, backend unit 52.6 %.
- Mutants (throwaway worktrees, nothing merged, no test added yet; all go to batch 1a or later):
  - Device lists 22, 0 survived. MD-T1: engine test lacks the equal-version case.
  - First contact 15, 7 survived: MF-01 lapsed ask read as accept, MF-02 decline retires queue, MF-03 `goodbye` for unknown/no-route record, MF-04 `befriend` guard, MF-05 acked device re-handed, MF-06 `friendHeard` on blocked/former, MF-07 block of a pending request.
  - Box 17, 3 survived: MB-1 inbox read dedup, MB-2 receipts-off gate, MB-3 relay to paused sibling.
  - Connection 26, 19 survived: MC-02 account-switch clear, MC-03 (+a/b/c) generation guards, MC-09 retry reset, MC-W5 watchdog cancel (P1); MC-04/05/08/13/W6 (P2); MC-07/10/11/12/X1/W1 (P3); MC-W2 equivalent; MC-14 killed only by an unrelated test.
- B3 file with `--run-skipped`: both tests red (fixture rot; Signal-layer TOFU still accepts). `node scripts/verify-session-lock-probe.mjs`: `SESSION_LOCK_PASS`.
- Live drives: #274 on a release web build of `ff4e9146`, local stack, real Chrome Web Push: muted chat, page closed, card in 4.3 s. NOT verified: Android #274 (no Firebase key locally, no device attached), prod, iOS.

## Notes for next session
- Next action: Phase 2 batch 1a, each fix behind a failing test, structural and behavioural PRs apart:
  - F-003 (one helper reading mute from the contact record) and F-002 small fix (silent when every chat is muted);
  - UI-01 toast text, UI-02 download host guard, BE-01 (failing two-connection int-spec first), BE-02;
  - the 10 P1 missing tests (MF-01/02/03/06/07, MB-3, MC-02/03/09/W5); Dependabot #172.
  - Drive on Android emulator + test phone + web, then ask the owner for the one batch OK. Reproduce Android #274 on the release APK in that drive.
- Owner decisions taken: audit doc §8. Web mute stays as is (F-001 closed as accepted). `getMessages` shim goes in batch 2. Composer OK covers only UI-05/06/07. BE-05 name index: check prod for duplicates first, return to the owner if any.
- Owner-owed: none open from this session. Release B due on or after 12-08.
- Leftovers not touched: folder `Desktop/fireplace-b7`, exited Docker projects `fireplace-b7`, `fireplace-gallery`.
- Audit gaps: box and UI areas about half read, 12 screens unopened, `encryption_provider.dart` ~25 %; most RACE rows are SUSPECT until their failing test exists.
- Scouts ran as agent type `scout`, mutation runs as `task`; their model class could not be set or checked.
- Recipes: the web-push drive recipe (compose env, build defines, hand-launched Chrome on port 9333, reading cards via `reg.getNotifications()`) is in `.planning/cleanup/findings.md` under Phase 0 and `drive/serve.mjs`.
- Traps (also in `traps.md`):
  - 13 crypto tests are skipped everywhere, CI included.
  - `flutter test --platform chrome` on the Web Lock test hangs on this PC; use the probe script.
  - Connection guards are almost untested (19 of 26 mutants survived).
  - Agent final messages omit their tables; take them from `history://<Name>`.
  - A mutation agent keeps sampling; cap it and kill it.
