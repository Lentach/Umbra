# PWA notifications after the metadata release: three box-path causes found, no code changed

**Date:** 2026-10-01 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- Investigation only (owner: "investigate, do not implement"). Evidence and query output: `.planning/pwa-notifications/findings.md`.
- Missed cards = H1, confirmed in code. `box.gateway.ts` `send` schedules the notifier only when no socket owns the rid (`BoxDelivery.onEnqueued`).
  - `BoxInbox` journals and acks with no visibility gate, so a hidden page whose socket lives gets box messages with no push and no card.
  - Desktop PWA: never a card [from code, not driven]. Android PWA: none while Chrome keeps the page alive. iOS: a push only after the ping timeout (~45 s).
  - The old path pushes whenever the device is not visible (`chat-message.service.ts:556-572`).
- Cards stay after reading. The box wake-up is `{type:'new_message'}` only, so `web-push-sw.js` tags it `new-message`.
  - `close-conv` and `sweepStaleNotifications` touch only `conversation-<id>` tags. Nothing in the app closes it.
  - Tapping it opens `/` with no deep link. The badge is not updated.
- "Setting up notifications": `handleNotifierChallenge` → `postAndClose` on every Apple-endpoint challenge, and on Chrome when no page is visible.
  - `BoxNotifiers` runs one challenge per pass, and a pass runs for each new contact queue. So each pair that moves onto the box costs a banner.
- Android shows no pop-up: Chrome's site channels are reported to default to IMPORTANCE_DEFAULT, which gives no heads-up [INFERENCE: Chromium source not re-checked; WebAPK not checked]. Only the user can raise it, the same fix the owner made on 09-30.
- Messages landing on open is by design. Push is content-free and decrypt lives in the page, so blobs wait in the box until the app subscribes. This is not a migration artefact.
- Timeline: the owner places the reports after the metadata merge. Release N (0.2.52, `5c18cdf0`) already held PR0.2 (`482563f5`), the new push SW and every box commit. It reached prod on 09-29 at ~18:53Z with the box OFF. Step B followed on 09-30 at ~01:44Z.
  - So any report from the evening of 09-29 can only be old-path/PR0.2. The box causes start at step B.
  - PR0.2 also widened old-path suppression. The push used to be skipped only while the recipient device was FOCUSED on that chat. Now it is skipped while the device reports itself visible at all.
  - A stale `clientVisible: true` (a hidden emit that never lands before iOS freezes) now silences every chat until the ping timeout. There is no wake-on-detach on the old path [INFERENCE: not measured].
- Out of repo: read-only SQL and `docker compose logs` on prod. The SW harness ran in the eval kernel (no file). No services were left running.

## Key files
- Read only (load-bearing): `frontend/web/web-push-sw.js`, `backend/src/box/box.gateway.ts`, `box-notifier.service.ts`, `box-push.transport.ts`, `box-delivery.service.ts`.
- Also: `frontend/lib/services/box/box_notifiers.dart`, `box_inbox.dart`, `push_box_source.dart`, `web_push_bridge_web.dart`, `notification_cleaner_web.dart`, `backend/src/chat/services/chat-message.service.ts`.
- New: this summary, `.planning/pwa-notifications/findings.md` (gitignored).

## Verification
- CI: 6/6 success on `279007e2` (last code commit; this commit is docs-only).
- SW harness (real `web-push-sw.js` in `node:vm`, fake `self`):
  - A box push leaves `[Umbra, New message, new-message]`, and it is still there after `close-conv 42` + `sweep []` (red). The old-path control (`conversationId 42`) is swept.
  - Challenge: apple+visible → show+close; chrome+visible → nothing; chrome+hidden → show+close.
- Prod, 14:20 UTC:
  - 46 normal queues: 29 with a notifier (17 Apple, 9 Chrome web, 3 FCM) and 17 without. Every box device mints one self-queue (`ensureSelf`, kind normal, no notifier by design, decision 32).
  - The 17 match the request queues by `touchedDay` (9/8 vs 8/8). So they are self-queues, and every contact queue has a notifier: there is no registration gap server-side.
  - The 105-blob notifier-less queue is therefore a self-queue: sent copies for an own sibling device not seen since 09-30. These are not lost messages [INFERENCE: device identity not checked].
  - One Apple token activated 12 queues in 7 separate minutes over 34 h, so at least 7 banners on that device.
  - 16/116 live devices have a request queue.
  - 40 h of backend logs show no `[box] … refused` and no `wake-up push failed` lines.
- NOT verified on a device: how long an Android PWA socket lives in the background; whether iOS shows the challenge banner before `close()` and whether `close()` removes it (code + owner report only); when the owner's users first reported (09-29 evening vs after step B).

## Notes for next session
- Owner, at session end: "it's not broken now, notifications arrive normally". This fits conditional causes (H1 needs a live background socket; a banner comes with each new contact queue).
  - Then: "start fixing, do your best to resolve this problem — let a fresh agent handle it". So fixes 1–3 are APPROVED, and the calls are delegated (log them as E-rows).
- Next action: implement fix 1 → 2 → 3 (full brief, file:line and recipes in `.planning/pwa-notifications/findings.md` § Implementation brief).
  - (1) `web-push-sw.js`: close the `new-message` tag on a `sweep`/`close-conv` whose `unreadTotal` is 0 (box unread is already in `_unreadCounts` via `_boxUnread`). Bump `SW_VERSION`.
  - (2) H1: when a PEER box message arrives while the page is hidden, the page asks the SW for a local card tagged `conversation-<id>`, with no server signal. The existing sweep then clears it. Candidate hook: `MessagingBox._showBoxMessage` (`messaging_provider.box.dart:1443`); trace its callers first.
  - (2) must exclude: the drain on app open, receipts/typing, sibling copies, redeliveries.
  - (3) `BoxNotifiers`: keep the last live code (server TTL 10 min) and activate new queues with it before challenging again. `authFailed` → challenge as today. Wire-legal under decision 34.
- Agent call (owner may overrule): split the box TTL. Challenge ≤ 600 s; wake-up for hours (blobs live 14 d).
  - The old path also uses 120 s (`push-notifications.service.ts:345`, pinned by spec `:182`). The relay already sees the TTL, so nothing new leaks.
- Done = device drive (release web against `docker-compose up`, where the box is on by default, plus two box-paired accounts), CI green, and the PATCH bumped. iPhone/Apple branch: vm harness, plus the owner's iPhone.
- NOT verified: Android background socket lifetime; iOS banner/`close()` on a real phone; report start time (it separates PR0.2 from the box causes).
- Traps: three lines appended to `traps.md` (Android / push): the uncleared box card, a challenge banner per new queue, and notifier-less normal queues being self-queues.
