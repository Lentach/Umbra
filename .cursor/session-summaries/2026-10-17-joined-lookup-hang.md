# A lookup joined across a reconnect can no longer hang a box send forever

**Date:** 2026-10-17 · **Version:** 0.2.66 → 0.2.67 (`28ac55af`) · **Tiers deployed:** both + APK

## What was done
- Field report: bob208's (37) box sends to SaraLee (63) and goonboy (48) stayed "sending" with no red dot and no tick. His diag log: `DEVICE_LIST_FETCH_EMIT {userId 37}` at 19:32:55 with no answer, an intentional reconnect at 19:32:57 with no new emit, then `SEND_START` with nothing after it from 19:33:13 on.
- Cause:
  - In `EncryptionProvider._fetchDeviceListAnswer`, only the caller that sent the request got a `.timeout()`. A caller that joined it waited on the shared completer with no time limit, and the timeout removed the map entry without completing the completer.
  - `ConnectionProvider.connect` step 7 replaces the socket without failing pending lookups, so the second connect's `BoxDeviceListRefresh` joined a request that was already lost.
  - `readyFor` never settled and never failed, so no retry was armed and `_boxRoute` waited forever.
  - The same flaw was in the pre-key fetch (`ensureSession`) and `_fetchBundleAnswer`. It dates from 2026-08-21 (`1461e9d1`).
- Fix, `encryption_provider.dart`: the new `_expireShared` makes the timer fail the SHARED completer, so the sender and every joiner fail together. It is used by all three maps and follows the `_checkServerIdentity` pattern.
- Fix, `connection_provider.dart` `connect()` step 7: it calls `_encryptionProvider?.onDisconnect()` when the socket is replaced, so the next lookup sends a fresh request.
- Out-of-repo changes:
  - Docker Desktop was started and the dev stack `fireplace` is up.
  - Throwaway worktree `../fp-hang` was removed.
  - `%TEMP%/dhang_*` bundles were deleted.
  - CDP Chrome (port 9461) was killed and the static server stopped.
  - The prod DB was read only, to map user ids to names; nothing on prod changed.

## Key files
- Edited: `frontend/lib/providers/encryption_provider.dart` (`_expireShared`, `ensureSession`, `_fetchDeviceListAnswer`, `_fetchBundleAnswer`), `frontend/lib/providers/connection_provider.dart` (`connect` step 7), root `CLAUDE.md` (test count).
- Tests:
  - `encryption_provider_device_list_test.dart`: a device-list joiner fails with the shared fetch.
  - `encryption_provider_test.dart`: a pre-key joiner fails with it (`fakeAsync`).
  - `connection_provider_socket_ready_test.dart`: a reconnect fails every pending lookup.
- Read only: `messaging_provider.box.dart` (`_boxRoute`), `box_device_list_refresh.dart`, `messaging_provider.dart` (`_boxLists`).

## Verification
- CI: green on `e415ce7d` (the fix) and on `28ac55af` (the 0.2.67 bump), master pushes. All 6 jobs `success` on each.
- Deploy (owner go):
  - Backup `chatdb-20261017T022831Z.dump.gpg`.
  - `deploy-backend.sh` → `/version` 0.2.67 / 28ac55af, healthy.
  - `deploy-web.ps1` → smoke 8/8, `main.dart.js` contains 28ac55af.
  - APK 20067: `build-android.ps1` signer + 16 KB gates OK. SHA256 `f2d8266532f5cf8ce88573458e97ab5634ad7a603fb613fd28ed3c6a6de8891e`, matched on the VM. Content-Length 52840329.
  - VM `.env` `ANDROID_APK_*` set to 0.2.67 (previous copy `.env.bak.pre-apk-0.2.67`), backend redeployed; `/version` android reads 20067.
  - 0 error/exception lines in the backend log 10 min after the deploy.
- Repro: all 3 new tests were RED on the unfixed lib files (stash A/B) and GREEN with the fix.
- Full Flutter suite: 3166 passed, 14 skipped.
- Dart lint ratchet held at baseline 3146. Two new `discarded_futures` in the test were wrapped in `unawaited`.
- Live drive, release web build against the dev stack, account F4 (user 255, origin 127.0.0.1:8094) sending to d101a:
  - Method: an init-script `WebSocket` subclass dropped the `getDeviceList` frame, the script closed every socket, and closed them again 2.5 s later.
  - 0.2.66 bundle: one emit was dropped, and after the second reconnect no new emit went out. `hang1` was still on the clock after 45 s, with no red dot and no tick, matching the field log exactly.
  - Fixed bundle, same origin: the dropped emit was followed by a fresh `getDeviceList` on the second reconnect, which was answered. `fix2` got its ✓ and arrived on d101a's chat list.
- NOT verified: the APK on a device, iOS, and the fix on prod with a real double reconnect.

## Notes for next session
- Next action: build decision 104 (owner picked option B: a failed box message is kept on the device and still shows "Ponów" after leaving the chat or a restart, with no auto-resend). Before building it, do the proper rerun:
  1. Revoke d101a's never-online 0.2.65 sibling (device 8) from d101a's Devices screen on 8091, not by SQL: the signed list decides coverage.
  2. A control send F4 (8094) → d101a must go green.
  3. Hold only the box's `send` ack (drop the incoming `43/box,…` frame, let the outgoing frame through), reload the sender, and check both sides.
  4. Read the reason for each red send in Privacy & Safety → the diagnostics panel. The page console doesn't carry `BOX_*`/`SEND_*` lines.
- Item 4 findings (10-17, release web, 0.2.66 and 0.2.67):
  - A failed or stuck box message is lost on reload and even on leaving the chat. It never reached the friend (`hang1`, `r1`–`r3`). This is decision 19 as written (RAM only).
  - The drive's instant reds (`r1`–`r3`) were most likely E101b coverage: d101a's device 8 is a live 0.2.65 sibling. [INFERENCE: the diag was not read.] My frame hook was blind in that run, so "no frame was emitted" is unproven.
  - Confirmed in code, not driven: `_sendOverBox` stores the sender's own record only after a peer device took a frame (`messaging_provider.box.dart:2494`). A reload mid-`deliver` can leave the friend with the message and the sender without it.
- Decision 104 design sketch and the rerun recipe: `docs/plans/2026-10-17-decision-104-unsent-box-messages.md` (no code written).
- Found, not fixed (owner go pending): `connection_provider.dart:833` (socketReady re-assert) and `:1124` (`_resyncAfterResume`) call `_socketService.getMessages(activeConvId)` without the `isLocalConversationId` guard (`messaging_provider.history.dart:524`). A reconnect or resume with a box-only chat open makes the server log `QueryFailedError … out of range for type integer` (seen on dev). Prod logs only go back to this morning's redeploy, so prod is unmeasured.
- Backup coverage on prod (10-17, read-only): 19 of 24 accounts have a backup. The 5 without one (52, 54, 62, 86, 101) are dormant and their only friend is bob208. That Bob's backup holds them is an assumption (the blob is opaque). None carries Phase 4 step 1 data yet, so re-measure after step 1 ships.
- Owner-owed decisions:
  - Still open from 0.2.66: a same-origin re-link breaks the primary's box sends; the rest of Phase 4 step 1.
  - The `getMessages` local-id fix.
- Also: ask bob208 whether box sends still stick after a resume on 0.2.67. He has to fully close and reopen the app.
- Recipe: see the `traps.md` line "Drive a lost socket request with an init-script `WebSocket` subclass". The drive profile is `%TEMP%/d101drive/prof`. Origins 8091 (d101a, user 253) and 8094–8096 (its friends) hold logged-in sessions.
- Traps: two lines were added to `traps.md` under E2E.
