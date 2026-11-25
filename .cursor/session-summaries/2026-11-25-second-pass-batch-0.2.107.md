# Second and third reading passes; 18 findings fixed and released as 0.2.107

**Date:** 2026-11-25 · **Version:** 0.2.107 · **Tiers deployed:** backend, web, APK

## What was done
- Two more read-only passes over the files the first audit never opened (16 readers: `encryption_provider.dart` and `encryption_service.dart` end to end, auth, contacts, device, settings screens, message widgets, media viewers, composer, `utils/`): 111 rows (1 P0, 6 P1, 33 P2, 71 P3). Reports and the table: the lead's `.planning/cleanup/scouts2/` and `.planning/cleanup/findings.md` (gitignored).
- PR #312 (squash `34cb4669`), owner's word "make sure everything checks out then merge and deploy". Every row had a failing test first and a mutant:
  - **A3-SVC-A-1** (live up to 0.2.106): with key-change warnings off, a server-reported identity change acknowledged whatever key sat in the pending slot (refusal-staged, held frame, compare screen) with no human step. Now only the key the local detection staged in that call is acknowledged; the server-event path writes the note only.
  - **A2-AUTH-01** (+ review blockers): nothing is marked read, no receipt and no countdown while the passcode lock is up. `ConversationsProvider.isClientVisible` consults `lockUp`; `MainShell` awaits the `evaluateOnForeground()` verdict before marking visible and marks the open chat read on unlock.
  - Recovery phrase: enrolment announced only on the server's `success: true`, pending phrase dropped on refusal / 10 s / logout / disconnect / passcode re-lock; back blocked while saving; clipboard cleared (A2-ENC-C-3, A2-AUTH-02/03).
  - Link gate: owed hello re-sent at session ready; a `p` code consumed only when the ceremony is on screen (A2-DEV-01/02).
  - Contacts: accepted row dropped when the friendship ends; "Wiadomość" on a wide window opens the chat; no double search, no stuck spinner (A2-CON-1/2/3).
  - Delete account: disconnect before the key wipe, no second run (A2-SET-1/2/3). Double Enter on sign-in (A2-AUTH-04).
  - Account switch: `_initEpoch` guard and `_identityIncomplete` reset in `EncryptionProvider` (A2-ENC-B-01, A2-ENC-C-1/2).
  - Owner decision: the copied diagnostic log carries no peer, conversation or device ids (`diag_export_redaction.dart`); TEMP session-inventory and persist probes removed.
- Out of repo: prod `.env` `ANDROID_APK_*` → 20107 / 0.2.107 (backup `.env.bak.pre-apk-0.2.107`). Worktrees `fp8-int`, `fp8-a`..`fp8-g` and their branches removed.

## Key files
- `frontend/lib/services/encryption_service.dart` (`_demoteKeyChangeIfMuted`, `_demoteLocalDetection`); `frontend/lib/providers/encryption_provider.dart` (`_initEpoch`, pending recovery phrase).
- `frontend/lib/screens/main_shell.dart`; `frontend/lib/providers/conversations_provider.dart` (`lockUp`, `isClientVisible`).
- `frontend/lib/utils/diag_export_redaction.dart`; `frontend/lib/screens/recovery_key_screen.dart`; `frontend/lib/screens/invitations_screen.dart`; `frontend/lib/services/device_link/link_ceremony_controller*.dart`.
- Tests: `frontend/test/services/encryption_muted_ack_candidate_test.dart` and the new files beside each fix.

## Verification
- Counts on the PR head: backend 899 / 57 suites (unchanged); Flutter 3692 / 1 skipped (local 3679 + 14 skipped). Dart ratchet 2473 against baseline 2482 (not lowered).
- Review, two reviewers (crypto, UI): crypto no blocker; UI two blockers in the lock fix (resume race; cold start / first connect counted as visible) and two SHOULD, all fixed test-first.
- CI by name: PR head `8e9e9ee1` 15 success + `Publish the GitHub release` skipped (one job failed in the Flutter setup action, exit 7, passed on re-run); master `34cb4669` 13 success.
- Local drive (stack `fp8`, debug APK on emulator-5560, branch web build in a wide browser window): messages both ways; read receipt baseline; passcode lock: single tick for 25 s on the lock screen, double tick after unlock; friend wiped + signed in: pill, accept, held message shown, send delivered; "Wiadomość" from the contact card; accepted row dropped after an unfriend and the handle found again; account switch with no link gate; recovery phrase enrolled with BACK pressed on confirm (rows `auth_v2`, emulator and Xiaomi); delete account with a double tap. Table: `.planning/cleanup/batches.md` "Batch 8".
- Release: backup `chatdb-20261125T201224Z.dump.gpg` (3 files listed on R2); backend + web `0.2.107 / 34cb4669`, web smoke PASSED; tag `v0.2.107`; unsigned SHA256 `4296eee33358d2f4375005e91912d29d9c282be0f3d05a3b1fee0f07dff4d206`; signed SHA256 `d257aacb7ce2d787a43ebfafe51afb58c2972ed9b4c78405b24cc66bfcec1461`, equal to the file served under `/apk/`; `/version` android 20107; post-deploy smoke PASSED; users 31.
- Live drive on prod, signed APK on the emulator against the live web, throwaways `rel107a`/`rel107b` (deleted in-app): read receipt baseline; lock screen up 45 s with the chat open underneath: single tick; unlock: double tick.

## Notes for next session
- **Next action:** ask the owner (a) is destroying every message 30 days after it was stored intended (A3-SVC-C-1); (b) OK to fix the composer-area rows A3-CMP-01/02 (reply or edit target follows you into another chat) and A3-CMP-03 (voice note goes to the newly opened chat on desktop). Without waiting, start the rows that need no owner call: A3-MSG-B-01/02/03/05, A3-MSG-A-01, A3-MSG-A-03, A3-SVC-D-01, A3-SVC-D-02 (failing test first), A3-UTL-01, A3-MISC-1/2/3.
- NOT driven: the signed APK on the Xiaomi (another project's app held the screen; see traps); link-gate `p` code; redact-on-copy; a cold start from a notification tap under the lock; the countdown of a disappearing message under the lock (only the receipt was observed); the web resume path under the lock; the hostile-server identity cases (tests only).
- Measured, not changed: a friend who reinstalls shows the sender the red "messages held" pill with warnings OFF on 0.2.106 and 0.2.107 alike, while the settings text says new keys are accepted by default. Owner call whether the text or the behaviour is wrong.
- During the Xiaomi drive one word of a throwaway LOCAL account's phrase, ENTER and BACK were sent while the other project's app may already have been in front; the enrolment landed in Umbra, where the BACK landed is unknown.
- Crypto review note N2 not applied: `_demoteLocalDetection(...).ignore()` drops a storage error silently.
- Split candidates, not approved: `chat-key-exchange.service.ts` (930 lines), `privacy_safety_screen.dart`, `messaging_provider.send.dart`; `encryption_service.dart` / `encryption_provider.dart` are the owner's decision.
- Owner-owed and Release B: unchanged from `2026-11-25-own-sender-label-0.2.106.md`.
