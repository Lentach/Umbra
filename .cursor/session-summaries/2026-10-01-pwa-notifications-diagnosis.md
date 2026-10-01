# PWA notifications after step B: three box-path causes found, no code changed

**Date:** 2026-10-01 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- Investigation only (owner: "investigate, do not implement"). Evidence and query output: `.planning/pwa-notifications/findings.md`.
- Missed cards = H1, confirmed in code. `box.gateway.ts` `send` schedules the notifier only when no socket owns the rid (`BoxDelivery.onEnqueued`).
  - `BoxInbox` journals and acks with no visibility gate, so a hidden page whose socket lives gets box messages with no push and no card.
  - Desktop PWA: never a card. Android PWA: none while Chrome keeps the page alive. iOS: a push only after the ping timeout (~45 s).
  - The old path pushes whenever the device is not visible (`chat-message.service.ts:556-572`).
- Cards stay after reading. The box wake-up is `{type:'new_message'}` only, so `web-push-sw.js` tags it `new-message`.
  - `close-conv` and `sweepStaleNotifications` touch only `conversation-<id>` tags. Nothing in the app closes it.
  - Tapping it opens `/` with no deep link. The badge is not updated.
- "Setting up notifications": `handleNotifierChallenge` → `postAndClose` on every Apple-endpoint challenge, and on Chrome when no page is visible.
  - `BoxNotifiers` runs one challenge per pass, and a pass runs for each new contact queue. So each pair that moves onto the box costs a banner.
- Android shows no pop-up: Chrome's site/WebAPK channels default to IMPORTANCE_DEFAULT (no heads-up). Only the user can raise it, the same fix the owner made on 09-30.
- Messages landing on open is by design. Push is content-free and decrypt lives in the page, so blobs wait in the box until the app subscribes. This is not a migration artefact.
- Timeline: the owner places the reports after the metadata merge. Prod ran `5c18cdf0` until release 0.2.53 and step B (09-30), which brought in every box commit and PR0.2 (`482563f5`).
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
  - 46 contact queues: 29 with a notifier (17 Apple, 9 Chrome web, 3 FCM) and 17 without. 16 of those 17 are empty; one holds the 09-30 drive's test blobs.
  - One Apple token activated 12 queues in 7 separate minutes over 34 h, so at least 7 banners on that device.
  - 16/116 live devices have a request queue.
  - 40 h of backend logs show no `[box] … refused` and no `wake-up push failed` lines.
- NOT verified on a device: how long an Android PWA socket lives in the background. The iOS challenge banner rests on code and the owner's report only.

## Notes for next session
- Next action: the owner picks a fix order. Recommended:
  - (1) Close `new-message` cards on app foreground or on a sweep with unread 0 (web-only, no privacy impact).
  - (2) H1: the page posts a local content-free card when a box message is journaled while hidden. A visibility signal to the box would be OWNER-class.
  - (3) Reuse a still-live challenge code (10-min server TTL; `activate` accepts more nids) before challenging again, so a session costs one banner, not one per contact.
- Owner-owed: raise `TTL: 120` (box + old path)? A device offline > 2 min loses the wake-up for good.
- NOT verified: Android background socket lifetime; iOS banner frequency on a real phone.
- Traps: two lines appended to `traps.md` (Android / push).
