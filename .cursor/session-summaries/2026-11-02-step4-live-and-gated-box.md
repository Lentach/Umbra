# Phase 4 step 4 LIVE on prod; a gated or revoked device no longer drains its old box queues (#205, not deployed)

**Date:** 2026-11-02 · **Version:** unchanged (0.2.72; backend `41117d8b` → `18382d52`) · **Tiers deployed:** backend

## What was done
- **Step 4 flip, owner's go 11-02 ("no point to wait to 11-05"):**
  - `docker-compose.prod.yml` `LEGACY_LISTS_SILENT: 'true'` (`18382d52`), CI 6/6.
  - Pre-deploy backup `chatdb-20261102T022421Z.dump.gpg` (3.5 MB vs 9.4 MB: the `box_msgs` drop 483 → 172, 16 KiB blobs; users/friend rows unchanged).
  - `./deploy-backend.sh` healthy 02:33Z.
  - Docs: wire.md, E124a, backend/CLAUDE.md, plan, and the undo order in traps.
- **Before the flip:**
  - Review doc fixes `baf25f09`.
  - goonboy waived on the owner's word (abandoned for goonboytest, which has no friend rows): `357fe149`, counts corrected `31666825`.
  - Issue #204 filed: warn before the box global ceiling.
- **#205 (owner: "start now", issue filed), `514f759e`, CI 6/6:**
  - `ConnectionProvider` starts `BoxSession` at the first E2E-ready only. `BoxSession.start` is idempotent; `resume`/`storeOpened` wait for it.
  - On `deviceRevoked` without a reason, `BoxSession.retireRevokedDevice` deletes every queue the device holds. It subscribes none and stops if another account opens the store. Logout closes the store after it.
  - `cd03e894`: the connect gate (`chat.gateway.ts:131`) sends no reason. A reasonless revoke now deletes only while the shared stored session (`AuthTokenStore.readSessionDeviceId`) still names the revoked id, so a tab that missed the live reset eviction keeps the recovering tab's queues (advisory).
  - Review follow-up (owner picked "small fixes + a1, full drive, a2 as issue"): a §6.2 reset/restore marks only the caller's own pre-reset id `rehomed: true` (its sibling tabs keep the queues); every other superseded device now deletes its own (before, `reason` alone kept them all). `retireRevokedDevice` disposes the inbox and `BoxClient.forgetAll()`s first (a reconnect re-subscribed every queue) and runs under ONE 15 s deadline (deletes included). Detach block → `_unwireBox`; `readSessionDeviceId` uses `JwtDecoder`; stale backend comments fixed. #206 filed: a device revoked while offline follows its queues on reconnect before the gate tells it.
  - Decisions E29a (narrows decision 29 client-side), wire.md, e2e-invariants, traps.
- **Prod evidence behind #205 (read-only):**
  - bob208's Android (device 11, revoked 10-20) signed in again with the password on 11-01, landing on device 1 (`resolveLoginDeviceId`), and sat on the link gate.
  - On 11-02 it subscribed 22 queues under its FCM token and drained them (`box_msgs` 172 → 82; `box_queues` stayed 231). Matched by yes/no only, decision 81.
- Out-of-repo:
  - Dev stack stopped (volumes kept).
  - Throwaway worktree `%TEMP%/w205` removed.
  - Dev accounts w205a (279), w205f (280).
  - Deleted my stray `%TEMP%s4up.log` (repo root, ignored) and `frontend/....flutter-test-205.txt`.

## Key files
- Edited:
  - `frontend/lib/providers/connection_provider.dart` (`connect`, `onE2EReady`, `disconnect`, `_onOwnDeviceRevoked`, `_retireRevokedBox`, `_unwireBox`)
  - `frontend/lib/services/box/box_session.dart` (`start`, `resume`, `storeOpened`, `retireRevokedDevice`, `_retireQueues`), `box_client.dart` (`forgetAll`)
  - `frontend/lib/services/auth_token_store.dart` (`readSessionDeviceId`)
  - tests: `connection_provider_box_test.dart`, `auth_token_store_test.dart`, `box_session_friends_test.dart`
  - `backend/src/chat/services/chat-key-exchange.service{,.spec}.ts`
  - `docker-compose.prod.yml`
  - docs: `wire.md`, `metadata-privacy-decisions.md`, `e2e-invariants.md`, `traps.md`, `CLAUDE.md`, plan
- Read only: `encryption_provider.dart` (`_initializeE2EInner`, `needsDeviceLink`), `queue_keys.dart`, `box_client.dart`

## Verification
- CI: 6/6 success on `514f759e` (#205), on `cd03e894` (gate-path fix), and on `18382d52` (flip).
- Prod after the flip:
  - `env` shows all three flags `true`.
  - `/version` `18382d52`, `/health` ok.
  - 0 restarts, 0 warn/error at +10 min.
- #205 gates:
  - Flutter 3300/14 skipped (verifier OK).
  - Backend 1263/71 (verifier OK).
  - Dart ratchet 3131 (held); backend ESLint ratchet 850/147; tsc clean; knip and no-user-logs clean.
  - 12 new provider tests, 2 token-store tests, 1 session test. Mutants killed: store-owner check, stored-session check, `rehomed` ignored, reason gate restored, `forgetAll` dropped, deadline dropped, backend `rehomed: false`.
  - Reviewer: P1 (another account's queues deleted) and P2 (reset tab) fixed, each with a test.
- Drive, dev stack with prod flags (frozen + silent), release web build of the working tree, CDP Chrome:
  - **A (primary, linking enabled):** box opened after E2E.
  - **B on the link gate:** account socket only, no box socket, `openProvisioning`.
  - **B linked as device 2:** box opened after linking (createQueue 2, subscribe 2).
  - **A revoked B:** B sent `deleteQueue` ×2, showed "To urządzenie usunięto…", `box_queues` 226 → 225 (B −2, A's rotation +1).
  - **B re-login:** gate again, no box socket.
  - Re-driven on the final build with device C: same (`deleteQueue` ×2, 227 → 226).
  - After `cd03e894`, device D (linked as 8): stored session decoded as 8, a plain revoke still sent `deleteQueue` ×2 (228 → 227), and D logged out.
- Follow-up drives (dev stack, web build of the working tree + debug APK, emulator Pixel_7):
  - **Reset with a sibling tab:** D re-signed-in onto the gate as device 1 in two tabs (D, D2), ceremony started from the gate, deadline aged by SQL, the completed ceremony spent by a SCRIPTED upload as device 1 (the gate did not spend it on its own after reload — not investigated). A, D, D2 (device 1, `rehomed`) sent no `deleteQueue`; E (device 12, `reason: 'reset'`) sent `deleteQueue` ×2; `box_queues` 231 → 229; the caller got no `deviceRevoked`.
  - **Passcode-locked boot:** account socket only while locked; box opened (subscribe 2) after the code was entered.
  - **Android emulator:** linked as device 2 of w205q386 from the web primary, box running (`box_queues` 235 → 237); revoked from the web: logged out with "To urządzenie usunięto…", `box_queues` 237 → 236 (−2 deleted, +1 primary rotation; the box logs no deletes). `native_content_store_device_test.dart` 8/8 on the emulator.

## Notes for next session
- Next action:
  - Owner OK to deploy #205: backend first (`rehomed`), then web, then the APK.
  - Then close #205.
  - Then confirm the owner's both-ways message under step 4 (not yet reported).
- Owner-owed:
  - the #205 deploy;
  - the step 4 both-ways test;
  - `backup.pass` off the VM.
- Residuals (E29a):
  - a device revoked while offline never hears `deviceRevoked`, so its queues wait for the 30-day TTL and the 90-day reaper;
  - a friend's stale list keeps writing into them until then (decision 59);
  - another install on the recovering caller's old id (a password login lands on the primary's id) keeps its queues;
  - #206: a device revoked while offline follows its queues on reconnect before the gate tells it.
- Seen, not investigated: a gate tab whose reset ceremony completed did not spend it after a reload (the drive scripted the upload).
- Step 5 after a few days of step 4.
- Drive recipe:
  - `%TEMP%/p4s4drive/h.mjs` (+ `intercept.js`: `__fp.wsOpened` kinds, `boxEmits`); `spendreset.cjs <token>` spends a completed ceremony.
  - Enable linking in a tab with an init-script `matchMedia('(display-mode: standalone)')` shim; `Emulation.setEmulatedMedia display-mode` does not work. It asks for a recovery key first (copy words, type the asked one).
  - Link by "Wpisz kod ręcznie" plus the clipboard (`Browser.grantPermissions clipboardReadWrite`). Android: the gate's code is in the uiautomator dump (`fp-link.v2…`); type it on the web primary.
- Traps: the gated-device drain line in `traps.md` (E2E group); the undo order (Deploy group).
