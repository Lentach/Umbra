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
- Next action: watch prod after 0.2.67. Ask bob208 whether box sends still stick after a resume. His tabs pick up the fix only after a full app close and reopen.
- Owner-owed decisions:
  - Still open from 0.2.66: a same-origin re-link breaks the primary's box sends; the rest of Phase 4 step 1.
- Observed, not investigated: in the old build, `hang1` disappeared from the sender's chat after a reload, yet the receiver's unread count read 2. Whether a reload re-sends or drops a hung box send is unknown.
- Recipe: see the `traps.md` line "Drive a lost socket request with an init-script `WebSocket` subclass". The drive profile is `%TEMP%/d101drive/prof`. Origins 8091 (d101a, user 253) and 8094–8096 (its friends) hold logged-in sessions.
- Traps: two lines were added to `traps.md` under E2E.
