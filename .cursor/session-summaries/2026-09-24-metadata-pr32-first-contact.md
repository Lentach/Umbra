# PR3.2: a device publishes a box request queue, and `searchUsers` serves a stranger's reachable devices with a claimed bundle each

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only; nothing to master or prod)

## What was done
- Owner decisions: (1) the PEER path of `getDeviceList` stays until **PR4.1** (moved there from PR3.2). The old path in release N still fetches peer lists in 5 client places, so deleting it breaks multi-device sends and withholds messages from device 2 and up. (2) `searchUsersResult` also carries `authorization`. (3) Bundles come WITH a one-time pre-key (OTP), per design §4.4.
- `setRequestQueue {sid, sealPub}` → `requestQueueSet {success, error?}` (`ChatSearchService.handleSetRequestQueue`, gateway 30/15 min, throttle answer in `ws-throttler.guard.ts`).
  - Writes `devices."requestSid"/"requestSealPub"` (migration `0023_device_request_queue.sql`, entity columns) on the JWT device's LIVE row only (`DevicesService.setRequestQueue`).
  - `SetRequestQueueDto` takes only the canonical base64url spelling of 32 bytes.
- `searchUsers`: each stranger entry adds:
  - `devices:[{deviceId, bundle, requestSid, sealPub}]` (`DevicesService.firstContactDevices`: `key_bundles` LEFT JOIN `devices`, revoked left out, a legacy device 1 with no row included);
  - `authorization` (new shared `mappers/device-authorization.mapper.ts`, also used by `deviceList`).
  - An account that owes a replacement enrollment answers `devices:[]`, `authorization:null` and claims nothing. Self and friends answer `[]` before any claim. Throttle 30/min → **100/15 min** (the fetch tier).
- `ChatKeyExchangeService.claimBundle` is now the one path that spends an OTP and fires `preKeysLow`: both `fetchPreKeyBundle` and search go through it.
- Docs: `wire.md` "First contact", `backend/CLAUDE.md` §4, root `CLAUDE.md` counts, `task_plan.md` PR3.2 as-built + the PR4.1 move; lint floor 870 → 850.

## Key files
- Edited: `backend/src/chat/{chat.gateway,dto/chat.dto,guards/ws-throttler.guard}.ts`, `chat/services/chat-{search,key-exchange,device-list}.service.ts`, `key-bundles/{device.entity,devices.service}.ts`, `frontend/test_e2e/full_stack_e2e_test.dart`, `test_e2e/support/e2e_test_client.dart` (tracks `requestQueueSet`, `searchUsersResult`).
- New: `backend/migrations/0023_device_request_queue.sql`, `chat/mappers/device-authorization.mapper.ts`, `key-bundles/devices.service.int-spec.ts`.
- Rewritten: `chat/services/chat-search.service.spec.ts` (no `any`).

## Verification
- TDD: the search spec failed to compile first (new constructor and handler), then went green.
  - Mutants 7/7 killed:
    - owed-replacement guard dropped;
    - null bundle served;
    - friend check after the claim;
    - regex loosened to `{43}`;
    - device taken from the default instead of the session;
    - `authorization` omitted;
    - `preKeysLow` dropped from `claimBundle`.
  - SQL mutants 4/4 killed by the new integration spec:
    - `revokedAt` moved into the ON clause;
    - INNER JOIN;
    - update without `IsNull`;
    - entity column type drift.
- jest **1193/68** (1182 before), `verify-claude-backend-test-counts` OK. `npm run test:int` **26/26** (box 23 plus 3 new, fresh DB, 0023 applied). Lint ratchet 850 (improved), knip clean, `verify-no-user-logs` and `verify-box-imports` OK, dart ratchet 3163.
- `flutter test test_e2e` with `E2E_DB_CONTAINER=fireplace-mp-db-1`: **47 passed / 16 skipped** (46 before, plus the new case), run twice. The second run was on the final code after the throttle fix. The new case covers:
  - bob publishes a queue;
  - alice's stranger search returns device 1 with bob's sid/seal key and an OTP bundle;
  - `e2eSql` shows that OTP row `used = t`;
  - no new registrations.
- A rolled-back psql probe on the dev DB matched the SQL semantics before the integration spec existed.
- One independent reviewer: APPROVE with 2 findings, both fixed (search throttle; a committed guard for the SQL semantics).
- NOT verified: no client speaks either verb until PR3.1 (backend only); CI on the pushed tip (see LATEST / the next session); `flutter test` (unit) not re-run, since no `lib/` or `test/` file changed.

## Notes for next session
- NEXT: PR3.1 frontend (`task_plan.md` "PR3.1"). The request queue is published through `setRequestQueue` at boot. First contact seals into each device's request sid. Dedup on `WireKey`. The old path keeps using peer `getDeviceList` until PR4.1/PR4.2.
- Owner-owed (unchanged): prod background-push check; web-deploy gate; 16 MiB box cap; `deleteQueue` → `auth_failed`; I2b; in-app cue for other chats.
- Residual to weigh in PR3.1: registering a push notifier on the REQUEST queue gives it the same token as the device's normal queues. A DB dump could then link account → request sid → `box_notifiers.token` → that device's other queues (an I2b-class link).
- Traps (also in `docs/agents/traps.md`): peer `getDeviceList` must survive release N; every path that hands out a bundle goes through `claimBundle`; `devices` carries an FK-name drift from 0015; `set VAR=… &&` does not export in the agent's bash tool.
