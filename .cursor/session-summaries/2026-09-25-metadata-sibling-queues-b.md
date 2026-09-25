# Sibling queues part B: sent copies reach the account's other devices over the box, and revoking a device rotates every survivor's self-queue

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- E5 `box_envelope.dart:boxEnvelope` returns `copyJson` (peer envelope + E2E `to` = peer id); `messaging_provider.box.dart:_boxRoute` needs every live sibling addressed (`own_uncovered` → whole old path), `_sendOverBox` seals a copy into each sibling self-queue, a refusal fails the row; `_takeSentCopy` files it as an own `sent` row only when journaled from a self-queue (`BoxInboxEntry.viaSelfQueue`), no sound.
- E6/E7 new `box_sibling_rotation.dart:BoxSiblingRotation`: an entry the own VERIFIED list (`MessagingProvider.ownLiveDevices`) no longer names live prunes `boxsib_v1` and rotates the self-queue in ONE write (`rotateSelfQueue`); the old queue stays subscribed and is deleted only after the 30-d TTL.
- `BoxSession.siblingAcked`: an ack of a non-current sid → `forgetSiblingAck` + `BoxSiblingSwap.handAgain` (heals an older handoff that overtook the newer one across queues); `_currentSelf` follows another tab's rotation; `noteSibling` before a first handoff.
- E8: a REVOKED sibling origin is finished at once; ABSENT origin / no session held ≤ 30 d on a self-queue only; no session → `rekeySibling` once per session; a copy waiting for a chat ≤ 30 d (`BOX_SIBLING_COPY_EXPIRED`).
- Drain-marker retirement was built, then DROPPED after re-review: an in-flight copy or a second tab's stale row lands after the marker and a send to a deleted sid answers ok. TTL-only is the design (decisions log E6).
- Docs: wire.md (`to`, Send, Own siblings rotation), e2e-invariants (boxsib_v1, one-path), remainder plan E6/E8 amended, decisions log E5–E8 + open owner question O6, decisions 24 and 27 DONE, CLAUDE.md test count.

## Key files
- Edited: `frontend/lib/services/box/{box_envelope,box_inbox,box_outbox,box_session,box_sibling_swap,box_siblings,queue_keys}.dart`, `frontend/lib/services/contacts/{contact_store_inbox,contact_store_siblings}.dart`, `frontend/lib/utils/e2e_envelope.dart`, `frontend/lib/providers/{connection_provider,messaging/messaging_provider.box}.dart`, 6 test files.
- New: `frontend/lib/services/box/box_sibling_rotation.dart`.
- Read only (load-bearing): `messaging_provider.decrypt.dart:_originDeviceIsLive`, `docs/plans/2026-09-25-metadata-pr31-remainder.md`.

## Verification
- flutter test 2595 passed / 14 skipped (count gate OK via `--log`); analyze 0 errors; lint ratchet 3163 held.
- Mutants: round 1 25/25 killed; review-fix round 7/9 (R7 `_ensureSelf` guard, R9 `_dropGone` adoption survived → deleted as redundant with `_currentSelf`); open-items round red-first, 15 killed (P1–P6, H1–H3, W1–W3, F1–F3), per-device self re-read in the swap survived → deleted; TTL switch T1, T2, H1, H3, F2, F3, R1 7/7 killed; U1 (finish an undecided origin) killed by the fetch-fails test.
- Reviews: PartBReview REQUEST_CHANGES (3) → fixed; PartBReReview REQUEST_CHANGES (P1 drain races, P2-3 shared identity) → TTL-only + O6; follow-up APPROVE (one doc nit fixed).
- Drive on the local stack, release web `59e141de` + throwaway `BOX_DRIVE` scaffold (deleted), 4 origins: E5 copies both ways (`frames 2`, copy shown as own ✓); decision 24 (A linked #4 mid-session: A's own side `frames 3` at once; peer B's send `frames 2`, reported sent, and #4 silently never got it until B reconnected (decision-21 residual); after the reconnect ONE whole old-path message, then `frames 3`); E6 revoke (#1 and #4 `BOX_SELF_QUEUE_ROTATED {gone:[2]}`, old queues retiring, #2 learned nothing). Server `messages` = 1 (the intended old-path send). Detail: `.planning/metadata-privacy/task_plan.md` part B.
- NOT verified: a peer's box sends to a REVOKED device before that peer reconnects (the mirror of the #4 miss; not driven); Android/native, iOS, prod (box OFF); a revoked device writing into a retiring queue (unit-tested only); the 30-d delete live (clock test only).

## Notes for next session
- Owner-owed: O6 (a revoked device shares the account identity key and can pose as a live sibling on the request queue) and O7 (a send-time pre-key fetch tells the server the account is sending) — both before box ON in prod.
- Residuals (decisions log E6): a sibling on the old address after the TTL loses what it sends; a reconnect can delete an EXPIRED retiring queue before its last frames are pushed.
- Incident: a cleanup command `rm -rf <Temp>/pbweb/..` deleted the whole `%TEMP%` of this PC (locked files survived). Told the owner.
- Next: box push registration (E9, decision 23), then the decision-22 slice.
- Traps: drain-marker retirement loses copies; `rm -rf <dir>/..` wiped %TEMP%; first click on the Flutter web send button after CDP text only shows its tooltip.
