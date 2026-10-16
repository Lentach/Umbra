# A resume probes the box socket and replaces a dead one (0.2.65, E76b); 10-15 reports traced

**Date:** 2026-10-16 · **Version:** 0.2.64 → 0.2.65 · **Tiers deployed:** both (web + backend restart for `/version`/APK; backend code unchanged) + APK

## What was done
- Investigated 10-15 prod reports (notification but no message; red "Ponów" that only a reopen fixed). Read-only prod: 0 box refusals/warnings in 7 d; delivery to connected devices works (55 queues read 10-15 held 15 blobs).
- Main cause on 10-14/15: 9 identity re-mints on 4 of bob208's friends (`identity_change_audit`): Magdalena (88) ×3, jacek67 (89) ×2, Norway (80) ×1 — the OWNER logged into their unenrolled accounts from his PC to mint contact backups — and ruchens69 (90) ×3 (his phone storage fills and wipes). E38c consequences: frames to the old install lost while the sender sees ✓, sends to the friend red until a reconnect.
- noobster1122 (83, one iPhone PWA, no churn, only friend bob208, his queue empty): late messages after a reopen. Cause: `ensureReconnectIfNeeded` probed only the account socket; a suspended page kept a dead `/box` transport that socket.io reported connected until its ping timeout (~45 s).
- Fix `BoxClient.checkAlive` (called from `ConnectionProvider.ensureReconnectIfNeeded`, through `BoxSession.checkAlive`): after `kBoxResumeGrace` (2 s) a socket that heard nothing since the resume and nothing for `kBoxSilenceLimit` (30 s) is replaced; silent for less → judged again at 30 s. `IoBoxSocket.lastHeardAt` is stamped by the Manager's `ping` and `packet` events. A live socket is never touched.
- A first version cycled the socket on every return ≥ 5 s; it contradicted decision 76 (box sees every switch, spends `subscribe`, can cut a send). Owner picked the probe; logged as E76b.
- bob208's offline Android (FCM token `cdbb7d97…`, 19 queues, untouched since 10-09) holds 561 undelivered blobs, one queue full since 10-11. Not a send cause: ✓ counts peer frames only.
- Out-of-repo: VM `.env` `ANDROID_APK_*` → 0.2.65 (backup `.env.bak.pre-apk-0.2.65`); `~/fireplace/apk/umbra-0.2.65.apk`; local `fp062` stack started and stopped again (throwaway users 25 `drvA1144`, 26 `drvB27950`, conversation 8 seeded by SQL).

## Key files
- Edited: `frontend/lib/services/box/box_client.dart` (`BoxSocket.lastHeardAt`, `IoBoxSocket`, `checkAlive`, constants), `box_session.dart`, `providers/connection_provider.dart`, `test/support/box_fakes.dart`, `test/services/box/box_client_test.dart`, `test/providers/connection_provider_box_test.dart`, `pubspec.yaml`, `CLAUDE.md` (3114), `docs/contracts/wire.md`, `docs/plans/metadata-privacy-decisions.md` (E76b), `docs/agents/traps.md`.
- Read only (load-bearing): `backend/src/box/box-delivery.service.ts` (newest subscriber wins a rid; window 16), `box.constants.ts` (subscribe 60 / 15 min / IP), `messaging_provider.box.dart` (`_sendOverBox`: ✓ = a peer frame taken).

## Verification
- CI: all 6 jobs success on `58ac065e` (code commit).
- Flutter 3114 passed / 14 skipped (full run); Dart lint ratchet PASS at baseline. Red before the fix: the provider test failed (`suspended.disposed` false). Mutant: dropping the "heard since resume" guard turned `checkAlive … keeps a socket that hears a ping` red.
- Drive (release web of the fix, local `fp062`, Chrome via CDP, minimised window = hidden): 40 s hidden with the server alive → no new socket, 2 pings per socket; backend `docker pause`d right after a box ping, shown at 29 s → at show+2 s the box socket sent `41/box`, a new one opened and resubscribed once unpaused, ~13 s before socket.io's own timeout.
- Prod: `/version` 0.2.65/58ac065e with android 20065; web smoke 7/7 (bundle contains 58ac065e); APK URL 200; 0 warn/error lines 5 min after; backup `chatdb-20261016T012915Z.dump.gpg`.
- APK SHA256 `19841eb968c8c29c305f3dd12073a5a10af03b1cd5ad516bc00ebb6d428570ed`, versionCode 20065, 50.3 MB, 16 KB gate 16/16. NOT booted on a device.
- NOT verified: a real iPhone (noobster or the owner), the APK on a phone.

## Notes for next session
- Next action: metadata Phase 4 — read-only check of `contact_backups` for the 26 kept accounts (the owner minted 80/88/89 from his PC on 10-14), then step 1 of `docs/plans/2026-10-08-friend-row-gap-check.md`.
- Owner follow-ups: noobster checks a late message on his iPhone after 0.2.65; jacek67's PC session (refresh token 10-14 23:55Z) still live — log it out; jacek67 and Norway re-mint once more when their phones next open; bob208 opens the Android once.
- Open, not investigated: a fresh pair (users 25/26) stayed old-path B→A ("ma starszą wersję aplikacji" on B) after both reloaded — A never handed B its queue.
- Recipe: hidden page = `Browser.setWindowBounds {windowState:'minimized'}` on a CDP Chrome launched with `--disable-features=CalculateNativeWinOcclusion`; a silent box transport = `docker pause <backend>` right after a `2` frame on the box socket.
- Traps: box socket and the resume probe (traps.md, end of the E2E / multi-device group, above `## Auth`).
