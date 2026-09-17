# The multi-device + codelock program was already finished; what was left was litter and two stale tracking docs

**Date:** 2026-09-17 · **Version:** unchanged (0.2.48) · **Tiers deployed:** none

## What was done
- Reconstructed repo state WITHOUT resuming the prior heavy sessions (owner: "blackholes of token drain"). Verdict: `feat/passcode-lock` is byte-identical to `origin/master` (`8dca7f79`), so multi-device + passcode lock ARE master; nothing was left half-built.
- Falsified a fresh audit's own claim that D1 (P0) / D2 (P1) are open: both are FIXED under amendment (xlvii) — `encryption_service.dart:2238` reads `getAccountIdentity(peerId)`, `acknowledgePeerIdentity` (`:407+`) clears the warning only when the anchor advanced (CAS + served-key door), `peer_reset_recovery_test.dart` = 5 tests / 0 skips. `.planning/multi-device/progress.md:152` said so all along.
- Killed the branch/worktree litter: **25 → 5 local branches**, **21 → 6 remote branches**, **7 → 3 worktrees**. Every deletion evidence-backed (see Verification), SHAs recorded below for recovery.
- Deleted `docs/ISSUE-BOARD.md` — 2 months stale, named 6 branches that no longer exist, marked shipped work (message editing) IN-PROGRESS, and its own header said it should never have been committed to a public repo. Tracker is GitHub Issues (`docs/agents/issue-tracker.md`); 0 open issues, 0 open PRs.
- Salvaged the board's one live item into `traps.md` § Owner-owed: the emoji-reaction **E2E-vs-metadata decision is the last thing holding D10 open** (plaintext reactions on fully-E2E rows).
- Added a `⛔ HISTORICAL LOG` banner to `.planning/multi-device/progress.md` naming the exact line pair (`:152` verdict vs `:312`/`:382` reports) that misled the audit, so the next reader cannot repeat it.
- Declined the owner's planned next feature (**sealed sender**) with the repo's own evidence: rejected by `docs/audit/2026-07-07-metadata-privacy-audit.md:340-346` and re-rejected by `2026-09-14-e2e-gap-audit.md:178-183`. Owner accepted; the next branch is items 1–4 below instead.

## Key files
- Edited: `docs/agents/traps.md` (+1 Owner-owed line), `docs/research/2026-09-mcp-servers.md:198` (dangling board reference), `.cursor/session-summaries/LATEST.md`, `.planning/multi-device/progress.md` (untracked, banner).
- Deleted: `docs/ISSUE-BOARD.md`.
- New: this file.
- Read only (load-bearing): both files in `docs/audit/` (untracked — never copy their specifics into a tracked file), `docs/agents/traps.md`, `rule://production-vm-deploy`, `CLAUDE.md` §2–§9.

## Verification
- **Tree health at `8dca7f79`, run this session:** `backend && npm test` 62/62 suites, **1127/1127**, 26 s · `npx tsc --noEmit` exit 0, zero diagnostics · `node scripts/lint-ratchet.mjs` PASS at the 898 floor (warnings 341 exact; prettier 151 vs 153 = the documented CRLF delta) · `flutter analyze` 0 errors / 0 warnings / 3168 infos · `flutter test` **2144 passed, 14 skipped, 0 failed** · both count verifiers OK. **Zero drift** from `CLAUDE.md` §3.
- **CI:** 6/6 `success` on the last code-bearing commit `1f05e3e6` (tip is docs-only → 1 row under `paths-ignore`).
- **Prod, re-measured today:** `/version` and `/version.json` both `0.2.48 / eefc44b0`; `/health` `{"status":"ok","db":"ok"}`.
- **Deletion evidence (content, not guesswork):** `test/video-nits-0.2.3` (+27, `c8f662eb`) — master carries the same commits as `81d2dcb2`/`383ceb1d`; `fix/frozen-page-reload` (+1, `d5536480`) — master has `frozen_page_reload_decision.dart` AND its test; `fix/pwa-notification-regression` (+3, `b306c995`) — master has `messaging_read_receipt_visibility_test.dart`; `fix/attachment-popover-anchor` (+2, `487be703`) — master has no `attachment_picker_web.dart` (owner reverted that route); `feat/cosmic-theme` (+1, `1745a50e`) — only a `starfield_preview.dart` density knob. 11 further remote deletions were all `ahead=0`.
- **Stashes inspected, NOT dropped** (owner asked for a report): all four are from 2026-05-24/25 on the deleted branch `feature/composer-trailing-send-voice`. Unmergeable — `chat_input_bar.dart` has drifted 1000+ lines, l10n ~3000, their two test files were renamed on master (`chat_input_bar_send_test.dart`, `recording_controller_test.dart`), and their `CLAUDE.md` copy is 446 lines behind. The only never-shipped idea in them is slide-to-lock voice recording.
- **NOT verified:** `frontend/test_e2e` (46/9) and the session-lock probe — both need `docker-compose up`; CI ran them green on `1f05e3e6`. No deploy, no prod mutation, no device work this session.

## Notes for next session
- **Owner takes items 1–4 on a future branch** (agreed this session): (1) web-origin security headers — prod still returns ONLY `HTTP/1.1 200`, re-measured today; (2) plaintext reactions / D10; (3) the `_reenrollAfterReset` in-flight latch; (4) rebase+CI+merge `feat/unreadable-reason` (+2, 10 behind master, CI never ran on its tip) and `proof/e2e-encryption` (+6; merging shifts the test_e2e count, so `CLAUDE.md` §3 must move in the same commit). Both branches and their worktree (`fireplace-e2eproof`) were deliberately LEFT INTACT.
- Sealed sender is closed as a direction. If metadata work is wanted, it is RP1 (ephemeral-by-default) + RP2 (padding buckets) from the 2026-07-07 roadmap — and QW0/QW1/QW2 are already largely done (docker log caps `10m×3`, the L1 send log + L2 roster dump are gone, FCM `senderName` and the web-push topic are stripped; only `conversationId` remains).
- Owner-owed still open: signing-cert choice (PEPK vs sideload-forever) before the `0.2.48` APK is handed out; the `0.2.48` APK was never smoked (phone is on `0.2.47`); recovery-phrase replace A/B/C/D; iOS everywhere.
- Traps (appended to `docs/agents/traps.md`): the emoji-reaction decision blocking D10; a historical planning log's newest-first sections read as current state; `git worktree remove` fails on a backslash `gitdir` path.
