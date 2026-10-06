# An offline own device no longer fails every box send (0.2.60 + 0.2.61, decision 93)

**Date:** 2026-10-05 · **Version:** 0.2.59 → 0.2.60 → 0.2.61 · **Tiers deployed:** both + APK 20061

## What was done
- Prod incident, measured read-only: the owner's Android (user 37, device 11), off since 10-02 17:02Z, filled its box self-queue (`BOX_NORMAL_QUEUE_CAP` 128) at 15:05:57Z. From then on every iPhone send got `queue_full` on that one sent copy, and `_sendOverBox` failed the whole row. Friends got and answered every one. A failed row is RAM-only (decision 19), so it vanished on reopen.
- Owner: "drop that stupid rule". New decision 93 / E93a supersede decision 20 and E5's clause. A box message is ✓ once ONE PEER device took its frame; own siblings never decide it.
- `services/box/box_outbox.dart`: `deliver` returns `BoxSendOutcome {taken, full, failed}`. `box_session.dart` maps `BoxRefused(queueFull)` to `full`; all callers migrated (first_contact, box_actions, box_receipts).
- `services/box/box_device_pause.dart` (new): a `full` device is paused per (user, device), RAM only. Nothing is sealed to it until a probe 1 h later, doubling to 24 h. Every seal moves its Signal chain, and libsignal refuses more than 2000 steps ahead.
- Resume: a frame its box takes (stored sends only; `live` typing frames are ignored, E61a), or a frame from it on a queue it holds. A sibling must be on our self-queue, a friend on its contact queue. Never the request queue: `_intakeRequest` journals an own-account claim with neither flag.
- `_sendOverBox` / `_sendBoxAction`: `failed` frames are owed to that device by E19l's in-RAM retry (`_oweBoxFrames`, key `msg|chat|wire`, same envelope and wire id). `full` is never owed. Receipts/typing skip a paused device (`isPaused`, no probe spent).
- Research note `docs/plans/2026-10-05-offline-device-fanout-research.md`. SimpleX (same 128 cap), Signal, WhatsApp, Threema, Wire, Matrix, Session, OMEMO: an offline device never blocks the sender.
- Out-of-repo: local dev stack stopped (`docker compose stop`); throwaway users 251 `ana93` (2 web devices, phrase enrolled) / 252 `bob93` in the local DB; static servers 8091–8093 stopped; `frontend/build/web` holds a local (non-prod) bundle.
- 0.2.61 (`7d8f37ca`, E93b, a review fix): 0.2.60 still sealed to every peer device when ALL were paused, so a friend whose only device was full lost a chain step per send. Now `_boxRoute` names no paused device, and `_peersAllPaused` fails the send for a retry with nothing sealed (`BOX_SEND_PEERS_FULL`; actions `why: peers_full`). No sibling probe is spent either. `box.constants.ts` comment fixed.

## Key files
- Edited: `messaging_provider.box.dart` (`consumeBoxEntry`, `_boxRoute`, `_sendOverBox`, `_noteBoxAnswers`), `messaging_provider.box_actions.dart`, `messaging_provider.box_receipts.dart`, `messaging_provider.first_contact.dart`, `messaging_provider.dart`, `box_outbox.dart`, `box_session.dart`, 11 test files, `pubspec.yaml`, `CLAUDE.md`, `wire.md`, `metadata-privacy-decisions.md`, `traps.md`.
- New: `box_device_pause.dart`, `test/services/box/box_device_pause_test.dart`, the research note.
- Read only (load-bearing): `third_party/libsignal_protocol_dart/lib/src/session_cipher.dart:272`, `backend/src/box/box.service.ts` `enqueue`, `box_inbox.dart` `_intakeRequest`.

## Verification
- CI: all ci.yml jobs success on `7d8f37ca` (0.2.61; Flutter, backend, e2e-wire, isolated probes, Web Lock, CodeQL); also 6/6 on `4c872c58` (0.2.60).
- `flutter test`: 3084 passed / 14 skipped (was 3078). `flutter analyze --no-fatal-infos`: infos only. Dart lint ratchet: PASS at 3153.
- New tests (send file):
  - a sibling refused → SENT, stored once, only that copy re-sent with the same wire id;
  - a friend device refused → SENT, re-sent to it alone;
  - a full device is paused: no seal before +1 h, one probe, a 2 h wait, a taken frame ends the pause;
  - a frame on its queue resumes it; request-queue and off-self-queue claims do not;
  - every friend device refused or full → FAILED, nothing owed.
- Other new tests: a full device is never owed a delete (actions file); `BoxDevicePause` waits 1, 2, 4, 8, 16, 24, 24 h (unit test); `deliver` tells `queue_full` from other refusals (session test).
- Live drive, release web of the working tree, local stack (box on). ana #1 (8091) + linked #2 (8092), bob (8093): first contact and every message over the box, 0 `messages` rows.
  - #2 closed, its self-queue filled to 128 by SQL. #1 sent hello 3 → ✓, bob got it, diag `BOX_DEVICE_FULL {251, 2}`, `BOX_SEND frames 2, peerTaken 1, full 1`. hello 4 → `frames 1` (paused). A voice note sent meanwhile → ✓.
  - #2 reopened: drained to 0, sent a message, so #1 logged `BOX_DEVICE_RESUMED {by: heard}`. hello 5 → `frames 2`, #2 shows it.
- Branch `feat/metadata-privacy` after the cherry-pick (`f55c2650`): Flutter 3076 passed / 14 skipped; not driven separately (same code as master).
- APK 20060: signer SHA-256 `8e9a6bf3…5cdf405d` = record-of-truth; `fireplace.ignorelist.com` and `4c872c58` found inside `libapp.so`; installed over 20059 on the Pixel_7 AVD (`firstInstallTime` unchanged), booted to the login screen with footer `4c872c58`. No login was driven on it.
- Prod: backup `chatdb-20261005T185333Z.dump.gpg`; `/version` = 0.2.60/4c872c58 with android 20060; smoke 8/8; 0 error/warn lines in the first 5 min; `/apk/umbra-0.2.60.apk` 200.
- NOT verified: the changed path on Android or the iPhone PWA; the owner's prod account (his Android is still off, its self-queue at 128).

## Notes for next session
- DEPLOYED 2026-10-06 01:20Z: web + backend `0.2.61/7d8f37ca` (CI 8/8 incl. Dependabot, smoke 8/8, 0 error lines), APK `/apk/umbra-0.2.61.apk` (20061, SHA256 `6d8919e1e3c4d413a7bd31af931d7083d6bed61d371486a971f299fbac047b4c`, signer = record-of-truth, booted on Pixel_7). Backup `chatdb-20261006T011617Z.dump.gpg`; VM `.env` backup `.env.bak.pre-apk-0.2.61`. 0.2.60 (`4c872c58`) was live ~4 h before.
- 0.2.61 proof: Flutter 3085/14; new test (a friend whose every device is paused: no `encryptCalls`, no frame, no old path; a retry after +1 h goes). Drive: bob offline, his queue filled to 128; send A failed and paused him, send B logged `BOX_SEND_PEERS_FULL` with ana #2's self-queue count unchanged.
- Next action: the owner checks on prod. Sending from the iPhone must now show ✓ while his Android is off. Then switching the Android on drains the 128.
- `feat/metadata-privacy` (fireplace-mp): both fixes are cherry-picked (`f55c2650`, `455cd608`); Flutter 3077/14 there. Its pubspec stays at the branch's 0.2.55; bump it past 0.2.61 at the merge. Rows 93/E93a/E93b are in the branch log.
- `messaging_provider_box_send_test.dart` flakes under load (pump-based waits; a different test fails each run). It also fails on `cc0e2ec9` (before this work); the full suite passed.
- Deferred, owner-owed (0.2.62+): inactive-device UI in Settings → Devices; a "some messages may not appear" notice on a device that was full; persisting failed rows (would overturn decision 19); auto-unlink of stale devices.
- Residuals (E93a): a restart forgets the pause (one chain step); a retry pass can spend a paused device's probe; frames a full device missed are not re-sent.
- Recipe (drive):
  - Linking on web needs an "installed" PWA: init script `Object.defineProperty(Navigator.prototype,'standalone',{get:()=>true})`.
  - Find the sibling's self-queue: close its tab, send once; it is the only normal queue left with `msgCount 1`.
  - Fill it with `INSERT INTO box_msgs … generate_series` and bump `box_queues.msgCount` + `box_totals` in the same statement.
  - The composer only takes `keyboard.type` once per open chat: back out and reopen the chat before each message, and click send at (457,716).
- Traps: one line in `traps.md` E2E.
