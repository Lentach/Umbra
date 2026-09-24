# PR3.1 slice (a): each device creates, stores and publishes its box request queue

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answered all 11 open decisions one at a time; recorded in `.planning/metadata-privacy/task_plan.md` above the PR3.1 block and in `NEXT.md`. Short: I2b request-sid exception accepted; no push notifier on a request queue; OTP-in-search kept (combined drain is 200 / 15 min per account: fetch 100 + search 100, separate throttler buckets — first told "same risk", corrected); friend filter moves into the app in PR3.1; PR3.1 in 7 ordered slices (a)–(g); the full first-contact e2e lands with slice (f); prod background push PASSED on the owner's phone (prod backend 0.2.51); web deploy of master is a separate owner-scheduled task; 16 MiB box cap: RAISE NOW (32 MiB rung + nginx `client_max_body_size` before the slice that moves media); `deleteQueue` → `auth_failed` accepted as "gone"; no in-app cue for other chats (owner: the open chat's sound + banner works fine).
- New `frontend/lib/services/box/box_session.dart` `BoxSession`: owns the `BoxClient`; publishes `setRequestQueue {sid, sealPub}` once per (device id, sid) per session after the box is ready, the account socket is ready and the store is open; refused → next ready, `rate_limited` → `retryAfterMs`, `accountLost` clears the in-flight answer, a request rid refused on resubscribe is replaced; `storeOpened()` re-runs it after a locked web vault unlocks.
- `QueueKeys.ensureRequest` (`queue_keys.dart`): load, or create `kind:'request'` → `ContactStore.claimRequestQueue` → subscribe; a refused stored rid is dropped and replaced once; the loser of a tab race deletes its queue. No notifier.
- `ContactStore` (`contact_store.dart`): one row `e2e_<uid>_boxreq_v1` OUTSIDE `contact_v1_` (the history backup copies that family verbatim); `requestQueue`, `requestQueueUnsupported`, `claimRequestQueue`, `dropRequestQueue`, `_readWhere`/`_decodeRequest`; unreadable row replaceable, a newer build's row untouched.
- `SealedWebContentKv._familyKey` + `boxreq_v1` (sealed on web).
- `ConnectionProvider`: `setProviders(boxClient:)`; step 4d creates one `BoxSession` per account (resume on same-account connect); `socketReady` → `accountReady(deviceId)`; disconnect → `accountLost`/`close`; logout + `dispose` → dispose; `requestQueueSet` routed; `onPasscodeLockRestore` and the 4b late-open path call `storeOpened()`. `ConversationsScreen` wires `BoxClient(baseUrl:)`.
- Docs: `wire.md` "First contact" (client speaks it; no notifier rule) + "The box" Client bullet; `e2e-invariants.md` boxreq bullet; `frontend/CLAUDE.md`; root `CLAUDE.md` flutter 2393/14.

## Key files
- New: `frontend/lib/services/box/box_session.dart`, `frontend/test/services/box/box_session_test.dart`, `frontend/test/providers/connection_provider_box_test.dart`.
- Edited: `frontend/lib/services/box/queue_keys.dart`, `frontend/lib/services/contacts/contact_store.dart`, `frontend/lib/services/encryption/sealed_web_content_kv.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/lib/screens/conversations_screen.dart`, `frontend/test/services/box/queue_keys_test.dart`, `frontend/test/services/sealed_web_content_kv_test.dart`, `docs/contracts/wire.md`, `frontend/docs/e2e-invariants.md`, `frontend/CLAUDE.md`, `CLAUDE.md`.
- Read only (load-bearing): `frontend/lib/services/box/box_client.dart` (resubscribe → `lostQueues` BEFORE `ready`; reconnect gives up after `reconnectMaxAttempts` until the next `connect()`).

## Verification
- TDD: every new test red first (missing API; boxreq row in cleartext on web; no publish after unlock), then green.
- `flutter test`: 2393 passed / 14 skipped (full suite, via `hub start` + `cmd /c`); `verify-claude-frontend-test-counts.mjs` OK; Dart lint ratchet held at 3163 (6 new infos fixed).
- Mutants 14/14 killed: claim keeps the disk row, refused-rid replace, newer-build guard, publish dedupe, device-id in the dedupe key, rate-limit retry, lost-rid reset, `accountReady` + `requestQueueSet` routing, logout dispose, `storeOpened` body + restore call. Two first-round survivors fixed by tightening tests (claim-race disk check; cross-account publish after logout).
- Live smoke on the mp stack (throwaway, deleted): real `BoxSession` → `requestQueueSet {success:true}` → a stranger's `searchUsers` returns the stored sid + sealPub → stranger `send` `BoxOk` → delivered and opened ("hello").
- Reviewer Pr31aReview: REQUEST_CHANGES → P2 (store opening after both sockets never re-ran ensure) fixed; P3 docs "once per (device, sid)" → "per session" fixed; P3 "logout test survives without dispose" rejected — that exact mutant was killed (logout nulls `_box`).
- CI 7/7 green on `2bc95974` (CodeQL, E2E wire harness, Flutter, backend, isolated probes, Web Lock probe, Analyze).
- Browser drive (owner ask; release web build `--dart-define=BASE_URL=http://localhost:3000` served on 127.0.0.1:8081, deleted after): registered `pr31azk5r60` (user 261) in the UI → DB `devices` 261/1 has `requestSid` + `requestSealPub`; `box_queues` row for that sid is `kind=request`, 0 `box_notifiers`, `touchedDay` today, `claimBy` null (subscribed); `localStorage flutter.e2e_261_boxreq_v1` is an `fps1:` envelope with no plaintext key names; after a page reload the same sid and no unclaimed request queue; no page errors.
- NOT verified: the 4b late-open `storeOpened()` call (needs the 4 s budget; untested); Android emulator/phone; nothing sends into a request queue from app code until slice (f).

## Notes for next session
- Next: slice (b) — one envelope dispatcher: subscribe the contacts' inbound queues at boot and consume + ack `BoxDelivery` (at-least-once, dedup on `WireKey`). Remember decision 9: the 32 MiB rung + nginx body size land before the slice that moves media into the box.
- With `BOX_ENABLED=false` (prod today) every client retries `/box` up to `reconnectMaxAttempts` per account connect, then waits for the next one — harmless, and the branch ships with release N which enables the box.
- Traps (also in `docs/agents/traps.md`): subagents default to the MAIN checkout — name the worktree path; `hub start` `bash` resolves to WSL on this PC — use `cmd /c`.
