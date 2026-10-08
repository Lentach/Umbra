# Step 2 gap check: what still needs the server's friend row (2026-10-08, read-only)

Question: can the server's `friend_requests` rows (the friend graph) be pruned for pairs that are on the box? Answer: **not yet**. Three paths still need the row, and the first one would delete contacts on the devices.

Checked against decisions 50, 51, 52, E15g, E15h, E20c, E50a, E50c (`metadata-privacy-decisions.md`) on `merge/0.2.62`.

| # | Dependency | Where | What breaks if the row goes | Covered by a decision? |
|---|---|---|---|---|
| 1 | The `friendsList` sweep removes every local friend record that the list omits, except a record with `boxOrigin` | `frontend/lib/providers/friends_provider.dart:184` | Every friendship made on the OLD path (no `boxOrigin`: all 65 accepted prod pairs, 10-07) is deleted from the device at the next `friendsList`: the user loses the contact. | E15g spares only box-made records |
| 2 | Device-list reads are entitled by `areFriends` | `backend/src/chat/services/chat-device-list.service.ts:274-283` (`mayReadDeviceList` → `validateCanMessage`) → `chat-validation.service.ts:29` → `friends.service.ts` | The E50a/E50c fallbacks (no list held, DAK change, >30 d off the box) are refused silently; the client reads that as "cannot verify" and the send fails. | E50a/E50c assume the lookup works |
| 3 | A friend's request-queue address comes from the `friendsList` `devices` | `frontend/lib/services/box/box_friend_handoff.dart:239-251` (`_requestQueues`), falling back to `boxOrigin.addresses` | An old-path friend with no `boxOrigin` has no address for a new handoff (re-mint, restore, new device). | E20c |

Also seen (not blockers): the old path's sends (`chat-conversation.service.ts:57`, `chat-message.service.ts:324`) need the row by design, and `requestSessionRebuild` is skipped for box-only peers (`messaging_provider.dart:651`).

## What pruning would need first
1. A device-side marker that a friendship is owned by the device whatever its origin (e.g. stamp the existing old-path friends once, behind the contact backup), so the sweep stops deleting them.
2. Device-list entitlement that does not read the friend graph (or a list carried over the box for every friend, decision 50, with no server fallback).
3. Request-queue addresses for old-path friends delivered without `friendsList` (in the contact backup or over the box).

Phase 4 (decision 86) stays the owner's call; this note only lists what it has to cover.
