# Cleanup batch 4b: box provider file split into seven parts, auth folder cycles broken (BOX-23, BE-15)

**Date:** 2026-11-24 · **Version:** 0.2.101 → 0.2.102 · **Tiers deployed:** both (+ APK 20102)

## What was done
- **Structural only; behaviour and test counts unchanged** (898 unit / 56 suites; 3554 Flutter / 1 skipped). PRs #295, #296.
- **BOX-23 (#295):** `frontend/lib/providers/messaging/messaging_provider.box.dart` 2890 → 431 lines. New `part` files, one extension each: `messaging_provider.box_friend_read.dart`, `box_sibling_read.dart`, `box_store.dart`, `box_local_rows.dart`, `box_send.dart`, `box_media_send.dart`. No caller changed, no privacy widened.
- **BE-15 (#296):** refresh-token entity, service and module moved to `backend/src/refresh-tokens/`; `password-hash`, `jwt-secret` and the JWT guard moved to the leaf folder `backend/src/auth-core/`. Folder cycles `auth ↔ users` and `auth ↔ key-bundles` are gone. `scripts/verify-box-imports.mjs` forbids both new folders inside `box/`.
- **Left on purpose:** the `refresh-tokens ↔ users` folder cycle. Breaking it needs a behavioural change (entity relation, session revocation), which a structural batch may not make.
- **Batch 4c started (not in this release):** four more audited giant files, one branch each: `cleanup/4c-firstcontact` (CONT-19), `cleanup/4c-auth` (CONT-21), `cleanup/4c-chatdetail` (UI-29), `cleanup/4c-usercard` (UI-30). PRs #297–#299 are open for three of them.
- Out of repo: release APK 0.2.102 on emulator-5560 and the Xiaomi (vibrate, `screen_off_timeout` 60000); `Desktop/umbra-0.2.102.apk`; local stacks `fp4b` and `fireplace-staging` torn down; VM keeps `.env.bak.pre-apk-0.2.102`.

## Key files
- Edited: `frontend/lib/providers/messaging/messaging_provider.box.dart`, `frontend/lib/providers/messaging_provider.dart` (part list), `backend/src/auth/**`, `backend/src/users/**`, `backend/src/key-bundles/**` (imports), `scripts/verify-box-imports.mjs`, `frontend/pubspec.yaml`, `docs/plans/2026-11-23-cleanup-audit.md` (status line).
- New: the six `messaging_provider.box_*.dart` parts; `backend/src/refresh-tokens/`, `backend/src/auth-core/`.
- Read only (load-bearing): `.planning/cleanup/findings.md` rows BOX-23, BE-15; `.planning/cleanup/batches.md` sections "Batch 4b", "4b review", "4b drive", "4b release".

## Verification
- CI: 13/13 on both PR heads (#295, #296 `367ebbdb`); 12/12 on master `6ee15ffe`.
- Order-preserving line check on #295: every code line of each new file is found in master's original in order; only doc comments, `part of` lines and extension headers differ.
- Reviews (correctness + standards per PR): no blockers. #295: three mutants in moved code turned existing tests red. #296: the reviewer compiled the prod build and showed `verify-box-imports.mjs` fails for an import of either new folder.
- Gates: lint ratchets (backend ESLint, Dart 2482) and knip ran in CI on both heads and on master.
- Staging rehearsal (prod image of the merged code): booted healthy; wire harness 33 passed / 17 opt-in skipped.
- Local drive, merged build `c3983ed9`, emulator-5560 + Xiaomi + web:
  - register, invite, accept, text both ways; photo from the emulator's gallery arrived on the Xiaomi;
  - cold start; logout and login (refresh-token rows 2 → 1 → 2);
  - link ceremony with the web as device #2, same security code on both; a message to that account reached both devices; each device's own send appeared on its sibling;
  - backend log: 0 errors.
- Release: backup `chatdb-20261124T172716Z.dump.gpg`, offsite verified 3/3. Backend and web serve `0.2.102 / 6ee15ffe`; web deploy smoke PASSED. APK SHA256 `37e2c429eccac18940ff23114085813d8e7d1cce657b7c8712b649671b756006`; the served file hashes the same.
- Live drive with the release APK (emulator-5560 + Xiaomi): register ×2, invite, accept, text both ways, photo, cold start on both, message after. Both throwaways deleted in-app; users 31. `post-deploy-smoke.mjs`: SMOKE PASSED.
- NOT verified: iOS; the installed PWA on a real phone (web was driven in desktop Chrome, locally only); link ceremony on prod.

## Notes for next session
- **Next action:** finish batch 4c. Review and merge #297–#299, collect `cleanup/4c-chatdetail`, drive the merged build on emulator + Xiaomi + web (first contact, login/logout/cold boot, chat screen incl. composer send and scroll, user card), release 0.2.103.
- Then record a reason for the files over 1 000 lines that stay unsplit: `messaging_provider.dart` 1065, `messaging_provider.send.dart` 1013, `messaging_provider.box_actions.dart` 1012, `contact_backup_service.dart` 1005, `conversations_provider.dart` 1004, `hieroglyph_glyphs.dart` 1521 (paint data), `chat_input_bar.dart` 1649 (composer, owner's OK needed).
- Owner-owed: the eight questions in `docs/plans/2026-11-24-signal-grade-gap.md` §6; BE-12; UI-16/UI-17; the composer split; TD-07.
- Open finding from the 4b review (M1): the 97 box send tests do not fail if `_boxRoute` accepts a device list this connect did not look up; one receipts test does.
- Leftover worktrees to remove: `fireplace-4b` (built an APK), `fireplace-4b-box`, `fireplace-4b-be15`, plus branches `drive/4b`, `cleanup/4b-box`, `cleanup/4b-be15`.
- Drive recipes are in `.planning/cleanup/batches.md` ("4b drive") and `.planning/cleanup/drive/adbui.py`.
- Traps (also in `docs/agents/traps.md`):
  - Xiaomi: the recovery-word confirm button ignores taps after BACK closed the keyboard; press ENTER in the field.
  - The dev compose stack answers `/health` about 6 minutes after `up --build`; a refused connection before that is not a failure.
  - A fake that subclasses a provider stops intercepting any member a split moves into an extension; tests can stay green.
