# Re-login-both loss: cause found, PARKED by the owner (decision 124); back to Phase 4

**Date:** 2026-10-28 · **Version:** 0.2.72 (no code change) · **Tiers:** none (investigation)

## What was done
- Reproduced on dev with a NEW pair, rla1028 (277) ↔ rlb1028 (278), made friends in the app:
  - before the re-login: `preA1` / `preB1` arrived both ways (`BOX_FRIEND_HANDOFF {acked: true}` on both sides);
  - re-login of both on fresh CDP browser contexts, A first, B 12 s later;
  - after it: both sides `BOX_SEND {peerTaken: 1}` with ✓, and nothing arrived.
- Cause, from both sides' `[DIAG]` console logs:
  - `CONTACT_BACKUP_RESTORED {count: 1}` brings back `outbound` but not `queues` (`contact_backup.dart:18-23`);
  - each new device logs `BOX_FRIEND_HANDOFF_SENT {viaRequest: false}`, handing its new queue to the other's dead pre-wipe queue;
  - `BoxFriendHandoff.targetOf` prefers a held `outbound`, and `_pass` looks the friend up only when a live device has no target, so no lookup ever runs.
- Why handing over the request queue too would not heal it, read from code and log timing (not driven):
  - A's first lookup (03:18:32) ran before B re-minted (03:18:44), so A pinned B's OLD key;
  - B's handoff on A's request queue is judged by `friendFrameIdentity` against that pin and refused `foreign_identity` (`messaging_provider.box.dart:255-257`);
  - a server lookup serving a different key throws `served_identity_mismatch` and raises no pill (`encryption_provider.dart:977-979`).
- Options put to the owner. All three also hand over the request queue after a restore, and a key change still needs a person's confirm:
  1. Re-look-up a friend whose queue is unconfirmed, once per 24 h. Loses up to a day of new messages with ✓.
  2. Look up at once on a `foreign_identity` refusal. A frame times a lookup, which breaks E114e.
  3. A durable ContactStore mark that the next connect's lookup consumes, then the pill. Heals at the next open; goes beyond 120's 24 h bound.
- Owner: "do we really need this right now?" → "proceed with phase 4 then". Recorded as decision 124: an exemption from 123 for the step 3 freeze, the step 4 server half and step 5.
- Corrected after his call: decision 116 removes the live key-change socket alarm at step 5, the one warning a pre-box pair may get today. Whether that alarm heals a pre-box pair today is untested.

## Key files
- Edited: `docs/plans/metadata-privacy-decisions.md` (decision 124), `docs/agents/traps.md` (the re-login-both line).
- Read: `services/box/box_friend_handoff.dart` (`targetOf`, `_pass`, `_handTo`), `providers/messaging/messaging_provider.box.dart` (`_readFriendHandoff`, the held-queue handoff), `providers/encryption_provider.dart` (`adoptServedAccount`).

## Verification
- Live drive only (web release build, dev stack); no code changed, so no tests and no CI.
- Drive kit, out of repo, `%TEMP%/relog`:
  - `r.mjs`: CDP browser contexts and `[DIAG]` capture;
  - `launch.ps1`: Chrome with a fresh profile. The old `d101drive/prof` autofills the staging password into the login form.
  - `diag/`: a web build whose `E2eDiagLog.add` also `print`s; the patch was reverted and nothing is in the repo.

## Notes for next session
- Next: Phase 4.
  - Owner's pair tests: SaraLee ↔ bob208 and BestiaBestia ↔ bob208. After them, prod `messages_id_seq.last_value` must still read 26956.
  - The freeze on prod: no earlier than 10-30, on the owner's go.
  - Meanwhile, build the step 4 server half test-first.
- Re-login-both: parked (decision 124). Pick an option with the owner before building.
- Dev accounts 277/278 are in the broken state.
