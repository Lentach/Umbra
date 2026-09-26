# A friend re-key now opens the "asked" window, so two friend devices that re-key each other converge (decision 49)

**Date:** 2026-09-27 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Hardened the crossing harness `frontend/test/providers/messaging_provider_box_friend_crossing_test.dart` (was uncommitted). `_Link` now keeps `BoxSession`/`BoxFriendHandoff`'s rules:
  - a re-key at most once per BOX session: a reconnect resumes the session (`connection_provider.dart` §4d), only `restart()` resets it;
  - the pass's gates: `ackedBy`, once per connect, and `handedAt` + 24 h;
  - ack and hand-back as `takeFriendHandoff` does them.
  - Refusals are read from `E2eDiagLog` (`BOX_FRIEND_HANDOFF_REFUSED`).
- Measured under fix B: each side refused the other's re-key (`would_replace`). Its answering re-key was already spent, so reconnects inside 24 h sent nothing. After that, every resend and every new session's re-key was refused again (3 sessions / 72 h). The stall was permanent.
- Owner answered O17 → (a), decision 49. `MessagingProvider.encryptForFriend`: `started = fresh || !hasSessionWith(...)`, so a re-key calls `friendSessionStarted` (review fix B is reverted). Comments were updated in `box_friends.dart` and `box_session.dart` `rekeyFriend`.
- Tests:
  - The crossing test now asserts convergence in one delivery: 0 refusals, 1 re-key each, and nothing is handed off after a reconnect or a new session.
  - The fix-B test in `messaging_provider_box_friend_test.dart` is flipped: a re-key opens the window and the replacing PreKey is read.
  - The "session this device did NOT just start" test now also writes on the held session (the 24 h resend) and asserts that no window opens.
  - New in `box_session_friends_test.dart`: the window applies to one device, lasts 10 min, and closes on answer.
- Docs: decisions log (decision 49, O17, E20c), `wire.md`, `e2e-invariants.md`, remainder plan E20c, `traps.md` (the crossing trap rewritten), and root `CLAUDE.md` Flutter count 2811 → 2813.
- Out-of-repo: local drive accounts 330 `cxjane` / 331 `cxkurt` (conv 102) remain in `fireplace-mp-db-1`. The Chrome profiles `%TEMP%/umbra-cx-*`, the befriend script `%TEMP%/umbra-crossing-befriend.cjs` and `frontend/build/web` were deleted. No services were left running.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.box.dart` (`encryptForFriend`), `frontend/lib/services/box/box_friends.dart`, `box_session.dart`, `frontend/test/providers/messaging_provider_box_friend_test.dart`, `frontend/test/services/box/box_session_friends_test.dart`, docs above.
- New: `frontend/test/providers/messaging_provider_box_friend_crossing_test.dart`.
- Read only: `box_friend_handoff.dart` (the pass's gates), `connection_provider.dart:492-508` (one BoxSession per account).

## Verification
- CI: pending on `da6a63a0` at writing (see Notes).
- Red before green: with the lib unchanged, the new crossing test failed (`converged` false) and the flipped test failed (`awaiting` empty); both pass after the change.
- Mutants on `started` (each run as a subprocess, lib hash checked after):
  - `!fresh && …` (fix B) → 4 red.
  - `fresh` only → 2 red (first contact).
  - no-session only → 2 red.
  - `true` SURVIVED the first round (a plain write on a held session would open the window). It is now killed by the resend assertion added to the "did NOT just start" test.
- `flutter test` (full): exit 0, 2813 passed, 14 skipped; `verify-claude-frontend-test-counts` OK. `flutter analyze` on the touched files: no issues. `scripts/dart-lint-ratchet.mjs`: PASS at baseline 3160.
- Live drive (NO REGRESSION only; the changed line was NOT exercised): release web on the local stack, two headless Chrome profiles on :8080. Setup was the F/G recipe: J 330 online; K 331 offline with its request queue nulled; befriended; J sent an old-path message (row in conv 102).
  - When K returned, J logged `would_replace`, then `BOX_FRIEND_REKEYED sent:true`, then `BOX_FRIEND_HANDOFF acked:true`. K logged no refusal and no re-key, and `BOX_FRIEND_HANDOFF acked:true, handedBack:true`.
  - K read J's re-key PreKey through K's OWN first-session window, which predates this change. K's ack and hand-back to J were whispers under J's session and needed no window. So J's re-key window (decision 49) was never consulted. Fix B would have converged this run too.
  - J's composer notice cleared live; "kurt/jane over the box" went both ways; conv 102 kept 1 `messages` row.
  - The two-sided crossing (both sides re-key at once, then `prekey_unasked`/`would_replace` both ways) is proven ONLY by the real-Signal harness `…_crossing_test.dart`. No UI or wire action makes both sides re-key at the same moment on demand.
- NOT verified: the crossing on a device; Android, iOS, prod (box OFF); a revoked friend device actually using the window.

## Notes for next session
- Next action: pending pass fixes 1–3 from `2026-09-26-metadata-item5-migration.md` Notes, then slice (e), queue rotation, per the remainder plan:
  - (1) ensure queues, then ONE subscribe with a retry after `retryAfter`, then the sends;
  - (2) a frame from an unacked friend device clears `handedAt[D]` and calls `friendChanged`, once per device per session;
  - (3) dedupe `BOX_FRIEND_HANDOFF_FAILED` per `user:device:stage:code` per session.
- Owner-owed: none new. Still carried: the lost `conversationsList` store write (trap), the `boxdel_v1` lost-write race, reactions not ordered by `ts`, and `getMessages`/`markConversationRead` naming box chats.
- Drive recipes: `.planning/metadata-item5/findings.md`, plus:
  - `emulate({viewport})` is needed for portrait;
  - type into the `flt-text-editing-host` input handle (element `type` drops all but the first char);
  - long-press the Privacy title to unlock the diag log, then copy it via `clipboardRead`.
- Traps: `docs/agents/traps.md` E2E / multi-device (the crossing line, rewritten).
