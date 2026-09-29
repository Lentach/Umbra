# G5 whole-effort review: step-B blocker fixed, decision 68 reverted, chat list keeps box messages

**Date:** 2026-09-29 · **Version:** 0.2.52 unchanged (fixes on top, not yet deployed) · **Tiers deployed:** none

## What was done
- Review of release N (`14c1f22d..5c18cdf0`) by 5 read-only reviewers: backend step A, box client vs absent `/box`, vendored libsignal, messaging seams, audit of `3b470dac`. libsignal fork: correct (2 patches, E49a). `3b470dac`: no leftover mutant, no lost edit.
- `backend/src/box/box.service.ts:markSubscribed`: an owner subscribe on/after the probation day establishes a queue (E65a). Before, only an ack did, so a full open band kept every queue on probation for good (step-B blocker).
- `chat-search.service.ts`: with the box off, a stranger search serves no devices and claims no OTP (E66a); drive showed step A spending one per search.
- Decision 68 client behaviour reverted to pre-G5; 68 is now an accepted residual. Its deferral lived in RAM only, so convergence needed a reconnect.
- `sendBoxFriendRequest`: E2E-not-ready falls back to the old path. Typing follows `_boxRoute`'s peer half (partly covered friend), via `_boxCoversPeer`.
- `EncryptionService._cachedWireClaims`: single-flight scan, stamps saved during it are merged; the old generation-check survivor now has a killing test.
- Chat list (`ConversationsProvider.onConversationsList`, `applyStoredBoxLastMessages`): box messages stay the last message, order and unread across a reconnect (found driving). Residual E69c: box badges are RAM-only across an app restart.
- Out of repo: staging stack UP with box ON on image `fireplace-staging-backend:latest` = 36451db8 (RC kept as `:rc`); staging-only accounts g5_eve (39), g5_fay (40) (re-register if their dummy password is lost); `%TEMP%/g5/web-fix`, `web-list`; `adb reverse tcp:3100`; fixer worktrees removed.

## Key files
- Edited: `backend/src/box/box.service.ts`, `backend/src/chat/services/chat-search.service.ts`, `frontend/lib/providers/conversations_provider.dart`, `frontend/lib/providers/messaging/messaging_provider.{box,send,first_contact,history}.dart`, `frontend/lib/services/box/box_{friends,friend_handoff,session}.dart`, `frontend/lib/services/encryption_service.dart`, `frontend/lib/providers/connection_provider.dart`.
- New: `frontend/test/services/encryption_service_wire_claims_test.dart`, `frontend/test/providers/messaging_provider_box_list_test.dart`.
- Docs edited: decisions E65b, E66a, E69a (step B = flip + second restart), E69b (step B is one-way), E69c, row 68; `docs/agents/traps.md` (step-B rollback line); `docs/contracts/wire.md`; `frontend/docs/e2e-invariants.md`, `client-reference.md`.
- Read only (load-bearing): `docs/plans/metadata-privacy-decisions.md` (64–69), `docs/contracts/wire.md` Items 5–8.

## Verification
- CI: see Notes (pushed `85e3a490`).
- Backend on `36451db8` tree: tsc clean; Jest 1222/68; int 50/50 (one run had 1 failure under heavy parallel load, rerun alone 50/50, test not identified); ESLint ratchet 850 held; knip, box-imports, no-user-logs OK.
- Flutter on `85e3a490`: analyze 3156 infos (Dart ratchet held); 3033 passed / 14 skipped; count verifier OK.
- Mutants: all killed. FixClientFallbacks M1 (drop `isE2EReady`) is equivalent, because `ownLiveDevices` also checks it. FixRevert68 M3/M4 survived the restored tests; tests were added and they kill both now.
- Staging drives (release web builds, :3100):
  - Box off, RC: friend search → `[]`, no OTP spent; a stranger search spent 1 OTP (→ E66a). Fix build: stranger search `devices: []`, OTP 20|0 unchanged; invite on the old path, chat both ways.
  - Flip without reload: `40/box,` ok within 1 s of the backend's return, request queues published. The pair stayed on the server with a false "older version" notice; a second restart moved it onto the box (0 new `messages` rows) → E69a.
  - Box off after step B: a covered send fails with "Ponów", then goes through once the box is back → E69b.
  - List preview: RC reverted to the server row after a restart; the list-fix build keeps preview, order and badge across a restart.
  - Emulator APK (RC debug) played the history voice note after upgrade: AAC decoded ~33 s. The label read `0:00/0:00` after play; the player code is unchanged since 14c1f22d.
- NOT verified: history import timing (native-only per review, not driven); old APK decision-66 UI (server answer is client-independent); typing to a partly covered friend (tests only); deferred re-key paths (reverted); release-signed APK; FCM; iOS; prod.

## Notes for next session
- Next action: once CI is green on `85e3a490`, get the owner's go, then ff master from `fireplace-0a` and redeploy prod backend (`deploy-backend.sh`, box stays OFF) and web (`deploy-web.ps1`, smoke `--commit`). Then publish the 0.2.52 APK from the main checkout (NEXT.md recipe of 6adf09b4 still holds).
- Step B runbook additions: flip, then a plain backend restart ~2 min later (E69a). Never set `BOX_ENABLED=false` afterwards (E69b). Week-one `box_totals` / ceiling-refusal watch (E65b). Then the FCM check (69).
- Owner-owed (delegated calls; may overrule): 68 is now a residual; E69c (no box badge after restart) is accepted for N, and its fix needs a per-chat "seen" marker in N+1.
- Recipe: in the browser device, only the FRONT tab paints. `page.bringToFront()` before typing, `page.keyboard.sendCharacter` for text, and the send button, not Enter.
- Traps: step-B rollback line added to traps.md § Deploy.
