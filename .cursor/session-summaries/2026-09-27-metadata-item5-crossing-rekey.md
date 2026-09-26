# Friend crossing re-keys now converge AND stay readable: decision 49's window plus a vendored libsignal fix (shallow-copy trial decrypt)

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
- Post-convergence traffic exposed a second bug. With decision 49 alone, the pair swapped queues, but the FIRST message after that failed with `No valid sessions` (4× `Bad Mac`). Root cause (proven, see Verification): libsignal 0.8.2 `SessionState.fromSessionState` shares the protobuf, so `SessionCipher._decrypt`'s failed try on the current state advances it before an archived state matches. After a crossing, each side reads the other's ack from an archived state.
- Fix: `libsignal_protocol_dart` is vendored at `frontend/third_party/libsignal_protocol_dart` (`lib/`, LICENSE GPL-3, README; version `0.8.2+umbra.1`) through `pubspec.yaml` `dependency_overrides`. It carries ONE `UMBRA PATCH`: `fromSessionState` copies via `fromBuffer(writeToBuffer())`. `analysis_options.yaml` excludes `third_party/**`. The (unused) `frontend/Dockerfile` copies `third_party` before `pub get`. 0.8.2 is the latest release. The crossing test now also sends 3 messages each way after convergence.
- Docs: decisions log (decision 49, O17, E20c, E49a), `wire.md`, `e2e-invariants.md` (the vendoring invariant), remainder plan E20c, `traps.md` (the crossing trap, and the libsignal trap marked FIXED), and root `CLAUDE.md` Flutter count 2811 → 2813.
- Out-of-repo: local drive accounts 330 `cxjane` / 331 `cxkurt` (conv 102) and 332 `cxlena` / 333 `cxmarc` (conv 103) remain in `fireplace-mp-db-1`. The Chrome profiles `%TEMP%/umbra-cx-*`, the befriend script `%TEMP%/umbra-crossing-befriend.cjs` and `frontend/build/web` were deleted. No services were left running.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.box.dart` (`encryptForFriend`), `frontend/lib/services/box/box_friends.dart`, `box_session.dart`, `frontend/test/providers/messaging_provider_box_friend_test.dart`, `frontend/test/services/box/box_session_friends_test.dart`, docs above.
- New: `frontend/test/providers/messaging_provider_box_friend_crossing_test.dart`, `frontend/third_party/libsignal_protocol_dart/` (vendored 0.8.2 + one patch in `lib/src/state/session_state.dart`).
- Edited (wiring): `frontend/pubspec.yaml` (+lock), `frontend/analysis_options.yaml`, `frontend/Dockerfile`.
- Read only: `box_friend_handoff.dart` (the pass's gates), `connection_provider.dart:492-508` (one BoxSession per account).

## Verification
- CI: 7/7 green on `57066bc5` (the libsignal fix, with decision 49). Decision 49 alone was 7/7 on `5b560057`.
- Red before green: with the lib unchanged, the new crossing test failed (`converged` false) and the flipped test failed (`awaiting` empty); both pass after the change.
- Mutants on `started` (each run as a subprocess, lib hash checked after):
  - `!fresh && …` (fix B) → 4 red.
  - `fresh` only → 2 red (first contact).
  - no-session only → 2 red.
  - `true` SURVIVED the first round (a plain write on a held session would open the window). It is now killed by the resend assertion added to the "did NOT just start" test.
- libsignal cause, proven: with the round trips added and upstream 0.8.2, the first A→B message failed with `No valid sessions` (4× `Bad Mac`). The one-line copy fix, applied TEMPORARILY in the pub cache (restored, hash checked), made it green. The vendored override with only that patch is green too. A second candidate patch (the stale duplicate archive entry) had no failing test and was dropped.
- Full `flutter test` with the vendored package: exit 0, 2813 passed, 14 skipped; the count gate OK. `scripts/dart-lint-ratchet.mjs`: PASS at 3160, after sorting `dependency_overrides` (`sort_pub_dependencies` had added +1). `pubspec.lock` switched to the path source.
- Live drive of the patched build (every decrypt goes through the patched copy): release web with the vendored package, two isolated Chrome profiles, fresh accounts L 332 / M 333 (conv 103).
  - Old-path messages were read both ways, then box messages both ways; the server rows stayed at 2.
  - After both profiles reloaded, history was intact and one message each way was read.
  - "box 2" never left the sender (a headless typing flake), not a lost message.
- Live drive J 330 / K 331 (conv 102), one-sided re-key: converged live, box both ways, 1 server row. It is a NO-REGRESSION check only: decision 49's window was never consulted, and the two-sided crossing is harness-only. Detail: `.planning/metadata-item5/findings.md` § 2026-09-27.
- NOT verified: the crossing on a device; the libsignal patch on Android/iOS (it is pure Dart, but the sibling re-key case in the trap was never re-driven); prod (box OFF); a revoked friend device actually using the window.

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
