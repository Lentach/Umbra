# PR3.1 remainder: everything left before release N, decided in one pass

**Date:** 2026-09-25 · **Branch:** `feat/metadata-privacy` (part A = `a8a4e560` after the rebase onto master; it was `a35930e4`) · **Decision log:** `metadata-privacy-decisions.md` (S8: owner answers only the OWNER questions below; the ENGINEERING calls are the agent's, with reasons, overruled at the gate if wrong).

## What is left

| # | Work | Built on | Notes |
|---|---|---|---|
| 1 | **Sibling queues part B**: sent copies to own devices over the box, rotation on revoke, pruning, no-session policy | part A (`a8a4e560`) | unblocks multi-device senders on the box |
| 2 | **Box push registration** | 1 | a box-only message wakes no closed app until this lands (23) |
| 3 | **Decision-22 slice**: disappearing timers, replies and media over the box | 1, 2 | decision 22: "their own slice right after sibling queues + push" |
| 4 | **Message actions over E2E**: reactions (plain emoji), pin, edit, delete-for-everyone | 3 | DONE 09-26 (`81b795e8`, decisions 45–46, E19a–E19j; web drive a–f passed; CI 7/7 on `c7f4abd0`) |
| 5 | **Slice (d)**: migration handoff over the old path | (c) | moves existing friendships onto the box |
| 6 | **Slice (e)**: `device_added` / `device_removed` / `list_update` over the box | (b), (c) | replaces the server's `staleLists` bounce |
| 7 | **Slice (f)**: first contact over request queues | (a), part A frames | friend requests over the box |
| 8 | **Slice (g)**: receipts and typing (D5, 33) | 3 | |
| 9 | **Prod prerequisites** for `BOX_ENABLED`: global ceiling (30), per-socket rid cap, media refusals counted | — | DONE 09-26 (`box_totals` migration 0024, E10–E12; client reads `limit` as not gone); prod still `BOX_ENABLED: 'false'` until G5 |
| 10 | **G5**: gate review, migration rehearsal on a device (master APK, then the branch APK over it), then release N | 1–9 | owner gate |

Order follows decisions 5, 17, 22 and 23 as they stand: sibling queues, then push, then decision 22's slice, then the remaining slices in decision 5's (d)–(g) order. Changing that order would be an owner question. Frontend slices share `messaging_provider.box.dart`, so they go one at a time. Item 9 is backend-only and runs alongside them.

## OWNER questions — ANSWERED 2026-09-25 in one pass (decisions 30–33)

O2 → (a) ~3 GB (30) · O3 → (a) honest 429 (31) · O4 → (a) no push on the self-queue (32) · O5 → (a) keep D5, one mutual switch, default OFF (33).

**O2 — How much of the server's disk may the box use in total?** Prod has 38 GB, 9.3 GB free, shared with Postgres. Today every limit is per queue or per IP, and anyone can mint a queue. That is the G4 blocker behind S3. At the ceiling, a send or upload answers `quota_exceeded` and the sender's row fails with 'Ponów'.
- (a) **~3 GB: 2 GiB of media + 60 000 undelivered message blobs (16 KiB each, ≈1 GiB).** Leaves more than 6 GB for Postgres and growth. *Recommended.* Today all old-path media together is 87 MB.
- (b) ~5 GB: 3.5 GiB media + 90 000 blobs. More headroom for a burst, less for everything else.
- (c) Dynamic: refuse when the disk has less than N GB free. Adapts on its own, but a burst elsewhere (logs, a backup) then starts refusing messages.

**O3 — Media over a queue's daily budget (1 GiB/day, S2): tell the sender, or hide it?**
- (a) **Answer `429 quota_exceeded`.** The sender's row fails and can be retried tomorrow. It shows a sid holder (a friend, or an ex-friend who kept the sid) that this queue is alive and spent today. *Recommended:* only someone already holding the sid can probe, and budgets are hit rarely.
- (b) Answer `201` and drop the file. Nothing is revealed, but the recipient gets a broken attachment and the sender never learns why.

**O4 — Should your sent messages wake your OTHER devices with a notification?** Part B sends each of your devices a copy of what you sent, into its self-queue.
- (a) **No push notifier on the self-queue.** Copies arrive when that device next opens or is already online. *Recommended:* the box cannot tell a copy from an incoming message, so a push would show a bare "new message" notification for something you wrote yourself.
- (b) Yes. Your other devices sync within seconds even when closed, at the cost of a notification for your own messages.

**O5 — Confirm D5 now that its visible effect is clear.** D5 (2026-09-20) says receipts and typing are mutual opt-in, default OFF. The effect: after release N, the ✓✓ read ticks and the typing indicator disappear for everyone on box chats until BOTH sides switch them on.
- (a) **Keep D5: one switch in Privacy settings, mutual (Signal's model: turn yours off and you stop seeing others'), default OFF.** *Recommended:* this is the design you approved, and read ticks are a live activity signal.
- (b) Default ON for accounts that exist today, OFF for new ones. Keeps today's look for current users.
- (c) A per-contact switch instead of one global one. Finer control, more UI.

**Still open, but not for now:** O1, the release N+1 convergence rule (`convergence-decision.md`), is needed before G6, not before release N.

## ENGINEERING calls (agent's, with the reason)

**1. Sibling part B**
- **E5.** `_boxRoute` covers siblings under decision 16: the box only when every live own device has a `boxsib_v1` address. One frame per sibling goes into its self-queue. The copy's envelope carries the peer's user id inside E2E, so the sibling files it under the right chat as an own row (`originDeviceId` = the sending device, status `sent`). *Reason:* the old path's own-device fan-out (`messaging_provider.send.dart:63-70`) does exactly this through the server.
- **E6. Rotation.** When the own verified list stops naming a device (identity `deviceListChanged`, then re-verify), each surviving device:
  1. creates a new self-queue;
  2. hands it to every remaining sibling through that sibling's self-queue;
  3. keeps the old queue RETIRING (subscribed, read) and deletes it once the 30-day box TTL has passed since the rotation.

  Idempotent per connect. *Reason:* decision 27. Only the survivors can act, since the revoked device learns nothing. *Amended in the build (two reviews):* "delete once the handoffs are acked" loses the old queue's backlog, and so did a drain-marker variant tried next (a copy already in flight in one tab, or sent by a second tab from an older row, lands after the marker) — a `send` to a deleted sid answers ok, so the loss is silent. The TTL is the only bound that needs no cross-tab ordering; the revoked device's frames into the old queue meanwhile are finished unread. An ack naming a non-current sid (an older handoff overtook the newer one across queues) forgets that sibling's ack and re-runs the swap.
- **E7.** On every own-list change, `boxsib_v1` entries for devices that are no longer live are dropped (in the rotation's one write when a self-queue exists). *Reason:* the verified list is the authority (E2).
- **E8.** A sibling no-session follows the peer failure policy: held only on the self-queue, re-keyed from our side (a fresh `queue_handoff`, once per session). *Amended in the build:* the journal prune drops only CONSUMED rows, so it bounds nothing here; the reader finishes a held sibling entry — and a sent copy waiting for a chat this device lacks — 30 days after intake, and finishes a frame from an origin the own list names REVOKED at once (an ABSENT origin, or one undecided because the own list cannot be fetched, is held). *Reason:* one policy, and the request-queue half is already fixed (E1–E3).

**2. Push**
- **E9.** A notifier (challenge, then activate) goes on every NORMAL inbound contact queue, with the device's existing FCM token or Web Push subscription. None goes on the request queue (decision 2), and none on the self-queue (decision 32). It is re-registered when the token changes. *Reason:* design §5 already accepts `nid → token` grouping one device's queues. The push is bare (D6). *Built 2026-09-25 (decisions log E9):* one queue at a time, since the pushed code names no queue; `boxntf_v1` keeps what is active per token. *Amended in the build:* the live drive found that a socket that dies silently keeps its queues until the ping timeout (~40 s), and nothing pushed the messages it was handed meanwhile; the box now wakes the device when such a socket is detached with messages waiting.

**8. Prod prerequisites**
- **E10.** At most 1 024 subscribed rids per socket, refused with a new `limit` code in wire.md. *Reason:* a device holds about one queue per contact plus the self and request queues, so 1 024 covers 1 000 contacts, and a flood socket is bounded.
- **E11.** Media quota refusals are counted in the existing per-verb refusal counters: counters only, never an IP. *Reason:* G4 item 3 and the logging decision A3.
- **E12.** The global ceiling is kept as a running total checked in `enqueue` and `chargeMedia`, and refused with `quota_exceeded`. The numbers are decision 30: 2 GiB of media and 60 000 message blobs. *Reason:* one indexed read per send, not a table scan.

**Slices**
- **E13 (d).** Per contact and per own device, an E2E `queue_handoff` goes over the old `sendMessage`, retried every connect until acked. The composer shows "waiting for <name>'s app to update" until then. *Reason:* the migration paragraph in `task_plan.md` Phase 3.
- **E14 (e).** DAK-verified `device_added` with OTP-less X3DH, `device_removed` with queue rotation, and `list_update` on a stale `senderListInfo`. A removal naming an unknown device is ignored. *Reason:* design §4.2.
- **E15 (f).** A friend request and its accept travel as account-bearing frames (0x12/0x13, already built) on request queues. *Reason:* design §4.4 and decision 6.
- **E16 (g).** Receipts and typing as E2E envelope types, gated by the one mutual switch in Privacy settings, default OFF (D5, confirmed as 33).
- **E17. Media.** Padded to the ladder rung, uploaded to `POST /box/media` against the recipient queue's sid, with `boxMediaId` inside E2E and downloaded through the capability URL. A file over 20 MiB of plaintext is refused before encryption. *Reason:* decision 9 and the I5 ladder.
- **E18.** Replies, disappearing timers (local, D4), reactions (plain emoji), pin, edit and delete-for-everyone travel as E2E envelopes for box messages in release N. *Reason:* decision 22, and a box message's action bar has to work before the cutover. Delete cannot reach a device offline for more than 30 days: an accepted residual (design §5).

## Item 3 (decision-22 slice): OWNER questions O8–O11 — ANSWERED 2026-09-26 in one pass (decisions 40–43)

O8 → (a) download on arrival, keep a local copy (40) · O9 → (a) Signal's countdown (41) · O10 → (a) setting stays a server column until PR4.x (42) · O11 → (a) pings move now (43) · O12 (asked later the same day, after a review showed it is OWNER-class, not the engineering call E17a first claimed) → (a) one upload, one shared id (44).

What the old path does today, for reference. Media sits on the server for as long as the message exists, and every view downloads it again. A reply names a server message id. A disappearing message's countdown starts when the RECIPIENT reads it: the server stamps `expiresAt` on read and tells both sides, so both copies go at the same moment, and an unread message goes after 1 day. The chat's timer is a server column (`conversations.disappearingTimer`, set with `setDisappearingTimer`). The box changes three of these facts: box media is deleted after 14 days whoever downloaded it (D8); there is no server read event, and receipts are off by default (D5/33); a box message has no server id.

**O8 — Box photos, videos, voice notes and files are deleted from the server after 14 days (D8). What stays viewable after that?**
- (a) **Every device downloads each attachment as it arrives and keeps an encrypted copy locally (the sender keeps its own).** History stays complete, as in Signal. Cost: storage on every device, and mobile data for files never opened (a video is up to 20 MiB). On the PWA the copy is device-local like the rest of its history (D9). *Recommended.*
- (b) Keep a local copy only once the attachment has been shown. An attachment in a chat nobody opens within 14 days is lost and shows "expired".
- (c) Keep nothing locally. Every view downloads again, and after 14 days every box attachment shows "expired" for everyone, the sender included. This does not work well with inline video either: `GET /box/media` is `no-store` and limited to 3000 per 15 min per IP.

**O9 — When does a disappearing message's countdown start in a box chat?**
- (a) **Signal's model: the sender's copies count from the send, and each receiving device counts from the moment it first shows the message. An unread message still goes 1 day after the send.** The visible change: the sender's copy of a message the peer has not read yet now disappears before the peer's copy does. *Recommended.*
- (b) Everything counts from the send. Simplest, but a 5 s message sent to a phone that is offline is gone before anyone sees it.
- (c) Keep today's shared deadline with a content-free "read" tick inside E2E. That tick is a read receipt the peer receives, which D5/33 leaves OFF by default, so (c) could only apply when both sides turned receipts on. Otherwise it falls back to (a).

**O10 — Where does a chat's timer SETTING live during release N?**
- (a) **It stays on the server, as today, until the old tables go (PR4.x). Each box message carries its own timer inside E2E, and the devices enforce it.** The server keeps learning which chats use disappearing messages and when that changes. In release N it already holds the `conversations` row naming the pair, so this leaks little on top of that. *Recommended.*
- (b) Move it now. A change travels as an E2E control message to the peer's devices and our own, and is stored in the contact record; the server column is no longer written for box chats. The server learns nothing, at the cost of a second source of truth for as long as a message can still fall back to the old path.

**O11 — Pings.** A ping is in no slice of the plan. Today a ping to a box contact goes over the old path, which leaves a server row naming the pair (decision 15 keeps a message on one path, but nothing moves pings).
- (a) **Move pings in this slice.** It is small: the message type rides in the envelope, and the box reader already plays the ping effect. *Recommended.*
- (b) Leave pings on the old path until a later slice.

### ENGINEERING calls for item 3 (agent's, with the reason)

- **E17a. Media wire.** The file is encrypted whole with AES-256-GCM as today (`MediaCryptoService`: fresh key and IV, refused above 20 MiB of plaintext before encryption). The ciphertext is framed as `uint32be(len) ‖ ct ‖ zeros` to the smallest ladder rung that fits (the `QueueSeal`/contact-backup framing), uploaded ONCE with `Box-Sid` = the queue of the first live peer device, and fetched by every device through `GET /box/media/<id>`, then unframed and decrypted. The envelope carries `boxMedia` (the 32-byte id, base64url) and today's `mediaKey`/`mediaIv`/`mediaDuration`/dimensions/thumbhash, never a `mediaUrl`. *Reason:* one upload is one budget charge (S2) and one file on disk; the id is the capability (design §4.1); a padded rung hides the size (I5).
- **E17b. Media send failures.** A `quota_exceeded` or `rate_limited` answer, or silence, fails the row (decisions 19 and 31). A retry after a successful upload reuses the same id, key and wire id; a retry before one uploads again. The frames follow the ordinary box send, so the row gets ✓ only when every frame was taken (decision 20). *Reason:* re-encrypting under a new key would orphan the uploaded file (the old path's retry rule, `retryFailedMessage`).
- **E17c. Media downloads never block the reader.** Journal, ack and read stay as they are (the 16-slot window, traps). Downloads run on their own queue after the message is stored, and a failed download is retried until the 14-day TTL has passed. *Reason:* a 20 MiB fetch on the read chain would stall every chat.
- **E18a. Replies.** The envelope carries `re: {w, s, k, x}`: the quoted message's wire id `w` and sender `s` (a wire id is unique per sender only, traps), its type `k`, and a snippet `x` of at most 256 UTF-8 bytes. The receiver shows its OWN copy of the quoted message when it holds `(s, w)`, and the snippet only when it does not. A quoted row with no wire id (older than PR2.1) sends the snippet alone. Old-path sends keep `replyToMessageId`. *Reason:* a box message's local id differs on every device and names no server row (decision 14). Preferring the local original limits a forged snippet to quotes of messages the receiver never had (the Signal property).
- **E18b. A timer per message.** The envelope carries `ttl` (seconds, 5 s..30 d, the timer sheet's range). The device that starts the countdown under O9 writes the record's own `_expiresAt` stamp, which the destruction gate already honours (`EncryptionService._recordExpiryDeadlineMs`). The receiver takes the message's `ttl`, not its own view of the chat's setting. A sibling's sent copy counts as the sender's copy. *Reason:* D4, and a stamp this device wrote cannot be lost the way the server's `messageDelivered` stamp can.
- **E18c. Fitting in one frame.** The quote snippet and `ttl` fit inside the decision-18 bound. The link preview is still the first thing dropped (`boxEnvelope`), and the fit proof (`box_frame_test.dart`) is extended to the longest text with a quote and a preview. *Reason:* a message the composer accepts is never refused for its extras.
- **E18d. Amendments made in the build (review, 09-26).**
  - The receiver's unread cap is the message's clamped send time + 1 d, never its arrival + 1 d: a device offline for a week gets no fresh day. It is stamped at receipt, and the first show overwrites it ONCE with show time + `ttl`.
  - A box retry takes the row's own `disappearAfterSeconds`, never the chat's current setting: the retry reuses the wire id, so the devices that already hold the message would otherwise disagree.
  - A quote of a message that has a timer carries NO snippet, so a reply never keeps text from a disappearing message.

Accepted residuals, recorded here:
- A snippet already delivered stays in the reply after its original is deleted-for-everyone. Clearing `re.x` for a deleted `(s, w)` belongs to item 4's delete, and is owed there.
- A disappearing box attachment's ciphertext stays on the box until its 14-day TTL, since the box has no delete for media (it is ciphertext with no queue link).
- The Anti-Quantum Note keeps its server-side note (`POST /notes`, authenticated). Only the message carrying it moves.
- A reply to a box message that has to take the old path still loses its quote, as today (`isServerMessageId` send gate).

## Item 4 (message actions over E2E): OWNER questions O13–O14 — ANSWERED 2026-09-26 in one pass (decisions 45–46)

O13 → (a) an E2E pin both sides see; pinning a box message clears an old server pin once (45) · O14 → (a) actions follow the message's path: old-path rows keep server events until release N+1 (46).

Rejected options, for the record: O13 (b) a pin private to one device, (c) no pins on box messages until PR4.x; O14 (b) reactions and pins of old-path rows over E2E while edit/delete stay on the server (two sources of truth for one row).

Engineering calls: E19a–E19d in the decision log (wire shape `t: react|pin|edit|del` + `tg: {s, w}`; sender-only edit/delete by the authenticated account; last-writer-wins on clamped `ts`; delete clears `re.x` and keeps a 30-d tombstone; plain emoji kept in the target's record).

## Item 5 (slice (d), migration handoff): OWNER questions O15–O16 — ANSWERED 2026-09-26 in one pass (decisions 47–48)

O15 → (a) request queues, addresses via the friends list (47) · O16 → (a) one line above the composer (48).

What exists today. No code path gives a friend a box address: `QueueKeys.createInbound` has no caller in `frontend/lib/`, and nothing writes a peer's `ContactRecord.outbound`. Every covered chat in the item 3 and item 4 drives came from a throwaway scaffold. So item 5 is the first code that moves a real friendship onto the box. Own devices already swap addresses through their request queues (decision 26), so E13's "per own device" half is done, and item 5 is per FRIEND only.

What a handoff over the old `sendMessage` costs, read from the code:
- The server stores it as an ordinary `messages` row and counts it. It raises the friend's unread count, becomes the chat list's last message, and sends a `new_message` push with the unread badge (`push-notification-coalescing.service.ts:105-139`).
- A friend still on the prod app (0.2.50) reads an envelope with no `content` as an EMPTY text message (`e2e_envelope.dart:78` at `d37e2dcc`): one blank bubble per friend.
- Retried "every connect until acked" (E13), a PWA that reloads often adds a row per reload while the friend has not updated.

**O15 — How does the handoff travel?** This changes the approved design: `task_plan.md` Phase 3 (migration paragraph) and E13 chose the OLD path.
- (a) **Through the friend's request queues.** The friends list the app already loads at connect also carries each friend device's request address (`devices.requestSid` / `requestSealPub`, what search hands to anyone today). Each of our devices sends its queue to each friend device as an account-bearing frame (0x12/0x13, built for siblings), and the friend's device answers over the box into the queue it just got. No server row, no push, no unread count, and an old app sees nothing, because an old app has no request queue. A friend who updates later hands us ITS queues first, and our app hands ours back on receipt (as siblings do, E4), so neither side needs to reconnect. Cost: the handoff waits until the friend opens the app (no push on request queues, decision 2). *Recommended.*
  The approved design ruled this out for two reasons, and neither holds any more. "Unavailable until BOTH sides are on release N": the later side hands off and the earlier side hands back on receipt. "A full-graph `searchUsers` replay is a new pairing disclosure": (a) never calls search, and the friends list already names every friend.
- (b) **The old path, marked as a control message.** A new server message type that the server stores but never counts, previews or pushes, deleted once acked. It is sent only when every device of the friend has published a request queue (so it runs release N), so an old app never gets a blank bubble. Cost: a backend change to the old path, which PR4.1 deletes anyway; the server sees "this pair is switching now" (it sees the pair go quiet soon after anyway).
- (c) **The old path as approved, unchanged.** An ordinary row: the friend gets a "new message" push and an unread badge for something that shows nothing, and a friend on an old app sees an empty message.

**O16 — What does a chat show while the friend is not on the box yet?** Sending always works. Until every device of the friend has handed us a queue, messages go the old way, as today (decision 16).
- (a) **One quiet line above the composer**, for example "{name} ma starszą wersję aplikacji. Wiadomości są szyfrowane, ale serwer widzi, kiedy piszecie." It shows only once our own device is on the box (so never while prod keeps the box off), and goes once the friend is covered. *Recommended:* it is honest about the weaker path and blocks nothing.
- (b) No notice: the switch is invisible.
- (c) The notice, plus a marker in the chat list on chats not switched yet.

### ENGINEERING calls for item 5 (agent's, with the reason)

- **E20a. Batch device lists, first.** `getDeviceLists {userIds: 1..256}` applies `getDeviceList`'s rules to each user and answers each served one with the SAME `deviceList` event (no batch answer event; silence per refused user), in its own throttle bucket of 60 per 15 min. On the client every batched lookup started in one turn leaves as one frame (`EncryptionProvider.getVerifiedDeviceList(batched: true)`: `BoxDeviceListRefresh` and the friend handoff's lookups); a lone one stays the plain `getDeviceList`. *Reason:* traps "owed before slice (d)": once every friend is covered, one `getDeviceList` per friend per connect (300 per 15 min per IP, shared) runs out after about six reconnects with 50 friends. The batch names the same pairs, at the same moment (connect), as today's parallel burst. *As built:* the answer shape changed from the note's first draft (`deviceLists {lists}`, 30 / 15 min) so the client's existing per-user answer path serves both verbs.
- **E20b. Who gets what.** Every `friend` contact; none for `blocked` or `former` (decision 35's reasoning), and pending requests belong to slice (f). Each device keeps ONE normal inbound queue per friend (`QueueKeys.ensureInbound`: the record's own, else create → store → subscribe, a queue another tab stored first winning) and hands it to every live device in the friend's VERIFIED list. No queue is made for a friend with no device to hand one to. *Reason:* E2, the server's list never decides who gets a capability; and a queue nobody sends to only costs a notifier and a rid.
- **E20c. Wire.** The envelope is the sibling one, `{t: 'queue_handoff', sid, sealPub}`: into the queue that friend device handed us when we hold one (a normal frame), else into its request queue from the friends list (an account-bearing frame). The reader takes a FRIEND's account-bearing frame only as `queue_handoff` (anything else from another account keeps waiting for slice (f)), and only after three checks before Signal sees it: a PreKey message must carry that friend's pinned identity; with none pinned yet the frame is finished and our own handoff goes out (its session build pins one from the server's bundle, the old path's trust); the sender device must be live in the friend's verified list; and a PreKey message that would replace our session with that device is read only when we asked for it — we built that session where we held none, to hand off, within 10 min; our re-key never opens that window — else answered by our re-key (decision 37's rule), which asks the server for the friends list once per device per session when it holds no address for that device (found in the drive: a friend whose app updated after our list was fetched) and gives up if the answer names none (second review: else a stranger could loop it). A hand-back on our own queue is taken from a PreKey message only under the same rule. *Amended after review:* the first build exempted every unanswered session, which also let a revoked friend device replace an old one-way session. The ack `{t: 'queue_handoff_ack', sid}` goes over the box into the handed queue, so its arrival proves the address works end to end. *Reason:* one envelope shape for siblings and friends; an ack over the new queue tests the thing the handoff is for; a revoked device of the friend still holds its account identity.
- **E20d. Receive.** The address is stored as `ContactOutbound(peerDeviceId: the frame's sender device, sid, sealPub)` in that friend's `outbound`, replacing an older entry for the same device. Then the ack, then our own handoff back if that friend device has not acked our current queue (E4's order, ack first), then `refreshBoxDeviceLists()`. A friend with no conversation linked yet has its handoff and ack read, and its chat messages are held (not dropped) until the chat is linked (found in the drive). *Reason:* traps: a peer covered mid-session fails every box send until the next connect unless the refresh runs.
- **E20e. Retry.** On each connect, once account, box, store and E2E are ready (`BoxSiblingSwap`'s gate, E3), when a friends list arrives and when a friend's device list is dropped, every friend device that has not acked our current queue gets the handoff again, at most once per connect. Acks are kept on our inbound queue (`ContactQueue.ackedBy`, device ids). A rate limit stops the pass and runs it again after `retryAfter`. A retry is a box send with no server row, so every connect is fine.
- **E20f. Coverage and the notice.** Decision 16 is unchanged: the box only when every live device of the friend has an `outbound` entry. O16's notice reads the same predicate as `_boxRoute`'s peer half. *Reason:* the notice and the route can never disagree.
- **E20g. Not in (d).** No queue rotation (slice (e), `device_removed`). A friend's newly linked device is covered by the next connect's retry (decision 24's residual, until slice (e)).

Proof beyond the ladder: `test_e2e/box_roundtrip_test.dart` case 3 (the task_plan's `box_migration_test`, folded into the file that already holds the box probe's two accounts, so the register bucket is not spent twice). A and B become friends on the old path; A's box session starts while B "predates the box" and A hands nothing; B starts, hands off into A's request queue, A hands back with no reconnect; a box message round-trips; no `messages` row appears and neither queue row names an account.

## Proof per item (unchanged ladder)

Each item follows the same ladder:
1. test-first, red before green;
2. mutants on every new rule;
3. one independent review;
4. a live drive on the local stack (two isolated browser profiles over CDP, and the Pixel_7 emulator where native behaviour differs);
5. CI on the draft PR (#185).

G5 adds the device migration rehearsal.
