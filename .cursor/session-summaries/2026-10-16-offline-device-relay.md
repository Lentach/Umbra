# A friend's message reaches an offline linked device (relay, catch-up sync, 30-day unlink line; decisions 101–103), reviewed and LIVE as 0.2.66

**Date:** 2026-10-16 · **Version:** 0.2.65 → 0.2.66 · **Tiers deployed:** both (web; backend restart for `/version`/APK, backend code unchanged) + APK

## What was done
- `2c1ca05e`, decisions 101–103:
  - Relay (`messaging_provider.box_relay.dart`, `_boxCoversLive`): the reader relays `t:'relay'` to the siblings missing from `ad`.
  - Catch-up (`box_catch_up.dart`, `messaging_provider.box_sync.dart`): one `sync_req`/`sync_resp` blob after more than 10 min off the box.
  - Unlink line: daily `alive` (`box_sibling_alive.dart`, `contact_store_alive.dart`), red line + Keep/Remove (`sibling_silent_line.dart`).
  - E37c: sibling re-key via the request queue.
- Two-axis review (code-review skill, two reviewer agents), then `7963a711`:
  - E103b: `alive` and `sync_req` never seal to a paused sibling. The `alive`, `sync_req` and `sync_resp` answers feed the pause (`_noteBoxAnswer`). A full answer counts as the day's `alive`.
  - Catch-up stays owed while every sibling is full or paused; E102a's clear rule, which the first build broke.
  - The relay seal loop now catches per target. A relay needs the origin device (no `?? 1`).
- E101b, found by the mixed-build check: a 0.2.65 sibling drops `t:'relay'` as an unknown type. `rl` now goes out only while every live sibling has sent `alive`/`sync_*`/`relay`; that fact is kept as `r` in `boxalive_v1`. A friend frame without `rl` clears `ContactOutbound.relays` (`toFriend(relays:)`, `_vouchesRelay`, `BoxFriendLink.friendRelays(relays:)`).
- Docs: `wire.md` (box-visible blob, `rl` semantics, pause), `e2e-invariants.md` (`boxsync_v1` bullet, `r` field), decisions log E101b/E103b, traps. Root `CLAUDE.md` count is 3163.
- Out-of-repo state:
  - VM: `.env` `ANDROID_APK_*` set to 0.2.66 (backup `.env.bak.pre-apk-0.2.66`); `~/fireplace/apk/umbra-0.2.66.apk`; backup `chatdb-20261016T171809Z.dump.gpg`.
  - Local: dev stack `fireplace` still up, with throwaway users 253–259 `d101*`. User 253's password was set by SQL to `Test123123`.
  - Drive debris: temp dirs `%TEMP%/d101web`, `d065web`, `d101drive`. CDP Chrome killed, static servers stopped, worktree `fp065` removed.

## Key files
- Edited (7963a711): `messaging_provider.box.dart` (`_noteBoxAnswer`, dispatch marks), `messaging_provider.box_alive.dart`, `messaging_provider.box_relay.dart`, `messaging_provider.box_sync.dart`, `box_session.dart`, `box_friends.dart`, `box_sibling_alive.dart`, `contact_store_alive.dart`, `utils/e2e_envelope.dart`, `pubspec.yaml`.
- Edited tests: the relay, sync and alive tests, plus the fakes in five tests.
- Read only: the 0.2.65 sibling reader (`58ac065e` `messaging_provider.box.dart:763`), which finishes an unknown `t`.

## Verification
- CI: all 6 jobs success on `7963a711`, and on `2c1ca05e` before it.
- Flutter 3163 passed / 14 skipped; `flutter analyze` 0 errors; Dart lint ratchet PASS (baseline 3146).
- New tests:
  - a full sibling gets no `alive` sealed while paused;
  - catch-up stays owed while full and asks once the sibling is heard;
  - `rl` only after the sibling's `alive`;
  - a frame without `rl` clears the flag.
- Local drives (release web, dev stack, one CDP Chrome; A1 = primary, A3 = 0.2.66 sibling device 6, A7 = 0.2.65 sibling device 8, F4/F6 = 0.2.66 friends, F5 = 0.2.65 friend):
  - Relay: a fresh friend wrote while A3 was closed. A1 logged `BOX_RELAY_SENT {device: 6, taken}` and A3 showed q1.
  - Catch-up: A3 reopened 15 min later and logged `BOX_SYNC_IMPORTED {offered 2, stored 1}` (the relayed copy deduped).
  - E101b, before the old sibling: F6's p1 went `BOX_SEND frames 1`, and A1 relayed it to 6.
  - E101b, after linking 0.2.65 device 8: A1's next frame cleared F6's flag, and F6's p2 hit `BOX_ROUTE_OLD_PATH peer_uncovered`. That is the pre-101 rule, not a silent loss on device 8.
  - Mixed friend: 0.2.65 F5 → A and A → F5 both arrived (an old build ignores `rl`/`ad`).
  - `messages` max id stayed 1040 throughout.
- Prod:
  - `deploy-backend.sh` → `/version` 0.2.66/7963a711, android 20066. `deploy-web.ps1` smoke 8/8 PASS (bundle contains 7963a711).
  - APK 0.2.66: SHA256 `2e24b57007f3b640bb5846718953af2133bd7bb39ad250217935a0c4ff335d00`, versionCode 20066, signer OK, 16 KB 16/16, URL 200 (52 834 489 B). NOT booted on a device.
  - Backend logs: 0 warn/error lines in the 4 min after the deploy.
- NOT verified: Android device, iPhone, a sync blob near 1 MiB, the `queue_full` pause path live (unit tests only).

## Notes for next session
- Next action: watch prod after 0.2.66 (backend warn/error lines, `BOX_RELAY_*`/`BOX_SYNC_*` reports from users). Then the rest of Phase 4 step 1 (`docs/plans/2026-10-08-friend-row-gap-check.md`).
- Found, NOT fixed (pre-existing; owner call whether next):
  - Re-linking a REVOKED device in the same browser origin leaves the primary unable to send any box message (`own_uncovered` → `BOX_RETRY_NO_ROUTE`). Likely cause: the link wipes only Signal material, so the old `boxsib_v1` acks survive (trap line). Recovery: revoke that device.
  - A freshly linked device gets no earlier box friends (Phase 4 backup item).
- Residuals:
  - A `sync_req` to an old-build sibling is lost.
  - Until a new sibling's first `alive`, friends that cannot address it fall back to the pre-101 rule.
  - A friend keeps a cached `rl` until our next frame to it.
  - The sync blob lives its 14-d TTL (there is no client media delete).
- Recipes: `docs/agents/traps.md` "Drive recipes for 101–103". Shift `Date` per page in `evaluateOnNewDocument`, give each device its own port, and drive old builds from a `git worktree` build on a separate port.
