# Friends' device lists now reach us inside E2E, pinned to the server's DAK; the per-connect friend lookup is gone

**Date:** 2026-09-27 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answered O18 → decision 50 (a new device's own handoff carries its account's list; changes design §4.2) and O19 → decision 51 (stop the per-connect lookup of box friends' lists). Engineering calls E50a–E50f in `docs/plans/metadata-privacy-decisions.md`; remainder plan row 6 DONE.
- E50a (added after an advisory): `DeviceListCache.adoptCarried` adopts a carried list only under the `dakPub`+`enrollmentSig` the SERVER last served (`_serverDak`); otherwise `EncryptionProvider.adoptCarriedDeviceList` spends ONE lookup per account per process. Replays at/below the held version: `stale`, never an I7 alarm.
- E50b: `BoxFrame` list-bearing kinds 0x32/0x33 carry the record OUTSIDE Signal; `BoxInboxEntry.carriedList` journals it; `MessagingBox._readFriendRequest` adopts it before `FriendFrameIdentity`/liveness/decrypt. `list_update` envelope for normal queues (`E2eEnvelope.buildListUpdate` / `carriedDeviceList`).
- E50c / decision 51: `EncryptionService` `e2e_<uid>_boxlists_v1` (`u` box peers' records, `r` box-ready stamp, `a` own list announced), seeded at init; `_boxLists.fetch` asks the server for a peer only when none is held or after a gap past the box TTL (`peerListOwedByServer`, `markBoxListsReady(peers)`); only box peers kept (`keepsDeviceListFor`, wired in `ConnectionProvider`).
- E50d: `MessagingBox._announceOwnListIfRevoked` → `BoxFriendHandoff.announceOwnList` (per-device progress `_announced`). E50e: `_rotateAwayFromRevoked` (devices the list NAMES revoked) + `QueueKeys.rotateInbound/retireInbound`, `ContactQueue.retiredAt`, `_retireExpired`. E50f: `_answerStaleView`; box frames look nothing up (`refreshPeerList`, own-skew refetch, accept gate `refetch: false`).
- Review (reviewer agent): 7 findings, all folded (stamp before owed answers, old-path peers seeded, absence = revoked, refused-frame revoke, announce retry churn, no-change writes, oversize list); re-review APPROVE + 3 NITs, 2 folded (stamp only on the box, a refused answer counts), 1 recorded as E50e residual.
- Docs: wire.md "Item 6" + frame kinds + Send; e2e-invariants slice (e) bullet; traps ×6 (1 wrong trap corrected: dev CORS takes any localhost/127.0.0.1 port); CLAUDE.md count 2818 → 2848.

## Key files
- Edited: `frontend/lib/services/device_list/device_list_cache.dart`, `providers/encryption_provider.dart`, `services/encryption_service.dart`, `services/box/{box_frame,box_friend_handoff,box_friends,box_inbox,box_session,queue_keys,box_device_list_refresh}.dart`, `services/contacts/{contact_record,contact_store_inbox}.dart`, `providers/messaging_provider.dart`, `providers/messaging/messaging_provider.{box,decrypt}.dart`, `providers/connection_provider.dart`, `utils/e2e_envelope.dart`; 6 test files.
- New: `test/providers/encryption_provider_carried_device_list_test.dart`, `test/providers/messaging_provider_box_lists_test.dart`.
- Read only: `.planning/metadata-privacy/design-candidate.md` §4.2, `device_authority_engine.dart:345-406` (the chain accepts any IK-endorsed DAK).

## Verification
- `flutter test`: 2848 passed, 14 skipped. `flutter analyze`: 0 errors/warnings. Lint ratchet PASS at 3160.
- Mutants: 22/22 then 9/9 on the review folds — killed (DAK pin off, stale off, lookup unbounded, no seed, reader no adopt, frame list ignored, no rotate/prune/retire, announce dead devices/links/untaken/revoked, stale-view always (killed after a test reorder)/no dedupe, box peer/own refetch, connect forces peers, list_update to request queue, no journal/send list, gap/stamp/keep/absence/refused/dedupe/fit).
- Live drive, release web of the working tree + a throwaway `DRIVE_LOG` print (reverted before commit), one managed Chrome, origins 8091 (ana 342) / 8092–8094 (bob 343 devices 1, 2, 4), local stack:
  - Bob enabled linking and linked #2: ana had bob as not-enrolled (no pin) → `BOX_LIST_CARRIED refetched` (E50a's one lookup) → handoff taken, handed back.
  - Bob linked #4: ana `DEVICE_LIST_CARRIED {version: 3, [1,2,4]}` → `adopted`, handoff taken, NO `DEVICE_LIST_FETCH_EMIT`. Ana's send: `BOX_SEND frames 3`.
  - Bob revoked #2: bob1 and bob4 `BOX_OWN_LIST_ANNOUNCED {all: true}`; ana adopted v4 [1,4] (second copy `stale`), `BOX_FRIEND_QUEUE_ROTATED`, new queue handed to 1 and 4 over their queues; ana's next send `frames 2`, both received. `messages` rows for the chat: 0.
- CI on `cdc1f179` (branch push, draft PR #185): 7/7 success — Backend tests, Flutter analyze and tests, E2E wire harness, E2E isolated probes, Web Lock probe, CodeQL, Analyze (actions).
- NOT verified: E50f's stale-view answer live (unit-tested only); the 30-d retire and the gap re-check live (clock tests); Android/iOS; prod (box OFF).

## Notes for next session
- Next action: slice (f), first contact over request queues (plan row 7).
- Owner-owed (before G5; recorded on decisions 50–51): (1) a MISSED revoke announcement — or a second web tab whose list predates the revoke — keeps encrypting to, and may hand our queue to, the REVOKED (possibly stolen) device until the friend's next frame draws our stale-view answer (E50f) or a >30-d gap forces a lookup; O19's option text named only "a device stays unaddressed". (2) E50a narrows decision 50: the first carry after an account enrolls or changes its DAK costs one lookup naming the pair (the drive's `refetched`).
- Drive accounts left in the local DB: se_ana 342, se_bob 343 (conv 109). Recipe: token injection into `flutter.jwt_token`/`flutter.refresh_token`, `flt-semantics-placeholder` click for a11y, `navigator.standalone`+`matchMedia` init script for linking, codes via `Skopiuj kod` + clipboard, text via `keyboard.sendCharacter`.
- Traps → `docs/agents/traps.md` (E2E ×4, Tests ×1, drive CORS corrected).
