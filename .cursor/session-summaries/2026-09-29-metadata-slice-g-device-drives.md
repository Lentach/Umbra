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
- NOT verified: the FCM (native Android) send (dev backend has no `FIREBASE_SERVICE_ACCOUNT`; only the platform-independent `BoxNotifierService.schedule` decision is proven); iOS; the voice-recording indicator and its refresh/expiry on a device; the NEW client against a backend with `/box` ABSENT (prod-like, box off) — never driven.

## Notes for next session
- Next action (owner has not yet approved the finish line): G5 = gate review of the diff since G4, then the rehearsal, then release N. This branch ends at release N (S5); Phase 4/G6 (delete the old path, O1) and Phase 5 are later and NOT this branch.
- Rehearsal (`docs/plans/2026-09-25-metadata-pr31-remainder.md` row 10) also covers the never-driven leg: new client vs a prod-config backend (box off), on the prod-mode staging stack the G2 gate used, `pg_dump` first. Release APK cannot reach a local backend (cleartext only on debug), so master/branch builds are debug, both `0.2.51` (same versionCode; `install -r` accepts it); worktree `Desktop/fp-g5-master` has `pub get` done.
- Release N as two steps: A = backend + web with `BOX_ENABLED` still `'false'` (add-only migrations 0023 two NULL columns, 0024 table + row, 0025 `quiet` default false; each header has its inverse; redeploy the previous commit to revert); B = flip the box later as its own step, one-way once box-only friendships exist. Publish the APK LAST: Android refuses a lower versionCode and uninstall destroys identity + history. Master tip shows no full-suite check-runs (only Dependabot, Analyze (actions)): confirm 7/7 before any deploy.
- Owner-owed: approve that finish line; FCM key or accept "check on the owner's phone after deploy"; re-sign the accepted residuals (decisions 57–60) at G5; G4 prerequisite (5), the media-quota liveness oracle, may have no decision row (not checked).
- Left up: Docker dev stack (`fireplace-mp`), Pixel_7 AVD with `bob_ft7dyf` and the branch debug APK, dev-DB accounts `dr_ana` 354, `dr_bob` 355, `dr_snd` 356, throwaway worktree `Desktop/fp-g5-master`. `frontend/build/` still holds the debug APK and `web/` was deleted: `flutter clean` before any `--release` build. The hand-launched Chrome (`--remote-debugging-port=9333`) was killed by its profile path and `%TEMP%/pushdrive-s` deleted; the 8121 server is stopped.
- Push-drive recipe: BEFORE trusting any "no push", prove a notifier exists for the queue that got the frame: `select m.quiet, m."createdAt", (n.nid is not null) has_notifier from box_msgs m join box_queues q on q.rid=m.rid left join box_notifiers n on n.nid=q.nid where m."createdAt" > now()-interval '3 minutes'` — old E9 rows (`verifiedAt` 09-25) make a bare `count(*)` of `box_notifiers` misleading; the first attempt this session had `has_notifier = f` and proved nothing.
- Traps → `docs/agents/traps.md`: Agent tooling ×2 (dev backend cold start / capture names; Chrome Web Push drive recipe).
