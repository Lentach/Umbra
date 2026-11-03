# #208: a re-linked device starts fresh and no longer breaks the primary's sends

**Date:** 2026-11-03 · **Version:** unchanged (0.2.73 on prod; fix unreleased) · **Tiers deployed:** none

## What was done
- `EncryptionService.adoptProvisionedIdentity` now wipes the whole `e2e_<uid>_` namespace via `_wipeAccountNamespace`: secure storage, the content kv and plain prefs (`boxsync_v1`), stamp last. The wipe must be proven; otherwise `LINK_RESIDUE_DISPOSAL_DEFERRED` and the ceremony aborts. The §6.2 reset disposal wipes it too.
- `EncryptionProvider.prepareFreshDeviceLife` → `ConnectionProvider._startFreshDeviceLife` runs before adopt: it stops the box, closes the store and empties the lists. Then `ContactBackupService.restartForEmptiedStore` re-arms the restore.
- Previous device life = stamp != stored session device id (`checkPreviousDeviceLife`). `AuthGate` keeps `MainShell` Offstage behind `BootHoneycomb` until the check has run, and E2E init refuses to start while it holds.
- `ContactBackupService.mayPublish = !needsDeviceLink`: a gated install never overwrites the backup.
- `BoxFriendHandoff._handoffTargets`: on an enrolled account, a held friend address with no session behind it goes via the friend device's request queue. This fixes `prekey_unasked`, which left the re-linked device receiving nothing.
- `LinkCeremonyController.onSessionReady` re-sends `openProvisioning` for a new-device flow still `opening`.
- Copy (pl/en): `devicesRevokeExplainer`, `linkGateStaleBody` and `siblingSilentBody` now say a re-linked device starts fresh.
- Out-of-repo:
  - the emulator's release 0.2.71 app was uninstalled; the debug APK is installed;
  - `git worktree prune` dropped stale metadata of the already-missing `fireplace-0a`, `fireplace-reactions`, `fp-g5-master` and `fp-lint-scratch`;
  - temp worktrees `w208*` were deleted.
  - Dev stack left running.

## Key files
- Edited:
  - `frontend/lib/services/encryption_service.dart`, `providers/encryption_provider.dart`, `providers/connection_provider.dart`, `main.dart`;
  - `services/device_link/link_ceremony_controller.dart`, `services/contacts/contact_backup_service.dart`, `services/box/box_friend_handoff.dart`, `services/box/box_session.dart`;
  - `screens/devices_screen.dart`, `screens/device_link_gate_screen.dart`, l10n arb + generated files;
  - docs: `frontend/docs/e2e-invariants.md` (#208 bullet), `docs/design/multi-device.md` amendment (xc), `docs/agents/traps.md`, `CLAUDE.md` §3 count, `scripts/dart-lint-baseline.json` (3130).
- New: `frontend/test/services/device_link/relink_fresh_start_test.dart`.
- Read only: `providers/messaging/messaging_provider.box.dart` `_boxRoute` (`own_uncovered`).

## Verification
- CI: 6/6 success on `63764ec8` (backend, Flutter, E2E wire, isolated probes, Web Lock probe, CodeQL).
- `flutter test` 3315 passed, 14 skipped; verifier OK. Dart lint ratchet 3131 → 3130; `flutter analyze` 0 warnings/errors. Targeted suites after the lint fixes: 85 passed.
- Mutants killed:
  - adopt doing a Signal-only wipe;
  - previous-life init gate removed;
  - `_notePreviousDeviceLife` no-op;
  - restart without `onSession`;
  - handoff keeping the held address;
  - handoff ignoring the session;
  - `mayPublish` ignored.
- Prod read-only SQL (owner OK): bob208 devices 1/11/18; 18 reused 11's `requestSid`; no "karol" account exists (132 deleted 10-27), so the invitation was stale local residue.
- Dev web drive, before the fix: chat-list flash, old frames, primary `own_uncovered`. After the fix:
  - revoke → logout;
  - gated device got nothing; the primary got it;
  - cold boot → honeycomb → gate;
  - re-link → 3 contacts, no history;
  - messages both ways; primary ✓.
- Android emulator (debug APK, Pixel_7 API 34):
  - link → revoke → instant logout;
  - password login → honeycomb → stale gate, every changed frame checked in screenrecord;
  - cold boot → gate;
  - fa22 sent while gated reached only the primary;
  - re-link (device 27) → 3 contacts, no history;
  - fa25 reached it; its af24 reached F after the retry below;
  - primary qa27 ✓ with the phone linked.
- NOT verified: iOS PWA, prod, release APK.

## Notes for next session
- Next action: ask the owner for the OK on release 0.2.74 (pubspec bump, web + APK; backend unchanged), then follow `production-vm-deploy`.
- Owner-owed:
  - the 0.2.74 OK;
  - 0.2.73 on his phone;
  - the step-4 both-ways test;
  - copying `backup.pass` off the VM.
- Still open: #206, #204, Phase 4 step 5. #208 stays open until it ships.
- Residuals (not fixed, in the docs):
  - old queues are not deleted on the box;
  - a logged-out, unrevoked device is a silent sibling;
  - a brand-new install shows the chat list for a few seconds before the gate;
  - a new device sends `own_uncovered` until every other live sibling has been online once. Seen: af24 red until web device 22 opened.
- Recipes:
  - re-link drives need PASSWORD logins on both devices;
  - on Android, type the phone's code on the web primary ("Wpisz kod ręcznie"); the code is in the uiautomator dump;
  - friend-handoff evidence is in the F tab's hacker-mode RAM log;
  - the Android flow log is `adb logcat -s flutter:I`.
- Traps (in `traps.md`):
  - a new device cannot send until every sibling has been online once;
  - adb typing a long code ANRs the debug app.
