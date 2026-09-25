# Sibling queues part B: sent copies reach the account's other devices over the box, and revoking a device rotates every survivor's self-queue

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- E5 `box_envelope.dart:boxEnvelope` returns `copyJson` (peer envelope + E2E `to` = peer id); `messaging_provider.box.dart:_boxRoute` needs every live sibling addressed (`own_uncovered` → whole old path), `_sendOverBox` seals a copy into each sibling self-queue, a refusal fails the row; `_takeSentCopy` files it as an own `sent` row only when journaled from a self-queue (`BoxInboxEntry.viaSelfQueue`), no sound.
- E6/E7 new `box_sibling_rotation.dart:BoxSiblingRotation`: an entry the own VERIFIED list (`MessagingProvider.ownLiveDevices`) no longer names live prunes `boxsib_v1` and rotates the self-queue in ONE write (`rotateSelfQueue`); the old queue stays subscribed and is deleted only after the 30-d TTL.
- `BoxSession.siblingAcked`: an ack of a non-current sid → `forgetSiblingAck` + `BoxSiblingSwap.handAgain` (heals an older handoff that overtook the newer one across queues); `_currentSelf` follows another tab's rotation; `noteSibling` before a first handoff.
- E8: a REVOKED sibling origin is finished at once; ABSENT origin / no session held ≤ 30 d on a self-queue only; no session → `rekeySibling` once per session; a copy waiting for a chat ≤ 30 d (`BOX_SIBLING_COPY_EXPIRED`).
- Drain-marker retirement was built, then DROPPED after re-review: an in-flight copy or a second tab's stale row lands after the marker and a send to a deleted sid answers ok. TTL-only is the design (decisions log E6).
- Docs: wire.md (`to`, Send, Own siblings rotation), e2e-invariants (boxsib_v1, one-path), remainder plan E6/E8 amended, decisions log E5–E8 + open owner questions O6/O7, decisions 24 and 27 DONE, CLAUDE.md test count.
- Out-of-repo: `~/.omp/agent/config.yml` gained `modelRoles.web: anthropic/claude-opus-5-5:high` (the CLI setter rejects that key; a no-`--model` `omp web-search` reported Opus 5.5; whether `:high` is honoured is unproven). Local stack (compose project `fireplace-mp`: db :5433 + backend :3000, `BOX_ENABLED` true) left UP. `%TEMP%` of this PC deleted by mistake (below).

## Key files
- Edited: `frontend/lib/services/box/{box_envelope,box_inbox,box_outbox,box_session,box_sibling_swap,box_siblings,queue_keys}.dart`, `frontend/lib/services/contacts/{contact_store_inbox,contact_store_siblings}.dart`, `frontend/lib/utils/e2e_envelope.dart`, `frontend/lib/providers/{connection_provider,messaging/messaging_provider.box}.dart`, 6 test files.
- New: `frontend/lib/services/box/box_sibling_rotation.dart`.
- Read only (load-bearing): `messaging_provider.decrypt.dart:_originDeviceIsLive`, `docs/plans/2026-09-25-metadata-pr31-remainder.md`.

## Verification
- CI: NOT RUN on `21cf61bf` — only CodeQL. Draft PR #185 is CONFLICTING with master: the only conflict is `.cursor/session-summaries/LATEST.md` vs master's docs commit `2acd49b1` (`git merge-tree`), so the rebase is small.
- flutter test 2595 passed / 14 skipped (count gate OK via `--log`); analyze 0 errors; Dart lint ratchet (`scripts/dart-lint-baseline.json`) 3163 held.
- Mutants: round 1 25/25 killed; review-fix round 7/9 — survivors R7 (`_ensureSelf` guard) and R9 (`_dropGone` adoption) were BOTH deleted as redundant with `_currentSelf`; open-items round red-first, 15 killed (P1–P6, H1–H3, W1–W3, F1–F3), per-device self re-read in the swap survived → deleted; TTL switch T1, T2, H1, H3, F2, F3, R1 7/7 killed; U1 (finish an undecided origin) killed by the fetch-fails test.
- Reviews: PartBReview REQUEST_CHANGES (3) → fixed; PartBReReview REQUEST_CHANGES (P1 drain races, P2-3 shared identity) → TTL-only + O6; follow-up APPROVE (one doc nit fixed).
- Drive on the local stack, release web `59e141de` + throwaway `BOX_DRIVE` scaffold (deleted), 4 origins: E5 copies both ways (`frames 2`, copy shown as own ✓); decision 24 (A linked #4 mid-session: A's own side `frames 3` at once; peer B's send `frames 2`, reported sent, and #4 silently never got it until B reconnected (decision-21 residual); after the reconnect ONE whole old-path message, then `frames 3`); E6 revoke (#1 and #4 `BOX_SELF_QUEUE_ROTATED {gone:[2]}`, old queues retiring, #2 learned nothing). Server `messages` = 1 (the intended old-path send). Step-by-step log: `.planning/metadata-privacy/task_plan.md` part B (gitignored; everything load-bearing is here).
- NOT verified: a peer's box sends to a REVOKED device before that peer reconnects (the mirror of the #4 miss; not driven); Android/native, iOS, prod (box OFF); a revoked device writing into a retiring queue (unit-tested only); the 30-d delete live (clock test only).

## Notes for next session
- Next action: rebase `feat/metadata-privacy` onto master (skill `resolving-merge-conflicts`; CRLF markers, rerere off — the one conflict is LATEST.md), push, confirm all `ci.yml` jobs green on the new sha; then box push registration (E9, decision 23), then the decision-22 slice.
- Before any commit while the stack is up: `git checkout -- backend/package-lock.json` (the container's npm strips its `libc` lines; traps § Deploy).
- Owner-owed: O6 (a revoked device shares the account identity key and can pose as a live sibling on the request queue) and O7 (a send-time pre-key fetch tells the server the account is sending) — both before box ON in prod, not blocking E9.
- Residuals (decisions log E6): a sibling on the old address after the TTL loses what it sends; a reconnect can delete an EXPIRED retiring queue before its last frames are pushed.
- Incident: a cleanup command `rm -rf <Temp>/pbweb/..` deleted the whole `%TEMP%` of this PC (locked files survived). Told the owner.
- Drive recipe (the scaffold is deleted; rebuild it for the next drive): a web-only `Timer.periodic(3 s)` in `BoxSession.start`.
  - Writes this device's `{from, dev, sid, sealPub}` per friend (inbound queue via `QueueKeys.createInbound`) to SharedPreferences `BOX_DRIVE_OUT`.
  - Merges peer addresses from `BOX_DRIVE_IN` (a list of those maps) into `ContactRecord.outbound`; mirrors self/retiring/siblings/outbound/`E2eDiagLog` to `BOX_DRIVE_STATE`.
  - Web storage: localStorage key `flutter.<KEY>`, value JSON-encoded TWICE — read `JSON.parse(JSON.parse(localStorage['flutter.BOX_DRIVE_OUT']))`, write `setItem('flutter.BOX_DRIVE_IN', JSON.stringify(JSON.stringify(list)))`.
  - Friendship seed: a `friend_requests` row `accepted` + a `conversations` row. Linking: Devices → `Włącz łączenie` → phrase → word check on the primary, `matchMedia('(display-mode: standalone)')` overridden.
  - Restore `box_session.dart` with `git checkout` before any commit.
- Traps: drain-marker retirement loses copies; `rm -rf <dir>/..` wiped %TEMP%; first click on the Flutter web send button after CDP text only shows its tooltip.
