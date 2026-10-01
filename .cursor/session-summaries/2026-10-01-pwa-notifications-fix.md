# PWA notification fixes A–D built and driven (0.2.58): per-chat wake-up cards, hidden-page card, one setup banner, iPhone wake in ~3 s

**Date:** 2026-10-01 · **Version:** 0.2.57 → 0.2.58 · **Tiers deployed:** none

## What was done
- Push SW `frontend/web/web-push-sw.js` (`SW_VERSION` 3): `handleBoxWakeUp` turns `{type:'new_message', n, c}` into one "Umbra / N new messages" card tagged `conversation-<id>` via IndexedDB `box-nids`; `showLocalCard` shows the page's own card; `box-wake` keeps the closed-app badge; `applyPageTotal` closes the generic `new-message` card on a total of 0; any visible page means badge only.
- Page: `ConversationsProvider.postHiddenArrivalCard` (called from `MessagingBox._showBoxMessage` when `isClientVisible` is false; muted chats excluded). `BoxPushNids` (+ `_web`/`_stub`) writes the nid → chat table at `BoxSession._registerPush`; `ConnectionProvider` clears it on logout and account switch. `ContactRecord.chatId` replaces `ConversationsProvider._chatIdOf`.
- `BoxNotifiers` reuses the last challenge code in RAM for 9 min (`codeReuse`, injectable `now`): one "Setting up notifications" banner per session, not per contact queue.
- Backend `backend/src/box/`: Web Push wake-up carries `n`/`c` (`BoxService.notifierFor` counts non-quiet unexpired blobs; FCM stays bare); Web Push TTL split 600 s challenge / 86 400 s wake-up; E83: a send delivered to a live socket also schedules the wake-up, so a frozen iOS page is woken ~3 s after the send; a Web Push wake-up is never sent for a count of 0, nor twice for the same blobs (`announced` map).
- Owner note "native Android is instant, iPhone PWA is not" drove E83. Prod, read-only: bob208's iPhone (device 1) has 12 notifiers on 12 queues, so registration was not its fault.
- Docs: decisions 76/77/79 BUILT, rows E76a–E83; `wire.md` box bullet; `frontend/CLAUDE.md`; `traps.md` (Android / push ×4, Agent tooling ×2); root `CLAUDE.md` §3 count 3071.
- Out-of-repo: throwaway compose project `fpdrive` (backend :3200, DB :5434), python servers :8091/:8092 and a Pixel_7 emulator drive; all stopped, volumes removed. Nothing deployed.

## Key files
- Edited: `web-push-sw.js`, `conversations_provider.dart`, `messaging_provider.box.dart`, `box_session.dart`, `box_notifiers.dart`, `connection_provider.dart`, `contact_record.dart`, `box.gateway.ts`, `box-notifier.service.ts`, `box-push.transport.ts`, `box.service.ts`, `box.int-spec.ts`, `pubspec.yaml`.
- New: `services/box/box_push_nids{,_web,_stub}.dart`, `test/services/box/box_push_nids_test.dart`.
- Read only (load-bearing): `notification_cleaner_web.dart`, `push_sw_channel_web.dart`, `box-delivery.service.ts`.

## Verification
- CI: NOT RUN on the code commit yet (filled in after the push).
- Flutter full suite 3071 passed, 14 skipped (+14 tests); `verify-claude-frontend-test-counts --log` OK. Dart ratchet PASS, 3154 → 3153 (floor lowered). Backend: tsc 0, knip 0, lint ratchet PASS, unit tests 1222 / 68; box int-spec 52/52 on a throwaway DB (46 → 52).
- Red-first: A's tests failed on the old `BoxNotifiers`; the two int tests for the c = 0 and repeat guards failed with the guards off and passed with them on. SW logic: ~30 checks in a node:vm harness with a fake `indexedDB` (no permanent file; the repo has no SW test runner).
- Driven, release web 0.2.58 against the local stack, hand-launched Chrome + CDP: hidden page → local card in 0.66 s, 3 sends = one card "3 new messages", cleared on open, muted = none; closed page → wake-up card 3.0–3.2 s with the chat tag; frozen page (`Page.setWebLifecycleState frozen`) → card 2.9–3.3 s; visible page → no push; second contact → no new challenge (code reused).
- Driven on the Pixel_7 emulator's Chrome: a hidden page acks and cards in ~0.4 s for 60.0 s, Chrome then freezes it and the E83 wake-up cards in 3.2–3.6 s; tap deep-links.
- Found by the drives and fixed: a `c: 0` push after a frozen page resumed, and a second card ~40 s later (ping-timeout wake-on-detach). RE-DRIVEN on the final backend (desktop Chrome, push listener inside the SW): hidden + frozen → exactly one push at +2.9 s and none at +33 s when the socket dropped; resume → no push; a second message while frozen → one more push (c:2); closed page → one push.
- `showLocalCard` got `pushCardCovers` (a thawed hidden page must not re-alert for a message a wake-up card already covers). Driven with the new SW copied into the served bundle: frozen → wake-up card → thaw while hidden → 0 extra shows (T1); a second message → one show "2 new messages" (T2); never-frozen hidden page → one local card (T3). T4 FAILED as a corner: with an EARLIER unread message in the chat the page's count (2) beats the card's (1, waiting blobs only), so the thaw shows one extra alert with the right count. Left as is.
- NOT verified: a real iPhone (Apple branch only in the vm harness), a real Android phone or an installed WebAPK, deep Doze, prod.

## Notes for next session
- Next action: with CI green on the code commit, deploy backend then web 0.2.58 (`production-vm-deploy`), then have the owner open the iPhone PWA once (the SW updates on load: `PUSH_SW {version: 3}`) and send a message with the app closed.
- Owner-owed: overrule E82 (TTL 600 s / 24 h) or E83 (wake-up for a live socket that does not ack) if wanted. Owner decided to LEAVE native "messages only fill the chat after open" as it is.
- Residual: the nid table carries no mute, so a muted chat's wake-up still cards (E77a). T4 above (thaw over earlier unread: one extra alert; fix = send `arrived` beside `count` in `local-card` and compare that). Light Doze can hold Chrome's push until the screen wakes (emulator, 2 of 4 six-minute runs).
- Unrelated, seen in both drives: `getMessages` reaches the server with a box chat id (2^48 + peer): `QueryFailedError ... out of range for type integer` in `ChatMessageService.handleGetMessages`. It also names the pair to the server. Pre-existing, not touched; file it.
- Recipes: the drive stack and Chrome/CDP steps are in `traps.md` (Agent tooling, last two lines; Chrome Web Push line).
- Traps: five lines appended to `traps.md` (Android / push ×4, Agent tooling ×2).
