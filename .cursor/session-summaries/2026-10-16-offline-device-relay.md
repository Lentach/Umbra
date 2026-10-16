# A friend's message reaches an offline linked device: relay, catch-up sync, 30-day unlink line (decisions 101–103); sibling re-key via the request queue (E37c)

**Date:** 2026-10-16 · **Version:** unchanged (0.2.65, not released) · **Tiers deployed:** none

## What was done
- Owner decisions 102 (catch-up sync, queue cap stays 128; raising it rejected as a band-aid that fills the 60 000 global ceiling) and 103 (daily quiet `alive` frame measures "unused") logged beside 101; E101a, E102a, E103a, E37c written.
- 101 A (`messaging_provider.box_relay.dart`, `_boxCoversLive` in `messaging_provider.box.dart`): every friend-bound frame carries `rl: 1`; a friend is covered when one addressed live device relays; peer frames go only to addressed devices with `ad`; the reader relays (`t:'relay'`, quiet, self-queue) to siblings missing from `ad`; the sibling reads it as the friend (dedup by `(friend, wireId)`).
- 102 (`box_catch_up.dart`, `messaging_provider.box_sync.dart`): >10 min off the box → one `sync_req {since}` to the most recently heard sibling; it answers `sync_resp` pointing at one AES-GCM box media blob (history-file payload, ≤ 1 MiB); import dedups, re-ids, quiet.
- 101 B / 103 (`box_sibling_alive.dart`, `contact_store_alive.dart` row `boxalive_v1`, `messaging_provider.box_alive.dart`, `widgets/sibling_silent_line.dart`): `alive` once a day per sibling; last-heard stamped after every sibling decrypt; the primary shows a red line for a sibling silent > 30 d → dialog Keep (30-d snooze) / Remove (Devices screen revoke).
- `ConversationsScreen`: the line is mirrored by a listener (`context.select` inside `LayoutBuilder` broke 30 screen tests).
- E37c (`BoxSiblingSwap.rekeyViaRequest`, `BoxSession.rekeySibling`): found by the drive — two siblings whose first sessions crossed refused each other's handoff and never got a self-queue address, silently; the re-key now goes through the request queue.
- Built by three parallel agents (RelaySlice, SyncSlice, AliveSlice); a reviewer and a drive agent died on a 429 rate limit (the drive agent had linked the two devices first).
- Out-of-repo: dev stack `fireplace` started (still up, throwaway users 253–256 `d101*`); temp build in `%TEMP%/d101web`, drive artefacts in `%TEMP%/d101drive`; CDP Chrome killed, static servers stopped.

## Key files
- New: the six lib files above, `box_catch_up.dart`; tests `messaging_provider_box_{relay,sync,alive}_test.dart`, `box_catch_up_test.dart`, `box_sibling_alive_test.dart`, `sibling_silent_line_test.dart`.
- Edited: `messaging_provider.box.dart`, `box_actions.dart`, `messaging_provider.dart`, `connection_provider.dart`, `utils/e2e_envelope.dart`, `contact_record.dart` (`ContactOutbound.relays`, not in backup), `contact_store.dart`, `sealed_web_content_kv.dart`, `box_session.dart`, `box_sibling_swap.dart`, `box_friends.dart`, `conversations_screen.dart`, `devices_screen.dart`, ARB en/pl; docs `wire.md` ("Offline linked devices"), `e2e-invariants.md`, decisions log, traps.

## Verification
- CI: all 6 jobs success on `2c1ca05e` (code commit, master push).
- Flutter 3160 passed / 14 skipped (full run); `flutter analyze` 0 errors/warnings; Dart lint ratchet PASS at 3146 (lowered from 3147). E37c test red before the fix by construction (`rekeySibling` returned before any fresh encrypt).
- Drive (release web on the local dev stack, one CDP Chrome, 8091 = A1 primary, 8092 = A2 linked, 8093/8094/8095 = friends F, F2, F3):
  - Before E37c: F's box sends went to A1 only (`BOX_SEND frames: 1`), A1 logged `BOX_RELAY_SKIPPED why: no_self_queue` — A1/A2 had `BOX_SIBLING_PREKEY_REFUSED` both ways.
  - After E37c (rebuilt, both reloaded): `BOX_SIBLING_REKEYED via: request` both ways, both handoffs taken, `BOX_SIBLING_ALIVE taken`.
  - A2 closed, fresh friend F3 sent "R": A1 `BOX_RELAY_SENT {device: 2, outcome: taken}`; A2 reopened shows it.
  - A2's catch-up: `BOX_SYNC_ASKED`, `BOX_SYNC_IMPORTED {offered: 4, stored: 3}` (the relayed one deduped); F's two earlier messages and F2's appear once each.
  - `messages` max id stayed 1040 through every send: nothing took the old path.
  - A1 with `Date` shifted +31 d: red line "Urządzenie „web · #2” nie było używane od 30 dni", dialog, Keep removed it; +62 d in Grafit (dark): line again, Remove revoked device 2 (Devices screen shows it revoked).
- NOT verified: Android, iPhone, a real phone; mixed old/new builds (only reasoned: `rl` gate); a sync blob near the 1 MiB cap.

## Notes for next session
- Next action: owner decides release 0.2.66 (web + APK; backend unchanged) — bump `pubspec.yaml`, CI green, deploy per runbook. Then the rest of Phase 4 step 1 (stop deleting on absence, backup carries chat id/addresses/list, merge on 409, app version at connect).
- Review owed: the reviewer agent died on a rate limit; run `code-review` on `2c1ca05e` before release.
- Residuals (E101a–E103a): `sync_req` to an old-build sibling lost; read-only old-build sibling is asked about after 30 d; synced history may show unread.
- Recipes: `docs/agents/traps.md` "Drive recipes for 101–103".
- Traps: four lines appended to the E2E group (E37c deadlock, last-heard stamp placement, old-build gaps, drive recipes).
