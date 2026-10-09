# A re-minted install could send nothing to a box friend (0.2.64, E38c)

**Date:** 2026-10-09 · **Version:** 0.2.63 → 0.2.64 · **Tier:** frontend only

## What was done
- Prod report: ruchens69 (user 90, one Android PWA, only friend bob208) saw every message red with "Ponów" that did nothing. Read-only prod facts: 14:33:52Z `[identity-churn] deviceId=1 via=unlocked` (his PWA lost its storage, password login, re-mint, contact backup restored); no `messages` row or send warning from him after it; bob208 enrolled (`account_authorizations` v10).
- Repro on the local stack (fp062, box on, release web of 0.2.63): a pair befriended with the box OFF (old path, as on prod), box ON (queues handed), the friend enrolled with "Włącz łączenie", then the sender's origin wiped (`Storage.clearDataForOrigin`) and logged in again. Red "Ponów"; diag `DEVICE_LIST_REJECTED reason: no_tofu_identity` at connect and every refresh backoff, `BOX_ROUTE_UNVERIFIED`, `SEND_FAIL DeviceListVerificationException(no_tofu_identity)`. With the friend NOT enrolled the same re-mint sent fine (an unenrolled list needs no anchor).
- Cause: only a session build pins a friend's account anchor. The restored contact carries no keys, the friend's devices hand the new install queues, E38a's pre-build runs only after the list verifies, and a covered friend never takes the old path (E38b), so nothing ever pinned it.
- Fix (`messaging_provider.dart`, the box list refresh's `fetch`): on `no_tofu_identity` for a friend that is not box-only, `ensureSession` with one device the friend's queues cover (log `BOX_LIST_ANCHOR_PIN`), then look the list up again. Connect-time only, no old path. Decision log E38c; trap in `traps.md` (E2E).
- A first proposal (decline to the old path in `_boxRoute`) was dropped: E38b forbids it and Phase 4 removes the old path.

## Key files
- Edited: `frontend/lib/providers/messaging_provider.dart` (`_boxLists` `fetch`), `frontend/test/providers/messaging_provider_box_lists_test.dart`, `frontend/pubspec.yaml`, `CLAUDE.md` (test count), `docs/plans/metadata-privacy-decisions.md` (E38c), `docs/agents/traps.md`.
- Read only (load-bearing): `messaging_provider.box.dart` (`_boxRoute`, `_prebuildBoxSessions`, `_boxOnlyPeer`), `encryption_provider.dart` (`_adoptDeviceListAnswer`, `adoptServedAccount`), `services/encryption/signal_stores.dart` (`saveIdentity` pins the account anchor on first contact), `backend/src/chat/services/chat-message.service.ts` (`staleLists`).

## Verification
- New test `messaging_provider_box_lists_test.dart` ("an install that lost its storage…"): red without the fix (`fetched` `[]`), green with it. Full suite 3110 passed / 14 skipped; lint ratchet holds the baseline; analyze no errors/warnings.
- Drive (release web build of the branch, local stack): after `Network.clearBrowserCache` the re-minted page logged `BOX_LIST_ANCHOR_PIN {userId: 24, device: 1}`, `SESSION_BUILT`, `DEVICE_LIST_VERIFIED enrolled: true`; its send showed ✓ (`BOX_SEND peerTaken 1`, no `messages` row) and the friend read it; the friend's reply reached it.
- Residual seen: the friend's message sent while the re-minted install was wedged (18:39) never arrived; the friend saw ✓. Not fixed.

## Notes for next session
- Ship 0.2.64 (web; APK for Android users), then ruchens69 closes and reopens the PWA once. bob208's messages to him since 10-09 14:33Z are probably lost.
- Drive trap: Chrome served the old `main.dart.js` from its HTTP cache after a rebuild (python `http.server`); clear the cache over CDP before judging a fix.
- Local stack: backend restarted with `-p fp062` (twice: box off, then on); throwaway users 21–24 (`rremint6382`, `bremint6382`, `rold4056`, `bold4056`, password `Passw0rd!x1`); CDP Chrome on 9333 (`fp-remint-cdp` profile); a stray `fireplace-062_default` docker network.
