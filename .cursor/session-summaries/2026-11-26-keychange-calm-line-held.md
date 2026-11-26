# Key-change "calm line + one tap" (decisions 152/153) built and driven; 0.2.112 NOT released (message-delivery windows)

**Date:** 2026-11-26 (evening) · **Version:** unchanged on master (0.2.111); branch carries 0.2.112 · **Tiers deployed:** none

## What was done
- Owner chose (form) to replace the provisional frame accept, then option C: a friend's PreKey frame under a new identity is NEVER decrypted before its key is confirmed and never causes a request by itself; eligible (warnings OFF, not verified, persisted list held and not enrolled) -> calm hold with a neutral tappable line and a muted list preview; only the person's tap looks the friend up; the served identity must equal the frame's with a valid signature; then accept + permanent note, session from that bundle, bounded drain, held sends released in order. Otherwise the red hold. Rows 152 (rewritten) and 153 (new, tap may look up) are on the branch.
- `feat/keychange-b` (draft PR #318, head `25bf1170`): `messaging_provider.box.dart` (`_holdForeign`, `CalmHold`, `confirmCalmHold`, `_calmDeferredSends`, `_calmDraining`, `_calmWaits`), `encryption_provider.dart` `confirmCalmKey`, `encryption_service.dart` (`calmHoldEligible`, `holdCalm`, `bundleProvesIdentity`), `widgets/calm_hold_line.dart`, `ConversationTile.calmHold`. All revert/snapshot machinery of the first design is deleted.
- Five builders in sequence, each started from the handover file (`.planning/keychange/keychange-c-design.md`); four independent reviews. No reviewer found a wrong key accepted, a decrypt before confirmation, or a request without a tap.
- Release stopped by the pre-set rule: three reviews in a row each found a window in which a message written around the tap goes to the friend's OLD queue (released before the handoff was read; guard off during the drain; and, still open, after a drain timeout/throw and when a send read its addresses before the guard).
- Out of repo: worktree `Desktop/fp14-kc` kept; stack `fp14`, web server, drive Chrome stopped and removed; debug app removed from the Xiaomi, power settings restored; `.planning/cleanup/drive/PHONE.md` (unlock recipe, PIN, not committed); `.planning/research/2026-11-26-agent-context-management.md`.

## Key files
- Edited/new (branch only): the files above, `frontend/lib/l10n/*` (calmHold*, messageSendWaitsForCalmHold), `frontend/test/providers/messaging_provider_box_friend_crossing_test.dart`, `messaging_provider_box_calm_send_test.dart`, `frontend/test/widgets/calm_hold_*`, `docs/plans/metadata-privacy-decisions.md`, `docs/agents/traps.md`, `frontend/docs/e2e-invariants.md`.
- Read only (load-bearing): the design/handover and the four review reports, saved in `.planning/keychange/` (gitignored: `keychange-c-design.md`, `review-*.md`).

## Verification
- CI: PR #318 on `25bf1170`: 15 rows success, release row skipped (16 rows).
- Local gates (last builder): `flutter test` `+4061 ~14: All tests passed!` (before a two-line lint touch-up; CI re-ran everything), Dart lint ratchet `PASS, IMPROVED 2465 -> 2464`, analyze no errors.
- Mutants: reviewers list killed/surviving guards per pass; survivors at the end: media guard during the drain, `_calmDraining.clear()` in `onConnect(false)` and `clearAll`.
- Devices (debug APK on the Xiaomi + real Chrome, local stack), tables in `.planning/cleanup/batches.md`:
  - Privacy, measured from the web observer's own outgoing socket frames (recorder proven by a manual search): 76 s with the line waiting = zero `searchUsers`/`fetchPreKeyBundle`/`getDeviceList`; exactly one `searchUsers` at the tap (`dae78340`).
  - Friend writes first; restart while the line waits; verified friend and warnings ON -> red at once; write while the line waits -> row waits, delivered once after the tap (phone and web); two waiting messages across a REAL reconnect -> both once, in order; refused tap -> red bar + refusal text (`25bf1170`).
- NOT verified: the open windows below on a device; enrolled-answer refusal; a pre-box friend; drain timeout; two tabs; linked multi-device friend; iOS; any release build; prod.

## Notes for next session
- Next action: fix the delivery windows STRUCTURALLY, not with another time-window mark: one invariant at the single seal chokepoint (`_sealBoxFrames` + `encryptForFriend`): a frame for a friend may be sealed only if the route's target queue is the one learned for the friend's CURRENT pinned identity; after an accepted key change the old address is stale until the handoff is read, and anything sealed meanwhile waits. Then one fresh review, re-drive, release. Ask the owner first whether he prefers that, or shipping as is with the gap documented.
- Open findings (RDrainFix): P1 drain bound/throw clears the mark while the handoff is unread; P2 a send's addresses are read before the guard; P3 order when the user types or retries during the release; timer/profile frames pass `encryptForFriend` during the drain; epoch check 1 not moved; three guards untested.
- Known gaps recorded in traps.md: message sent on the old session before the friend's frame arrives is never re-sent (older, also on master per two builders, not confirmed on a device); restart window before the first drain; the red hold's unawaited drain before Retry.
- UI seen: the waiting row shows a red dot and "Ponów" next to "will go out by itself"; verified/warnings turned ON while the line waits keeps the calm line until tapped.
- Recipes: `.planning/cleanup/drive/PHONE.md`; in-page frame recorder = `page.evaluateOnNewDocument` wrapping `WebSocket.prototype.send`, names parsed from `42["event"` / `42/box,N["event"`; "reinstall" on web = `Storage.clearDataForOrigin` + login; a real reconnect needs the backend restarted (removing `adb reverse` does not cut an open socket).
- Traps (also in `docs/agents/traps.md`): helpers rotate before ~60% context with a handoff file; a guard keyed to a time window around an await keeps leaking: key it to state.
