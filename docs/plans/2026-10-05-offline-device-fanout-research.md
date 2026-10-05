# Offline devices, per-device queues and partial fan-out — prior art (2026-10-05)

**Why:** prod incident 2026-10-05. The owner's second device (Android, device 11) was off from 10-02 17:02Z. Its box self-queue (one queue carries the sent copies of EVERY chat) reached `BOX_NORMAL_QUEUE_CAP = 128` at 15:05:57Z. From then on every send answered `queue_full` for that one frame. `_sendOverBox` (`messaging_provider.box.dart:2273`, `accepted.contains(false)`) marked each message failed. Friends received and answered every one of those messages. A failed box send is never stored (decision 19), so the bubble vanished when the chat was reopened. The rule behind it is E5's clause "a sibling refusal fails the row". Decision 16 itself asks only for an ADDRESS for every device.

**Method:** four parallel research passes against primary sources (specs, server/client source pinned to commits, official support pages), 2026-10-05. Claims carry their source, and the appendices keep each pass whole. UNVERIFIED and [INFERENCE] markers are the researchers' own.

## 1. Comparison

| System | Offline retention | Per-device cap | When an offline device's backlog is too big | Can one device fail the sender? | Stale device |
|---|---|---|---|---|---|
| **SimpleX SMP** (our lineage) | 21 d, silent | **128 per queue** (same as ours) + quota marker | `ERR QUOTA` → the agent treats it as TEMPORARY: orange warning, retry every 5 min → 6 h for **7 days**, resumes at once on `QCONT` (sent by the recipient once it drains the queue). After 5 quota warnings the contact is marked inactive: group sends are held locally (`MSAPending`) and flushed on `QCONT` | **No.** One delivery worker per queue; a group item's status is computed from successes only (`SndSent Partial`) | No multi-device at all |
| **Signal** | 30 d (sample config) | none by count; ~10 GB/device backstop | primary: trim oldest; **linked device: unlinked** | **No.** Sync copy is a separate request sent AFTER recipients are marked Sent (Desktop `send.preload.ts`) | linked device unlinked after **45 d** idle; primary must come online every 30 d |
| **WhatsApp** | 30 d | unpublished | unpublished | **No** (client fan-out, server checks list completeness only). Two ticks = **any** one device | companion out after 30 d idle (FAQ, UNVERIFIED); primary every 14 d; device-list TTL 35 d |
| **Threema** (multi-device mediator) | 14 d | reflection-queue limit (number unpublished) | **the lagging device is dropped** (close code `4114`) | **No** | slot policies `VOLATILE` / `DROP_LEAST_RECENT` |
| **Wire** | 28 d | none | dead-lettered → `EventFullSync` on return + in-chat notice "You haven't used this device for a while. Some messages may not appear here." | **No** (412 only for UNKNOWN clients). Partial federated failure = sent + "won't get your message" note | max 7 permanent clients |
| **Matrix** | until delivered | none | n/a (history is server-side) | **No** (`m.room_key.withheld`) | Element flags 90 d "inactive"; Synapse `delete_stale_devices_after` (opt-in) |
| **iMessage** | 30 d | unpublished | silent expiry | UNVERIFIED | none documented |
| **Session** | 14 d | none per account | silent expiry | **No**. Sync sent after `sent: true`; its error only logged | — |
| **OMEMO** (Conversations / Gajim) | MAM, pruned oldest-first | — | — | **No**. Inactive devices are skipped silently | Conversations drops own devices after **42 d**; Gajim stops after **2000** unacknowledged messages |

**Every system examined makes the offline device pay** (expiry, trim, unlink, drop, full-sync, gap notice). None blocks the sender. Delivered means **any one** device (WhatsApp FAQ, MIMI message-status `delivered` = "a messaging client"). Sync copies to one's own devices are best-effort, and Signal Desktop and Session send them only after the recipient status is settled. Fireplace is the only design found where a full own-device queue fails a message the friend received.

## 2. What this means for Fireplace

1. **Status rule (the bug).** A message is *sent* once at least one live PEER device accepted its frame. Own-sibling frames never decide the status. Refused peer frames (a friend's offline tablet) are not a failure while one peer device took it. *Failed* only when NO peer device accepted (the route is gone, the box is down, every peer device refused). This is SimpleX's `membersGroupItemStatus` plus Signal Desktop's order. Unlike E19l ("any frame") a sibling-only acceptance must NOT count, or a message no friend got would show as sent.
2. **Refused frames are a temporary state per device, not per message.** Keep the refusal code (`deliver` returns `BoxResult`, not `bool`). `queue_full` → retry that device's frame on reconnect / with backoff, up to the 30-d box TTL, same envelope, same `msgId` (the receiver drops a duplicate wire id: `wireHeldByOther`). Transient codes → short backoff. Mirrors SimpleX (QUOTA = warning + retry 7 d) and E19l's in-RAM per-device retry for actions.
3. **Inactive device (SimpleX `quotaErrCounter >= 5`, Threema `4114`).** After a `queue_full` from a device, stop sealing new frames to it and stop retrying on every send. Mark it *inactive* locally. Any frame later received FROM that device (or a successful send to it) makes it active again; that is our `QCONT` with no wire change. Show it in Settings → Devices: "Android — not synced since <date>, missing messages" + Remove.
4. **Gap notice on the returning device (Wire, OMEMO).** A device that drains a full queue, or finds it was marked inactive, shows "You haven't used this device for a while. Some messages may not appear here." A server-side quota marker (SimpleX's `MessageQuota`) would make detection exact, but it changes the box wire → an OWNER decision, a later phase.
5. **Stale device lifecycle (Signal 45 d, Conversations 42 d, WhatsApp 30 d).** Auto-unlink is the norm. Ours must stay client-driven (revocation is a primary-only DAK-signed mutation, design §5.5): the primary prompts to remove a device inactive for N days. A later phase; the numbers are an owner call.
6. **Keep the cap.** 128 is SimpleX's own number, and the cap exists because a sid is a bearer credential (I3). It is harmless once a refusal stops being a message failure.
7. **Persist failed and pending sends (decision 19 → owner).** Every system examined keeps an unsent message (Signal "Failed to send", SimpleX persists pending messages with retry state). With rule 1, a real failure is rare, so a persisted *failed* row costs little.

## 3. Metadata-privacy check

Rules 1–3 change only client bookkeeping: no new wire field, no new server state, no new lookup. The box sees exactly the same sends as today, minus repeat sends to a full queue. Rule 4's server marker and rule 5's last-seen are the only items that could touch the wire or the server, and both are deferred to owner decisions. Log as decision **93** / **E93a** (master log ends at 92, `feat/metadata-privacy` at 89; 76–81 already collide). `_sendOverBox` / `_sealBoxFrames` / `deliver` have NO differing hunks between `origin/master` and `origin/feat/metadata-privacy` (checked 2026-10-05: `git diff -U0` hunks stop at box.dart:1488 and box_session.dart:842), so a master hotfix cherry-picks onto the branch cleanly.

## Appendix

### SimpleX (SMP)

Sources were read from shallow clones on 2026-10-05:
- **SMQ** = `https://github.com/simplex-chat/simplexmq/blob/27a37387be98d9c7ec0e62373e125539675d0095/` (master, committed 2026-07-31)
- **SC** = `https://github.com/simplex-chat/simplex-chat/blob/479548ee53ffb73db73841e77acbeee5a78dbbd5/` (master, committed 2026-10-03)

Citations below are `prefix + path#Lline`. Anything I inferred rather than read directly is marked [INFERENCE].

#### 1. Per-queue quota and the `QUOTA` / `QCONT` flow control

**Quota value**
- The server-wide default is `defaultMsgQueueQuota = 128` (SMQ `src/Simplex/Messaging/Server/Env/STM.hs#L267-L268`).
- The server sets `msgQueueQuota = defaultMsgQueueQuota` directly (SMQ `src/Simplex/Messaging/Server/Main.hs#L537`). It does not read this from the ini file. The generated ini template has no quota key, only `expire_messages_days` and similar (SMQ `src/Simplex/Messaging/Server/Main/Init.hs#L99-L103`). So operators cannot change it without rebuilding.
- History: the quota was reduced to 128 in simplexmq 1.0.3 ("Reduce server message queue quota to 128 messages", SMQ `CHANGELOG.md#L816`). Quotas themselves were added in 0.5.x (`CHANGELOG.md#L903`).

**How a full queue behaves on the server** (in-memory store: SMQ `src/Simplex/Messaging/Server/MsgStore/STM.hs#L151-L164`; journal store does the same: `MsgStore/Journal.hs#L613-L625`)
- A write is allowed only if `canWrite || empty`.
- On each write, `canWrt' = quota > size`. While that holds, the message is stored.
- The write that would go past 128 does not store the message. The server stores a `MessageQuota {msgId, msgTs}` marker in its place, sets `canWrite = False`, and returns `Nothing`.
- So the queue holds at most **128 real messages plus 1 quota marker**.
- `SEND` then answers `ERR QUOTA` (SMQ `src/Simplex/Messaging/Server.hs#L2008-L2012`, which also increments the `msgSentQuota` stat).

**What the spec says** (SMQ `protocol/simplex-messaging.md`)
- #L923: "The router must respond with `"ERR QUOTA"` … When sender reaches queue capacity the router will not accept any further messages until the recipient receives ALL messages from the queue. After the last message is delivered, the router will deliver an additional special message indicating that the queue capacity was reached."
- #L1289-L1295: wire format is `msgQuotaExceeded = %s"QUOTA" SP timestamp`.
- #L1388: error list entry `QUOTA`.

**`QCONT`: how sending resumes**
1. The recipient agent receives `ClientRcvMsgQuota` and calls `queueDrained`. That function enqueues an agent message `A_QCONT (sndAddress rq)` on the **reply queue** of the duplex connection (SMQ `src/Simplex/Messaging/Agent.hs#L3172-L3176`).
   - Wire encoding: `A_QCONT = %s"QC" sndQueueAddr` (SMQ `protocol/agent-protocol.md#L259`, `#L314-L316`).
2. When the sender agent receives `A_QCONT`, `continueSending` finds that queue's delivery worker. It runs `tryPutTMVar retryLock ()`, which wakes the sleeping retry loop so it resends immediately. It also emits the `QCONT` event to the app (SMQ `Agent.hs#L3494-L3502`; event documented in `agent-protocol.md#L668`).

**Version history**
- `QCONT` shipped in simplexmq **4.2.0**, tag `v4.2.0`, commit `b328492d`, dated 2023-01-09. Changelog: "server sends quota exceeded message … recipient sends QCONT … once the queue is drained (via reply queue) … sender retry delays are increased … sender instantly resumes delivery where QCONT is received" (SMQ `CHANGELOG.md#L634-L639`).
- 4.3.0 then "increase[d] retry interval when sending messages after ERR QUOTA" (`#L630`).
- I found no separate agent-protocol version number for `QCONT`. The agent version history (SMQ `src/Simplex/Messaging/Agent/Protocol.hs#L284-L291`) does not mention it [UNVERIFIED whether it was gated by a version].

#### 2. Server retention / expiry
- Default retention is `defMsgExpirationDays = 21`, configured as `[STORE_LOG] expire_messages_days` (SMQ `Env/STM.hs#L222-L230`, `Main.hs#L557-L561`; official doc SC `docs/SERVER.md#L711` shows `expire_messages_days: 21`).
- The expiry sweep runs every 7200 s, i.e. 2 h (`checkInterval = 7200`, `Env/STM.hs#L229`).
- Expiry also runs on server start and on each `SEND` (`expire_messages_on_start` and `_on_send`, `Main.hs#L562-L563`, `Server.hs#L2005`). The generated ini sets `expire_messages_on_send = off` (`Init.hs#L101-L102`), but the code default when the key is missing is on.
- Push-notification records expire after `expire_ntfs_hours = 24` (`Env/STM.hs#L235-L243`).
- **What happens to expired messages:** they are silently deleted, oldest first, from the head of the queue while `msgTs < old` (SMQ `src/Simplex/Messaging/Server/MsgStore/Types.hs#L200-L211`). Nobody is notified, neither sender nor recipient.
- [INFERENCE from the same loop] The loop only matches `Message {msgTs}` and stops at a `MessageQuota` marker. So once a full queue has expired, the marker is still there, the queue is not empty and `canWrite` is still False. The sender keeps getting `QUOTA` until the recipient actually fetches the marker.
- **Gap detection on the receiving side:** the agent detects skipped or duplicate messages using `internalSndId` and `prevMsgHash` in the agent envelope. The chat app then shows a "dropped/skipped messages" item (`RMEDropped`) (SC `src/Simplex/Chat/Library/Subscriber.hs#L726-L727`). [UNVERIFIED in detail: I did not trace the agent's integrity-check code beyond these call sites.]

#### 3. Agent send retry, give-up rules and errors

**One delivery worker per send queue**
- `runSmpQueueMsgDelivery` runs one worker per `SndQueue` (SMQ `Agent.hs#L2171-L2185`).
- Messages for a given queue are sent strictly in order. A stuck message only blocks later messages to **that same queue**.
- This per-queue design is deliberate: an early bug "blocked delivery of all server messages when server per-queue quota exceeded, making it concurrent per SMP queue, not per server" (SMQ `CHANGELOG.md#L879`).

**Backoff schedules** (`defaultMessageRetryInterval`, SMQ `src/Simplex/Messaging/Agent/Env/SQLite.hs#L196-L211`)
- **Fast schedule** (network errors, TIMEOUT, HOST): starts at 2 s, starts growing after 10 s elapsed, capped at 120 s.
- **Slow schedule** (`QUOTA`): starts at 300 s (5 min), starts growing after 60 s elapsed, capped at 6 h.
- Growth rule: `delay*3/2` once elapsed ≥ `increaseAfter` (SMQ `src/Simplex/Messaging/Agent/RetryInterval.hs#L114-L118`).
- The retry state is persisted with each message (`updatePendingMsgRIState`, `Agent.hs#L2252-L2254`), so it survives app restarts.

**Give-up timeouts** (`SQLite.hs#L230-L233`), measured from the message's `internalTs`, i.e. when it was created:

| Error | Timeout | What happens before giving up |
|---|---|---|
| `QUOTA` | `quotaExceededTimeout = 7 days` | Each failed attempt emits `MWARN msgId QUOTA` and retries on the slow schedule (`Agent.hs#L2204-L2215`). Changed from 21 days to 7 days in simplexmq 5.5.1 (tag dated 2024-02-02, `CHANGELOG.md#L473`). |
| Temporary / host errors | `messageTimeout = 2 days` (HELLO: `helloTimeout = 2 days`) | Retries on the fast schedule. `MWARN` is emitted only for server-host errors (`Agent.hs#L2240-L2247`). |
| `AUTH` and other permanent errors | none | Immediate `MERR` and the message is deleted (`Agent.hs#L2216-L2250`). |
| `QUOTA` during the connection handshake (`CONN_INFO`) | none | Connection error `NOT_AVAILABLE` (`Agent.hs#L2206-L2208`). |

- When a timeout is hit, `notifyDelMsgs` sends `MERR` for the current message. It also deletes **every other pending message on that queue that is past the same cutoff** and reports them together in one `MERRS` (`Agent.hs#L2325-L2334`).
- The chat layer (simplex-chat) does not override any of these timeouts; searching `src` for `quotaExceededTimeout|messageTimeout|messageRetryInterval` finds nothing.
- Documented semantics (SMQ `protocol/agent-protocol.md#L606`, `#L661-L664`): `SENT` means the message was accepted by a router; `MWARN` is a temporary failure; `MERR` / `MERRS` is a permanent failure.

**Chat item statuses** (SC `src/Simplex/Chat/Messages.hs#L940-L998`)
- `CIStatus` values: `CISSndNew`, `CISSndSent SSPPartial|SSPComplete`, `CISSndRcvd MsgReceiptStatus progress`, `CISSndWarning SndError`, `CISSndError SndError`, and `CISSndErrorAuth` (deprecated).
- `SndError` values: `SndErrAuth`, `SndErrQuota`, `SndErrExpired` (TIMEOUT/NETWORK), `SndErrRelay`, `SndErrProxy`, `SndErrProxyRelay`, `SndErrOther`.
- How agent errors map to these: `agentSndError` (SC `src/Simplex/Chat/Library/Subscriber.hs#L1814-L1828`):
  - `QUOTA` → `SndErrQuota`
  - `NETWORK` / `TIMEOUT` → `SndErrExpired`
  - `HOST` → `SrvErrHost`
- Direct chats (`Subscriber.hs#L715-L724`): `MWARN` → `CISSndWarning`; `MERR` / `MERRS` → `CISSndError`.

**What the UI shows** (Kotlin, SC `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/ChatModel.kt#L3752-L3787`)
- `SndNew`: no icon, just a transparent placeholder (`CIMetaView.kt#L99-L108`). It is not a clock.
- `SndSent`: single check, drawn pale when partial.
- `SndRcvd`: double check; red if the message hash was bad.
- `SndWarning`: orange `ic_warning_filled`, titled "Message delivery warning".
- `SndError`: red `ic_close`, titled "Message delivery error".
- Error texts (SC `apps/multiplatform/common/src/commonMain/resources/MR/base/strings.xml#L376-L384`):
  - `snd_error_quota`: "Capacity exceeded - recipient did not receive previously sent messages."
  - `snd_error_expired`: "Network issues - message expired after many attempts to send it."

**Marking a connection "inactive"** (SC `src/Simplex/Chat/Types.hs#L1872`, `#L1889-L1896`; `Subscriber.hs#L1715-L1747`)
- Each `MWARN QUOTA` increments `quotaErrCounter`.
- At **5** (`quotaErrInactiveCount`), or immediately on `MERR QUOTA` (the counter is set to 999), the connection is flagged inactive and the app receives `CEvtConnectionInactive … True`.
- `QCONT` resets the counter to 0 and sends `CEvtConnectionInactive … False`.
- Per the comment in Types.hs#L1872, this flag only changes group sending; "sending to contacts is unaffected".

#### 4. Group fan-out: per-member status and isolation
- A group message is a single `SndMessage`. It is delivered over a separate pairwise connection (separate queue) to each member, and each member has its own `GroupSndStatus`: `GSSNew | GSSForwarded | GSSInactive | GSSSent | GSSRcvd | GSSError | GSSWarning | GSSInvalid` (SC `Messages.hs#L1118-L1126`).
- **One member's error never fails the whole item.**
  - `MWARN` / `MERR` / `MERRS` from member *m*'s connection only update *m*'s row via `updateGroupMemSndStatus'` (SC `Subscriber.hs#L1282-L1313`, `#L4003-L4010`).
  - Errors in groups are deliberately not shown in the event log: "group errors are silenced to reduce load on UI event log" (`#L1287`).
- **Overall bubble status** is computed by `membersGroupItemStatus` (SC `Messages.hs#L1088-L1101`) from successes only:
  - All members received → `SndRcvd Complete`.
  - Some received → `SndRcvd Partial`.
  - All sent → `SndSent Complete`.
  - At least one sent → `SndSent Partial`.
  - Otherwise → `SndNew`.
  - Errors and warnings are never promoted to the item's status.
- **Inactive members (full queue):** `memberSendAction` returns `MSAPending` when `connInactive conn` is true (SC `src/Simplex/Chat/Library/Internal.hs#L2586-L2604`, `#L2636-L2644`).
  - The message is not handed to the agent at all. It is saved as a `pending_group_messages` row (`createPendingGroupMessage`) and that member's status is `GSSInactive` (SC `src/Simplex/Chat/Library/Commands.hs#L4841-L4844`).
  - UI for that member: `ic_person_off` icon, "Member inactive — Message may be delivered later if member becomes active." (`ChatModel.kt#L3863`, `#L3877`; `strings.xml#L477-L478`).
  - When `QCONT` arrives, the pending backlog is flushed with `sendPendingGroupMessages` (`Subscriber.hs#L1277-L1281`).
  - The code carries a `TODO ensure order - pending messages interleave with user input messages` (`Internal.hs#L2666`).
  - The UI shows per-member statuses in the message info "Delivery" tab (`strings.xml#L436`).

#### 5. Multi-device
- **SimpleX does not fan out to multiple devices of one user.** Its docs say outright "you cannot access the same profile from multiple devices" (SC `docs/BUSINESS.md#L48`).
- **Linked desktop is a remote thin UI, not a second device.** The desktop app drives the phone's chat core and database over XRCP (TLS 1.3 plus post-quantum KEM), and no server is involved (SMQ `protocol/xrcp.md#L19`; blog SC `blog/20231125-simplex-chat-v5-4-link-mobile-desktop-quantum-resistant-better-groups.md#L55-L67`).
  - The phone must be on the same local network.
  - The iOS app has to stay open.
  - You cannot use the mobile app while the desktop is controlling it.
  - The stated upside is that "you do not need to have a copy of all your data on desktop".
- **Why there is no multi-device fan-out** (SC `docs/FAQ.md#L332-L349`):
  - All existing multi-device schemes weaken end-to-end encryption: Signal loses break-in recovery and Session dropped the double ratchet entirely.
  - The "device as group member" model (Signal/WhatsApp) leaks which device you use. It also allows "send messages to some devices but not to the others", leading to inconsistent history.
  - Options under consideration: each device as a group member, ratchet state in an encrypted server container, or a thin client.
  - Current workarounds: the linked desktop, small groups that include your own devices, and business-address groups.
- So SimpleX has **no sync copies and no "own device offline" failure mode**. When a user has several devices, they appear only as ordinary group members.

#### Takeaways for Fireplace
1. **Quota scope.** A full queue blocks only that one queue's (or member's) delivery worker. It never blocks sends to other queues (SMQ `CHANGELOG.md#L879`, `Agent.hs#L3500`).
2. **Message status.** A refused copy is a per-recipient warning, not a message-level failure. The item stays "sent (partial)" if any copy succeeded (`Messages.hs#L1088-L1101`).
3. **Retry instead of fail.** `QUOTA` is treated as temporary: the item gets an orange warning and is retried every 5 min to 6 h for up to 7 days. Resending is triggered immediately by an explicit drain signal (`QCONT`) sent back on the reply queue.
4. **Hard error only at the end.** The message becomes a hard error (`SndErrQuota`, red) only after those 7 days. All other expired messages on that queue are failed together with it (`MERRS`).
5. **Stop queueing to dead recipients.** After 5 quota warnings the recipient is marked "inactive" and new group messages for it are stored locally as pending, not pushed to the server. They are flushed when `QCONT` arrives.
6. **Silent server-side loss.** The server deletes undelivered messages after 21 days (checked every 2 h) without telling anyone; the only signal is the receiver's gap detection.

### Signal

Sources pinned to: Signal-Server `dec95043` (2026-10-02) = **SS** `https://github.com/signalapp/Signal-Server/blob/dec95043fafa6c85219e331a81cd351c752e444c/service/src/main/java/org/whispersystems/textsecuregcm/`; Signal-Android `b377bd21` (2026-10-02) = **SA**; Signal-Desktop `832279c2` (2026-10-01) = **SD**. Support pages were fetched 2026-10-05.

#### 1. How long the server keeps undelivered messages (per device)
- The DynamoDB message queue is keyed per (account ACI, device). The partition key is ACI + `(device.created & ~0x7f) + deviceId` (SS `storage/MessagesDynamoDb.java:188-194`). Every item gets a TTL attribute `E = serverTimestamp/1000 + timeToLive` (`MessagesDynamoDb.java:57,184-186`).
- `timeToLive` is set by config (`configuration/DynamoDbTables.java:38`). The public sample sets `messages.expiration: P30D # Duration of time until rows expire` (`service/config/sample.yml:121-123`). The production config is private, so **30 days in production is UNVERIFIED**, although the sample points to it.
- There is a newer FoundationDB store, cleared by the job `ClearExpiredFoundationDbMessagesCommand`. Its `--message-ttl-days` flag is `required(true)` and has no default (SS `workers/ClearExpiredFoundationDbMessagesCommand.java:68-72,95,106`). The production value is UNVERIFIED.
- Expiry is silent. Neither file shows any code that notifies the sender or the recipient when a message expires.
- The privacy policy only says: "Signal queues end-to-end encrypted messages on its servers for delivery to devices that are temporarily offline". It gives no number of days (https://signal.org/legal/, "Updated May 25, 2018").
- Ephemeral messages (typing indicators etc.) are dropped if they are older than 10 s (`storage/MessagesCache.java:163`).

#### 2. Per-device message count limit
- **There is no message-count cap and no `queue_full`-style rejection.** On send, `MessageSender.sendMessages` validates the device set and then always calls `messagesManager.insert(...)` for every device. If the device is not connected, it fires a push (SS `push/MessageSender.java:112-142`).
- The only reasons a send is refused are listed in `MessageController.sendMessage` (SS `controllers/MessageController.java:179-197`):
  - `409` Mismatched devices (`missingDevices`/`extraDevices`)
  - `410` Stale devices (registration-id mismatch)
  - `413` too large (`MAX_MESSAGE_SIZE` = 96 KiB, `push/MessageSender.java:77`)
  - `428` challenge
  - `401` and `404`
  - the rate limit `messages` = 60 / 1 s per sender (`limits/RateLimiters.java:26`)
  - read-only mode → 503 (`MessageController.java:689-690`)
- **The only size backstop is byte-based, and the server enforces it asynchronously, not the sender.** `MessagePersister.persistQueue` catches DynamoDB `ItemCollectionSizeLimitExceededException` (SS `storage/MessagePersister.java:302-318`):
  - **Primary device:** "will trim oldest messages". It deletes the oldest persisted messages to free `estimatedCachedBytes × trimOversizedQueueExtraRoomRatio` (`:333-389`).
  - **Linked device:** "will unlink device". It calls `accountsManager.removeDevice(...)`.
  - AWS sets this limit at **10 GB per partition key** on tables with local secondary indexes (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/LSI.html#LSI.ItemCollections.SizeLimit).
  - The messages table has an LSI sort key `U` (`MessagesDynamoDb.java:52`). [INFERENCE] So the effective cap is about 10 GB per device queue.

#### 3. One recipient device offline for a long time
- The send is **accepted** (HTTP 200) as long as the sender lists every current device with the right registration ID (`push/MessageSender.java:385-425`).
- Offline status never affects acceptance. The message just sits in that device's queue until the TTL or the 10 GB trim/unlink.

#### 4. Sender's own linked device offline
- The sync transcript (`SyncMessage.Sent`) is a separate request to the sender's own ACI. That request must cover all own devices except the sending one: `excludedDeviceId` (`push/MessageSender.java:390-393`); the server takes the sync path when `account.isIdentifiedBy(destination)` (`MessageController.java:239-241`).
- When the sender has more than one device, the server returns `needsSync = account.getDevices().size() > 1` in `SendMessageResponse` (`MessageController.java:243,254`).
- An offline own device only gets queued messages, so it can never cause a refusal.
- **Order on Android:** recipient first, then sync. `sendContent` sends to the recipient, calls `sendEvents.onMessageSent()`, and only then sends the sync transcript if `isNeedsSync()` (SA `lib/libsignal-service/.../api/SignalServiceMessageSender.java:491-502`). [INFERENCE] If the sync send throws, the exception propagates to the job.
- **Order on Desktop:** the per-recipient state is set to `Sent` and saved, and only then does it run `sendSyncMessage` if `sentToAtLeastOneRecipient` (SD `ts/messages/send.preload.ts:108-135,255-263`). A successful sync marks *our own* conversation entry `Sent` and sets `synced: true` (`send.preload.ts:425-465`). On retry, recipients whose state is already `Sent` are skipped (SD `ts/jobs/helpers/sendNormalMessage.preload.ts:579-581`). So a failed sync can never un-send or re-send to friends.

#### 5. Automatic unlink of inactive devices
- **Thresholds** (SS `storage/Device.java:35-36,207-211`):
  - `ALLOWED_LINKED_IDLE_MILLIS = Duration.ofDays(45)`
  - `ALLOWED_PRIMARY_IDLE_MILLIS = Duration.ofDays(180)`
- **Linked-device unlink job:** the CLI command `remove-expired-devices` (`workers/RemoveExpiredLinkedDevicesCommand.java:54-56,149-157`). It crawls accounts and calls `removeDevice` for every non-primary device where `isExpired()`. It is registered at `WhisperServerService.java:405`.
- **Idle-primary job:** `UnlinkDevicesWithIdlePrimaryCommand` unlinks *all* linked devices when the primary was last seen more than `--primary-idle-days` ago. The default is `DEFAULT_PRIMARY_IDLE_DAYS = 90`, and `--dry-run` defaults to `true` (`workers/UnlinkDevicesWithIdlePrimaryCommand.java:41,56-74,92-100`). The production cron arguments are UNVERIFIED.
- **Warning header:** when the primary has been idle for 30 days, the server adds `X-Signal-Alert: idle-primary-device` on the linked device's WebSocket upgrade. Config default `IdlePrimaryDeviceReminderConfiguration(Duration.ofDays(30))` (`WhisperServerConfiguration.java:343-344`; `auth/IdlePrimaryDeviceAuthenticatedWebSocketUpgradeFilter.java:27,30,51-52`).
- **Official support text:** "After linking a device, your phone has to come online at least once every 30 days. Otherwise, your linked devices will become unlinked." and "Linked devices will also become unlinked after 45 days of inactivity." Also: "limit of 5 linked devices" (https://support.signal.org/hc/en-us/articles/360007320551-Linked-Devices).
  - The 45-day figure matches the code.
  - The 30-day figure does **not** match the job default of 90. [INFERENCE] Production probably runs it with `--primary-idle-days 30`. UNVERIFIED.

#### 6. What Signal Desktop shows
- **Idle primary:** Desktop parses `idle-primary-device` and `critical-idle-primary-device` (SD `ts/util/handleServerAlerts.preload.ts:25-29`).
  - Banner: "Open Signal on your phone to keep your account active" (`_locales/en/messages.json:9391-9392`). After dismissal it is hidden for 1 `WEEK` (`handleServerAlerts.preload.ts:97`).
  - Critical: "Your account will be deleted soon unless you open Signal on your phone…" (`messages.json:9387-9388`), plus a modal 3 days after first receipt and then daily (`handleServerAlerts.preload.ts:105-106`).
  - The current server only emits the non-critical header (SS filter above). The source of `critical-…` is UNVERIFIED.
- **After unlink:** "Unlinked" with "Click to relink Signal Desktop to your mobile device to continue messaging." (`messages.json:3427-3431`). The relink flow offers "Delete all data?" and then a transfer of history from the phone (`messages.json:12081-12086`). Support confirms the erase-and-resync option (Linked Devices page above).
- I found no "you may have missed messages" gap detection for TTL-expired messages (none in the strings/code I read). UNVERIFIED that it does not exist elsewhere.

#### 7. Tick semantics and retries
- **Sent (one check):** "your message has been sent to the Signal service". **Delivered:** "delivered to the recipient's device" (https://support.signal.org/hc/en-us/articles/360007320751). The server answers 200 only after `insert` for all listed devices of that recipient. So one check means the whole per-recipient fan-out was accepted; the sync copy is a separate request.
- Whether "Delivered" requires the first device or all devices is UNVERIFIED. [INFERENCE] Receipts are per recipient, so the first device that delivers is enough.
- **Desktop status:** status is tracked per conversation (`sendStateByConversationId`). Failed recipients are marked `Failed` individually and the others stay `Sent` (`send.preload.ts:170-191`). Retries run for `MAX_RETRY_TIME = durations.DAY` with exponential backoff (SD `ts/jobs/conversationJobQueue.preload.ts:339-340`).
- **Android:** `IndividualSendJob` uses `setLifespan(TimeUnit.DAYS.toMillis(1))` and `setMaxAttempts(UNLIMITED)`. `onFailure()` leads to `markAsSentFailed` (SA `app/src/main/java/org/thoughtcrime/securesms/jobs/IndividualSendJob.kt:126-127,253-257`).
- **409/410 handling:** these are fixed automatically, not shown to the user. 409 archives sessions for extra devices and fetches prekeys for missing ones; 410 archives stale sessions. Then it retries, up to `RETRY_COUNT = 4`, else `IOException("Failed to resolve conflicts…")` (SA `SignalServiceMessageSender.java:175,2123-2142,2164,3027-3059`).

### WhatsApp

Sources: "WhatsApp Encryption Overview" technical whitepaper, **Version 9, February 25, 2026** (https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf); faq.whatsapp.com pages rendered 2026-10-05; https://www.whatsapp.com/legal/privacy-policy. WhatsApp's server is closed source, so there are no code citations.

#### 1. Offline storage duration and caps
- "If a message cannot be delivered immediately (for example, if the recipient is offline), we keep it in encrypted form on our servers for up to 30 days as we try to deliver it. If a message is still undelivered after 30 days, we delete it." (privacy policy; page shows "Effective January 4, 2021").
- I found no published per-device or per-queue message-count cap, and no published behaviour when one is hit. UNVERIFIED.

#### 2. Fan-out and device lists
- "The client uses client-fanout for all the exchanged messages, which means each message is encrypted for each device with the corresponding pairwise session." (whitepaper, "Exchanging Messages").
- The initiator "can immediately start sending messages to the recipient, even if the recipient is offline" ("Initiating Session Setup").
- **Sender Side Backfill** (whitepaper p.20):
  - The sender must list all destination devices, including its own other devices.
  - The server compares a hash of the listed devices with its own records. On mismatch it "will notify the sender to update the devices list". The sender then encrypts and resends only to the newly found devices.
  - Backfill is "only allowed within a short duration after the initial message sending" (duration not stated).
  - [INFERENCE] As in Signal, the server checks list completeness, not the online state of each device. Nothing in the paper says an offline companion, own or recipient's, blocks a send.

#### 3. Tick semantics with multiple devices (FAQ "How to check read receipts", https://faq.whatsapp.com/665923838265756)
- One check: "The message was successfully sent."
- Two checks: "successfully delivered to the recipient's phone **or any of their linked devices**." **The first device to receive it is enough; it does not wait for all devices.**
- "If the recipient's phone is off and the message isn't delivered to any of their linked devices, the second check mark won't appear."
- Groups: "the second check mark appears when everyone has received your message."
- Clock: "Seeing a clock means the message is not yet sent or delivered. This could be due to connectivity issues."
- Message info "Delivered: … delivered to your recipient's phone or linked devices".
- How the sender's *own* companions affect ticks is not documented. UNVERIFIED.

#### 4. Inactive devices and logout
- **Primary inactive:** "You'll need to log in to WhatsApp on your primary phone every 14 days to keep linked devices connected" and "Your companion phones will be logged out if you don't use WhatsApp on your primary phone for over 14 days." (https://faq.whatsapp.com/1046791737425017). The same rule appears in "Can't send or receive messages": linked devices "work even when your phone isn't online, but your linked devices are logged out if you don't use your phone for over 14 days … relink your computer if it was logged out." (https://faq.whatsapp.com/5155925751185676).
- **Companion inactive:** "We'll also automatically disconnect linked devices after 30 days of inactivity." This is attributed to "About linked devices" (https://faq.whatsapp.com/378279804439436). That page returned "This Page Isn't Available" on 2026-10-05 and has no Wayback snapshot, so the quote comes from a search-index snippet only. **UNVERIFIED.**
- **Cryptographic expiry (whitepaper, "Companion Device Removal" pp.33-34):**
  - Companions may be logged out by themselves, by the primary, "or … by the WhatsApp server".
  - The primary periodically re-signs the device list.
  - "Signed Device Lists are expired with a Time to Live of **35 days** or less … Clients will only send and receive messages and calls with the primary device of an account with an expired Signed Device List." So other people's clients **stop encrypting to the companions** of an account whose primary has been silent for more than 35 days. Sending resumes once a newer list arrives.
  - In-chat device-consistency data cuts a stale list's TTL to **48 hours**, "not enforced until the receiving client comes online after the 48 hour window".
- Limit of "up to four" linked devices (FAQ 1046791737425017).

#### 5. Gap detection and retry
- The whitepaper describes no mechanism telling a returning companion that it missed messages that expired after 30 days. History Sync happens only "Immediately after linking a companion device" (p.20).
- Client retry duration and backoff are not published. UNVERIFIED.

### Takeaways for Fireplace (comparison, [INFERENCE])
- Neither system refuses a send because some device's queue is full. Signal accepts the send and only enforces a cap later in the background, by bytes (about 10 GB). At that point it **drops the oldest** messages for a primary and **unlinks** a linked device. It never fails the sender.
- Both track status per recipient. A failed or late own-device sync never changes recipient status. Signal Desktop explicitly sends the sync *after* recipients are marked `Sent`.
- Inactive-device numbers:
  - Signal: linked device 45 d (code + support); primary 30 d per support (job default 90 d); warning header after 30 d.
  - WhatsApp: primary 14 d (FAQ); companion 30 d (UNVERIFIED FAQ); device-list TTL 35 d (whitepaper); server storage 30 d (policy).

## Prior art: offline device storage, partial fan-out, stale devices (Matrix, Wire, iMessage, Threema, Session)
As of 2026-10-05. Code links are pinned to the commits I fetched. **UNVERIFIED** means I could not find a primary source.

### Matrix (spec v1.19, Synapse `7773f05`, Element Web `b243535`, matrix-js-sdk `4cbf531`)
**Architecture.** Conversation messages live in the room DAG, which the server keeps as history. Every device catches up through `/sync` and `/messages`, so offline devices have no per-device message queue. Only the E2EE key material (Megolm room keys, sent over Olm) goes through per-device **to-device** inboxes.
- **Offline retention.** Spec: "Servers should store pending messages for local users until they are successfully delivered to the destination device." A message counts as delivered when the client calls `/sync` again with the `next_batch` token. The spec sets no TTL. It only says that if the queue is large, the server "should limit the number sent in each /sync response. 100 messages is recommended" — https://github.com/matrix-org/matrix-spec/blob/c6a54df511489a9e7f7880b4d55a36ae67405400/content/client-server-api/modules/send_to_device.md (Server behaviour).
- **Per-device caps.** None in the spec. In Synapse I found only per-message limits: `MAX_TO_DEVICE_CONTENT_SIZE` (oversize messages are rejected as "too large to send") and the `rc_key_requests` rate limit, which drops `room_key_request` — `synapse/handlers/devicemessage.py` L97-145, L263-269. Fetching is paged with a `limited` flag (L361-442). My conclusion that the inbox has no count/TTL cap until the device is deleted is **[INFERENCE]** from those files.
- **Stale-device auto-removal.** Synapse `delete_stale_devices_after` (duration; default `null` = never). If set, "a daily background task to log out and delete any device that hasn't been accessed for more than the specified amount of time"; the example value is `1y` — https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#delete_stale_devices_after. Code: `DELETE_STALE_DEVICES_INTERVAL = Duration(days=1)`, and `_delete_stale_devices` calls `get_local_devices_not_accessed_since` — `synapse/handlers/device.py` L94, L214-225. Deleting a device also schedules batched deletion of its queued to-device messages, up to the current stream id ("to avoid deleting non delivered messages if an user re-uses a device ID"), with `DEVICE_MSGS_DELETE_BATCH_LIMIT = 1000` (L330-356, L899).
- **Partial fan-out.** One room event goes to the homeserver once. If the sender cannot establish an Olm session with a recipient device (e.g. no one-time keys), it skips that device and may send `m.room_key.withheld` with code `m.no_olm` ("an olm session could not be established"). Only one such notice is sent per device, "to avoid filling the recipient's device mailbox". Other codes: `m.blacklisted`, `m.unverified`, `m.unauthorised`, `m.unavailable`, and `m.history_not_shared` (v1.19) — https://github.com/matrix-org/matrix-spec/blob/c6a54df511489a9e7f7880b4d55a36ae67405400/data/event-schemas/schema/m.room_key.withheld.yaml. One device therefore never blocks sending; the affected device later shows the event as undecryptable, with the withheld reason.
- **Sender status / retry.** js-sdk `EventStatus` values: `not_sent` ("will no longer be retried"), `encrypting`, `sending`, `queued`, `sent`, `cancelled` — `src/models/event-status.ts`. Backoff is `1000 * 2^attempts` ms, honouring `retry_after`. It gives up after more than 4 attempts and never retries 4xx errors other than 429, or `M_TOO_LARGE` — `src/http-api/utils.ts` L186-211. Status covers server acceptance only; it is not per device.
- **Stale-device UI.** Element: `INACTIVE_DEVICE_AGE_MS = 7.776e9 // 90 days` — `apps/web/src/components/views/settings/devices/filter.ts` L14. The strings say "Inactive devices are devices you haven't used in some time, but they continue to receive encryption keys" and "Remove devices you haven't used in %(inactiveAgeDays)s days or more" — `apps/web/src/i18n/strings/en_EN.json` L2904-2923. These are recommendations only: Element does not remove devices automatically and does not stop encrypting to them.
- **Gap detection on a returning device.** A device that comes back sees history; messages whose keys it never got show as UTD, and it can recover keys through key backup or key requests. I found no "you may have missed messages" banner.

### Wire (wire-server `ecbcb377`, wire-webapp `508667b`)
- **Offline retention: 28 days.** Helm `notificationTTL: 2419200` — "TTL of stored notifications in Seconds. After this period, notifications will be deleted and thus not delivered. The default is 28 days." It is set in both the cannon and gundeck sections — `charts/wire-server/values.yaml` L563-566, L799-802.
- **Per-client queue (current "consumable notifications" design).** Each client gets its own RabbitMQ quorum queue named `user-notifications.<uid>.<cid>`, with a dead-letter exchange `dead-user-notifications` — `libs/wire-api/src/Wire/API/Notification.hs` L219-256. The queue sets no `x-max-length` (no count cap; **[INFERENCE]**: no match for it anywhere in the repo). Persistent notifications are published with `msgExpiration` = TTL; transient ones (typing etc.) get expiration `"0"`, i.e. they are dropped if no consumer is connected — `services/gundeck/src/Gundeck/Push.hs` L347-376.
- **What happens when the TTL is exceeded.** The sender is never rejected. The expired message is dead-lettered, and `DeadUserNotificationWatcher` parses `x-last-death-queue` and runs `INSERT INTO missed_notifications (user_id, client_id)` — `services/background-worker/src/Wire/DeadUserNotificationWatcher.hs` L65-109. When that client reconnects, cannon's `sendFullSyncMessageIfNeeded` sends `EventFullSync`, waits for `AckFullSync`, then deletes the row — `services/cannon/src/Cannon/RabbitMqConsumerApp.hs` L291-330.
- **Legacy pull API.** `GET /notifications?since=&client=&size=` (size 100-10000). For `since` IDs it no longer has, it returns 404 "Notification list" (≤v2) or `NotificationNotFound` (v3+) — `libs/wire-api/src/Wire/API/Routes/Public/Gundeck.hs` L98-131. The client treats this as a gap.
- **Gap UI.** On missed notifications the webapp publishes `CONVERSATION.MISSED_EVENTS`, which injects a system message into every conversation — `apps/webapp/src/script/repositories/event/EventRepository.ts` L271, L496-500; `ConversationRepository.ts` L4249-4260. Text: "You haven't used this device for a while. Some messages may not appear here." For MLS: "You haven't used this device for a while, or an issue has occurred. Some older messages may not appear here." — `apps/webapp/src/i18n/en-US.json` L880, L1455.
- **Fan-out to clients (Proteus).** The server checks the recipient client list. Under the default `report_all`, "the message is not sent if any clients are missing" and the response is **412 "Missing clients"** with `missing`/`redundant`/`deleted`. The client then fetches prekeys, re-encrypts and retries; the alternative strategies are `ignore_all`, `report_only` and `ignore_only`. The rejection is about *unknown* clients, not offline ones: offline clients just queue. A partial federated failure "is reported as a 201, the clients for which the message sending failed are part of the response body" (`failed_to_send`, `failed_to_confirm_clients`) — `libs/wire-api/src/Wire/API/Routes/Public/Galley/Messaging.hs` L147-153, L203-217; `libs/wire-api/src/Wire/API/Message.hs` L497-545.
- **Partial-failure UI.** The message is shown as sent, with an expandable note: "{count} participants from {domain} won't get your message" / "will get your message later" / "didn't get your message". Total failures show "Message could not be sent due to connectivity issues" or "…as the back-end of {domain} could not be reached" — `en-US.json` L1434-1454.
- **Device caps and removal.** `setUserMaxPermClients` defaults to 7 (`values.yaml` L1259-1260). Registering past the limit fails with **403 `too-many-clients`** (`libs/wire-api/src/Wire/API/Error/Brig.hs` L163); the user must delete a client manually. Temporary clients have no limit, and registering one returns the user's other temporary clients as "old" so they get replaced (only one at a time) — `libs/wire-subsystems/src/Wire/ClientSubsystem/Interpreter.hs` L202-222. Inactivity-based auto-removal of permanent clients: **UNVERIFIED / not found**.

### Apple iMessage (Apple Platform Security guide, current web edition)
- **Fan-out.** "The user's outgoing message is individually encrypted for each of the receiver's devices… The resulting messages, one for each receiving device… are then dispatched to the APNs". "For group conversations, this process is repeated for each recipient and their devices." — https://support.apple.com/guide/security/sec70e68c949/web
- **Offline retention: 30 days.** "Unlike other APNs notifications, however, iMessage messages are queued for delivery to offline devices. Messages are stored on Apple servers for up to 30 days." (same page). Messages for Business says it explicitly: "After 30 days, an undelivered cached message expires and is permanently deleted." — https://support.apple.com/guide/security/sec1c603aab4/web
- **Generic APNs, for contrast.** Storage is "30 days or less" depending on `apns-expiration`, and "APNs stores only one notification per bundle ID… In most cases, the latest notification is stored" (drop-older coalescing). `apns-expiration: 0` means try once and don't store — https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns. iMessage is an exception to that one-per-app limit.
- **Per-device caps / behaviour when exceeded.** No count cap is published; expiry silently deletes the message. **UNVERIFIED** beyond the 30-day TTL.
- **Sender UI.** A red exclamation mark with "Not Delivered" → "Try Again" → "Send as Text Message" — https://support.apple.com/en-us/118433. How "Delivered" is computed across multiple recipient devices, and whether copies to the sender's own devices count, is **UNVERIFIED**: Apple does not document it.
- **Stale devices / gaps.** Apple documents no auto-unlink after inactivity and no "missed messages" banner (**UNVERIFIED**). Messages in iCloud separately syncs history, which in practice covers devices that were offline longer than 30 days.

### Threema (FAQ; protocol sources in threema-android `d44a2b5`, `domain/protocol/src/`)
- **Offline retention: 14 days.** "Messages and files are stored on the servers until they are successfully delivered or until 14 days have elapsed (whichever happens first)." — https://threema.com/en/support/private (FAQ "How long do messages stay in queue for delivery?"). CSP flags: `0x02` "No server queuing" (e.g. typing), and `0x20` "Short-lived server queuing… only be queued for 60 seconds" — `csp.struct.yml` L610-628. The server sends `queue-send-complete` when the incoming queue has been fully transmitted (L1019-1028).
- **Multi-device (mediator).** A device that sends reflects the message to the mediator. `reflect-ack` confirms the message "has been stored in their respective reflection queues" (one per other device). An Ephemeral flag `0x0001` forwards only to connected devices — `md-d2m.struct.yml` L198-256.
- **When a lagging device's queue is full, the lagging device is dropped; the sender is not refused.** Mediator close code **`4114`: "Dropped by server because the reflection queue length limit was reached"**. 41xx codes "do not allow for automatic reconnect and require user interaction"; others reconnect with "linear backoff". Other codes: `4111` "Device limit reached", `4113` "Dropped by other device", `4115` "Device slot state mismatch" — `md-d2m.struct.yml` L94-122. The queue-length number is not published (**UNVERIFIED**).
- **Device slots.** `ServerInfo.max_device_slots`. When slots run out, `DeviceSlotsExhaustedPolicy` is `REJECT` or `DROP_LEAST_RECENT` ("Drop the least recently used device"). `DeviceSlotExpirationPolicy` is `VOLATILE` ("removed shortly after the device disconnected… delay of several minutes") or `PERSISTENT` ("kept as long as possible"). `ServerInfo.reflection_queue_length` gives the backlog size, followed by `ReflectionQueueDry`. `DevicesInfo` exposes `last_disconnect_at` per device, and `DropDevice` frees a slot — `md-d2m.proto` L57-171, L184-229.
- **Gap detection (Ibex FS).** Per-direction monotonically increasing `counter`, which is a hint for "an intermediate Encapsulated message went missing". The receiver accepts skips up to a delta of **25,000**. On undecryptable messages it sends `Reject`, and "the sender can then (after manual confirmation by the user) re-send the message in a new FS session" — `csp-e2e-fs.proto` L180-200, L296-312, L855-865. The single-device-era `device-cookie-change-indication` warns when another device connected with the same ID — `csp.struct.yml` L371-392.
- **Stale-device auto-removal.** Only through slot policies (`VOLATILE` expiry, `DROP_LEAST_RECENT`, `4114`). I found no fixed N-day rule (**UNVERIFIED**).

### Session (session-storage-server `a1aac76`, session-desktop `f9465ad`)
- **Architecture.** No per-device queues. All linked devices share one account key and poll the same swarm. Self-sent "sync" copies are stored in the sender's own swarm, so every own device reads the same mailbox.
- **Retention.** Server: `TTL_MAXIMUM = 14 * 24h` for new public-namespace messages, and `TTL_MAXIMUM_PRIVATE = 30 * 24h` for private namespaces and TTL extensions — `oxenss/common/ttl.h`. Client defaults: `CONTENT_MESSAGE: 14 * DURATION.DAYS`, `CONFIG_MESSAGE: 30 days`, `TYPING_MESSAGE: 20s`, `CALL_MESSAGE: 5 min` — `ts/session/constants.ts` L44-53.
- **Caps.** No per-account message count. There is a per-node DB `SIZE_LIMIT = 10 GiB`; when it is full, the store returns `StoreResult::Full` ("database is full") — `oxenss/storage/database.hpp` L128, `database.cpp` L771-776. Message body max is `76'800` bytes, and retrieve pages are capped at `RETRIEVE_MAX_SIZE = 7'800'000` bytes — `oxenss/rpc/client_rpc_endpoints.h` L100/L166, `request_handler.h` L45. Expired messages are simply gone; a device offline for more than 14 days misses them silently (**[INFERENCE]**, no gap UI found).
- **Sync copy ordering and failure.** The message is marked `sent: true` first. Only after that does the client send the sync copy (1:1 only; "there is no sync for groups, each device pulls all messages"), wrapped in try/catch with `log.warn` — `ts/session/sending/MessageSentHandler.ts` L114-160. A send failure toward our own pubkey still runs `saveErrors(error)` and resets `sentSync: false`, with the comment "always mark the message as sent… errors… based on the saveErrors()" (L187-215). What the UI shows for a sync-only error is **UNVERIFIED**. Retry: `pRetry`, `attempts = 3`, `retryMinTimeout = 100` ms — `MessageSender.ts` L231-251.

### Takeaways relevant to Fireplace's `queue_full`
| | Retention | Count cap | When exceeded | Does one device block the send? |
|---|---|---|---|---|
| Matrix | until delivered / device deleted | none (100 per sync page) | n/a; device deleted after `delete_stale_devices_after` | no (`m.no_olm` withheld) |
| Wire | 28 d TTL | none | dead-letter → `EventFullSync` + "haven't used this device" | only *unknown* clients (412), not offline ones |
| iMessage | 30 d | unpublished | silent expiry | **UNVERIFIED** |
| Threema | 14 d chat / mediator queue | limit (number unpublished) | **lagging device dropped (`4114`)**, sender unaffected | no |
| Session | 14 d / 30 d config | none per account | silent expiry | sync sent after `sent`; errors logged |

Across every system I checked, when an offline device's queue is full or expired, the server penalises that device (expiry, full-sync, drop) and the sender is never refused. None of these sources shows a full self-device queue blocking delivery to friends.

### OMEMO / MLS / standards

Versions checked 2026-10-05: XEP-0384 **0.9.1 (2026-04-06, Experimental)**; XEP-0313 1.1.3; XEP-0280 1.0.1; XEP-0160 1.0.1; Conversations `master@bf3269cd128d4dbf0e479c091477fd9544a798b0` (Codeberg); Gajim `master@00e937108841602e9d303e67e71199d39431d268` + omemo-dr 1.2.0 (PyPI); RFC 9420, RFC 9750; draft-ietf-mimi-protocol-06, -mimi-content-09, -mimi-arch-03, draft-mahy-mimi-message-status-01.

#### 1. OMEMO spec (XEP-0384): no inactivity rule, one stanza for all devices
- **The spec sets no time or message-count rule for stale devices.** It only says: "Clients MUST only consider the devices on the `urn:xmpp:omemo:2:devices` node of each recipient (i.e. including their own devices node, but excluding itself)" (§5.5.2, https://xmpp.org/extensions/xep-0384.html#encrypt). Whether a device gets messages depends on the **device list**. Clients add or prune that list themselves.
- **Fan-out is a header, not separate messages.** Each message is ONE `<message>` stanza. It has a single shared payload and one `<key rid=…>` per recipient device, including "other devices of the sender" (§1.2 and §5.8.3 #group-send). There are no per-device queues, so one device cannot refuse a copy while the others accept it.
- **Own-device sync is pull-based.** Sync works through Carbons (XEP-0280) for online devices plus MAM (XEP-0313) for catch-up (§1.2 #intro-overview). Messages carry `<store xmlns='urn:xmpp:hints'/>` (§5.5.3 example).
- **Gap message on the returning device.** If a received message has no `<key>` for this device, "the message was not encrypted for this particular device and a warning message SHOULD be displayed instead" (§5.6 #usecases-receiving). Conversations shows the string "Message was not encrypted for this device." (`src/main/res/values/strings.xml:723`).
- **Decryption failures.** Duplicates MUST be ignored silently. In all other cases clients "SHOULD notify their users … so that the users know they potentially missed a message" (§6 #rules).
- **Heartbeat rule (count-based ratchet hygiene).** "When a client receives the first message for a given ratchet key with a counter of **53** or higher, it MUST send a heartbeat message", which is an empty OMEMO message (§6). An *active* device therefore keeps resetting the sender's chain counter. A counter that keeps growing means the device has stopped answering, and Gajim's heuristic below relies on this.
- **Async principle.** "Asynchronicity: The usability of the protocol does not depend on the online status of any participant." (§2 #reqs). Group sends include "recipients who are currently offline" (attic 0.8.3 §5.8.1, https://xmpp.org/extensions/attic/xep-0384-0.8.3.html).
- **Skipped keys.** MAX_SKIP is RECOMMENDED at 1000 per session, with FIFO discard (§4.3).

#### 2. Conversations (Android): own stale devices expire after 42 days
- `Config.java:74-77`, verbatim comment: "remove *other* omemo devices from *your* device list announcement after not seeing any activity from them for 42 days. They will automatically add themselves after coming back online." The constant is `OMEMO_AUTO_EXPIRY = 42 * MILLISECONDS_IN_DAY`.
  https://codeberg.org/iNPUTmice/Conversations/src/commit/bf3269cd128d4dbf0e479c091477fd9544a798b0/src/main/java/eu/siacs/conversations/Config.java
- `crypto/axolotl/AxolotlService.java:445-470` (`getExpiredDevices`) applies to the user's **own** sessions only. A device is expired when BOTH conditions hold:
  1. `now - lastActivation > 42 d`, and
  2. `now - getLastTimeFingerprintUsed() > 42 d`, where the second value is the `timeSent` of the newest stored message with that fingerprint (`persistance/DatabaseBackend.java:2014-2030`).
  The device is then marked `toInactive()`, and `registerDevices` (`:351-355`) republishes the own device list without it. Contacts' clients then stop encrypting to it.
- **Return path.** If a device sees its own id missing from the list, it re-adds itself (`needsPublishing = me && !deviceIds.contains(getOwnDeviceId())`, `:321`).
- **Contacts' devices.** Any device id that disappears from a contact's published list has its session flipped to inactive (`:325-336`). If it reappears, it is reactivated with a new `lastActivation` (`:337-349`). Conversations has no time heuristic for other people's devices.
- **Enforcement.** `XmppAxolotlSession.processSending` (`:150-162`) only encrypts when `status.isTrustedAndActive()`. Inactive or untrusted devices are left out of the header without an error, and the message still sends.
- **UI.** The key list has "Show inactive" / "Hide inactive" toggles (`strings.xml:635-636`).
- **Catch-up limits.** `MAM_MAX_CATCHUP = 5 days` and `MAM_MAX_MESSAGES = 750` (`Config.java:112-113`). After a longer outage, the global catch-up starts at `lastSessionEstablished - 5d`, and separate per-conversation queries cover older conversations (`xmpp/manager/MessageArchiveManager.java:74-85`, `:349-351`).

#### 3. Gajim / omemo-dr: stop after 2000 unacknowledged messages
- Gajim configures `OMEMOConfig(..., unacknowledged_count=2000)` (`src/gajim/common/modules/omemo.py:160-166`, https://github.com/gajim/gajim/blob/00e937108841602e9d303e67e71199d39431d268/src/gajim/common/modules/omemo.py).
- The "unacknowledged count" is the sender chain index for that session, i.e. messages sent since the device last ratcheted or replied (`src/gajim/common/storage/omemo.py:732-737`: `state.get_sender_chain_key().get_index()`).
- omemo-dr 1.2.0 `session_manager.py:210-218`: during encrypt, if `count >= 2000` it logs "Set device inactive … because of … unacknowledged messages" and calls `remove_device`. That calls `storage.set_inactive` (`:442`). The current message still includes the device; later messages skip it.
- `update_devicelist` (`:394-405`) also ignores devices with `count > 2000` when the list is refreshed.
- **UI.** The trust manager shows "(inactive)" and has a "Show Inactive Devices" switch (`src/gajim/gtk/crypto_trust_manager.py:303-304`; `data/gui/crypto_trust_manager.ui:158`).
- No refusal or failure reaches the user. The device simply stops being a recipient.

#### 4. XMPP server storage semantics
- **XEP-0313 §3.2 (MAM retention).** "A server MAY impose limits on the size of an individual archive … discard old messages once the archive reaches a certain size, or only keep messages until they reach a certain age. Any such deleted messages **MUST be the oldest** … it is not permitted to create gaps or 'holes'." UIDs are never reused. If a client pages from a UID that has been pruned, the server "MUST return an `item-not-found` error" (§4.1.3/§4.2). That error is a server-side signal that the archive was trimmed past the client's position.
- **XEP-0160 (offline storage).** "if not (e.g., because the recipient's offline message queue is full), the server returns a `<service-unavailable/>` error to the sender." This applies **per account (bare JID)**, not per device (https://xmpp.org/extensions/xep-0160.html §2).
- **XEP-0280 §8.** The server "delivers a forwarded copy to each Carbons-enabled resource … excluding the sending client." Carbons only reach resources that are connected right now. Offline own devices recover later from the per-account MAM archive, so sync copies are best-effort by design.

#### 5. MLS (RFC 9420 / RFC 9750): stale members
- **RFC 9420 §16.6.** "There is thus a risk to forward secrecy as long as any member has not deleted these keys. This is a particular risk if a member is offline for a long period of time. Applications **SHOULD have mechanisms for evicting group members that are offline for too long** (i.e., have not changed their key within some period)." No number is given. https://www.rfc-editor.org/rfc/rfc9420#section-16.6
- **RFC 9420 §12.1.8.** Shows the mechanism with an example: "an automated service might propose removing a member of a group who has been inactive for a long time", sent as an external-sender Remove proposal.
- **RFC 9420 §5.3.2.** A client "syncing up with a group after being offline … SHOULD accept signatures from members with expired credentials".
- **RFC 9420 §16.12.** If a member misses or rejects a Commit, it cannot catch up and must re-add itself with an external Commit or reinitialize the group.
- **RFC 9750 §8.2.2.** "any client which is persistently offline may still be holding old keying material and thus be a threat to both FS and PCS … *Recommendation:* Mandate key updates from clients that are not otherwise sending messages and evict clients that are idle for too long … The precise details … are a matter of local policy." https://www.rfc-editor.org/rfc/rfc9750#section-8.2.2
- **RFC 9750 §6.3.** "No operation in MLS requires two distinct clients or members to be online simultaneously … send messages without waiting for another user's reply." The transport must deliver "asynchronously and reliably".
- **RFC 9750 §5.2.** Ordering only matters for Commits and their Proposals. For everything else, "messages that arrive significantly out of order can be dropped without otherwise affecting the protocol." A strongly-consistent DS means "clients needing to handle rejected messages" (§5.2.1), i.e. rejection of conflicting Commits, not per-recipient refusals.
- **RFC 9750 §6.6.** After state loss, a member rejoins as a new member. Reinitialising "does not provide the member with access to group messages exchanged during the state loss window."
- **RFC 9750 §6.7.** Each device is a separate leaf (client), and a new device does not get history.
- **Effect on delivery.** In MLS a stale member never blocks others. Messages are encrypted once to the group epoch, and a stale leaf only weakens FS/PCS until it is removed.

#### 6. IETF MIMI: acceptance is the hub's promise, delivered means any one client
- **draft-ietf-mimi-protocol-06 §5.5.** "A client which receives a success to either an UpdateRoomResponse or a SubmitMessageResponse can view this as a commitment from the hub provider that the message will eventually be distributed to the group." Hub → follower fan-out uses `POST /notify/{roomId}`. A response other than 201 means the hub "SHOULD retry … respecting … Retry-After". Followers MUST answer 201 to duplicates and process only the first. The hub fans out to "all local clients which are **active members**" and may generate "Remove proposals to remove a **lost client**". https://www.ietf.org/archive/id/draft-ietf-mimi-protocol-06.txt
- **Same draft §5.2.** Key-material fetch has `success` vs `partialSuccess`: "key material was provided for at least one client of the target user". Partial device coverage is a normal, non-fatal result.
- **Same draft §7.5, and draft-ietf-mimi-arch-03 §2.** An "Inactive Participant" is a user "with zero client members in the room's cryptographic state. Users in this state may be unable to decrypt messages sent while no clients are members". Clients may be "temporarily 'kicked' out of the group".
- **draft-ietf-mimi-content-09 §5.** "Messages sent to an MLS group are delivered to every member of the group active during the epoch in which the message was sent." §4.2: detecting out-of-order or missing messages needs AppAck (mls-extensions) or MIMI message-status.
- **draft-mahy-mimi-message-status-01 §3.** Status codes are `0 unread`, `1 delivered` ("**a** messaging client of the sender of the report received the message"), `2 read`, `3 expired`, `4 deleted`, `5 hidden`, `6 error`. So *delivered* means any one client of the user, not every device.

#### 7. Signal Sesame (industry spec, cross-reference)
Sesame revision 2 (2017-04-14), https://signal.org/docs/specifications/sesame/. Stale DeviceRecords are kept only to decrypt delayed messages and "may be deleted … at any time". The recommended deletion is after `MAXLATENCY`. On a device-list mismatch the server rejects the send and returns old and new DeviceIDs; the sender marks old devices stale and re-sends. An undecryptable message triggers a retry request.

#### Answers
1. **When a client stops encrypting to an inactive device.**
   - The OMEMO spec gives **no number**.
   - **Conversations:** removes its own other devices after **42 days** with no activation and no received message. Contacts' devices are dropped when they leave the published device list.
   - **Gajim / omemo-dr:** stops after **2000** messages sent with no ratchet reply. The heartbeat at **53** keeps active devices far below that.
   - **How it is surfaced:** the device is skipped without an error (sending is never blocked). The key-management UI shows "(inactive)" or a "Show inactive" toggle. The returning device shows a per-message warning: "Message was not encrypted for this device."
2. **MLS on stale members.**
   - Stale leaves threaten FS/PCS.
   - RFC 9420 §16.6 says applications SHOULD evict members offline "too long". RFC 9750 §8.2.2 says to mandate updates and evict idle clients, with the policy left local and no numbers given.
   - Delivery is not blocked. An evicted or desynced device rejoins (external Commit) without the history it missed.
3. **Principle that an offline device must not block the others.** There is no single normative sentence that says exactly this. The closest normative texts are:
   - XEP-0384 §2 ("usability … does not depend on the online status of any participant").
   - RFC 9750 §6.3 ("No operation … requires two distinct clients … to be online simultaneously").
   - MIMI protocol §5.5 (success = hub commitment to eventual distribution).
   - MIMI message-status (`delivered` = *a* client).
   - MIMI `partialSuccess` for key fetch.

   Structurally, XMPP has no per-device queues. There is one stanza per account, Carbons reach only online devices, and the MAM archive is pruned oldest-first. A per-device overflow therefore cannot fail the sender. [INFERENCE] Under these designs, a full own-device queue should never decide the sender-visible status.

**UNVERIFIED:** whether other OMEMO clients (Dino, Monal, Cheogram) use different thresholds; Conversations' exact UI wording when its own device list is pruned (only the inactive-key toggle strings were checked).
