# 0.2.109: failed-link rollback, key-replaced warning after unlock, saved copies deleted on wipe, note status without login, composer document toast and background recording, 30-day notices

**Date:** 2026-11-26 · **Version:** 0.2.108 → 0.2.109 · **Tiers deployed:** both (+ signed APK)

## What was done
- A3-SVC-B-1: `EncryptionService.adoptProvisionedIdentity` writes a marker `e2e_<uid>_link_unsettled_v1` holding the adopted identity's public key, rolls back every write on a failure, and `initialize` discards an unsettled adopt only when the stored record matches the marker; `settleProvisionedIdentity` clears it after the server confirms; restore and mint paths delete the marker first.
- A3-SVC-A-2: server "own identity replaced" reports are held as `(occurredAt, replacedTo)` until `initialize` ends and replayed through `recordOwnIdentityReplacedFromServer` (dismissal watermark and the one-shot own-publish flag honoured). A3-SVC-A-3: a refused acknowledge clears only its own rebuild entries (`clearSessionRebuilds(peerId, addresses)`). A3-SVC-C-2: `removeDecryptedContent` waits for in-flight saves; `_replaceBoxRow` skips a deleted message. A3-SVC-D-04: three tests pin `revokeForPasscodeLock`.
- A3-MSG-A-04 (owner decision): saved copies go to `<documents>/saved_downloads/`, deleted on logout, account delete, revoked-device logout, "delete all local messages" and the local-store erase; legacy `image_<id>.<ext>` files removed. Old document downloads with the sender's file name stay (not identifiable).
- A3-MSG-B-04 (decision 151): `GET /note/:token/status` lost its JWT guard; the client sends no headers.
- A3-CMP-05: `sendFileMessage` returns `bool`; the toast follows it. A3-CMP-04 (owner OK): `recording_controller.dart` discards a recording on `paused`/`hidden`, also when the start finishes while away; the cancel notice shows on resume.
- 30-day notices (owner decision): line on Privacy & security, warning on the storage-loss restore screen and the restore row.
- Dart lint floor lowered 2482 → 2478 (`scripts/dart-lint-baseline.json`).
- Out-of-repo: worktrees `fp11-*` and their branches deleted; VM `.env.bak.pre-apk-0.2.109` left beside `.env`; emulator-5560 has no Umbra installed; no real phone touched (the only phone adb saw, Samsung `R58M87CFHBD`, had the Dzwonek app in front).

## Key files
- Edited: `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/auth_provider.session.dart`, `frontend/lib/providers/messaging_provider.send.dart`, `frontend/lib/widgets/input/recording_controller.dart`, `attachment_handler.dart`, `frontend/lib/utils/download_utils_io.dart`, `frontend/lib/screens/privacy_safety_screen.dart`, `backend/src/secret-notes/secret-notes.controller.ts`, `docs/plans/metadata-privacy-decisions.md` (row 151), `frontend/docs/composer-media.md`, `CLAUDE.md` (counts).
- New: `frontend/test/services/device_link/adopt_rollback_test.dart`, `frontend/test/utils/download_utils_io_test.dart` and the tests beside each fix.
- Read only (load-bearing): `.planning/cleanup/scouts2/R11Svc.md`, `R11Ui.md` (reviews), `.planning/cleanup/keychange-B-design.md`.

## Verification
- CI: 13 rows success on master `f9bae96d` (run 45736443375). PR #315 head `334569ba`: 15 success + `Publish the GitHub release` skipped.
- Local: Flutter `+3810 ~14: All tests passed!` (CI count 3823 / 1 skipped); Dart ratchet 2478; backend 902 / 57 (count script OK); backend lint ratchet PASS.
- Release: backup `chatdb-20261126T012132Z` (3/3 on R2) → backend first → tag `v0.2.109` → web `SMOKE PASSED` → APK SHA256 `31abd901fe4705f672d60ff93a4953f2325ac03449fa4e2be3bbf9fec8df2da6`, served file hashes the same; `/version` android 20109; post-deploy smoke PASSED; users 31.
- Local drive (emulator + web): `.planning/cleanup/batches.md` "Batch 11" (document toasts, recording + HOME, both notices, saved copy gone after wipe and after logout, note flip, delete-for-everyone after restart).
- Live drive on prod (signed APK on emulator-5560 + live web, throwaways `rel109a/b/c` deleted in-app): small PDF "Dokument wysłany!", 26 MB PDF "Nie udało się przesłać"; recording + HOME shows "Nagrywanie głosu anulowane", nothing sent; note from the phone revealed on web, both cards "Notatka zniszczona"; unauthenticated `curl /note/<token>/status` answers 200.
- A3-MISC-3 (from 0.2.108) now checked live: the 0.2.108 APK shows the update banner for 0.2.109.
- NOT verified: any real phone; iOS; a web tab going `hidden` mid-recording (the drive Chrome never reports it); a recording started while the app goes away; the restore-screen warning; account-delete and revoked-device paths of the saved-copy delete on a device; A3-SVC-A-2, A-3, B-1 on a device (tests only).

## Notes for next session
- Next action: P3 rows of `.planning/cleanup/findings.md` (A2-AUTH-05/06/07, A2-CON-4..7, A2-DEV-03..10, A2-SET-4/5/6, A2-ENC-A-1/2/3, A2-ENC-B-02..05, A2-ENC-C-4/5), test-first in a fresh worktree.
- Owner-owed: key-change behaviour is ON HOLD by his choice (options: a "Verified" mark only, or the mark plus auto-accept for unverified friends with a PERMANENT note; separate release either way; design in `.planning/cleanup/keychange-B-design.md`; auto-accept partly reverses decision 143).
- Open, not fixed: R11Svc S2 (a second web tab discards an unsettled link; needs a Web Lock); `_clearBoxQuotes` can re-create a deleted record like the fixed `_replaceBoxRow`; after "delete all local messages" the open chat shows old rows until restart; A3-CMP-08, UI-13.
- Trade-off shipped: a crash between the server confirming a link and the settle makes the phone start unlinked; the user links again and removes the stale device row.
- Traps: five lines added to `docs/agents/traps.md`.
