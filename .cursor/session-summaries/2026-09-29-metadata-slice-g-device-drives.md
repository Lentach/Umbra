# Slice (g) driven on a Pixel_7 and on a real Web Push device: upgrade, ticks, typing, wake suppression

**Date:** 2026-09-29 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy`, code HEAD `c00937ff`, CI 7/7)

## What was done
- No code change. Drives only, following `2026-09-28-metadata-slice-g-receipts-typing.md`.
- Setup: dev stack from `fireplace-mp` (`docker compose up`, migration 0025 applied), debug APK of the branch (`--dart-define=BASE_URL=http://10.0.2.2:3000`) installed with `install -r` OVER an older install of `bob_ft7dyf`; release web builds served on 8121 as peers (`dr_ana`, `dr_snd`).

## Key files
- None edited. Read: `backend/src/box/{box-notifier.service,box-push.transport}.ts`, `frontend/web/web-push-sw.js` (the `new_message` handler), `frontend/lib/services/{push_service,push_box_source,web_push_bridge_web}.dart`.

## Verification
- Upgrade over an old install: login kept; the legacy chat with `alice_ft7dyf` still decrypts and shows its 24 Sep history.
- Box first contact, Android → web: request, accept, chat both ways; 0 `friend_requests`/`conversations`/`messages` rows.
- Switch (decisions 62–63): ON on web only → Android (OFF) read the message, the sender stayed ✓; both ON → `on4` turned ✓✓ while `hi1`/`off3` (read while OFF) stayed ✓; Android typing showed "pisze…" on web and cleared ~6 s later.
- Android as RECEIVER: its `ctl`/`ctl2` turned ✓✓ when `dr_snd` opened the chat; web typing showed "pisze…" in the Android header.
- Wake suppression on a real device (Web Push through `fcm.googleapis.com`, installed Chrome, notifier row registered for the queue, its page CLOSED): Android read `m3` → one `quiet` row landed on a queue that HAS a notifier and no notification appeared after 22 s (coalescing max 10 s); an ordinary message `ctl2` to the same device produced `Umbra | New message` within 16 s (positive control); Android typing (`live`) stored no row and pushed nothing.
- NOT verified: the FCM (native Android) send — the dev backend has no `FIREBASE_SERVICE_ACCOUNT`, so only the platform-independent `BoxNotifierService.schedule` decision is proven; iOS; the voice-indicator refresh/expiry on a device.

## Notes for next session
- Next action: G5 prep, plan row 10 (`docs/plans/2026-09-25-metadata-pr31-remainder.md`): gate review, then the migration rehearsal (master build, then the branch build over it). The release APK cannot reach a local backend (cleartext only on the debug variant), so the rehearsal needs debug builds of `origin/master` (throwaway worktree `Desktop/fp-g5-master`, `pub get` done) and of the branch, both `0.2.51` (same versionCode; `install -r` accepts it).
- Left up: Docker dev stack, Pixel_7 AVD with the branch debug APK; local accounts `dr_ana` 354, `dr_bob` 355, `dr_snd` 356. `frontend/build/web` deleted; run `flutter clean` before any `--release` build.
- Traps → `docs/agents/traps.md`: Agent tooling ×2 (dev backend cold start / capture names; Chrome Web Push drive recipe).
