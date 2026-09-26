# Box messages get reactions, pins, edits and delete-for-everyone over E2E (item 4); the box now has a global storage ceiling and a per-socket rid cap (item 9)

**Date:** 2026-09-26 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy` only; prod still `BOX_ENABLED: 'false'`)

## What was done
- The owner answered O13 and O14 in one pass. Decision 45: a pin on a box message is an E2E pin that both sides see, and it clears an old server pin with one `unpinMessage`. Decision 46: an action takes the same path as its message. Logged with engineering calls E19a–E19j (`d53d3a91`).
- Item 4 (`81b795e8`): `messaging_provider.box_actions.dart` sends and reads envelopes `t: react|pin|edit|del` with `tg {s, w}`. The pin is a last-writer-wins register at `ContactSettings.boxPin`, left out of the contact backup. Delete tombstones live in `e2e_<uid>_boxdel_v1` for 30 days. Delete-for-everyone clears `re.x` in RAM and in the records, which closes the item-3 residual. UI gates open through `hasActionTarget`. Four failure snackbars are in both ARBs.
- Item 4 review fixes (same commit):
  - `_editOverBox` applies last-writer-wins on the sender, and reverts or settles only its own `_pendingEdits` snapshot.
  - `onMessagePinned` keeps the register's own `ts` and never uses this device's clock.
  - The server pin is forgotten only when `messageUnpinned` arrives (`serverPinOf` replaced `takeServerPin`).
- Item 9 (`4f089b11`) was built in a separate worktree and cherry-picked:
  - Migration `0024_box_totals.sql` adds a one-row running total, checked in `enqueue` and `chargeMedia`: 60 000 blobs and 2 GiB of media, otherwise `quota_exceeded`, with no oracle.
  - `BOX_SOCKET_RID_CAP` 1 024, refused per entry with the code `limit`.
  - Refusal counters `send:ceiling`, `mediaUpload:ceiling` and `mediaUpload:budget`.
- Item 9 review fix (`ced0d698`): `BoxClient._subscribeChunks` treats `limit` as not gone. The rid stays in the set, is never reported lost, and is offered again on the next connection.
- Docs: `wire.md` covers the item-4 envelopes, the ceiling and the rid cap. The decision log marks decisions 30, 45 and 46 DONE. The remainder note marks items 4 and 9 DONE. `CLAUDE.md` Flutter count is 2762 (`c7f4abd0`).

## Key files
- New: `frontend/lib/providers/messaging/messaging_provider.box_actions.dart`, `backend/migrations/0024_box_totals.sql`, `backend/src/box/entities/box-totals.entity.ts`, 3 item-4 test files.
- Edited: `conversations_provider.dart`, `messaging_provider{,.box,.actions,.decrypt}.dart`, `contact_record.dart`, `encryption_service.dart`, `e2e_envelope.dart`, `message_ids.dart`, `widgets/message/*` (menu gates only), `box.service.ts`, `box.gateway.ts`, `box-media.controller.ts`, `box-delivery.service.ts`, `box-throttler.guard.ts`, `box_client.dart`, `box_wire.dart`, `docs/contracts/wire.md`, `docs/plans/*`.
- Read only: `.cursor/session-summaries/2026-09-26-metadata-item3-decision22.md`, `2026-09-25-metadata-sibling-queues-b.md` (drive recipe).

## Verification
- Flutter full suite 2761/14 before the item-9 client test was added, `flutter analyze` 0 errors or warnings, the lint ratchet held at 3160. Item-9 box tests 214/214, including the new `limit` test (red first: "lost isEmpty" failed).
- Backend (item 9): `npm run test:int` 38/38 (7 new, all red before the fix), jest box 16/16, `tsc` clean, 17/17 mutants killed. Independent review: APPROVE, with one MINOR (the client did not know `limit`) that is now fixed.
- Item 4: 38/38 builder mutants killed. An independent review returned REQUEST-CHANGES (1 MAJOR, 2 MINOR); all three are fixed with new tests. Their mutants: LWW removed → killed; revert without the ownership guard → survived first, test fixed, then killed; server pin at `DateTime.now()` → killed.
- Dev DB: 0024 applied after `docker restart` (`box_totals` = `1|131|167849984`).
- Web drive of `c7f4abd0` (release build plus a throwaway `BOX_DRIVE` scaffold, since deleted), users 294 ↔ 295, conversation 89, CDP frame log. All passed:
  - (a) reactions: add, change and remove seen by the peer; they survived reloads; only `/box send`.
  - (b) pin over a server pin: one `/box send` plus exactly one `unpinMessage`; `pinnedMessageId` became NULL; both banners survived a reload; unpin cleared both.
  - (c) edit: the peer saw the new text and the "edytowano" marker across reloads; no `editMessage`.
  - (d) delete-for-everyone: the row was gone on both sides, the reply quote lost its words, the `_decrypted_` key was gone, and `boxdel_v1` was written; no `deleteMessage`.
  - (e) old-path row 613 still used `addReaction` and `pinMessage`.
  - (f) `messages` in the chat stayed at 1; `box_msgs` equalled `box_totals.msgCount` throughout.
- CI 7/7 success on `c7f4abd0`.
- NOT verified: Android and iOS; sibling copies of actions on a real linked device (unit-tested only); an action that arrives while its target still waits in the journal (E19i residual).

## Notes for next session
- Next: item 5 (slice (d), migration handoff over the old path). Batch its OWNER questions in one note first (S8).
- Seen in the drive, not caused by items 4 or 9:
  - A reaction chip reacts to taps only on its lower edge (`chat_message_bubble.dart:502-503`: `Positioned(top: -14)` sits outside the Stack's hit area). This affects old-path rows too; the owner should decide whether to fix it.
  - Typing to a box peer still emits `typing` on the account socket. That belongs to item 8.
- Residuals: an action that only some devices accepted stays on those devices while the sender reverts (E19h); prod stays OFF until G5.
- Traps → `docs/agents/traps.md` (4 new lines, 1 reworded).
