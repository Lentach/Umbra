# Own-message sender label and the flaky timing test fixed; 0.2.106 released

**Date:** 2026-11-25 · **Version:** 0.2.106 · **Tiers deployed:** backend, web, APK

## What was done
- Owner: "yes fix both, freeze is over" (recorded as O-17 in `docs/plans/2026-11-23-cleanup-audit.md`). Merge and release approved through a form.
- PR #311 (squash `f247beb0`):
  - Reply to your OWN message showed "Unknown" (composer preview, hardcoded English) and "Nieznany" (bubble quote). An own row has an empty `senderUsername`. New `quotedSenderLabel(l10n, {senderUsername, senderId, currentUserId})` in `reply_preview_helper.dart`: `l10n.senderYou` when the ids match, else the username, else `l10n.unknown`. `ReplyPreviewBar` and `ReplyQuoteCard` take an optional `currentUserId`.
  - Same cause, found by the review: the pinned banner put the PEER's name on your own pinned message (`screens/chat_detail/scroll.dart`). Fixed, red test first.
  - l10n key `videoSenderYou` renamed `senderYou` (one key, same text).
  - `identity-reset.service.spec.ts`: the two "COSTS the same" tests no longer assert a 15 ms wall-clock floor. `argon2.verify` is a passthrough `jest.fn`; the tests assert one call with `TIMING_SAFE_DUMMY_VERIFIER`; a new test pins that hash to `RECOVERY_ARGON2_OPTIONS`.
- Out of repo: prod `.env` `ANDROID_APK_*` → 20106 / 0.2.106 (backup `.env.bak.pre-apk-0.2.106`).
- Worktree `fireplace-7` and branch `fix/own-reply-sender` removed.

## Key files
- `frontend/lib/utils/reply_preview_helper.dart`; `frontend/lib/widgets/input/reply_preview_bar.dart`; `frontend/lib/widgets/message/reply_quote_card.dart`; `frontend/lib/screens/chat_detail/scroll.dart`.
- `frontend/test/screens/chat_detail_own_sender_label_test.dart`; `frontend/test/widgets/message/reply_quote_card_test.dart`; `frontend/test/widgets/input/reply_preview_bar_test.dart`.
- `backend/src/key-bundles/identity-reset.service.spec.ts`.

## Verification
- Counts by full runs on the PR head: backend 899 / 57 suites; Flutter 3613 / 1 skipped (local 3600 + 14 skipped). Dart ratchet 2479 against baseline 2482 (not lowered); backend lint ratchet PASS.
- Review, one reviewer, both axes: no blocker; four SHOULD items applied (wiring tests, null guard test, pinned banner fix, dummy-hash parameter test). Mutants on the timing tests (early return at either door, different hash) red.
- CI by name: PR head `af90bdfb` 15 success + `Publish the GitHub release` skipped; master `f247beb0` 13 success.
- Local drive (stack `fp7`, debug APK, emulator + Xiaomi): reply to own message → "Ty" in the composer preview and the sent quote, on both; reply to the peer's message → peer's name (emulator); receiver sees the sender's name, or "Ty" when their own message is quoted; pinned banner "Ty" on own, peer's name on the peer's, both directions.
- Release: backup `chatdb-20261125T154402Z.dump.gpg` (3 files on R2); backend + web `0.2.106 / f247beb0`, web smoke PASSED; tag `v0.2.106`; unsigned SHA256 `79280c82f33de7214a872fca1624e92560c546e32a2a9a92608796183546dbc5`; signed SHA256 `5bd3f7ed8fe05fd0d9c33b55600cf3fa3735c2ad9f42b082b4d0ae97e4654ac8` ("signed = unsigned + signature" proven by the script); the served file hashes the same; `/version` android 20106; post-deploy smoke PASSED.
- Live drive on prod, signed APK, throwaways `rel106a`/`rel106b` (deleted in-app; users 31): own reply "Ty" in preview and bubble, receiver sees the sender's name; own pinned banner "Ty", receiver sees the sender's name; after a force-stop and reopen on both devices the banner and the quotes keep those labels (banner read from the unfiltered tree).

## Notes for next session
- **Next action:** the freeze is over; ask the owner what feature work comes first.
- NOT driven: web (any of this); the fullscreen video header (renamed key only); a voice-message reply quote; iOS.
- GitHub had a partial outage during the release: `Publish the GitHub release` failed with HTTP 500 and `gh run rerun --failed` returned 500 for about 20 minutes. The re-run then passed; the release holds the three expected files. See traps.
- `git worktree prune` is blocked by the agent tool policy; `git worktree remove` left no stale entry, so nothing was needed.
- Still open, not asked: no test covers the attachment doors or the mic layer's pointer guard while recording.
- Owner-owed: UI-17 decision (old `http` media fallbacks); re-read of both privacy-policy drafts; a lawyer on the licence. Not approved: reproducible builds and pinning; `.sha256` under `/apk/` downloading instead of displaying; `security-extended` CodeQL; stale `docs/design/multi-device.md` I4/I6 and `docs/proof/e2e-encryption-proof.md`.
- Release B (avatar file deletion, TD-13) due on or after 2026-12-08.
