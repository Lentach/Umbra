# 0.2.108: third-pass fixes (notes, media, key wipe, account pinning) and composer targets scoped to their chat

**Date:** 2026-11-26 · **Version:** 0.2.107 → 0.2.108 · **Tiers deployed:** both (+ signed APK)

## What was done
- Anti-Quantum Note sheet (A3-MSG-B-01/02/03/05): in-flight guard, not closable while decrypting (`showGlassSheet(enableDrag: false)`), unknown-outcome / server-error / 429 states, long-press preview shows the card label instead of the link.
- Media (A3-MSG-A-01/03): fullscreen video closes on expiry or delete without a double pop; a failed voice note has Retry (`failed_send_retry.dart`, re-sends the same row through `_sendMediaOverBox`).
- Keys and purges (A3-SVC-D-01/02): `clearAllKeys` finishes every stage and logs `KEY_WIPE_INCOMPLETE`; sweep, drain and `purgeConversations` are pinned to the account they started under (`forUser` / `account:`).
- Misc: only the chat closes after unfriend (A3-MISC-1); repeat-password field (A3-MISC-2); the update URL is accepted only when `https` and on the API host (`ApkUpdateService._isOwnHttpsUrl`, A3-MISC-3); `notifyConvStrippedUrl` (A3-UTL-01).
- Composer (A3-CMP-01/02/03, owner OK 2026-11-25): every send site reads the reply target through `_replyTargetIn(conversationId)`; `_installChat` drops a foreign reply or edit target; `recording_controller.dart` binds a recording to `_recordingConversationId` and discards it on a chat switch.
- Flaky test fixed: `privacy_safety_diag_copy_test.dart` asserted no `'31'` in a line that carries the clock.
- Owner decision recorded: the 30-day local retention is intended (A3-SVC-C-1 closed, not a bug).
- Out-of-repo: worktrees `fp9-int`, `fp10` and branches `fix/third-pass-batch`, `fix/composer-targets` deleted; VM `.env.bak.pre-apk-0.2.108` left beside `.env`; emulator-5560 has no Umbra installed; the Xiaomi was not touched.

## Key files
- Edited: `frontend/lib/providers/messaging_provider.send.dart`, `messaging_provider.dart` (`_installChat`), `frontend/lib/widgets/input/recording_controller.dart`, `frontend/lib/widgets/message/anti_quantum_note_*.dart`, `frontend/lib/services/encryption_service.dart` (`clearAllKeys`, purge passes), `frontend/lib/services/apk_update_service.dart`, `frontend/pubspec.yaml`, `CLAUDE.md` (count 3774).
- New: `frontend/lib/widgets/message/failed_send_retry.dart`, `frontend/lib/utils/notify_conv_url.dart`, `frontend/test/widgets/message/voice_message_retry_test.dart` and the tests beside each fix.
- Read only (load-bearing): `frontend/docs/composer-media.md`, `.planning/cleanup/findings.md`, `.planning/cleanup/batches.md` (Batch 9, Batch 10 drive tables).

## Verification
- CI: 13 rows success on master `8c963615` (run 45718114391). Before the merge PR #313's head `9320549d` (with #314 merged in): 15 success + `Publish the GitHub release` skipped.
- Local: Flutter suite on the combined branch `+3761 ~14: All tests passed!` (CI count 3774 / 1 skipped); Dart lint ratchet 2471 (baseline 2482); backend untouched (899 / 57).
- Release: backup `chatdb-20261125T230151Z` (3/3 on R2) → backend `0.2.108 / 8c963615` → tag `v0.2.108` → web `SMOKE PASSED` → APK built in CI, signed on the PC, SHA256 `a1e3cfcf4b2871d80c6b00dc0887985c11d7262ef6207d19e79144afecafe11d`; the served file hashes the same; `/version` android 20108; post-deploy smoke PASSED; users 31.
- Live drive on prod, signed APK on emulator-5560 + live web in Chrome, throwaways `rel108a/b/c` (all deleted in-app): invite and accept; reply from the phone quotes on both sides; voice note phone → web; note sent from the phone, long-press preview on web shows "Notatka antykwantowa", reveal shows the text, both sides then show "Notatka zniszczona"; password change on web refuses a mismatch ("Hasła nie są takie same"), accepts a match, signs out, new password signs in and sends.
- Update path: the old 0.2.107 APK shows the banner "Dostępna jest wersja 0.2.108". This proves the 0.2.107 client, NOT the new URL guard (the guard runs in 0.2.108 and first meets a real update at 0.2.109).
- Local drive of the composer fixes (two chats, web desktop width + emulator): `.planning/cleanup/batches.md` "Batch 10".
- NOT verified: Xiaomi and any real phone; iOS; the 120 s auto-send; photo/GIF/file/video with a stale reply target (tests only); leaving a chat and returning on a phone; the "recording cancelled" notice; the note error states (429, server error) on a device; `KEY_WIPE_INCOMPLETE`; fullscreen video closing on expiry on prod.

## Notes for next session
- Next action: next batch of open rows that need no owner call, test-first in a fresh worktree: A3-SVC-A-2, A3-SVC-A-3, A3-SVC-B-1, A3-SVC-C-2, A3-SVC-D-04, A3-CMP-04 (composer: needs owner OK). Owner-class first: A3-MSG-A-04 (saved files stay as plaintext), A3-MSG-B-04 (note status poll with the JWT; read `docs/plans/metadata-privacy-decisions.md`).
- Owner-owed: key-change behaviour A/B/C (B recommended); a 30-day notice in Privacy & security and on the restore screen; OK for A3-CMP-04/05.
- Review leftovers not applied: `clearDecryptedContentCache` and LRU eviction call `markRetired` / `forgetDecryptedMany` unpinned; `KEY_WIPE_INCOMPLETE` reports `content.left: 0` when enumeration throws; `isAntiQuantumNoteUrl` vs `isOwnOriginNoteUrl` differ in chat list / reply quote / pinned banner; back arrow during a recording shows the cancel toast.
- Behaviour changes users can see: the reply bar is dropped when leaving a chat; a recording is discarded on a chat switch.
- Recipes: drive tooling in `.planning/cleanup/drive/` (`adbui.py`, `serve.mjs`); live web needs a hand-started Chrome with `--remote-debugging-port`.
- Traps: see the seven lines added to `docs/agents/traps.md` (Composer, Deploy, Tests, Agent tooling).
