# PR3.1 remainder: everything left before release N, decided in one pass

**Date:** 2026-09-25 · **Branch:** `feat/metadata-privacy` (part A = `a8a4e560` after the rebase onto master; it was `a35930e4`) · **Decision log:** `metadata-privacy-decisions.md` (S8: owner answers only the OWNER questions below; the ENGINEERING calls are the agent's, with reasons, overruled at the gate if wrong).

## What is left

| # | Work | Built on | Notes |
|---|---|---|---|
| 1 | **Sibling queues part B**: sent copies to own devices over the box, rotation on revoke, pruning, no-session policy | part A (`a8a4e560`) | unblocks multi-device senders on the box |
| 2 | **Box push registration** | 1 | a box-only message wakes no closed app until this lands (23) |
| 3 | **Decision-22 slice**: disappearing timers, replies and media over the box | 1, 2 | decision 22: "their own slice right after sibling queues + push" |
| 4 | **Message actions over E2E**: reactions (plain emoji), pin, edit, delete-for-everyone | 3 | the PR3.1 bullet; a box message's action bar fails today |
| 5 | **Slice (d)**: migration handoff over the old path | (c) | moves existing friendships onto the box |
| 6 | **Slice (e)**: `device_added` / `device_removed` / `list_update` over the box | (b), (c) | replaces the server's `staleLists` bounce |
| 7 | **Slice (f)**: first contact over request queues | (a), part A frames | friend requests over the box |
| 8 | **Slice (g)**: receipts and typing (D5, 33) | 3 | |
| 9 | **Prod prerequisites** for `BOX_ENABLED`: global ceiling (30), per-socket rid cap, media refusals counted | — | backend only, runs in parallel with 3–8 |
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

## Item 3 (decision-22 slice): OWNER questions O8–O11 — OPEN (asked 2026-09-26, one batch)

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

Accepted residuals, recorded here:
- A disappearing box attachment's ciphertext stays on the box until its 14-day TTL, since the box has no delete for media (it is ciphertext with no queue link).
- The Anti-Quantum Note keeps its server-side note (`POST /notes`, authenticated). Only the message carrying it moves.
- A reply to a box message that has to take the old path still loses its quote, as today (`isServerMessageId` send gate).

## Proof per item (unchanged ladder)

Each item follows the same ladder:
1. test-first, red before green;
2. mutants on every new rule;
3. one independent review;
4. a live drive on the local stack (two isolated browser profiles over CDP, and the Pixel_7 emulator where native behaviour differs);
5. CI on the draft PR (#185).

G5 adds the device migration rehearsal.
