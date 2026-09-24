# PR3.1 slice (a): each device creates, stores and publishes its box request queue

**Date:** 2026-09-24 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answered all 11 open decisions one at a time; recorded in `.planning/metadata-privacy/task_plan.md` above the PR3.1 block and in `NEXT.md`. Short: I2b request-sid exception accepted; no push notifier on a request queue; OTP-in-search kept (combined drain is 200 / 15 min per account: fetch 100 + search 100, separate throttler buckets — first told "same risk", corrected); friend filter moves into the app in PR3.1; PR3.1 in 7 ordered slices (a)–(g); the full first-contact e2e lands with slice (f); prod background push PASSED on the owner's phone (prod backend 0.2.51); web deploy of master is a separate owner-scheduled task; 16 MiB box cap: RAISE NOW (32 MiB rung + nginx `client_max_body_size` before the slice that moves media); `deleteQueue` → `auth_failed` accepted as "gone"; no in-app cue for other chats (owner: the open chat's sound + banner works fine).
- New `frontend/lib/services/box/box_session.dart` `BoxSession`: owns the `BoxClient`; publishes `setRequestQueue {sid, sealPub}` once per (device id, sid) per session after the box is ready, the account socket is ready and the store is open; refused → next ready, `rate_limited` → `retryAfterMs`, `accountLost` clears the in-flight answer, a request rid refused on resubscribe is replaced; `storeOpened()` re-runs it after a locked web vault unlocks.
- `QueueKeys.ensureRequest` (`queue_keys.dart`): load, or create `kind:'request'` → `ContactStore.claimRequestQueue` → subscribe; a refused stored rid is dropped and replaced once; the loser of a tab race deletes its queue. No notifier.
- `ContactStore` (`contact_store.dart`): one row `e2e_<uid>_boxreq_v1` OUTSIDE `contact_v1_` (the history backup copies that family verbatim); `requestQueue`, `requestQueueUnsupported`, `claimRequestQueue`, `dropRequestQueue`, `_readWhere`/`_decodeRequest`; unreadable row replaceable, a newer build's row untouched.
- `SealedWebContentKv._familyKey` + `boxreq_v1` (sealed on web).
- `ConnectionProvider`: `setProviders(boxClient:)`; step 4d creates one `BoxSession` per account (resume on same-account connect); `socketReady` → `accountReady(deviceId)`; disconnect → `accountLost`/`close`; logout + `dispose` → dispose; `requestQueueSet` routed; `onPasscodeLockRestore` and the 4b late-open path call `storeOpened()`. `ConversationsScreen` wires `BoxClient(baseUrl:)`.
- `BoxClient._lostConnection` (emulator-found): past `reconnectMaxAttempts` the box keeps retrying at `reconnectMaxDelay` until `close()` — before, a server outage > ~31 s left it dead until an app restart.
- Docs: `wire.md` "First contact" (client speaks it; no notifier rule) + "The box" Client bullet; `e2e-invariants.md` boxreq bullet; `frontend/CLAUDE.md`; root `CLAUDE.md` flutter 2393/14.

## Key files
- New: `frontend/lib/services/box/box_session.dart`, `frontend/test/services/box/box_session_test.dart`, `frontend/test/providers/connection_provider_box_test.dart`.
- Edited: `frontend/lib/services/box/queue_keys.dart`, `frontend/lib/services/contacts/contact_store.dart`, `frontend/lib/services/encryption/sealed_web_content_kv.dart`, `frontend/lib/providers/connection_provider.dart`, `frontend/lib/screens/conversations_screen.dart`, `frontend/test/services/box/queue_keys_test.dart`, `frontend/test/services/sealed_web_content_kv_test.dart`, `docs/contracts/wire.md`, `frontend/docs/e2e-invariants.md`, `frontend/CLAUDE.md`, `CLAUDE.md`.
- Also edited: `frontend/lib/services/box/box_client.dart` (+ `box_client_test.dart`); `lostQueues` fires BEFORE `ready`.

## Verification
- TDD: every new test red first. `flutter test` full suite green (count in root `CLAUDE.md`, verifier OK); Dart lint ratchet held at 3163; 17/17 mutants killed; CI 7/7 on `2bc95974` and `d501ffc7`. Mutant list, review back-and-forth and drive detail: `.planning/metadata-privacy/findings.md`.
- Live Dart smoke on the mp stack: publish → stranger search returns the stored sid + sealPub → stranger `send` → delivered and opened.
- Browser drive (release web on 127.0.0.1:8081): registered user 261 in the UI → `devices` holds `requestSid`/`sealPub`; `box_queues` row `kind=request`, 0 notifiers, subscribed; `flutter.e2e_261_boxreq_v1` is an `fps1:` envelope; reload → same sid, no new queue; no page errors.
- Emulator drive (Pixel_7 AVD, debug APK): published, no notifier; force-stop + relaunch → same sid (SQLCipher), no new queue. **Found a bug**: after a 194 s backend restart the box never reconnected (the reconnect manager stops after 5 attempts) — fixed in `BoxClient._lostConnection` (keeps retrying at `reconnectMaxDelay` until `close()`), regression test red→green, re-driven: box back at healthy+30 s while backgrounded.
- NOT verified: passcode-locked web boot → unlock (`storeOpened`) on a device; the 4b late-open call; iOS; the owner's phone.

## Notes for next session
- Next: slice (b) — one envelope dispatcher: subscribe the contacts' inbound queues at boot and consume + ack `BoxDelivery` (at-least-once, dedup on `WireKey`). Remember decision 9: the 32 MiB rung + nginx body size land before the slice that moves media into the box.
- With `BOX_ENABLED=false` (prod today) every client retries `/box` up to `reconnectMaxAttempts` per account connect, then waits for the next one — harmless, and the branch ships with release N which enables the box.
- Decision 3 (OTP drain) re-asked with the corrected fact (200/15 min, double the old limit): owner kept it.
- Traps (also in `docs/agents/traps.md`): subagents default to the MAIN checkout — name the worktree path; `hub start` `bash` resolves to WSL on this PC — use `cmd /c`; `ChatReconnectManager` stops after 5 attempts; AVD airplane mode does not cut 10.0.2.2; never leave a capped context file near its cap.
