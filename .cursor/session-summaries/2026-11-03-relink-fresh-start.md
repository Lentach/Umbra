# #208: a re-linked device starts fresh and no longer breaks the primary's sends

**Date:** 2026-11-03 → 11-04 · **Version:** unchanged (0.2.73 on prod; fix unreleased) · **Tiers deployed:** none

## What was done
- Round 1 (`63764ec8`): a link adopt wipes the `e2e_<uid>_` namespace; a previous device life (stamp != stored session id) shows the gate from the first frame and E2E init refuses before any publish; a gated install never publishes the contact backup; the friend handoff uses the request queue; copy says a re-link starts fresh.
- Review 1 (`c59e1a96`, `cad490a8`): proven wipe (stamp last, `localIdCounterKey` kept), `beforeWipe` after the blob parses, old queues deleted before the wipe, handoff keyed on `friendAnswered`, one-shot `openProvisioning` re-send.
- Review 2 (owner: "fix everything, then drive"):
  - `openProvisioning` is re-sent when owed: sent before `socketReady` or unanswered at a socket drop (`ProvisioningEventSink.onSessionLost`).
  - Phrase restore wipes history only for a previous device life (`adoptRestoredIdentity(freshDeviceLife:)`, `restoreStartsFresh`); a lock-refused install keeps it (owner).
  - A reset disposal whose teardown throws records `RESET_STALE_DISPOSAL_DEFERRED` and mints nothing.
  - Queue deletes have a hard deadline (per-delete `.timeout`); names, typedefs, dead seams cleaned.
- Gaps (owner: fix ASAP):
  - New install: `AuthGate` holds the honeycomb while a keyless install awaits its verdict (`awaitingIdentityVerdict`, 20 s cap, ends at the first verdict).
  - Unlinked phone woken by a friend: the gate deletes the old queues at once (`onPreviousDeviceLife` → `_retirePreviousLifeQueues`, stamp re-read BEFORE the box is taken); the server drops box notifiers on the revoked device's push tokens (decision 125); the client re-registers its push token when the device id moves (`PushService.registerAgain`).
  - Unconfirmed deletes stay owed in the sealed `boxgone_v1` row (kept by the wipe) and the next ready box deletes them (`BOX_OWED_QUEUES_DELETED`).
- Found driving: the link's reconnect still saw the cached gate verdict and retired the NEW box, so the re-linked phone took nothing until reopened; fixed with the pre-take re-read + regression test.
- Out-of-repo: emulator has the debug APK; Docker Desktop was restarted (engine had stopped); planted/consumed `box_notifiers` test rows on dev only.

## Key files
- Frontend: `providers/{connection,encryption}_provider.dart`, `services/encryption_service.dart`, `services/box/{box_session,box_friend_handoff}.dart`, `services/contacts/{contact_store,contact_store_owed_deletes,contact_backup_service}.dart`, `services/encryption/sealed_web_content_kv.dart`, `services/device_link/link_ceremony_controller.dart`, `services/push_service.dart`, `main.dart`.
- Backend: `chat-device-revocation.service.ts` (+ spec), `fcm-tokens.service.ts`, `web-push-subscriptions.service.ts`.
- Docs: `e2e-invariants.md`, `multi-device.md` (xc), `wire.md`, `metadata-privacy-decisions.md` (125), `traps.md`, `CLAUDE.md` counts.

## Verification
- Round 1: CI 6/6 `63764ec8`; 3315 tests; mutants killed: adopt Signal-only wipe; previous-life init gate removed; `_notePreviousDeviceLife` no-op; restart without `onSession`; handoff keeping the held address; handoff ignoring the session; `mayPublish` ignored. Prod read-only SQL (owner OK): bob208 devices 1/11/18, 18 reused 11's `requestSid`, no "karol" account (stale local residue). Drives: web revoke → gate → re-link 3 contacts, no history; emulator link → revoke → gate → re-link (device 27) both ways. fa21/fa23 never left F (tab backgrounded / no focus): `.planning/208-relink/findings.md`.
- Review 1: CI 6/6 `c59e1a96`; drive B (device 37 → unlink → gate, no chat-list frame → device 39, `held: 6`).
- CI: 6/6 success on `80b98d53` (review 2 + gaps: backend, Flutter, E2E wire, isolated probes, Web Lock probe, CodeQL).
- Review 2: Flutter 3335 passed / 14 skipped, backend 1264, analyzer 0, Dart lint 3130, backend ratchet PASS. Mutants killed and reverted: socket-drop re-send; answered-before-drop not re-sent; stale restore Signal-only; lock-only restore wiping; reset `beforeWipe` failure; owed row wiped; keyless verdict wait; keyless wait removed from `AuthGate`; hard-deadline retire; owed delete not drained; gate-time delete dropped; pre-take stamp re-read dropped. Backend: notifier teardown has a failure-path test (no mutant run).
- Drive (emulator debug APK + web, 11-04 15:45–16:14):
  - fresh install, password login: 87/87 frames login → honeycomb → gate, no chat list (`u_login.mp4`);
  - link → device 41; `fcm_token` row under 41 (old rows stayed under 7);
  - planted 3 `box_notifiers` rows; unlink 41 while closed → its token's row gone, device 7's and the control row kept;
  - F's next send `frames: 3` (41 dropped); relaunch → logged out → password login → stale gate, no chat list (`u_relog.mp4`); `BOX_PREVIOUS_LIFE_RETIRE` 15:52:32, `BOX_REVOKED_QUEUES_RETIRED {held: 5, owed: 0}` 15:52:35, link at 15:54;
  - bug above, fixed, rebuilt: device 43 → 45, box up 4 s after the link, F's u4 `frames: 4` reached it; ap5 went after sibling 32 swapped (ghost 39 revoked first).
- Drive 2 (web build of `80b98d53` + same APK, 11-04 16:40–17:10; throwaway dev account `r208a` id 283, phrase in `v_phrase.txt`):
  - owed deletes: stale tab, backend `docker pause`d at boot → `BOX_REVOKED_QUEUES_RETIRED {held: 3, owed: 3}`, `boxgone_v1` row written; unpause → stale phrase restore → `E2E_FRESH_DEVICE_LIFE`, then `BOX_OWED_QUEUES_DELETED {deleted: 3, owed: 0}`, row gone;
  - stale phrase restore (other tab): `RESTORE_STALE_MATERIAL_DISPOSED` + `E2E_FRESH_DEVICE_LIFE`; keyless restore (fresh origin): neither logged;
  - reset on a stale tab (no phrase, `deadlineAt` aged by SQL): `IDENTITY_RESET_SPEND {shape: mismatch}` → `E2E_FRESH_DEVICE_LIFE` → `RESET_STALE_MATERIAL_DISPOSED` → device 11;
  - voice note on the phone: `281474976710691.audio` cached → unlink, re-link → `audio_cache` gone → next note `…698.audio` (ids still rising);
  - `openProvisioning`: stale gate booted with the backend paused shows no code; code appears 4 s after unpause.
  - Web linking needs installed mode: CDP init script `navigator.standalone = true`.
- Evidence: `%TEMP%/p4s4drive/evidence/w208r/` (`u_*`, `v_*`).
- NOT verified on a device: lock-only restore (needs `identityUploadLocked`); a reset whose teardown throws (needs fault injection); `onSessionLost` with a provisioning open in flight while the socket drops (drive 2 covered only "sent before the socket was ready"); web-push endpoint teardown; a real FCM wake (dev has no service account); iOS PWA, prod, release APK.
- Seen, not changed: the contact-backup prompt ("Chroń swoje kontakty") opens on top of the link gate on web.

## Notes for next session
- Next action: owner OK for 0.2.74 — backend (decision 125) + web + APK; then `production-vm-deploy`.
- Owner-owed: the 0.2.74 OK; 0.2.73 on his phone; the step-4 both-ways test; copying `backup.pass` off the VM.
- Still open: #206, #204, Phase 4 step 5. #208 stays open until it ships.
- Residuals: a new device sends `own_uncovered` until every live sibling swapped with it (a ghost sibling blocks it for good: revoke it); a logged-out, unrevoked device is a silent sibling.
- Recipes: re-link drives need PASSWORD logins; type the phone's code on the web primary; one `input keyevent` call per field, re-read the EditText bounds after the first (the keyboard moves the form); the hacker-mode live log is an inner list — swipe inside it; a snapshot emulator may hold an old RELEASE app (`dumpsys package` → `pkgFlags` lacks DEBUGGABLE, screencap empty).
- Traps (in `traps.md`): new device cannot send until every sibling swapped; adb typing a long code ANRs; per-char adb typing scrambles; re-link drive needs password logins.
