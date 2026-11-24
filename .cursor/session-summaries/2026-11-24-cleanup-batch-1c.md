# 0.2.96: cleanup batch 1c, the remaining races and two cross-account key leaks fixed behind failing tests

**Date:** 2026-11-24 · **Version:** 0.2.95 → 0.2.96 · **Tiers deployed:** both (+ APK 20096)

## What was done
- PR #278 (`88a024e9`), 37 findings fixed, each behind a red test: BOX-03 (sibling latch), BOX-04/05/06/17, CONN-02/03/05/17, CONT-03/06/07/08/09/10/11/12, UI-08/10/11, WEB-01/02/05, BE-03/05/06/08/20/29, ENC-03/05/06/08/11. Per-finding detail: audit doc §5 and `.planning/cleanup/batch1c/rows.md`.
- BE-05: migration `0031_users_lower_username_unique.sql` (unique index on `LOWER(username)`); `UsersService.create` answers the index's 23505 as "nickname taken".
- EC-15 (found by the device drive, in every release up to 0.2.95): `EncryptionService.initialize` now drops `_keysForUpload`/`needsKeyUpload` when the account changes. Before: A → logout → register B → logout → login A in one app run uploaded B's bundle under A.
- EC-16 (found by the second review): `EncryptionProvider.clearAll` drops the stashed one-time pre-keys (`_dropStashedOneTimePreKeyUpload('account_change')`).
- WEB-05: the padlock tap is broadcast to other tabs (`BroadcastChannel('fireplace-passcode-lock')`); auto-lock and logout are not.
- Parked, no code (audit EC-13, EC-16): BOX-03 friend half, BOX-07, BOX-09, BOX-18, CONN-04, CONT-04, CONT-11 second half, WEB-03, WEB-04, ENC-04; an adopt (`adoptProvisionedIdentity`/`adoptRestoredIdentity`) outliving its account; the CONT-03 send marker.
- Out of repo: local stack `fp1c` removed with its volume; worktrees `fireplace-1c-*` and branches `cleanup/1c*` removed; the emptied folder `Desktop/fireplace-1c` could not be deleted (long paths); emulator app uninstalled, emulator stopped; VM `.env.bak.pre-apk-0.2.96` left on the VM.
- Xiaomi: this session uninstalled `com.fireplace.app` from it and left `screen_off_timeout` at 1800000 (normal 60000). The owner then said another agent is using the phone: nothing was restored.

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/encryption_provider.dart`, `frontend/lib/providers/friends_provider.dart`, `frontend/lib/services/box/*`, `frontend/web/web-push-sw.js` (SW_VERSION 6), `backend/src/users/users.service.ts`, `backend/src/users/user.entity.ts`, `CLAUDE.md` (test counts), `docs/plans/2026-11-23-cleanup-audit.md` (EC-13..16, O-11), `docs/contracts/wire.md`, `docs/agents/traps.md`.
- New: `backend/migrations/0031_users_lower_username_unique.sql`, `frontend/test/providers/encryption_provider_otp_stash_account_test.dart`, the red tests of each finding.
- Read only (load-bearing): `docs/plans/2026-11-23-cleanup-program.md`, `docs/plans/metadata-privacy-decisions.md` (70, 150).

## Verification
- CI: 13/13 success on PR head `38468ace`; on master `88a024e9` every `ci.yml` row success (12 rows listed when checked; the CodeQL row had not appeared yet).
- Tests: backend 926 unit / 56 suites, 82 int (private Postgres); Flutter 3537 passed / 16 skipped (count script). Backend ESLint ratchet PASS 252/252, knip clean, `verify-no-user-logs` OK. Dart ratchet reads 2479 locally vs floor 2478 (known local +1; CI analyze green).
- Review: two-axis review plus a second pass on the follow-ups; every BLOCKER/SHOULD applied.
- Deploy: backup offsite 3/3 before and after; migration dry-run in a rolled-back transaction on prod, then 0031 applied at boot; `/version` 0.2.96 / `88a024e9` / APK 20096; served APK hash = built hash (`0c9d820d…`); web smoke PASSED (script and `deploy-web.ps1`).
- Local drive (debug APK emulator + Xiaomi, web): table in `.planning/cleanup/batches.md` "1c drive" (BE-05/06/20, reconnect, edit, mute, account switch, two-tab lock, device link, web ↔ phone).
- Live drive (0.2.96 release APK on emulator + live web in Chrome; the Xiaomi was NOT used):
  - A → logout → register B → logout → login A, twice: A's `key_bundles` row unchanged, 0 `identity_change_audit` rows.
  - A new web account invited A; A accepted; text both ways.
  - Crossed request, taps about 120 ms apart: both sides "czat gotowy" with no manual accept; a message arrived. An earlier attempt was not simultaneous (one side got an ordinary request; manual accept worked).
  - 4 throwaways deleted through the app; prod users = 31.
- NOT verified on a device: BOX-03, BOX-17, CONN-17, CONT-03/08/10/11/12, UI-08/10/11, WEB-01, WEB-02, BE-03, BE-08, BE-29, ENC-03/05/06/08/11, EC-16 (fault or sub-second timing: tests only). The release APK on a real phone. WEB-05 on live. iOS.

## Notes for next session
- Next action: batch 2 (dead code) by the same method (tool flag + LSP references + no dynamic use; persisted keys and wire names are never dead). Include the `getMessages` shim (O-7) and a review of the other per-account fields of `EncryptionService` that an account change does not clear (listed in EC-15).
- Before batch 2: when the Xiaomi is free, install `Desktop/umbra-0.2.96.apk`, drive login / cold start / one message, and set `screen_off_timeout` back to 60000.
- Owner-owed: none. Release B due on or after 2026-12-08.
- Leftovers: `Desktop/fireplace-1c` (empty tree, long paths), `Desktop/fireplace-b7`, worktree `fireplace-drive`, exited Docker projects `fireplace-b7`, `fireplace-drive`, Chrome profiles `chrome1a`, `chrome1b`.
- Not in any batch: the 6th account delete within an hour closes the dialog and leaves the account (throttle 5/h per IP; whether a toast shows was not checked).
- Recipes: `.planning/cleanup/batches.md` "1c drive" (web clicks, link code, recovery words, register throttle).
- Traps (also in `traps.md`):
  - `EncryptionService` and `EncryptionProvider` are process singletons: every per-account field must be cleared on an account change.
  - Gboard autocorrects a link code typed on the phone.
  - `verify-no-user-logs.mjs` scans `*.int-spec.ts` too.
  - Agents sharing one worktree sweep each other's files into commits.
  - A device seen in `adb devices` may be in use by another agent.
