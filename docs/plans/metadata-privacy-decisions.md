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
| 24 | 09-24 | The "peer links a device mid-session" drive happens in the sibling slice | ENGINEERING | ACTIVE |
| 25 | 09-24 | A box-pinned retry whose route is gone stays failed; the user resends | OWNER | ACTIVE |
| 26 | 09-25 | Siblings swap self-queue addresses through their REQUEST queues, not the link blob | OWNER — changes approved design §4.2 | DONE (part A `a35930e4`) |
| 27 | 09-25 | One self-queue per device; revoking a device = each survivor rotates its self-queue | ENGINEERING (owner was asked) | ACTIVE (rotation = part B) |
| 28 | 09-25 | Sibling addresses live in `boxsib_v1`; no backup carries them | OWNER | DONE |
| 29 | 09-25 | No auth-key escrow; a revoked device's queues are left to the 90-day reaper | OWNER — changes approved design §4.2 | ACTIVE |
| S8 | 09-25 | Decisions are classed OWNER / ENGINEERING, batched per phase, logged here | OWNER | ACTIVE |
| 30 | 09-25 | (O2) The box may hold ~3 GB in total: 2 GiB of media + 60 000 undelivered message blobs; past it a send/upload answers `quota_exceeded` | OWNER | ACTIVE |
| 31 | 09-25 | (O3) Media over a queue's daily budget answers an honest `429 quota_exceeded` (the sender can retry); the residual — a sid holder learns the queue is alive and spent — is accepted | OWNER | ACTIVE |
| 32 | 09-25 | (O4) No push notifier on the self-queue: your own sent copies reach your other devices when they open, never as a notification | OWNER | ACTIVE |
| 33 | 09-25 | (O5) D5 confirmed with its visible effect: one global switch in Privacy settings, mutual (Signal model), default OFF — ✓✓ and typing disappear on box chats until both sides turn them on | OWNER | ACTIVE |

## Engineering calls made in the work so far (owner may overrule at the gate)

| Id | Call | Reason |
|---|---|---|
| E1 | A sibling PreKey message must carry the ACCOUNT identity key before it is decrypted (`prekey_identity.dart`) | The request queue is public and the identity store is TOFU: a stranger's PreKey message would replace the real sibling session |
| E2 | The self-queue is handed only to devices the own VERIFIED list names live | The server says which siblings exist; it must not decide who holds our self-queue |
| E3 | Nothing device-scoped is published before E2E is ready on that connect | A device on the link gate holds the primary's token (found live: it overwrote device 1's request queue) |
| E4 | `BoxSession.takeSiblingHandoff`: store → ack → hand ours back, ack first | Closes the primary's `devices:[]` race with no reconnect; ack-first stops a handoff ping-pong (pinned by an exact 4-send test) |

## Open — owner input owed

| Id | Question | Needed before | Where |
|---|---|---|---|
| O1 | When release N+1 may drop the old tables (convergence rule). Current recommendation: no min-version gate; `contact_backups` row existence as the condition, plus a pre-G6 query that must be empty or knowingly accepted | G6 | `.planning/metadata-privacy/convergence-decision.md` |

## Contradictions found while building this log

- **The 16 MiB cap was asked twice with opposite answers.** On 09-24 in the mp worktree it was "raise now" (9); on 09-25 in the master checkout "accept the gap until Phase 5". The second question was asked without reading the first, because 9 lived only in a gitignored plan. Resolved the same day: the owner said "do 32 MiB", matching 9. Prevention: this log is tracked, and master points at it.
- **Three different "decision 1"s** (§3b, §3c, and the PR3.2 block) in the working plan. Renumbered here as A1–A5, B1–B4 and 1–29.
- **Design §4.2 described superseded choices** (sids in the link blob, auth-key escrow) until 09-25. It now points at 26–29.
