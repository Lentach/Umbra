# Metadata privacy — decision log

**The one place every metadata-privacy decision lives.** Tracked, so every worktree and every session sees the same list. Before answering ANY metadata-privacy question — from any checkout — read this file; on master it is `git show origin/feat/metadata-privacy:docs/plans/metadata-privacy-decisions.md`.

## How decisions are made (owner, 2026-09-25)

- **OWNER decides:** product, what users see, privacy (what the server or box can learn), cost and limits, and anything that changes the design approved 2026-09-20 (`.planning/metadata-privacy/design-candidate.md`). A change to that design is asked as "changes approved design §X", never as an ordinary pick.
- **ENGINEERING decides** (the agent doing the work): wire formats, storage layout, id schemes, retries and backoff, internal structure. Each call is written into this log with its reason; the owner can overrule any of them at the phase gate.
- **Batched:** open owner questions for a phase are collected in ONE design note before coding (`2026-09-25-metadata-pr31-remainder.md` for the rest of PR3.1), not asked slice by slice.
- **Superseding:** a decision is never edited in place. A new row says what it replaces, and the old row's status says `SUPERSEDED by <id>`. The `.planning/` notes stay the working record; this log is the authority.

Status: ACTIVE (in force), DONE (carried out, still binding), SUPERSEDED, OPEN (asked, not yet answered).

## Design decisions (2026-09-20, `design-candidate.md` §7 and §4.5)

| Id | Decision | Class | Status |
|---|---|---|---|
| D1 | Box shape approved: identity service + unauthenticated `/box`, queues addressed by random sids | OWNER | ACTIVE |
| D2 | Live receive (a): one always-subscribed `/box` WebSocket per device, its own `io.io()` | OWNER | ACTIVE |
| D3 | Client IP is procurement (Orbot/Tor), not engineering | OWNER | ACTIVE |
| D4 | Disappearing timers are client-side | OWNER | ACTIVE |
| D5 | Receipts and typing ride inside the envelope, **mutual opt-in, default OFF** | OWNER | ACTIVE |
| D6 | A notification opens the app, not a chat; box push is bare `{type:'new_message'}` | OWNER | ACTIVE |
| D7 | Identity keeps no push token and sends no push; identity alarms show on open only | OWNER | ACTIVE |
| D8 | TTL 30 d for undelivered messages, 14 d for media | OWNER | ACTIVE |
| D9 | PWA history is device-local; backup ships with the cutover; the user is told on loss | OWNER | ACTIVE |
| D10 | History backup = a user-held file now | OWNER | DONE (PR2.3) |
| D11 | Same process for identity and box, namespace `/box` | OWNER | ACTIVE |
| D12 | Native first | OWNER | ACTIVE |

## Phase 0–2 decisions (2026-09-20 → 09-23)

| Id | Date | Decision | Class | Status |
|---|---|---|---|---|
| A1 | 09-20 | Auth audit log lines: strip every account id, keep event names | OWNER | DONE |
| A2 | 09-20 | Media TTL 14 d | OWNER | ACTIVE (= D8) |
| A3 | 09-20 | nginx access log OFF; `error_log … crit` | OWNER | DONE (prod) |
| A4 | 09-20 | G0: Phase 0 to master + prod | OWNER | DONE |
| A5 | 09-20 | G1: store shape A (one record per contact); PWA eviction answered by an AUTOMATIC server-held contact backup wrapped by the PASSWORD, phrase optional | OWNER | DONE (PR2.2, PR2.4) |
| S1 | 09-20 | Line budgets on PRs deleted ("build proper code") | OWNER | ACTIVE |
| B1 | 09-22 | Own-key banner on a wiped linking-OFF install: soft neutral notice | OWNER | DONE |
| B2 | 09-22 | One neutral divider text for both link and re-mint causes | OWNER | DONE |
| B3 | 09-22 | Keep keys across storage loss via a password-wrapped identity backup (lever d) | OWNER | SUPERSEDED by S4 |
| B4 | 09-22 | Built-in Tor (Arti) stays Phase 5 | OWNER | ACTIVE |
| S2 | 09-23 | Box media budget 1 GiB per normal queue per UTC day | OWNER | ACTIVE |
| S3 | 09-23 | G4: box OFF on prod (`BOX_ENABLED: 'false'` pinned in the prod compose) until the PR3.1 prerequisites land | OWNER | ACTIVE |
| S4 | 09-23 | Lever (d) and storage-loss Parts B + C dropped | OWNER | ACTIVE |
| S5 | 09-23 | The branch stays a branch until release N; master then fast-forwards | OWNER | ACTIVE |
| S6 | 09-23 | G4 passed: Phase 1 on master, backend live with the box off | OWNER | DONE |
| S7 | 09-23 | PR0.2 push change signed off (visible app → badge only; closed or backgrounded app → push as before) | OWNER | DONE |

## PR3.x decisions (2026-09-24 → 09-25)

| Id | Date | Decision | Class | Status |
|---|---|---|---|---|
| 1 | 09-24 | I2b exception accepted: `devices.requestSid` equals `box_queues.sid` | OWNER | ACTIVE |
| 2 | 09-24 | No push notifier on the REQUEST queue; friend requests arrive on the next open | OWNER | ACTIVE |
| 3 | 09-24 | Search keeps spending one-time pre-keys (fetch 100 + search 100 per 15 min) | OWNER | ACTIVE |
| 4 | 09-24 | The "already a friend" filter moves into the app | OWNER | ACTIVE |
| 5 | 09-24 | PR3.1 ships as small slices (a)–(g), each test-first and reviewed | OWNER | ACTIVE |
| 6 | 09-24 | The full first-contact chain is proven with slice (f) in `box_roundtrip_test` | ENGINEERING | ACTIVE |
| 7 | 09-24 | Prod background-push check passed on the owner's phone | — | DONE |
| 8 | 09-24 | The web deploy of master is a separate owner-scheduled session | OWNER | ACTIVE |
| 9 | 09-24 | Box media top rung 32 MiB NOW, so no file that sends today stops (nginx `/box/` 32m) | OWNER | DONE (`191fc86a`; nginx applied on prod 09-24) |
| 10 | 09-24 | `deleteQueue` on a gone queue answers `auth_failed` (= "gone") | OWNER | ACTIVE |
| 11 | 09-24 | No in-app sound or banner for other chats; badge only | OWNER | ACTIVE |
| 12 | 09-24 | Binary in-seal frame `u8 v ‖ u8 kind ‖ u16be device ‖ Signal` | ENGINEERING (owner was asked) | ACTIVE |
| 13 | 09-24 | Message time = the sender's clock, clamped to the receive time | OWNER | ACTIVE |
| 14 | 09-24 | Box message ids are local, from a counter starting at 2^48 | ENGINEERING (owner was asked) | ACTIVE |
| 15 | 09-24 | A message is never on both paths | OWNER | ACTIVE |
| 16 | 09-24 | All-or-nothing: the box only when EVERY live peer device and EVERY other own device has an address | OWNER | ACTIVE |
| 17 | 09-24 | Sibling queues next, then box push | OWNER | ACTIVE (order refined by 23) |
| 18 | 09-24 | An over-long message is blocked in the composer, same limit everywhere | OWNER | ACTIVE |
| 19 | 09-24 | Box down or unacked = the row fails with 'Ponów'; no persisted outbox | OWNER | ACTIVE |
| 20 | 09-24 | ✓ only when the box took every frame | OWNER | ACTIVE |
| 21 | 09-24 | Device lists are verified once per connect, never by a send | ENGINEERING (owner was asked) | DONE |
| 22 | 09-24 | Disappearing timers, replies and media move to the box in their own slice after sibling queues + push | OWNER | ACTIVE |
| 23 | 09-24 | Order: sibling queues, then box push registration | OWNER | ACTIVE |
| 24 | 09-24 | The "peer links a device mid-session" drive happens in the sibling slice | ENGINEERING | DONE (part B drive 09-25): until the peer reconnects, its box sends go ONLY to the devices it already knew, reported sent; the newly linked device silently never gets them (decision-21 residual, closed by slice (e) announcements). After the reconnect: one whole old-path message, then the box once addressed. Not driven: the mirror for a REVOKED device (a peer keeps sending it box frames until it reconnects) |
| 25 | 09-24 | A box-pinned retry whose route is gone stays failed; the user resends | OWNER | ACTIVE |
| 26 | 09-25 | Siblings swap self-queue addresses through their REQUEST queues, not the link blob | OWNER — changes approved design §4.2 | DONE (part A `a8a4e560`, CI 7/7 on `dbe54d3a`) |
| 27 | 09-25 | One self-queue per device; revoking a device = each survivor rotates its self-queue | ENGINEERING (owner was asked) | DONE (part B `59e141de`, revoke driven 09-25; old queue deleted after the 30-d TTL, E6) |
| 28 | 09-25 | Sibling addresses live in `boxsib_v1`; no backup carries them | OWNER | DONE |
| 29 | 09-25 | No auth-key escrow; a revoked device's queues are left to the 90-day reaper | OWNER — changes approved design §4.2 | ACTIVE |
| S8 | 09-25 | Decisions are classed OWNER / ENGINEERING, batched per phase, logged here | OWNER | ACTIVE |
| 30 | 09-25 | (O2) The box may hold ~3 GB in total: 2 GiB of media + 60 000 undelivered message blobs; past it a send/upload answers `quota_exceeded` | OWNER | ACTIVE |
| 31 | 09-25 | (O3) Media over a queue's daily budget answers an honest `429 quota_exceeded` (the sender can retry); the residual — a sid holder learns the queue is alive and spent — is accepted | OWNER | ACTIVE |
| 32 | 09-25 | (O4) No push notifier on the self-queue: your own sent copies reach your other devices when they open, never as a notification | OWNER | ACTIVE |
| 33 | 09-25 | (O5) D5 confirmed with its visible effect: one global switch in Privacy settings, mutual (Signal model), default OFF — ✓✓ and typing disappear on box chats until both sides turn them on | OWNER | ACTIVE |
| 34 | 09-25 | Box notifier registration is batched per TOKEN: one `notifier_challenge` push proves the token, then every queue is activated in one batch of `{nid, sig}`, each signed by its own queue key over `nid ‖ 0x02 ‖ code`. Replaces E9's one-queue-at-a-time client (wire.md + backend + int tests + client) | OWNER | DONE 09-25 (wire.md + backend + int tests + `BoxNotifiers`; engineering shape in E9a) |
| 35 | 09-25 | No notifier on a `blocked` or `former` contact's queue (the box cannot know a block; a blocked peer holding the sid could ring an offline device). Residual: a contact blocked AFTER registration keeps its notifier until the queue is deleted | OWNER | DONE 09-25 (`BoxNotifiers` skips both states, red-first; retiring self-queues pinned excluded) |
| 36 | 09-25 | E9 keeps ONE sealed `boxntf_v1` row per account (not one row per queue); the Android/FCM E9 path is verified at G5 on a device, not locally | OWNER | ACTIVE |
| 37 | 09-25 | (O6) A device REFUSES a sibling PreKey message that would replace an existing session with that sibling unless this device asked for the re-key; per-device keys (O6 option b) stay a later design change | OWNER | DONE 09-25 (E37a/E37b; web drive of two linked devices: lost session → refused → re-keyed → both sides read) |
| 38 | 09-25 | (O7) Missing Signal sessions to box-covered devices (own siblings and peer devices) are PRE-BUILT at connect, so no pre-key fetch on the account socket lines up with a send | OWNER | DONE 09-25 (E38a/E38b; web drive: bundle fetched at connect, the send emitted none; a lost session failed the send with no fetch and healed on reconnect) |
| 39 | 09-25 | The OLD `new_message` push on an Apple endpoint always posts a notification and closes it at once, even for a focused chat (Safari revokes a subscription after 3 silent pushes); other endpoints unchanged | OWNER | DONE 09-25 (`web-push-sw.js`; Chrome drive: focused chat silent, other chat carded; Apple branch proved only in a vm harness, iPhone at G5) |
| 40 | 09-26 | (O8) Box media: every device downloads each attachment on arrival and keeps an encrypted local copy (the sender keeps its own), so history outlives the 14-d box TTL; on the PWA the copy is device-local (D9) | OWNER | ACTIVE |
| 41 | 09-26 | (O9) Disappearing countdown on box chats, Signal's model: the sender's copies count from the send, each receiving device from the first time it shows the message; an unread message goes 1 d after the send | OWNER | ACTIVE |
| 42 | 09-26 | (O10) The chat's timer SETTING stays the server column (`setDisappearingTimer`) until PR4.x; each box message carries its own `ttl` inside E2E and the devices enforce it | OWNER | ACTIVE |
| 43 | 09-26 | (O11) Pings move to the box in item 3 (decision-22 slice) | OWNER | ACTIVE |
| 44 | 09-26 | (O12) A box attachment is uploaded ONCE, charged to one peer queue, and every addressed device (peer devices and own siblings) downloads the same id. Accepted residual: the box sees several downloads of one id from different devices and IPs, which links the queues that received it | OWNER | ACTIVE |

## Engineering calls made in the work so far (owner may overrule at the gate)

| Id | Call | Reason |
|---|---|---|
| E1 | A sibling PreKey message must carry the ACCOUNT identity key before it is decrypted (`prekey_identity.dart`) | The request queue is public and the identity store is TOFU: a stranger's PreKey message would replace the real sibling session |
| E2 | The self-queue is handed only to devices the own VERIFIED list names live | The server says which siblings exist; it must not decide who holds our self-queue |
| E3 | Nothing device-scoped is published before E2E is ready on that connect | A device on the link gate holds the primary's token (found live: it overwrote device 1's request queue) |
| E4 | `BoxSession.takeSiblingHandoff`: store → ack → hand ours back, ack first | Closes the primary's `devices:[]` race with no reconnect; ack-first stops a handoff ping-pong (pinned by an exact 4-send test) |
| E5 | Sent copies ride the E2E field `to` (the peer id); the route needs every live sibling addressed, else the whole message takes the old path; a sibling refusal fails the row | Decision 16; the box sees no account. The send-time pre-key fetch it can cause is owner question O7 (ANSWERED 09-25 → decision 38: a box send no longer fetches, E38b) |
| E6 | A retiring self-queue is deleted only after the 30-d TTL, never on acks or drain markers; an ack of a non-current sid re-hands the current one | Two reviews: every earlier-delete scheme lost a copy still in flight or sent by a second tab from an older row, silently (a send to a deleted sid answers ok). Residuals: a sibling still on the old address after the TTL loses what it sends there; on a reconnect the TTL delete runs beside the resubscribe, so an EXPIRED queue can go before the box pushed its last frames; a sibling that re-learns the old address loses what it sends there until the re-hand reaches it |
| E7 | `boxsib_v1` entries the own verified list no longer names live are pruned (in the rotation's write) | The verified list is the authority (E2) |
| E8 | A revoked sibling origin is finished at once; an absent one, an undecided one (the own list is not cached and its fetch fails) or a missing session is held ≤ 30 d on a self-queue only; a copy waiting for a chat ≤ 30 d | The journal prune never drops an unconsumed row, so the reader must bound the hold |
| E9 | (Registration part SUPERSEDED by 34 / E9a.) Box push registration runs one queue at a time (the pushed code names no queue); active notifiers are kept per push target in `boxntf_v1`, so a queue is challenged once per token; a target that gets no code, or that the box refuses (`invalid_payload`), rests 15 min; a web page takes a challenge only while visible, and the push SW posts-then-closes a notification whenever no visible page took it or the endpoint is Apple's. The box also wakes a device when a socket goes away while its queue still holds messages | Plan E9. Safari revokes a subscription after 3 silent pushes. The disconnect wake-up was found by the live drive: a dead socket is detached only at the ping timeout (~40 s), and every message stored meanwhile was handed to it, never pushed. Residual: a resubscribe inside the 2.5 s coalescing still gets the push (same as `send`) |
| E9a | (Decision 34's wire, replaces E9's one-queue-at-a-time registration.) Step 1 `{v, platform, token}` is UNSIGNED and names no queue; step 2 `{v, code, queues:[{nid, sig}] 1..256}` → `{ok, refused:[{nid, code}]}`, each entry signed over `nid ‖ 0x02 ‖ code`. Pending codes are kept 10 min keyed by SHA-256(code), several per token. A dead code refuses the whole frame; a bad entry is refused alone. The client challenges once per pass for every owed queue, activates a frame at a time and records each frame as it lands; a nid refused in a batch is not offered again by that `BoxNotifiers` (each offer costs a push) | The old step-1 signature protected nothing: queues are free to mint, so anyone could already make the box push a code to any token. Keying by the code, not the nid (gone), the token or the socket, means a reconnect between the steps or a stranger challenging the same token voids nothing (int test). A frame of 256 matches `subscribe` |
| E37a | (Decision 37's test.) A sibling PreKey message "would replace" only when this device holds a NON-fresh session record for that sibling and no current or archived state matches the message's `(version, baseKey)` — libsignal 0.8.2 `SessionBuilder.processV3` (`session_builder.dart:56-76`) archives the current state exactly then. Checked in `_readSiblingBox` after the live-origin gate, before `decrypt` | "PreKey + a session exists" would refuse every normal first contact: an initiator keeps sending PreKey messages under the SAME base key until the responder answers |
| E37b | "This device asked for the re-key" = this device ran `rekeySibling(d)` within the last 10 min (in memory, `BoxSession`); cleared by the first message from `d` that decrypts. A refused PreKey is FINISHED (not held) and answered by `rekeySibling(d)` from our side, under the existing once-per-session guard, with `fresh: true` = `markSessionRebuild` + `ensureSession`, so `processPreKeyBundle` ARCHIVES (never deletes) our state with `d` and the handoff is a fresh PreKey message (a hand-rolled load/archive/store cannot work: `containsSession` must stay true for archived-state decrypts, so the send path would encrypt on an empty state) | Today's recovery makes the device that lost its session the INITIATOR, so the other side would refuse it; answering a refusal with our own re-key makes the loser the receiver it asked for: D re-keys → S refuses and re-keys → D accepts (it asked). A forged PreKey costs one re-key built from the real bundle, which the forger cannot read. Residual: a second loss in the same session waits for a reconnect (the once-per-session guard); not persisted, so a restart mid-exchange costs one more round Also: crossing first contacts (each side holding its own unanswered session) refuse each other once and spend both guards; a garbage PreKey carrying the public account identity costs two re-keys. libsignal 0.8.2 trial-decrypts on a SHALLOW copy of the current state, so an old-session message read AFTER the re-key breaks the fresh session (Bad MAC on the next reply) — pre-existing for every rebuild, bounded by queue order (old messages precede the re-key on the self-queue) |
| E38a | (Decision 38.) Sessions are pre-built inside `BoxDeviceListRefresh`: once a user's list verifies (connect, list change, backoff retry), every live box-covered device on it — a peer device with an address, a live own sibling — that has no session or a pending rebuild gets `ensureSession`, and `readyFor(user)` resolves only after that attempt. A peer's rebuild request re-runs the pre-build for that device on receipt | The refresh is already the one connect-time, event-driven place that knows the verified devices, and `_boxRoute` already awaits `readyFor`; every fetch is then caused by connect or an inbound event, never by a send |
| E38b | A box send NEVER fetches a pre-key bundle: a device with no usable session (none, or a rebuild pending) FAILS the box send, the row shows retry, and the device is left to E38a's next pass (backoff timer, list change, reconnect). Siblings' re-key (`rekeySibling`, decision 37) and connect-time handoffs still fetch: they follow an inbound frame or the connect, not a send | Same rule as decision 21 for lists: a send-timed lookup names the sender at the moment of the box frame. Falling back to the old path would leave a server row naming the pair (decision 15) As built: for our own account "covered" = a sibling with a self-queue address (one without goes the old path, E5); a rebuild request reaches the pre-build through the existing `invalidateDeviceList` chain (the mark is set first); the backoff timer exists only after a FAILED pass, so a session lost after a good pass heals at the next list change or reconnect; a failed own-account pre-build fails every box send until retried; a rebuild mark landing between the usable-session check and `encrypt` lets one message out on the old session |

## Open — owner input owed

| Id | Question | Needed before | Where |
|---|---|---|---|
| O1 | When release N+1 may drop the old tables (convergence rule). Current recommendation: no min-version gate; `contact_backups` row existence as the condition, plus a pre-G6 query that must be empty or knowingly accepted | G6 | `.planning/metadata-privacy/convergence-decision.md` |
| O6 | (ANSWERED 09-25 → decision 37.) Every device of an account shares ONE identity key, and a box frame's `senderDeviceId` is not authenticated, so a REVOKED device can still seal a PreKey message posing as a LIVE sibling into our public request queue: its handoff would replace that sibling's session and address, and every later sent copy (E5) would go to it. Options: (a) refuse a sibling PreKey message that would replace an existing session unless this device asked for a re-key; (b) per-device keys bound into the verified device list (changes approved design); (c) accept until slice (e)/(f). Recommendation: (a) now, (b) later | Box ON in prod | Re-review of part B (PartBReReview, P2-3), `.planning/metadata-privacy/task_plan.md` part B |
| O7 | (ANSWERED 09-25 → decision 38.) A box send to a device with no Signal session yet (a sibling, or a peer device since slice (c)) fetches its pre-key bundle on the account socket at send time, which tells the server this account is sending now. Options: (a) accept (the swap's PreKey handoffs make it rare for siblings); (b) decline to the old path when a session is missing; (c) pre-build sessions at connect. Recommendation: (c) | Box ON in prod | Re-review of part B (PartBReReview, P3-3) |
| O8 | (ANSWERED 09-26 → decision 40.) Box media is deleted after 14 d (D8): (a) every device downloads on arrival and keeps an encrypted local copy; (b) keep once shown; (c) keep nothing, expired after 14 d. Recommendation: (a) | Item 3 (decision-22 slice) | `2026-09-25-metadata-pr31-remainder.md` § Item 3 |
| O9 | (ANSWERED 09-26 → decision 41.) Disappearing countdown on box chats: (a) sender from send, each receiving device from first show, unread gone 1 d after send; (b) all from send; (c) shared deadline via an E2E read tick, only when both have receipts on. Recommendation: (a) | Item 3 | same |
| O10 | (ANSWERED 09-26 → decision 42.) The chat's timer SETTING in release N: (a) stays a server column until PR4.x, each box message carries its own `ttl`; (b) moves now to E2E control messages. Recommendation: (a) | Item 3 | same |
| O11 | (ANSWERED 09-26 → decision 43.) Pings (in no slice; a ping to a box contact is a server row naming the pair): (a) move them in item 3; (b) later. Recommendation: (a) | Item 3 | same |

## Contradictions found while building this log

- **The 16 MiB cap was asked twice with opposite answers.** On 09-24 in the mp worktree it was "raise now" (9); on 09-25 in the master checkout "accept the gap until Phase 5". The second question was asked without reading the first, because 9 lived only in a gitignored plan. Resolved the same day: the owner said "do 32 MiB", matching 9. Prevention: this log is tracked, and master points at it.
- **Three different "decision 1"s** (§3b, §3c, and the PR3.2 block) in the working plan. Renumbered here as A1–A5, B1–B4 and 1–29.
- **Design §4.2 described superseded choices** (sids in the link blob, auth-key escrow) until 09-25. It now points at 26–29.
