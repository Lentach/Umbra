# A wiped device's first queue handoff no longer times out, so a friend's messages after a wipe arrive

**Date:** 2026-10-27 · **Version:** unchanged (0.2.71 live; fix ships in 0.2.72) · **Tiers deployed:** none

## What was done
- Owner: "release together with the fix for messages lost after a wipe". So 0.2.72 waits for this fix and carries it with multi-photo send and the composer/tempId fixes.
- Root cause, found on a native release APK that printed the RAM diag to logcat (staging, Pixel_7 AVD):
  - After `pm clear` + login, the connect's session pre-build and the friend queue handoff both called `ensureSession` for the same friend device.
  - The second call arrived while the first one's bundle was being BUILT into a session. There was no session yet and no fetch pending, so it fetched again.
  - The server refuses a repeat fetch of the same pair inside its interval with a bare `error` (`chat-key-exchange.service.ts` `isPreKeyFetchRateLimited`).
  - The handoff timed out after 10 s (`BOX_FRIEND_ENCRYPT_FAILED TimeoutException` → `HANDOFF_FAILED no_frame`) and was not retried in that process.
- `EncryptionProvider.ensureSession` (`frontend/lib/providers/encryption_provider.dart`):
  - A second caller now joins an in-flight fetch-AND-build per device (`_sessionBuilds`, body moved to `_fetchAndBuildSession`). Before, it joined only the fetch.
  - The (lix) re-arm of a failed rebuild intent holds for joiners too.
  - `clearPendingPreKeyFetch` and `clearEncryptionKeys` drop the in-flight builds.
- Docs:
  - `docs/agents/traps.md`: post-wipe trap rewritten as FIXED, with the cause and the logcat recipe.
  - Plan doc `2026-10-08-friend-row-gap-check.md` §"Freeze rehearsal 10-27": the native leg now records the cause and the fix.
  - Root `CLAUDE.md`: 3286 Flutter tests / 14 skipped.
- Out of repo, all left RUNNING for the owner's phone test:
  - dev stack (`docker compose start db backend`);
  - CDP Chrome :9461 (`%TEMP%/d101drive`);
  - emulator Pixel_7 with `fix.apk` 20073 (staging-pointed);
  - services `stg-web` (8301–8312), `phone-proxy` (:8400) and `phone-tunnel` (cloudflared quick tunnel).
  - Staging is DOWN again (volumes kept).

## Key files
- Edited: `frontend/lib/providers/encryption_provider.dart`, `frontend/test/providers/account_identity_anchor_test.dart`, `CLAUDE.md`, `docs/agents/traps.md`, `docs/plans/2026-10-08-friend-row-gap-check.md`.
- Out of repo:
  - `%TEMP%/stg-drive/build-diag.ps1`: release APK of a commit with an optional working-tree overlay, `E2eDiagLog.add` printing `[DIAG]`, `BASE_URL` `127.0.0.1:3100`; outputs `apk/diag.apk` and `apk/fix.apk`.
  - `%TEMP%/phonetest/`: `cloudflared.exe`, `proxy.mjs` (the prod nginx path list sent to the dev backend with `Origin` rewritten to localhost), `web/` built with BASE_URL = tunnel URL.

## Verification
- CI: 6/6 success on `5fced2de`.
- Red first: `account_identity_anchor_test.dart` "two session builds for one device overlap".
  - Old code: `TimeoutException`, with the log sequence identical to the device's.
  - Fixed: passes. Removing the join is exactly the old code.
- Dart ratchet 3131 (PASS); analyze 0 warnings/errors; full suite 3286 / 14 skipped; `verify-claude-frontend-test-counts` OK.
- Native drive on staging (N1 = APK on the AVD, P2 = web `b0def3ff` @8302):
  - HEAD `ab244533` build: one `SESSION_FETCH_EMIT` before the pre-build's `SESSION_BUILT`, a second during it, then a timeout. X0–X13, sent over 3 min from 10 s after login, never arrived, though P2 shows ✓. The next start healed it (`HANDOFF_SENT`).
  - Fixed build: the same overlap with ONE fetch. `BOX_FRIEND_HANDOFF_SENT` came 1.1 s after `CONTACT_BACKUP_RESTORED`. Y0–Y7 were all on N1's screen (uiautomator), and N1 → P2 "N1reply" arrived.
- The same fixed APK, multi-file send from the installed app: the system picker (Images › Pictures) selected 3 photos. 3 `BOX_SEND peerTaken 1`, in order, with the new tempIds `temp_<ms>_<n>_137`, and all 3 were shown on P2.
- Phone-test link smoke (Chrome via the tunnel): login as mpz1027 restored the contact; "tunnel smoke" sent ✓ to mpx1027. `/socket.io` polling answered with the tunnel `Origin`.
- Receipt check at the tunnel, two separate CDP browser contexts:
  - **FAIL, pre-existing, not multi-photo:** mpx1027 and then mpy1027 logged in one after the other on fresh storage, so both re-minted (`IDENTITY_MINTED server-bundle-unlocked-remint`, `BOX_ROUTES routed` both). Text both ways showed ✓ and NOTHING arrived either way, not even after reopening both.
  - Cause not diagnosed. It is the same family as the stale-queue / `foreign_identity` residual: each side's handoff can only reach the other's pre-login queue, whose keys died.
  - PASS: two API-registered accounts (ipx1027 273, pcy1027 274) on their first login, invited by `name#tag` and accepted. Text both ways, then a 3-photo paperclip pick (`selectMultiple`) arrived in pick order.
- NOT verified: iOS (the owner's iPhone test is pending); a real Android phone; prod.

## Notes for next session
- Next action: the owner tests multi-photo send on his iPhone via the tunnel link.
  - Accounts: ownerphone (275, #4007) on the iPhone, ownerpc (276, #9337) on the PC browser, password `Test123123`. Registered via the API and never logged in, so each login is a first mint. He invites `ownerpc#9337` from the iPhone and accepts on the PC.
  - Do NOT use mpx/mpy: a fresh login on both sides of an existing pair loses messages (above).
  - The tunnel URL dies with `phone-tunnel`; a new URL needs a web rebuild with the new `BASE_URL`.
- Owner question: both friends logging in again on new storage loses messages both ways (receipt check above). It is pre-existing, so it does not block 0.2.72 by the multi-photo change, but decision 123 makes it a message-loss finding. Diagnose it before or after 0.2.72?
- After the phone test: release 0.2.72 per `2026-10-21-release-0269.md`. It carries multi-photo send, the composer/tempId fixes and this fix.
  - Remove `%TEMP%/phonetest` and `%TEMP%/stg-drive/apk/{diag,fix}.apk` afterwards.
- Residual, by design: what a friend sent between the wipe and the new handoff is still lost, because the old queue's keys died with the wipe.
- Owner-owed: the iPhone test; the pair tests (SaraLee/BestiaBestia ↔ bob208); the freeze go (not before 10-30).
