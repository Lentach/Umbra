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
- **The client needs no new storage for the MAP.** It derives `token(emoji)` for its picker set on
  demand and caches the map in memory; rendering a chip is a reverse lookup in that map.
- **`K_react` DOES have to persist on the client — corrected 2026-09-17, and it changes a property
  this document previously advertised.** The earlier draft claimed the key never rests: held in
  memory, pulled again next launch. That is impossible with a Signal-wrapped key. **Signal
  decryption consumes the message key**, which is the same fact that forces this app to keep a
  LOCAL plaintext record store for messages (`reconcileStoredPlaintext`; the server's copy is
  ciphertext whose ratchet key is spent). A stored wrap can therefore be opened exactly ONCE, so a
  device that discards `K_react` at exit cannot recover it from the mailbox next launch.
  Consequences, all of which must be stated rather than discovered later:
    * `K_react` is persisted through the machinery that already holds content keys
      (`content_key_manager.dart` / `content_key_wrap.dart`) — the same custody, not a new class of
      secret. On web that custody is the documented obfuscation, not encryption
      (`signal_stores.dart:27-52`: the unwrapping key sits beside the ciphertext in localStorage),
      so on web this key is as exposed as the content key already is. It buys privacy against the
      SERVER, which is the threat D10 is about, and nothing against someone who can read that
      origin's localStorage.
    * PULL is still right for FIRST acquisition — the mailbox row is what a newly linked or
      long-offline device reads once.
    * Losing the local copy costs readability of existing chips, exactly as losing local plaintext
      costs message history. Self-healing needs no new event: a participant that cannot open its
      row generates a fresh key and uploads it at `epoch + 1`. Old chips stay unreadable (their
      key is gone), new ones work. Accepted residual.
    * The alternative that would keep nothing at rest is wrapping with a STATIC DH between the two
      devices' long-term identity keys instead of a ratchet session — re-derivable forever, so the
      mailbox row could be opened on every launch. It is also hand-rolled key agreement outside
      libsignal's session machinery, which is a much bigger review surface than a persisted key.
      Not chosen; recorded so the trade is visible.

### 3.1 Key distribution — PULL, not push (corrected after measuring the client)

`K_react` must reach **every device of both participants**, including devices that appear later.
The first draft of this section said it rides the message envelope fan-out. Measuring
`messaging_provider.send.dart:1489-1557` says that is the wrong shape: the fan-out's offline
durability comes from the `message_envelopes` rows hanging off a MESSAGE row, so a pushed control
message needs its own store plus delivery-on-connect and ack/cleanup machinery — all of it new.
Piggy-backing the key on the next real message's `E2eEnvelope` is cheaper but leaves a quiet
conversation unable to react until somebody speaks.

So: one small table, and clients **pull their own copy**.

```
reaction_keys(conversationId, userId, deviceId, epoch, ciphertext, createdAt)
  PK (conversationId, userId, deviceId, epoch)
```

- The creating client generates `K_react`, resolves targets exactly like a send
  (`_resolveFanOut` → `ensureSession` → `encrypt(userId, key, deviceId:)`, unchanged code), and
  uploads N wrapped copies in one emit. Reuses the existing per-device Signal sessions and the
  `MAX_ENVELOPES_PER_MESSAGE` bound; adds no crypto primitive.
- A device that needs a key asks for its OWN row (`fetchReactionKey { conversationId }` → the row
  for the caller's authenticated `(userId, deviceId)`). Offline-safe with no delivery state to
  track, because the store IS the mailbox and the reader is the owner.
- The **epoch is server-assigned** on `conversations`. Two clients racing would otherwise both
  write epoch 1 and one side's tokens would be permanently undecodable; an upload naming a stale
  epoch is refused. This is the one genuinely new server-side invariant.
- A newly linked device has no row for any old conversation. The peer's client re-uploads on
  `deviceListChanged` (already emitted to both parties on any device mutation — `wire.md:41`);
  until it lands, §3.2's placeholder renders. The account's OWN other devices are covered by the
  same upload, since a send already addresses them.
- Revocation: a revoked device keeps material it already holds, consistent with revocation being
  logout and never remote wipe (`wire.md:42`), and it cannot read new rows without a session.
  **Rotate anyway on revoke** — new epoch, fresh upload to the surviving devices only, old rows
  kept so existing chips stay readable. Rotation is what makes "remove this device" mean something
  for reactions.

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
| 1 | `reaction_keys` entity (incl. the server-attributed `senderUserId`/`senderDeviceId` a receiver needs to pick the right session) + `conversations.reactionKeyEpoch` + numbered migration `0018` (and, if the owner says so, nulling legacy `messages.reactions`) | S |
| 2 | DTO: accept token \| emoji; `chat-reaction.service` untouched except validation | S |
| 3 | `uploadReactionKey` / `fetchReactionKey` handlers, server-assigned epoch, stale-epoch + foreign-recipient refusals, envelope-count bound reuse | M |
| 4 | Append the reaction contract (it has none) to `docs/contracts/wire.md` | S |
| 5 | Client: key create/upload via the EXISTING `_resolveFanOut`→`ensureSession`→`encrypt` path, pull-on-miss, **persist `K_react` through the content-key store (§3, the one-shot decryption fact)**, in-memory HMAC map, picker → token, chip reverse lookup, placeholder render | L |
| 6 | Client: re-upload on `deviceListChanged`, rotate on revoke — **NOT DONE (owner ruling: out of scope for the token cutover).** The server accepts both shapes; no client sends them. Consequence, stated plainly: a device linked after the key was distributed renders placeholder chips for that conversation INDEFINITELY. It is not waiting for a mechanism that exists. **The "self-heal by re-keying at `epoch + 1` when the local key is gone" this row used to promise is DELIBERATELY not built either** (owner ruling 2026-09-17): re-keying blanks the chips of every device that can still read those messages, and a device that cannot read pre-link history loses nothing by showing placeholders, so `ReactionKeyService` mints a key at epoch 0 ONLY. | M |
| 7 | Tests: token determinism, one-emoji-per-user through tokens, placeholder render, epoch race refusal, legacy-shape compat, pull-on-miss, and re-launch readability (the regression the old "nothing at rest" claim would have shipped) | M |
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
- (R7) Keep `K_react` in memory only, as the first draft of §3 said → reactions render on the
  session that created the key and are permanently unreadable after a relaunch, because the
  mailbox wrap was already consumed. This is the falsification that killed that claim.
- (R8) Let the client name the uploader in `fetchReactionKey`'s answer instead of the server
  attributing it → a hostile server (or client) points a victim's device at the wrong Signal
  session and burns a ratchet step on garbage.

## 6. What this design does NOT hide, stated plainly

- **Who reacted and when.** `userId` lists stay in the clear; they are the addressing the fan-out
  needs, and the message's sender/recipient/timestamps are already visible metadata
  (`docs/audit/2026-07-07-metadata-privacy-audit.md`).
- **Emoji equality inside one conversation.** The server learns that two reactions are the same
  emoji, and how many distinct emoji a conversation uses. It cannot INVERT a token — 16 bytes of
  HMAC-SHA256 under a per-conversation key — and per-conversation keys block cross-conversation
  correlation and the global frequency attack. What survives, priced honestly: the token is stable
  for the life of an epoch and the server counts each one's occurrences, so within a single
  conversation it can RANK tokens against public emoji-frequency priors. Naming the most-used token
  is probabilistic guesswork, not a break — but it is not impossible either, and the earlier
  phrasing ("cannot name any of them") overstated it.
- **A participant-run server learns its own conversations' mapping.** It holds that conversation's
  key legitimately as a participant. No design fixes this one.
- This is a *blinding*, not a ratchet: the token for an emoji is stable for the life of an epoch.
  A server that ever learns one mapping learns it retroactively for that conversation.

Option A (§2) has none of these three leaks. If the owner later trades new-device continuity for
that, this document's §3.1 machinery is the part that gets deleted, not extended.
