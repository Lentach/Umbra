# Reaction privacy — design (blinded emoji token)

**Status:** design, owner-picked 2026-09-17 (option B of three). Not implemented.
**Problem:** reactions are the one piece of message CONTENT the server stores in the clear.
Known as D10 since 2026-07-07 and re-measured today, still true.

## 1. What is true today (measured, not remembered)

| Layer | Fact |
|---|---|
| Column | `messages.reactions` TEXT, JSON `{"👍":[1,3],"❤️":[2]}` — `message.entity.ts:82-84` |
| Write | `addOrUpdateReaction` / `removeReaction`, `SELECT reactions … FOR UPDATE` then `UPDATE`, one transaction — `messages.service.ts:929-951`, `:970-987` |
| Read | `parseReactions` degrades a corrupt row to `{}` — `message-reactions.util.ts` |
| Emit | `reactionUpdated { messageId, conversationId, reactions }` to the actor's socket **and** `userRoom(peer)` — `chat-reaction.service.ts:61-71`, `:117-127` |
| Map | `MessageMapper.toPayload` → `reactions` on history, new message, edit — `message.mapper.ts:61` |
| DTO | `AddReactionDto` / `RemoveReactionDto` accept exactly one emoji grapheme — `chat.dto.ts:269-285` |
| Client send | `emitAddReaction` / `emitRemoveReaction` — `socket_service.dart:149-155` |
| Client state | `MessageModel.reactions` (`message_model.dart:56`), merged in `messaging_provider.events.dart:598-608` |
| Client render | `ReactionChipsRow` (`reaction_chips_row.dart`), bubbles at `chat_message_bubble.dart:498`, `voice_message_content.dart:399`, picker state at `message_context_menu_overlay.dart:403` |
| Wire contract | **Reactions appear nowhere in `docs/contracts/wire.md`.** The contract has to be written, not amended. |

So the server knows, for every message: which emoji, from which user, when. Everything else about
the message body is ciphertext. A database dump — or the census in
`docs/proof/e2e-encryption-proof.md` — reads reactions as prose.

## 2. Why not "just encrypt it like a message" (option A, declined)

A reaction-as-envelope design is the stronger one: the server stores nothing and the
`SendEnvelopeDto` / `message_envelopes` fan-out already exists. It was declined because the state
it replaces is device-independent: the server's `{emoji:[userId]}` is visible to a newly linked
device, to a device that was offline for a week, and to a reinstall that restored from the phrase.
Envelope-delivered reaction events are none of those things — a device that did not exist when the
reaction was sent can never learn it, exactly like message history. Losing reactions on every new
device link is a product regression the owner did not accept.

## 3. Design: the server keeps the bookkeeping, blind

Replace the emoji in the column with a **conversation-scoped deterministic token**, and change
nothing about who merges, toggles or fans out.

```
K_react[conv]  = 32 random bytes, generated once per conversation by the first client that needs it
token(emoji)   = base64url( HMAC-SHA256(K_react[conv], "umbra.reaction.v1" || emoji) [0..15] )
column value   = {"<token>":[userId, …], …}
```

- **The server can neither read nor guess an emoji.** It has no `K_react`, and HMAC without the key
  is not invertible; the candidate set being public (`emoji_picker_flutter`) buys nothing without
  the key.
- **Everything server-side survives unchanged.** One emoji per user is enforced by removing that
  `userId` from every key before inserting — emoji-blind already (`messages.service.ts:939-946`).
  The `FOR UPDATE` atomicity, the corrupt-row degradation, the `reactionUpdated` fan-out to both
  user rooms, and history mapping are untouched.
- **Chips still aggregate.** The token is deterministic per conversation, so both participants'
  "👍" collapse to one chip with two userIds — which is also the leak, priced in §6.
- **The client needs no new storage.** It derives `token(emoji)` for its picker set on demand and
  caches the map in memory; rendering a chip is a reverse lookup in that map.

### 3.1 Key distribution — the only genuinely new machinery

`K_react` must reach **every device of both participants**, including devices that appear later. It
rides the transport that already solves exactly this problem: the per-device envelope fan-out.

- A control message `reactionKey { conversationId, epoch }` whose per-device ciphertext is the key,
  one envelope per recipient device **and** per the sender's other devices — the same shape as
  `sendMessage`'s `envelopes`, with the same `MAX_ENVELOPES_PER_MESSAGE` bound.
- The first client to react (or to open a conversation that has a token it cannot read) generates
  and fans out the key. Two clients racing produce two keys; last write wins per `(conversation,
  epoch)` and the loser's tokens become undecodable — so the epoch must be **server-assigned**, on
  `conversations`, and a fan-out that names a stale epoch is refused. This is the one place the
  design needs a new server-side invariant rather than reuse.
- `deviceListChanged` (already emitted to both parties on any device mutation — `wire.md:41`) is
  the trigger to re-fan the current key to the new device set.
- Revocation: a revoked device keeps the key material it already holds. That is consistent with
  the standing posture — revocation is logout, never remote wipe (`wire.md:42`) — and it cannot
  read new rows because it has no session. **Recommendation: rotate anyway on revoke** (new epoch,
  re-fan, old tokens stay readable to the remaining devices because they keep the old key by
  epoch). Rotation is what makes "remove this device" mean something for reactions.

### 3.2 What a device without the key renders

A chip whose token is unknown is **not** an error and **not** hidden — hiding it would make the
peer's reaction silently invisible, which is the class of bug `(lxxxiv)`/(D28) kept producing.
Render the count with a neutral placeholder glyph and no emoji, and re-render when the key lands.
This is also the newly-linked-device path, so it will be seen in practice.

### 3.3 Rollout and legacy clients

There is no auto-update: an APK floor exists (`versionCode 20047`) and PWAs update on relaunch, so
plaintext-emoji clients will be live for weeks.

- `AddReactionDto` / `RemoveReactionDto` accept **either** a single emoji (legacy) or a token
  (`^[A-Za-z0-9_-]{22}$`), for one explicit compat window.
- A row may therefore hold both shapes. Clients render a legacy plaintext key directly and a token
  through the map — the two are distinguishable by shape, and a token can never be a valid emoji.
- Backend first (it must accept tokens before any client sends one), then clients, then a follow-up
  that **removes** the emoji branch and refuses legacy with a stable code. That removal is the
  commit that actually closes D10; until then the hole is narrowed, not closed. Write it down as
  owed work, not as done.

### 3.4 Existing plaintext rows

Migration must decide: keep them (historical content stays readable on the server, contradicting
the point) or null them (users lose old reactions; re-adding one costs a tap). **Recommendation:
null them in the same numbered migration that ships the DTO change**, and say so in the release
note. Owner call — this is the only user-visible data loss in the design.

## 4. Work breakdown

| # | Change | Size |
|---|---|---|
| 1 | `conversations.reactionKeyEpoch` + migration; null legacy `messages.reactions` | S |
| 2 | DTO: accept token \| emoji; `chat-reaction.service` untouched except validation | S |
| 3 | `reactionKey` envelope event + epoch refusal + fan-out bound reuse | M |
| 4 | Append the reaction contract (it has none) to `docs/contracts/wire.md` | S |
| 5 | Client: key generation, HMAC map, picker → token, chip reverse lookup, unknown-token render | M |
| 6 | Client: re-fan on `deviceListChanged`, rotate on revoke | M |
| 7 | Tests: token determinism, one-emoji-per-user through tokens, unknown-token render, epoch race refusal, legacy-shape compat | M |
| 8 | Follow-up: remove the emoji branch, refuse legacy | S |

## 5. Falsifications to drive the implementation

- (R1) Drop the conversation scope from the key (one global key) → two conversations' identical
  emoji produce identical tokens; a server that learns one mapping learns it everywhere.
- (R2) Derive the key from identity keys instead of distributing one → the sender's OTHER devices
  cannot compute the same token, so a user's own chips disagree across their devices.
- (R3) Let the client pick the epoch → two clients racing both write epoch 1, and one side's chips
  are permanently undecodable.
- (R4) Hide unknown tokens instead of rendering a placeholder → a freshly linked device shows the
  peer's reaction as absent, which is indistinguishable from "they removed it".
- (R5) Skip the compat window → every not-yet-updated client's reaction is refused, or worse,
  written as plaintext into a column clients now read as tokens.
- (R6) Truncate the token to 8 bytes → collisions inside one conversation merge two different
  emoji into one chip.

## 6. What this design does NOT hide, stated plainly

- **Who reacted and when.** `userId` lists stay in the clear; they are the addressing the fan-out
  needs, and the message's sender/recipient/timestamps are already visible metadata
  (`docs/audit/2026-07-07-metadata-privacy-audit.md`).
- **Emoji equality inside one conversation.** The server learns that two reactions are the same
  emoji, and how many distinct emoji a conversation uses. It cannot name any of them, and
  per-conversation keys block cross-conversation correlation and any global frequency attack.
- **A participant-run server learns its own conversations' mapping.** It holds that conversation's
  key legitimately as a participant. No design fixes this one.
- This is a *blinding*, not a ratchet: the token for an emoji is stable for the life of an epoch.
  A server that ever learns one mapping learns it retroactively for that conversation.

Option A (§2) has none of these three leaks. If the owner later trades new-device continuity for
that, this document's §3.1 machinery is the part that gets deleted, not extended.
