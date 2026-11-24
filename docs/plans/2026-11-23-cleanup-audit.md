# Cleanup audit: what is wrong, how bad, and in what order to fix it (2026-11-23)

Phase 1 output of `docs/plans/2026-11-23-cleanup-program.md`. Read-only audit of `master` `ff4e9146` (0.2.93 live). Nothing in the code was changed.

**Verdict:** no P0 (nothing found that leaks message content or lets a stranger read or forge messages). 13 P1 code findings, mostly races that lose a message or leave a stale state, plus 2 wrong texts/paths the user can hit today. 10 P1 test gaps: guards that can be deleted with every test still green. The connection code is the weakest-tested part. The code is large, not rotten: zero unused-code hints from the analyzers, lint at the ratchet floor.

Raw material (gitignored, on the lead's PC): `.planning/cleanup/findings.md` (every row), `.planning/cleanup/scouts/*.md` (one report per area, with each scout's "not read" list), `.planning/cleanup/metrics.md` (baseline numbers).

## 1. How to read the evidence

- `[CONFIRMED]` = read in code by the scout; the lead re-read BE-01, UI-01, UI-02, CONN-01 and they hold.
- `[SUSPECT]` = both paths and the `await` between them are visible, no failing test yet. Most RACE rows are SUSPECT. Per the brief, each gets a failing test before any fix; a row whose test cannot be made to fail is closed as "not a bug".
- Driven on a device: only #274 on web (F-001). Android #274 (F-002) is NOT verified: the local stack has no Firebase key and no phone was attached.
- The scouts ran as the `scout` agent type and the mutation runs as `task`. The tool does not let the lead set or check their model class; the brief asked for the lead's class.

## 2. Findings by area and risk

| Area | P0 | P1 | P2 | P3 | Total | Share of area read |
|---|---|---|---|---|---|---|
| 1 Encryption and sessions (audit only) | 0 | 0 | 10 | 10 | 20 | `encryption_service` ~55 %, `encryption_provider` ~25 % |
| 2 Box send/receive | 0 | 2 | 12 | 10 | 24 | ~half |
| 3 Connection lifecycle | 0 | 2 | 5 | 12 | 19 | `connection_provider` nearly whole; handlers behind events not read |
| 4 Contacts, first contact, linking, auth | 0 | 3 | 10 | 11 | 24 | tests not read |
| 5 UI and composer | 0 | 3 | 13 | 14 | 30 | ~half; 12 screens never opened |
| 6 Web-only | 0 | 0 | 6 | 11 | 17 | service worker and bridges read; small helpers not |
| 7 Backend | 0 | 2 | 5 | 23 | 30 | most of `src` |
| 8 Tests and docs | 0 | 0 | 2 | 19 | 21 | sampled |
| 9 Tests of removed features | 0 | 0 | 1 | 7 | 8 | names and greps, not bodies |
| #274 (Phase 0) | 0 | 1 | 2 | 1 | 4 | driven on web |
| Mutation sampling (test gaps) | 0 | 10 | 9 | 9 | 28 | 80 mutants in 4 areas |
| Skipped tests | 0 | 0 | 2 | 1 | 3 | all 16 |

By kind (areas 1-9, 193 rows): RACE 75, BUG 23, DRIFT 25, DEAD 25, TEST 19, DUP 14, GIANT 12.

## 3. Top 10 risks, in plain words

1. **A muted chat still notifies when the app is closed (F-001, #274).** The web push worker does not know which chats are muted. Driven: muted chat, tab closed, card in 4.3 s. Android wake-ups (F-002) have the same gap by design: the wake-up names no chat. A swipe-deleted chat also reads as "not muted" (F-003).
2. **Two people can be handed the same one-time key (BE-01).** The server's key hand-out has no lock, so two requests at the same moment can get the same key. One of the two first messages then fails to decrypt. Needs a failing database test first.
3. **A phone can stop getting wake-ups until it reconnects (BE-02).** If the connection drops at the wrong moment during subscribe, the server remembers a dead connection as "online" and skips the push.
4. **A message can get stuck or be thrown away on arrival (BOX-01, BOX-02).** If reading a delivery throws, the message is neither kept nor confirmed; 16 of those stall all delivery until reconnect. And a message arriving while the contact list is being rewritten can be confirmed and dropped.
5. **Logout can be undone by a late token refresh (CONT-02).** A refresh already on its way can land after logout and write the old account's tokens back.
6. **Connect/disconnect can overlap (CONN-01, CONN-06).** A `disconnect()` during a slow `connect()` does not cancel it, so the old connect finishes and reconnects. Work also starts before the server says the socket is ready, so early requests can be silently ignored.
7. **A friend request that crosses with theirs can delete the new friend's queue (CONT-01).** Both ask at once; our side's failed send then cleans up a queue the friendship now depends on.
8. **Linking a device can run twice at once (CONT-05).** Two copies of the hand-over blob both start "adopt identity", and each wipes the account's local data first.
9. **Wrong words and an unguarded download (UI-01, UI-02).** After "clear chat" the toast says "Chat deleted for both sides"; it clears this device only. And a file message without a key is downloaded from whatever address the sender put in it, with no host check.
10. **A caption can go to the wrong chat (UI-05).** On the desktop split view, switching chats while a photo uploads sends the caption to the newly opened chat. Composer area: needs the owner's OK.

Next in line (P2): a message lost if the tab dies between decrypt and save (ENC-01/02); a "repair once per session" latch set before the repair is sent (BOX-03); a send finishing after sign-out writing into the next account's lists (BOX-05/06); one undeletable file stopping the whole server sweep including the alarm ping (BE-03); a 4 MB body parsed before login on `/backup/contacts` (BE-06); no cleanup of old refresh tokens (BE-08); passcode lock not shared between tabs (WEB-05); badge counts overwritten by parallel pushes (WEB-01).

## 4. Tests

- **Skips: 16, the same 16 in CI.** 13 are real crypto round trips (AES-GCM, PBKDF2) skipped with "webcrypto native unavailable" because nobody runs `webcrypto:setup`: they run nowhere (SK-2). 2 are the B3 impersonation file (SK-1). 1 is the Web Lock test (SK-3).
- **B3 file, run with `--run-skipped`: both red.** Test 1 is broken fixture data. Test 2 shows the Signal layer still accepts a swapped identity; only the box reader holds the frame. The file's own header calls it a demonstration. Three green tests in `messaging_provider_box_test.dart` (lines 356, 380, 413) cover the held frame.
- **Web Lock test:** stays. The CI probe asserts the same thing plus "no lock API = refuse to run", and passes locally (`node scripts/verify-session-lock-probe.mjs` → `SESSION_LOCK_PASS`). The test itself under `flutter test --platform chrome` hung at "loading" twice on this PC (7 and 15 min, killed); cause not investigated.
- **Mutation sampling** (break one guard, see if a test notices): device lists 22 mutants, 0 survived (strong). First contact 15, 7 survived. Box 17, 3 survived. Connection 26, 19 survived (weak).
  - First contact and box: every survivor is a guard that exists but is tested only with a well-formed record, never a blocked, former, lapsed or route-less one. Worst: a forged `goodbye` guard (MF-03), a lapsed request read as an accept (MF-01), a block of a pending request (MF-07), a relay to a paused own device (MB-3).
  - Connection: no test notices if an account switch stops clearing the old account's lists (MC-02), if the "a newer connect won" guards are removed (MC-03, the same hole as CONN-01), if the retry counter is never reset (MC-09), or if the 10 s ready-watchdog is never cancelled (MC-W5). The reconnect back-off class has no test file. Nothing checks that logout unregisters push (MC-W6).
- **Tests of removed features:** 102 files matched; 0 safe deletes found on a first pass. About 30 tests have "old path" in the title but assert live behaviour: rename, do not delete.
- **Real duplicates:** a 400-line copy of the box send harness inside `messaging_provider_box_send_test.dart` (TD-02); echo/duplicate backend specs (TD-04/05).
- **Local test time (idle PC):** whole Flutter suite 79 s, 3402 passed, 16 skipped, 293 files. Slowest files by summed test time: `messaging_provider_box_first_contact_test` 17.9 s, `connection_provider_box_test` 14.7, `box_session_friends_test` 12.8, `box_session_siblings_test` 10.6, `contact_network_view_test` 9.7, `peer_recovery_durability_test` 8.4, `chat_input_bar_attachment_test` 7.7, `messaging_provider_box_send_test` 7.7, `box_notifiers_test` 7.0, `passcode_store_test` 6.9.
- **CI time today (run on `49a0d64e`):** wall 3m19s; slowest leg `services` 3m04s. About half of each leg is Flutter setup, not tests.

## 5. Proposed batches (order from the brief §5)

Each batch = one owner OK, one release, driven on Android emulator + test phone + web first. Structural and behavioural changes go in separate PRs inside a batch.

| Batch | Content | Type |
|---|---|---|
| 1a | #274: F-001 (after decision O-1), F-003; UI-01 text; UI-02 download guard; BE-01; BE-02; Dependabot #172; the 10 P1 missing tests (MF-01/02/03/06/07, MB-3, MC-02/03/09/W5), tests only | behavioural |
| 1b | Client races, each behind a failing test: CONN-01, CONN-06, CONT-01, CONT-02, CONT-05, BOX-01, BOX-02; UI-05 only with the composer OK | behavioural |
| 1c | P2 behaviour: BOX-03, BOX-05/06, BE-03, BE-06, BE-08, CONT-09, WEB-01, remaining P2 races that survive their failing test | behavioural |
| 2 | Dead code and dead fallbacks: BE-09/10/12/13, dead env lines (TD-18), dev previews out of `test/` (TD-12), `getMessages` shim after decision O-4 | structural |
| 3 | Duplicates: TD-02 harness, TD-04/05, the DUP rows per area | structural |
| 4 | Giant splits, one file per PR, re-measured first: `messaging_provider.box.dart` (2852 lines, 7 extension files named in BOX-23), `box_session.dart`, `connection_provider.dart`, `contact_network_view.dart`, `link_ceremony_controller.dart`, `chat-key-exchange.service.ts` (BE-14), then `chat_input_bar.dart` last (composer rule). Backend folder cycles (BE-15): extract `refresh-tokens/` first | structural |
| 5 | Test pruning and doc drift: renames (TL-1..8), SK-1/SK-2, README and rule drift (TD-14..21), gated counts in `CLAUDE.md` §3 | structural |

Release B (drop of old tables/files) is due on or after 2026-12-08 and rides whichever batch is open then.

**Status:** batch 1a shipped as 0.2.94 on 2026-11-23 (PR #276, `c073bdfc`). Batch 1b shipped as 0.2.95 on 2026-11-24 (PR #277, `6c37b151`; `.cursor/session-summaries/2026-11-24-cleanup-batch-1b.md`): CONN-01, CONN-06, CONT-01, CONT-02, CONT-05, BOX-01, UI-05/06/07 fixed; BOX-02 parked (EC-12). Batch 1c (0.2.96): BOX-03 (sibling), BOX-04/05/06, BOX-17, CONN-02/03/05/17, CONT-03/06/07/08/09/10/11/12, UI-08/10/11, WEB-01/02/05, BE-03/05/06/08/20/29, ENC-03/05/06/08/11 fixed; parked and accepted costs in EC-13, EC-14. Next: batch 2.

## 6. Engineering calls (E-rows, no owner action)

| id | Call |
|---|---|
| EC-1 | A SUSPECT race whose failing test cannot be written in half a day is logged and parked, not fixed blind. |
| EC-2 | F-003 is fixed with one helper that reads mute from the contact record; both call sites use it; one test covers both. |
| EC-3 | BE-01 stays "needs failing int-spec" until a two-connection Postgres test shows the double hand-out. |
| EC-4 | Encryption findings that need a change inside the vendored libsignal (ENC-01/02) are not fixed in this program. They go into the Phase 3 report with B6. Encryption findings that are plain ordering fixes outside the vendored code go to batch 1c. |
| EC-5 | "Old path" tests are renamed, not deleted, unless the covering test is named in the PR. |
| EC-6 | Mutation agents work in throwaway worktrees; nothing from them is merged. The missing tests are written fresh in batch 1a. |
| EC-7 | Web-only findings are tagged `[web-only: retire with §7]` and fixed only when the owner said so (O-10) or it is a one-line change; nothing web-only is deleted. |
| EC-8 | The slowest-file list is re-measured on an idle PC before any test is pruned for speed; the contended run is not used. |
| EC-9 | (Owner had no view, 11-23.) `encryption_b3_impersonation_test.dart` is deleted in batch 5; the PR names the covering tests `messaging_provider_box_test.dart:356,380,413`. The missing Signal-layer re-key gate (E143g) goes into the Phase 3 report. |
| EC-10 | Android per-chat mute while closed needs fetch-then-notify (wake-up carries nothing, the phone decrypts, then decides). Listed for after the freeze; not built in this program. |
| EC-11 | (Batch 1b, CONN-06.) E2E init starts at `socketReady`, not at transport connect. Cost accepted: a link that connects but never turns ready runs no E2E init, so stored messages stay unread until the next good connect, the same as an offline start. Running init twice (once local, once after ready) was rejected as a larger change than the finding. |
| EC-12 | (Batch 1b.) BOX-02 parked: every subscribe is ordered after the store write that makes the queue visible to `_ownerOf`, so the ack-and-drop window cannot open. |
| EC-13 | (Batch 1c.) Parked, no code: BOX-03 friend half (releasing the latch after a refused send would widen decision 70's one-lookup bound: owner call), BOX-07 (the row's fix is what decision 68 built and 70 reverted), BOX-09 (owed frames need a new persisted key: after the freeze), BOX-18 (the wipe error is already caught and logged; the real gap, no retry of a failed wipe, needs a persisted marker), CONN-04 (no deterministic red test for the library's own reconnection; `disableReconnection()` needs a device drive first), CONT-04 (the claimed orphan row does not exist; the remaining drop needs a two-device sender to show), CONT-11 second half (`clear()` during an upload), WEB-03 and WEB-04 (need a session generation / a cross-tab KEK signal, more than the lock channel), ENC-04 (whole-set writers need lock + reload + merge with removal semantics: Phase 3 report). |
| EC-14 | (Batch 1c.) Costs accepted with the fixes: BE-06 a junk bearer still gets the 4 MiB parse; BOX-17 `internal` retries every minute with no cap (under the server's 30 / 15 min throttle); ENC-08 a wipe waits for session work already queued; ENC-06 a caller that joins a rebuild in flight fails with that rebuild's error; ENC-05 the account anchor is read from storage on each call on web; WEB-05 only the padlock tap is announced, not auto-lock or logout; `kvWrite` in `web-push-sw.js` is left without callers (web-only code is not deleted); CONT-12 a UI search unanswered for 10 s ends as "not found". |
| EC-15 | (Batch 1c, found by the device drive; not in the audit.) `EncryptionService` is one object per process and kept the keys it had just made for account B in memory after B logged out. Logging back into account A in the same app run then uploaded B's key bundle and one-time pre-keys under A: the server recorded an identity change for A (`[identity-churn] via=unlocked`) and new contacts could not reach A (`InvalidKeyIdException`). Present in every release up to 0.2.95. Fixed in 0.2.96: the pending upload is dropped when the account changes. Still open, listed for batch 2 review: other per-account fields of that object that an account change does not clear (`_ownIdentityReplacedAt`, `_ownIdentityReplacedSeenAt`, `_ownPublishUnacknowledged`, `_ownIdentitySince`, `_provisionalIdentityAdopted`). |
| EC-16 | (Batch 1c, second review pass.) Same class as EC-15, one layer up: `EncryptionProvider` kept one-time pre-keys waiting for their bundle's answer across a logout, so the next account's answer could send them into that account's pool. Fixed in 0.2.96 (`clearAll` drops them; red test first). Not fixed, low risk, parked: a device-link or restore adopt still running when the account changes can write the old account back into `EncryptionService` (`adoptProvisionedIdentity`, `adoptRestoredIdentity`; whether logout aborts an open ceremony was not checked); the CONT-03 send marker (`_sendOverBox`) is still removed without the liveness check, and that check compares user ids only. |

## 7. Gaps in this audit

- Areas 2 and 5 were read about half. The 12 unopened screens include settings, devices, contacts, invitations, auth, recovery key and the link screens.
- `encryption_provider.dart` was read about 25 %; the device-list adopt paths in it were covered only by the mutation run (all killed).
- Backend raw SQL paths and the int-specs were not mutated (no Postgres in the mutation worktrees).
- Tests of removed features: titles and greps only.
- No Android drive in this phase.

## 8. Owner decisions (triage, 2026-11-23)

| id | Question | Answer |
|---|---|---|
| O-1 | Web: store the muted-chat list where the closed app can read it (no passcode)? | No. Left as is; muted chats keep notifying on web while the app is closed. F-001 is closed as "accepted" (decision 149). |
| O-2 | Android: same problem | Small fix now: silent only when every chat is muted. Proper fix after the freeze (EC-10, decision 149). |
| O-3 | B3 test file | Owner had no view; lead's call, EC-9. |
| O-4 | Run the 13 skipped crypto tests in CI | Yes. Measure the services leg before and after. |
| O-5 | Batch order | OK, start with 1a. |
| O-6 | One name ignoring case (BE-05) | Add the rule. Check production for existing duplicates first; come back if any. |
| O-7 | Server leftovers for apps 0.2.75 / 0.2.74 and older (BE-11, CONN-11) | Remove in the dead-code batch, not at Release B. |
| O-8 | Log fingerprints and old records (BE-20, BE-29) | Remove fingerprints; 30 days for old rows; newest identity-change row per account stays (decision 150). |
| O-9 | Composer | OK for the three bug fixes UI-05/06/07, each with a failing test and a drive. The composer file split stays last. |
| O-10 | Passcode lock across tabs (WEB-05) | Fix it. |
| O-11 | (11-24, batch 1c.) Old account's push table left in the browser after logout (WEB-02, web-only, about 15 lines) | Keep the fix. |

Effect on the batches: 1a loses F-001 and gains F-002 (small fix) and F-003; 1b gains UI-05/06/07; 1c gains WEB-05, BE-05, BE-20, BE-29; batch 2 gains the `getMessages` shim.
