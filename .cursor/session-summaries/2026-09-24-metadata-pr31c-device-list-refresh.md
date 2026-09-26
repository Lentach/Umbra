# PR3.1 slice (c): a box send never looks a device list up — the connect does, for the peer AND the own list

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy`)

## What was done
- Owner decision (21) built. New `services/box/box_device_list_refresh.dart` `BoxDeviceListRefresh`: one lookup future per user; a failed one is retried on its own backoff (5 s, 30 s, 2 min, then every 5 min); `reset()` on connect, logout and dispose. `refresh()` re-fetches only users that are missing or failed.
- `MessagingProvider._boxLists`: users are every `BoxOutbox.coveredPeers()` (friends with an address) PLUS the own account. The own list is included only when some peer is covered. Entry points `refreshBoxDeviceLists()` and `onDeviceListInvalidated(userId)`.
- `_boxRoute` awaits `readyFor(peer)` and `readyFor(own)`, then reads BOTH lists from `cachedDeviceList`. A lookup that is missing, failed or dropped since → `BOX_ROUTE_UNVERIFIED` → failed row. `_kBoxListMaxAge`, `_boxListCheckedAt` and the send-time `forceRefresh` are deleted.
- `ConnectionProvider._refreshBoxDeviceLists` runs once E2E-ready AND `socketReady` have both happened (the `_accountReady` gate): a `getDeviceList` sent before auth is silently dropped by the server. It is also called after a late store open and after a passcode unlock.
- `EncryptionProvider.onDeviceListInvalidated` fires on a rebuild request, an adopted identity and the own `deviceListChanged`, so the box refresh re-fetches that list; a send never does.
- Follow-up commit: every list drop goes through `EncryptionProvider.invalidateDeviceList`, which fires the hook (this covers the restore path and the decrypt-time rechecks as well). The `ownLookup == null` guard is back so the route fails closed (an equivalent mutant, kept on purpose). The test fake records every `getVerifiedDeviceList` call (`fetches`), not only forced ones.
- `BoxSession.coveredPeers()`. Root `CLAUDE.md` count updated to 2509. Earlier commit `66af4501`: count 2491, which fixed the red Flutter job on `c0ed515a`.

## Key files
- New: `frontend/lib/services/box/box_device_list_refresh.dart`, `frontend/test/services/box/box_device_list_refresh_test.dart`
- Edited: `messaging_provider.dart`, `messaging/messaging_provider.box.dart`, `connection_provider.dart`, `encryption_provider.dart`, `services/box/box_outbox.dart`, `box_session.dart`, `test/providers/messaging_provider_box_send_test.dart`, `test/services/box/box_session_test.dart`, `docs/contracts/wire.md` ("Send"), `frontend/docs/e2e-invariants.md`, `docs/agents/traps.md`
- Read only: `backend/src/chat/services/chat-device-list.service.ts` (`handleGetDeviceList`: no socket user → `return`)

## Verification
- RED first: the new tests failed to compile against the missing API. Then the four box test files went green (64 tests before the own-list tests were added).
- Full `flutter test`: 2509 passed / 14 skipped (`full21b.log`). `verify-claude-frontend-test-counts` OK. Lint ratchet held at 3163 after fixing one import order.
- Mutants, 25 unique, each run against a green baseline:
  - Refresh class R1–R11: all killed. R11 (backoff counter not reset) was killed only after the new test "a lookup that went through starts the backoff over".
  - Route B1–B4: killed. Provider P2–P4: killed.
  - P1 (the `isE2EReady` gate) survived as unobservable and was deleted: a pre-init lookup throws locally, emits nothing, and E2E-ready re-fetches it.
  - `coveredPeers` filter S1/S2: killed after a new `box_session_test`.
  - Own list O1, O3, O5, O6: killed. O5 and O6 needed the new tests "waits for our own list's lookup" and "covers no peer → looks nothing up".
  - The own-lookup null check was dead (the refresh that looks up a peer always looks up the own list) and was deleted.
- Live drive on a fresh pair: alice 272 on release web ↔ bob 273 on the Pixel_7 AVD debug APK, with the `BOX_DRIVE` scaffold (deleted afterwards; `box_session.dart` restored by sha256 `0ace13a2…`).
  - Drive 1 caught a real gap. Bob's logcat showed `DEVICE_LIST_FETCH_EMIT {userId: 273}` (his OWN list) 14 ms after the send started. That led to the own-list fix.
  - Drive 2, final code:
    - Bob's connect made 2 lookups (273, 272). Two sends produced two `BOX_SEND`s and 0 `FETCH_EMIT`.
    - Alice's connect made 2 `getDeviceList` (272, 273) in the same millisecond. Her sends produced box `send` frames and 0 lookups.
    - Box frames travel on a separate WebSocket from the account socket (instance-tagged recorder).
    - 45 s offline → a real reconnect → the new connect's 2 lookups at +311 ms. A send at +438 ms showed "Ponów", because the box socket reconnected after it (decision 19). The retry went over the box with no lookup, ✓.
    - Bob received all 5 of alice's messages, one copy each. Server `messages` rows for 272/273: 0.
- NOT verified live: the invalidation hooks (rebuild request, adopted identity, `deviceListChanged`), which are unit-tested only; the backoff retry on a real failed lookup; iOS.

## Notes for next session
- Slice (d) must call `refreshBoxDeviceLists()` when it stores a peer address. Otherwise that peer fails every send until the next connect.
- OWED before slice (d): the connect lookup is one `getDeviceList` per contact, sent in parallel (there is no batch endpoint). It spends the shared 300/15 min throttle on every reconnect; about 50 box contacts exhaust it in about 6 reconnects. Fix (an owner call on freshness): on a same-user reconnect, skip lists verified less than N minutes ago. Details in task_plan decision 21.
- In the first second after a reconnect, the box socket is usually still down, so a send shows "Ponów" (decision 19; the auto-retry or the user resends). This is not caused by decision 21.
- Next per decision (23): the sibling-queue slice, with the live link-mid-session drive (24). Its design questions go to the owner before any test.
- Traps (also in `traps.md`): never a send-time list lookup, own list included; a `getDeviceList` sent before `socketReady` is dropped; slice (d) owes a refresh call.
