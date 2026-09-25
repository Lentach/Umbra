# Owner decisions 37–39 answered and built: sibling re-key refusal, connect-time session pre-build, Apple push flash

**Date:** 2026-09-25 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only)

## What was done
- Owner answered the three owed questions in one batch (S8). Recorded as decisions 37 (O6), 38 (O7) and 39 (Apple `new_message` banner) in `docs/plans/metadata-privacy-decisions.md` (`cdef5d12`); O6/O7 in the Open table point at them.
- Decision 39 (`78a4f36c`): `web/web-push-sw.js` now has top-level `isApplePushEndpoint()` (fails toward Apple) and `postAndClose(title, body, tag, data)`. The box `notifier_challenge` and a `new_message` suppressed for the focused chat both flash-and-close on Apple endpoints. A failed flash never skips the sweep/badge writes.
- Decision 37 (`79632a91`): `_readSiblingBox` refuses a sibling PreKey message that would REPLACE our session unless `BoxSession.awaitingRekeyFrom(d)` (10 min, in memory, cleared by `rekeyAnswered` on the first decrypt). A refused frame is finished and answered by `rekeySibling(d)`, which now encrypts with `fresh: true` (`markSessionRebuild` + `ensureSession` → libsignal archives). The test is `preKeyWouldReplace` (`prekey_identity.dart`) behind `EncryptionService.siblingPreKeyWouldReplace`, mirroring libsignal 0.8.2 `processV3`. Engineering calls E37a/E37b.
- Decision 38 (`8cd0949e`): `BoxDeviceListRefresh(prebuild:)` runs `MessagingBox._prebuildBoxSessions` after each verified list; `readyFor` resolves after both; passes per user serialized. `_sendOverBox` no longer calls `ensureSession`: a target without a usable session fails the row (`BOX_SEND_NO_SESSION`) before anything is encrypted. Engineering calls E38a/E38b; E5 points at 38.
- Docs: `frontend/CLAUDE.md` §push silence, `frontend/docs/e2e-invariants.md` (two new lines: 37, 38), traps (Apple branch proof, libsignal shallow copy), root `CLAUDE.md` count 2616 → 2635. Earlier-session summary corrected (`b72eb958`).
- Decisions 37 and 38 were built by subagents from my specs and design rows. I reviewed the lib diffs, checked the missing-record → fresh `SessionRecord()` path (`signal_stores.dart:902`), and checked the rebuild-request → `invalidateDeviceList` → pre-build chain (`encryption_provider.dart:2772-2779`).

## Key files
- Edited: `frontend/web/web-push-sw.js`; `frontend/lib/providers/messaging/messaging_provider.box.dart`, `messaging_provider.dart`, `encryption_provider.dart`; `frontend/lib/services/{encryption_service,encryption/prekey_identity,box/box_session,box/box_siblings,box/box_device_list_refresh}.dart`; tests `messaging_provider_box_sibling_test.dart`, `messaging_provider_box_send_test.dart`, `box_session_siblings_test.dart`, `box_device_list_refresh_test.dart`
- New: `frontend/test/providers/messaging_provider_box_sibling_rekey_test.dart` (real libsignal, two devices)
- Read only (load-bearing): libsignal_protocol_dart 0.8.2 `session_builder.dart:56-76`, `session_record.dart`, `session_state.dart:30-32`

## Verification
- Decision 39: a throwaway `vm` harness ran the REAL SW source with a fake `self` over 8 cases. With a focused chat: Apple posts silent then closes; FCM posts nothing; a failed `getSubscription` posts then closes. With an unfocused chat: FCM and Apple both post a loud card that stays. `notifier_challenge`: nothing on a visible page on FCM; a flash on Apple, or when hidden.
- Decision 39 device drive: release web, installed Chrome, real FCM subscription, account 284 with chat 83 open. CDP `ServiceWorker.deliverPushMessage` with SW `showNotification` recorded: a focused conv 83 got no show; conv 999 got a card; a challenge on the visible page got no flash.
- Decision 37: red first (compile errors plus 3 assertion failures), then green (+49 in 3 files). Box/contacts/messaging set +337. Web drive with two linked devices of d37a (288) plus friend d37b (289): the link converged with no refusal and a normal sibling send worked. Deleting A2's session key produced A2 `BOX_SIBLING_REKEYED` → A1 `BOX_SIBLING_PREKEY_REFUSED` → `SESSION_ARCHIVED_FOR_REBUILD` → A1 `BOX_SIBLING_REKEYED` → A2 `BOX_SIBLING_HANDOFF acked`. Later copies read on both devices.
- Decision 38: red first (compile error plus 6 failures), then green (+50). Set +347. Web drive with d38a (290) and d38b (291), CDP `webSocketFrameSent`. Session deleted, then reload: `fetchPreKeyBundle` went out at connect, and the send put only `typing` plus the box `send` on the wire. Session deleted, no reload: the send failed with `BOX_SEND_NO_SESSION` and no fetch; the reconnect pre-built; Retry sent over the box; 0 server `messages` rows.
- flutter analyze 0 errors/warnings; Dart ratchet held (3163).
- CI: `78a4f36c` 7/7; `79632a91` 7/7 (count 2625); `8cd0949e` 7/7 (count 2635).
- NOT verified: iOS/Safari (decision 39's Apple branch, vm harness only), Android, Firefox, a forged PreKey from a REVOKED device (unit tests only), prod (box OFF).

## Notes for next session
- Next: remainder item 3, the decision-22 slice (E17 media, E18 replies/timers). Batch OWNER questions in one note first.
- Residuals (log E37b/E38b): crossing first contacts spend both once-per-session re-key guards; a second loss in one session waits for a reconnect; a session lost after a good pre-build pass heals only at a list change or reconnect; a failed own-account pre-build fails every box send until retried.
- Dev DB now holds users 288–291 and conversations 86/87 (drive accounts).
- Traps: libsignal shallow-copy trial decrypt; the Apple SW branch cannot be exercised in Chrome (both in `docs/agents/traps.md`).
