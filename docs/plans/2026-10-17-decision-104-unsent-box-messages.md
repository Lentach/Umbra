# Decision 104: keep a failed box message on the device

Owner, 2026-10-17. This amends decision 19. A box message that did not go out stays on the device: it shows red with "Ponów" after leaving the chat and after a restart. It is never resent until the user taps it, and the retry reuses its wire id.

## Why

Driven 10-17 on release web builds (0.2.66 and 0.2.67, dev stack, d101 accounts). A failed or stuck box message was lost on reload, and even on just leaving the chat; it never reached the friend (`hang1`, `r1`–`r3`). Today the row lives only in RAM (decision 19).

Confirmed in code, not driven: `_sendOverBox` stores the sender's own record only after a peer device took a frame (`messaging_provider.box.dart:2494`). A reload mid-`deliver` can therefore leave the friend with the message and the sender without it.

## Before building: the rerun

The d101 drive accounts can't take a box send to d101a: d101a (user 253) holds a never-online 0.2.65 sibling, device 8, so under E101b every friend's send fails red at once.

1. Revoke device 8 from d101a's Devices screen on origin 8091. Not by SQL: the signed list decides coverage.
2. A control send from F4 (8094) to d101a must go green.
3. Hold only the box's `send` ack: drop the incoming `43/box,…` frame and let the outgoing frame through. Reload the sender and check both sides.
4. Read the reason for every red send in Privacy & Safety → the diagnostics panel. The page console doesn't carry `BOX_*`/`SEND_*` lines.

## Design sketch (no code written yet)

- **Store:** `e2e_<uid>_boxunsent_v1` in content kv.
  - Add it to the sealed-family regex in `sealed_web_content_kv.dart:86`.
  - Mirror `boxact_v1` (`encryption_service.dart:4184-4327`): the cross-context lock plus an in-process queue, no backup, a cap, and a 30-day prune.
- **Entry**, keyed by tempId: chat, peer, createdAt, wire id (`_sendTokenFor`), type, content, ttl, reply, and the box media fields if the attachment was uploaded.
- **Write:**
  - When a send enters the box branch: `messaging_provider.send.dart:1655-1695`, before `_boxRoute`.
  - At `BOX_RETRY_NO_ROUTE` (`:1705`).
- **Drop:** after the sent record is stored (`messaging_provider.box.dart:2494`), and when the user deletes the failed row.
- **Restore:**
  - In `_mergeLocalBoxRows` (`messaging_provider.box.dart:1619`, which runs on every chat open and launch) as `failed` rows.
  - Re-seed `_pendingSendContent`, `_sendTokenByTempId` and `_boxTempIds`, so a retry never falls back to the old path. The box may already hold the message, and receivers drop a repeated wire id.
- **Residual:** an attachment whose upload never finished can't be retried after a restart, because its bytes are gone.
