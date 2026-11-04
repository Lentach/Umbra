# #208: a re-linked device starts fresh and no longer breaks the primary's sends

**Date:** 2026-11-03 → 11-04 · **Version:** unchanged (0.2.73 on prod; fix unreleased) · **Tiers deployed:** none

## What was done
- Round 1 (`63764ec8`): a link adopt wipes the whole `e2e_<uid>_` namespace; a previous device life (stamp != stored session id) shows the link gate from the first frame and E2E init refuses before any publish; a gated install never publishes the contact backup; the friend handoff uses the request queue; copy says a re-link starts fresh.
- Review round (two-axis `code-review`, owner: fix everything) — `EncryptionService._wipeAccountNamespace`: secure storage then kv, every `remove` checked, stamp deleted LAST only when proven; keeps `ContactStore.localIdCounterKey` (decision 14, no cache-id reuse).
- `adoptProvisionedIdentity` / `adoptRestoredIdentity` take `beforeWipe`, run after the blob parses → `EncryptionProvider.prepareFreshDeviceLife` → `ConnectionProvider._startFreshDeviceLife`: old queues deleted (`retireRevokedDevice`, 10 s budget), shared `_releaseAccountState` (also logout), `BoxCatchUp.forget` (StateError if kept), voice cache cleared best effort.
- A stale phrase restore wipes the namespace too (owner); a keyless restore keeps its history.
- `BoxFriendHandoff._handoffTargets` keys on `friendAnswered` (`EncryptionService.hasAnsweredSession`: no unacknowledged pre-key), not "a session exists" — the box connect's prebuild had made the handoff go to the held address again and F refused it `prekey_unasked` (found driving).
- `LinkCeremonyController`: re-sends `openProvisioning` only if the first went before the socket was ready; a duplicate `provisioningOpened` is cancelled. One `linkGateway()` factory; `storedSessionDeviceId` has one reader; diags record stored session + material ids.
- Copy: `linkGateScanBody` (pl/en) adds "Połączenie zacznie to urządzenie od zera."
- Out-of-repo: emulator's release 0.2.71 app replaced by the debug APK; drive kit `%TEMP%/p4s4drive/h208.mjs`; temp worktrees `w208r`, `w208r2` removed at the end; dev stack left running.

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `providers/encryption_provider.dart`, `providers/connection_provider.dart`, `services/device_link/link_ceremony_controller.dart`, `services/box/{box_friend_handoff,box_session,box_catch_up}.dart`, `services/contacts/{contact_store,contact_store_inbox,contact_backup_service}.dart`, `screens/{device_link_gate,devices}_screen.dart`, l10n arb + generated, round 1 also `main.dart`.
- Docs: `frontend/docs/e2e-invariants.md` (#208 bullet), `docs/design/multi-device.md` amendment (xc), `docs/agents/traps.md`, `CLAUDE.md` §3 count; `scripts/dart-lint-baseline.json` 3130.
- Tests: new `test/services/device_link/relink_fresh_start_test.dart`; edited `connection_provider_box_test.dart`, `post_ceremony_refresh_test.dart`, `encryption_service_per_device_test.dart`, `box_session_friends_test.dart`.

## Verification
- CI: 6/6 success on `63764ec8` (round 1). Review round: see the follow-up line below.
- `flutter test` 3324 passed, 14 skipped (verifier OK); Dart lint ratchet 3130 PASS; `flutter analyze` 0 warnings/errors.
- Mutants, round 1: 7 killed. Review round: 7 mutants (M1–M7) on the new guards, each killed by its test, all reverted (grep `MUTANT` empty); the per-mutant list was not recorded before compaction.
- Drive A (web + debug APK, 11-03/04 00:xx): device unlinked while closed → friend's message only on the primary → password login → honeycomb → stale gate, no chat list (every frame of `and2_relog.mp4`) → re-link: `BOX_REVOKED_QUEUES_RETIRED {held: 5}`, `CONTACT_BACKUP_RESTORED {count: 3}`, no old messages; F `BOX_FRIEND_HANDOFF {acked, handedBack}`.
- Drive B (Android emulator, debug APK from the review tree, 11-04 02:2x–02:40), web primary 7 + web 32 + F:
  - fresh install: keyless gate shows the new copy; linked as 37 → 3 contacts; rf71 in, ap72 ✓ (`frames: 3`);
  - app closed, 37 unlinked on the primary: F's rf73 went `frames: 2` (7, 32); primary qa74 ✓;
  - relaunch → logged out (`refresh_invalid_after_access_401`); password login → honeycomb → stale gate ("stare wiadomości z niego znikną"), no chat-list frame (`d_relog.mp4`, 9 sheets checked);
  - re-link (SAS 735 238 on both) → device 39: `BOX_REVOKED_QUEUES_RETIRED {held: 6}`, `E2E_FRESH_DEVICE_LIFE`, `CONTACT_BACKUP_RESTORED {count: 3}`, `BOX_FRIEND_HANDOFF_SENT {viaRequest: true}`; empty chat; rf75 in, ap76 ✓, primary qa77 ✓ on all four.
- Evidence: `%TEMP%/p4s4drive/evidence/w208r/` (`d_*`).
- NOT verified: iOS PWA, prod, release APK.

## Notes for next session
- Next action: ask the owner for the OK on release 0.2.74 (pubspec bump, web + APK; backend unchanged), then follow `production-vm-deploy`.
- Owner-owed: the 0.2.74 OK; 0.2.73 on his phone; the step-4 both-ways test; copying `backup.pass` off the VM.
- Still open: #206, #204, Phase 4 step 5. #208 stays open until it ships.
- Residuals (not fixed, in the docs):
  - a new device sends `own_uncovered` until every live sibling swapped with it; once a connected tab swapped only after a reload, once at once — cause open;
  - a brand-new install shows the chat list for a few seconds before the gate;
  - a friend's push between revoke and link may go to a stale list (empty push);
  - queues the 10 s budget does not reach are left to the reaper;
  - a logged-out, unrevoked device is a silent sibling.
- Recipes: re-link drives need PASSWORD logins; on Android type the phone's code on the web primary; type into the debug APK with one `input keyevent` call; Android E2E diags live in Settings → Prywatność i bezpieczeństwo, long-press the big title → hacker mode, readable via uiautomator; fa21/fa23 story: `.planning/208-relink/findings.md`.
- Traps (in `traps.md`): new device cannot send until every sibling swapped; adb typing a long code ANRs; per-char adb typing scrambles; re-link drive needs password logins; a friend made while the backup is LOCKED misses the backup.
