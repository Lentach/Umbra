# Multi-device (linked devices) — design

**Status: v5 — FROZEN 2026-08-17 after THREE review rounds + a delta micro-verification (round 1
on v2; round 2 on v3 + SAS literature check; round 3 delta-scoped termination round on v4; final
micro-check on the round-3 folds returned FREEZE with zero mechanism findings). §11 owner
questions ALL ratified. Design review is CLOSED at doc level; all further review happens at phase
gates (spec-level, with code in hand — Phase 2 mandatory). NO CODE until Phase-0a dispatch.**
Research record: `.cursor/session-summaries/2026-08-17-session-multidevice-research.md` and
`.planning/multi-device/findings.md`.

---

## 1. Goal and non-goals

**Goal:** one account usable on up to 3 concurrent devices (1 primary + 2 linked) with:
- no weakening of the E2E model (server stays blind; keys never transit the server in the clear);
- device additions impossible without physical possession of the primary (kills today's
  password-only takeover AND eprint 2021/626-class server-side device injection);
- per-device Signal sessions (compromise of one device's sessions does not expose another's);
- self-sync (a message sent on device A appears on device B).

**Non-goals (explicitly out of scope):**
- PQXDH/Kyber (separate epic: Rust-FFI lib swap; never combined with this migration).
- Sealed sender, groups, iOS native app, history-transfer-on-link (Phase 4, optional, own doc).
- Remote wipe of a revoked device's local data.
- Any change to disappearing-message semantics, the reconcile protocol's fail-closed rules, or the
  plaintext-store invariants (`frontend/CLAUDE.md` §5) beyond what §5.4/§5.6/§5.7 state explicitly.

## 2. Threat model and the invariant matrix

Actors: **P** = password thief (credential only). **S** = malicious/compromised server.
**L** = compromise of a *linked* device (incl. XSS on a linked PWA, which can read that device's
web-stored keys). **Pr** = compromise of the *primary* device.

| Capability | P | S | L | P+S | L+S |
|---|---|---|---|---|---|
| Read past messages | no | no | that device only | no | that device only |
| Read future messages | **no** (today: YES) | no | that device only | no | that device + forged-list risk¹ |
| Add/replace a device (honest server) | no | n/a | **no** | n/a | n/a |
| Add a device (server colludes) | no | no² | no² | no² | **yes¹** |
| Freeze/split a peer's view of the device list | no | bounded³ | no | bounded³ | bounded³ |
| Trigger identity reset | yes, but loud + delayed (§6.2) | no | yes, loud + delayed | yes, loud + delayed | yes, loud + delayed |

¹ L+S: a linked device holds the shared identity key IK; with a colluding server it can present a
forged enrollment to *new* peers (TOFU). Existing peers detect it: they pin the DAK (§3) and the
list version, and a DAK change or version rollback renders the loud identity-changed surface.
Accepted residual risk — deep full-compromise territory.
² Device-list mutations require a DAK signature (§3). S alone lacks IK and DAK. L alone holds IK
but not DAK; both server and peers refuse IK-signed mutations by construction.
³ S can withhold a NEWER validly-signed list (freeze), which per-peer monotonicity alone cannot
detect. Bounded by the end-to-end version cross-check in §5.2: every encrypted envelope carries the
sender's view of both list versions *inside the plaintext*, so any message from any honest device
exposes the freeze to the frozen peer. S must then also block those messages entirely — degrading
to denial of service, which S can always do anyway.

**Non-negotiable invariants** (each gets a red-first test, §10):

- **I1** — The server NEVER holds a private key: not IK, not DAK, not per-device keys. Provisioning
  transports IK device-to-device encrypted under a human-verified DH secret; the server relays
  opaque bytes. An ABORTED provisioning obliges the new device to DISCARD IK and every minted key
  (§5.1) — a failed link leaves no keyed residue anywhere.
- **I2** — Every device-list mutation carries a signature by the account's **DAK**, whose private
  half exists ONLY on the current primary, in platform Keystore. The shared identity key is NEVER a
  device-list signing authority (a linked PWA holds IK in web storage; one XSS must not mint
  devices). Primary handover ROTATES the DAK (§6.3); the private half never leaves its origin
  device, and a demoted primary's DAK has no remaining authority.
- **I3** — Linking requires possession: QR scan + DH-bound SAS confirmation + explicit approve on
  the primary, AND a valid password login on the new device. Neither alone suffices. No
  password-only fallback, ever. No secret leaves the primary before the SAS is human-confirmed.
- **I4** — Identity/DAK *reset* (all devices lost) is credential-gated, slow and loud: fixed delay,
  rate-limited, every live session AND every push endpoint notified before it takes effect; cancel
  wins any race with expiry (§6.2). The recovery key (§6.2.1) shortens the delay but is NEVER
  silent: same notifications, non-zero cancel window, slow-hashed, single-use, rate-limited.
- **I5** — Fail-closed inheritance: every existing UNKNOWN-is-not-absence rule survives per-device
  (the 0.1.10 guard's tri-state, reconcile's null-answer-purges-nothing, ledger fail-open rules).
  A device-list fetch failure means "cannot send", never "send to fewer devices".
- **I6** — A revoked device stops receiving new envelopes at revocation commit, atomically with the
  signed list mutation. Its local history remains its own; **the server answers a revoked device's
  `getServedMessageIds` with SILENCE** (a missing reply purges nothing — never an empty/partial
  answer, which would read as "destroy all"). Verified consequence: the revoked device's expiry
  sweep also fails closed forever (no fresh server clock) — over-retention on a device the user
  chose to cut off, consistent with the root §7 asymmetry. Re-linking the same physical device
  under a new deviceId is safe: the local content store keys by `(uid, msgId)`, not deviceId, and
  reconcile stays per-user (I8).
- **I7** — Peers verify the device list against the IK→DAK chain, monotonic version, AND the
  end-to-end version cross-check of §5.2; the server is untrusted for list content and freshness.
  Rollback, invalid chain, or an INDEPENDENTLY VERIFIED cross-check staleness = loud
  identity-changed surface. An unverifiable peer claim alone NEVER alarms (§5.2).
- **I8** — The reconcile contract is UNTOUCHED: "served" remains row-existence + participant based
  (per user, metadata-blind — `messages.service.ts:194-243`), independent of the envelope
  dimension. Envelopes gate realtime routing and per-device delivery stamps ONLY, never reconcile,
  never history visibility of an existing row.
- **I9** — Read-based disappearing TTL starts ONLY on the recipient user's `markConversationRead`
  over the PEER's rows (today's `markConversationAsReadFromSender` semantics). It NEVER starts from
  envelope `deliveredAt`/`readAt`, and NEVER from the sender's own device reading its self-sync
  copy. The delivery projection is decoupled from expiry by construction (§4).

## 3. Keys

| Key | Curve/API | Custody | Lifetime |
|---|---|---|---|
| **IK** — account identity | Curve25519 (existing) | every device's secure storage (Keystore on Android; sealed web KV on a linked PWA) | account lifetime; reset only via §6.2 |
| **DAK** — device authorization | Curve25519 via `Curve.generateKeyPair()`; sign/verify via `Curve.calculateSignature/verifySignature` (XEdDSA, 64B, source-verified in `libsignal_protocol_dart` 0.8.2 `src/ecc/curve.dart`) | **current primary only**, `flutter_secure_storage` (Keystore). Never provisioned, never uploaded, never derived from IK, never copied — handover = rotation (§6.3) | until rotation (§6.3) or reset (§6.2) |
| per-device `registrationId`, signed prekey (id 0), OTPs 0..N | existing | that device only | per device |

**Enrollment record** (created on the primary when multi-device is first enabled):
`E = { userId, dakPub, createdAt, sig_IK(userId ‖ dakPub ‖ createdAt) }`.
Server pins `E` first-write-wins; replacing a DAK requires `sig_oldDAK(userId ‖ newDakPub ‖
createdAt')` (rotation §6.3) or reset (§6.2). Peers cache `(dakPub, listVersion)` per contact;
verification chain is *their TOFU'd IK → E → DAK → list*.

**Signed device list**: canonical bytes of
`{ userId, version (monotonic int), devices: [{deviceId, name?, platform, addedAt, revokedAt?}] }`,
signature by DAK over the canonical serialization. **Canonical-form constraints (enforced at sign
time AND re-validated at parse time):** JSON with sorted keys, no whitespace, userId and version
first; duplicate keys REJECTED; `version`/timestamps integer-only; `name` NFC-normalized,
length-capped, control-characters rejected. `listHash = SHA-256(canonical)`.
**Transport rule:** `listCanonical` travels and is stored as OPAQUE BASE64 BYTES everywhere
(`deviceListStale`, `getDeviceList`, DB column) — never a nested JSON object a transport layer
could re-serialize; hash and signature are always computed over the decoded bytes verbatim.
(Round-2 security finding 4, folded.) `name` is user-chosen, server-readable metadata — said
plainly in UI.

Library caveats honored: `calculateVrfSignature` is stubbed — never referenced; `sign`/`verifySig`
mutate passed buffers — always pass copies of retained key/signature buffers.

## 4. Data model (backend)

New/changed tables (numbered migrations, staging rehearsal mandatory — root `CLAUDE.md` §6):

- **`devices`**: `(userId, deviceId)` PK, `name`, `platform`, `isPrimary`, `addedAt`, `revokedAt`.
  `deviceId` per-account small int from 1 (existing accounts = device 1 implicitly, §8). No
  `lastSeenAt`: dropped by migration 0019 (metadata privacy step 0, 2026-09-20) — the server keeps
  no per-device "last online" clock; `ensureRow` creates device 1's row on first connect and
  otherwise writes nothing.
- **`account_authorizations`**: `userId` PK, `dakPub`, `enrollmentSig`, `listVersion`,
  `listSignature`, `listCanonical` (opaque bytes, §3), `updatedAt`.
- **`key_bundles`**: UNIQUE becomes `(userId, deviceId)`. The **identity-epoch invariant is
  re-keyed** at all three sites (`key-bundles.service.ts:60-189`): partition dimension becomes
  `(identityPublicKey, deviceId)` — purge/claim/count operate strictly within one device's
  namespace. Under shared IK the identity half only changes on reset.
- **`one_time_pre_keys`**: unique `(userId, deviceId, keyId)`; epoch tag unchanged in meaning.
- **`message_envelopes`**: `id`, `messageId` FK CASCADE, `recipientUserId`, `recipientDeviceId`,
  `ciphertext`, `deliveredAt?`, `readAt?`, `createdAt`. Envelopes are **retained**, not
  mailbox-deleted — they live exactly as long as the message row (expiry cron, delete-for-*,
  clear-history cascade). Storage ×N accepted at cap 3.
- **`messages`**: keeps metadata; gains `originDeviceId` and `sendToken` (client-generated UUID,
  §5.4; **UNIQUE per (senderId) — server rejects a duplicate token as a duplicate send**, round-2
  data-loss finding 1). Single `deliveryStatus` stays as a **projection over RECIPIENT envelopes
  ONLY** (`recipientUserId != senderId` — self-sync envelopes NEVER count, or the sender's own
  second device would fake a read receipt; round-2 coherence finding 3): delivered = first
  recipient envelope delivered; read = any recipient envelope read. The projection is written ONLY
  as a column-scoped UPDATE of `deliveryStatus`, NEVER a full-entity save — **the existing
  `MessagesService.updateDeliveryStatus` full-entity `save()` (`messages.service.ts:319-320`) is a
  named conversion target**; the mark-read path (`:568-570`) already uses a scoped update (round-2
  coherence finding 5). Legacy `encryptedContent` retained for pre-migration rows ONLY —
  legacy-client sends are converted to a device-1 envelope at ingest (§8), so new-model rows have
  exactly one storage shape; new multi-device sends write envelopes only.
- **`refresh_tokens`**: + `deviceId`, `deviceName` — the per-device session anchor; per-device
  revoke = delete that device's rows + kick its sockets. JWT payload gains `deviceId`.
- **`fcm_tokens`** / **`web_push_subscriptions`**: + `deviceId` → per-device push targeting and
  suppression.

## 5. Protocols

### 5.1 Provisioning (linking) ceremony — two-round, DH-bound SAS, secrets last

The v3 single-shot SAS (`KDF(ephPubN ‖ provisioningId)`) was cryptographically unsound: one-party
public input, ~20-bit human comparison → offline-grindable collision (Vaudenay/ZRTP literature;
confirmed independently by round-2 security review). v4 replaces it with a two-round DH-bound
ceremony. Soundness argument: the QR is an out-of-band channel for `ephPubN` (physical scan), and
the SAS is derived from the ECDH secret — an attacker substituting either ephemeral on the relayed
leg cannot COMPUTE the honest side's SAS target (it needs a private key it doesn't have), so a
short SAS cannot be ground against, and no commitment round is required. No secret leaves the
primary before the human confirms.

```mermaid
sequenceDiagram
    participant N as New device (logged in, deviceId pending)
    participant S as Server (blind relay)
    participant P as Primary (holds DAK)
    N->>N: ephemeral pair ephN
    N->>S: openProvisioning → {provisioningId (UUID, 10 min TTL)}
    N->>N: show QR {provisioningId, ephPubN}
    P->>N: user scans QR (out-of-band ephPubN)
    P->>P: ephemeral pair ephP; S_dh = DH(ephPrivP, ephPubN); SAS = HKDF(S_dh, info="fp-link-sas", provisioningId ‖ ephPubN ‖ ephPubP)
    P->>S: provisioningHello {provisioningId, ephPubP}   — NO secrets
    S->>N: provisioningHello relay
    N->>N: S_dh = DH(ephPrivN, ephPubP); display SAS (same derivation)
    Note over N,P: HUMAN compares SAS on both screens; P user approves
    P->>S: provisionDevice {provisioningId, blob = AEAD under HKDF(S_dh, info="fp-link-blob") of {IK pair, dakPub, E, assigned deviceId}, stagedMutation = {list v+1 adding deviceId, sig_DAK}}
    S->>S: verify sig_DAK vs pinned dakPub; verify v+1; STAGE mutation (not committed)
    S->>N: provisioningBlob {blob}
    N->>N: decrypt under HKDF(S_dh, info="fp-link-blob"); store IK; mint registrationId/signedPreKey/OTPs
    N->>S: provisioningComplete {provisioningId} + per-device bundle upload (tagged deviceId) — accepted ONLY from N's originating authenticated session
    S->>S: ONE transaction: commit staged mutation + devices row + activate deviceId + bundle
    S-->>P: deviceListChanged (all own sessions; peers pick it up via §5.2)
```

Rules:
- **Secrets last (I3):** the IK-bearing blob exists only AFTER the human SAS confirmation, and it
  is encrypted under the SAS-verified DH secret itself (HKDF → AEAD, using the lib's
  `calculateAgreement` + `HKDFv3` + AES-CBC/HMAC primitives — the stock `ProvisioningCipher`
  generates its own internal ephemeral, which would bypass the verified secret, so the explicit
  construction is REQUIRED).
- **Two-phase commit:** mutation STAGED at `provisionDevice`, committed only on
  `provisioningComplete`. Until completion the blob may be re-fetched against the same
  `provisioningId`; TTL expiry or a primary-side cancel discards the stage.
  `provisioningComplete` is bound to the SAME authenticated socket session that called
  `openProvisioning` — knowledge of `provisioningId` alone drives nothing (round-2 security
  finding 6).
- **Revoke preempts linking:** a `revokeDevice` mutation AUTO-CANCELS any pending stage and takes
  the version slot — a security action never waits on a stuck link. Cancel is primary-only.
- **Abort hygiene (I1, round-2 data-loss finding 2):** on TTL expiry, cancel, or
  `provisioningComplete` failure, N MUST discard IK, all minted key material, and the assigned
  deviceId — a failed link leaves N exactly as unkeyed as before it started. The server likewise
  rejects any bundle upload tagged with a never-activated deviceId.
- Concurrent link attempts: two staged mutations both at `v+1` — the second commit loses on the
  version check; primary re-signs at `v+2` and re-submits (bounded retry, then surfaced failure).
- Both ceremony sides are new clients by definition; no legacy compat needed here.

### 5.2 Send fan-out and device-list freshness (Sesame §3.3 + E2E cross-check)

Client send: `sendMessage { conversationId, meta…, senderListVersion, recipientListVersion,
sendToken, envelopes: [{userId, deviceId, ciphertext}] }` — one ciphertext per *(recipient
device)* plus one per *(sender's other devices)* (self-sync), each from its own pairwise session
(`SignalProtocolAddress(userIdStr, deviceId)` — free int, lib-verified).

Freshness is checked at TWO layers:
1. **Server-side (liveness):** stale stamps → reject `deviceListStale { userId, version,
   listCanonical (base64), listSignature, enrollment }`; client verifies the signature chain (I7),
   updates its cache, re-encrypts, resends. Retry cap 3, then a surfaced send failure — never
   silently dropping devices (I5).
2. **End-to-end (trust):** the E2E plaintext envelope gains
   `senderListInfo: {ownVersion, ownListHash, peerVersion, peerListHash}` — the sender's view of
   BOTH lists at encrypt time. Escalation discipline (round-2 security finding 3 — the field is
   attacker-controlled plaintext):
   - Sender's view OLDER than recipient's own current list → candidate freeze signal: recipient
     re-fetches its own signed list; the alarm renders ONLY after the recipient independently
     confirms the discrepancy against DAK-signed data. A bare peer claim NEVER alarms (I7).
   - Sender CLAIMS NEWER than the recipient knows → unverifiable: triggers one rate-limited
     re-fetch; if the server confirms the recipient is current, the claim is DISCARDED as noise.
     Never a standalone alarm — a lying peer gets one bounded fetch, not an alarm oracle.
   - **Self-sync envelopes** (peer == self): both halves reference the same account list; a
     legitimate link/revoke race puts own devices briefly at different versions. Bounded own-list
     skew renders as a benign "syncing devices…" state, NEVER the identity-changed surface
     (round-2 security finding 5).
   - Older clients ignore the extra field (root `CLAUDE.md` §7 envelope-compat convention).

Version match → one message row + N envelope rows in ONE transaction, then per-device delivery
(§5.3). Sessions to a newly-seen deviceId are built lazily via `fetchPreKeyBundle {userId,
deviceId}` (per-device OTP claim; `preKeysLow {remaining}` becomes per-device, routed to that
device).

### 5.3 Realtime delivery, rooms, push, history reads

- Socket auth carries `deviceId` (JWT claim); socket joins `user:<uid>` (metadata: reactions,
  delivery, list changes, deletes) **and** `device:<uid>:<did>` (ciphertext: `newMessage`,
  `messageEdited` — each device gets *its* envelope).
- `emitToNewestTab` survives, demoted to *within one web device*: tabs of a linked PWA share one
  session store, so ciphertext to a device room targets that device's newest socket (renamed
  `emitToDeviceNewestSocket`; its documented removal condition is unchanged, now per-device).
- **Per-device history read (round-2 coherence finding 2):** `getMessages`/`findByConversation`
  joins `message_envelopes` on the REQUESTING `(userId, deviceId)` and serves that device ITS
  ciphertext. Fallback order per row is DEVICE-GATED (round-3 termination finding 1 — legacy
  ciphertext is bound to the ORIGINAL device's ratchet, so serving it to any other device yields a
  terminal `[Decryption failed]` across the entire pre-link history):
  1. this device's envelope;
  2. legacy `encryptedContent` (pre-migration rows only, §4) — served ONLY to the row's session
     owner: `deviceId == 1`, or `deviceId == originDeviceId` for own rows (backfilled rows carry
     `originDeviceId` NULL = device 1). **Load-bearing invariant: deviceIds are monotonic per
     account and NEVER reused, including across a §6.2 reset** — device 1 permanently names the
     account's original device; a reused id would resurrect the foreign-ratchet decrypt this gate
     exists to prevent;
  3. every other device falls through to the explicit `envelopeStatus: "none_for_device"` marker
     (the row predates this device's link). The marker is the discriminator that lets the client
     render the honest "sent before this device was linked" placeholder instead of
     `[Decryption failed]` or a stuck "Decrypting…" (round-2 data-loss finding 4).
- Push suppression: skip push only for the device whose own socket has the conversation focused.
  Envelope `deliveredAt`/`readAt` stamped per device; wire keeps the projected single
  `deliveryStatus` (recipient-envelopes-only projection, §4).

### 5.4 Self-sync, lost-ack, and the reconcile — coexistence rules (the danger zone)

Own-sent messages: device B receives an envelope with `senderId == me` and
`originDeviceId != myDeviceId` — decrypted like any inbound message (pairwise session between own
devices), persisted normally.

**Every own-sender guard that switches from `senderId == me` to `originDeviceId == myDeviceId`**
(round-2 coherence finding 4 — fixing only one leaves self-sync dead): the live-path queue guard
(`messaging_provider.decrypt.dart:962-963`), the decrypt guard (`:975`), the third guard
(`:1290`), and the history own-message branches (`history.dart:529`, `decrypt.dart:642`). The
Phase-2 implementation checklist enumerates all five; missing one is a red falsification-6 run.

**Rules, each with a falsification test (§10):**
- **Reconcile untouched (I8).** `getServedMessageIds` stays per-user, row-existence based. The
  origin device is served for its own rows like today. A device linked AFTER a message existed
  sees the row via the `none_for_device` marker (§5.3) — an honest placeholder, NEVER a
  destruction trigger, never `[Decryption failed]`, never retired. (Round-2 data-loss review
  verified: no path through the ledger gate, terminal-duplicate retirement, or reconcile can
  destroy on this marker — there is no ciphertext and no stored plaintext to act on.)
- **Lost-ack keyed by `sendToken`, with uniqueness law (round-2 data-loss finding 1 — the token
  guards the ONLY plaintext copy):** client mints a UUID per send; server enforces per-sender
  uniqueness (duplicate token = duplicate send, rejected); the own-message reconcile branch
  matches on `(senderId, originDeviceId, sendToken)` and MUST resolve to EXACTLY ONE row — an
  ambiguous match is a no-op that NEVER consumes the pending record. Retry of the SAME send
  (same pending record, same ciphertexts) reuses its token — same row either way. An EDIT mints
  new ciphertexts but is a mutation of an already-acked row and never touches pending-send.
  Exact-ciphertext equality remains the legacy fallback for pre-migration records.
- A self-sync row must NEVER consume a pending-send record (origin-device scoping).
- The `messageSent` ack goes only to the origin device; other own devices get envelopes.
- Own-device sessions run through the same `_sessionTails` serialization, keyed
  `(peerId, deviceId)` — own devices are just another peer address to the ratchet layer.

### 5.5 Revocation

Primary-only action (DAK-signed mutation, `revokedAt` set, version+1, one transaction; preempts
any pending provisioning stage — §5.1):
- server stops routing envelopes to the device, deletes its refresh tokens + push rows, kicks its
  sockets; its still-valid access JWT gets SILENCE from `getServedMessageIds` (I6) and rejection
  from mutating handlers until natural expiry;
- peers drop the device from fan-out on the next staleness bounce (worst case one rejected send),
  and the §5.2 cross-check exposes any server attempt to keep serving the pre-revocation list;
- the revoked device's local data is NOT remotely wiped (logout semantics; non-goal, stated in UI);
- the revoked device's OTPs are purged (only that device could complete those handshakes; it is no
  longer served envelopes).

### 5.6 Disappearing messages — deliberate ruling

Row-level expiry is RETAINED: the read-based TTL starts ONLY per invariant **I9** — the recipient
user's `markConversationRead` over the PEER's rows, exactly today's
`markConversationAsReadFromSender` semantics. It never starts from envelope stamps and never from
the sender's own device reading its self-sync copy (round-2 data-loss finding 3). At the deadline
the row + ALL envelopes are destroyed — including an envelope a linked device never fetched.
**Disappear means disappear, on every device, at one deadline.** Per-envelope expiry was
considered and rejected: it would keep "disappeared" content alive on idle devices past the
deadline. Consequence, stated honestly in docs and UI: a linked device offline past the deadline
never shows that message (same behavior as Signal). Falsification 11 asserts no error artifact is
produced; client-side destruction rules (server-clock gating, root §7) are unchanged and
per-device.

### 5.7 Edit under envelopes (round-2 coherence finding 1)

Editing is sender-only, any of the sender's devices (they all hold the plaintext via self-sync),
within the existing 15-minute window checked server-side against the row. The inbound wire becomes
`editMessage { messageId, envelopes: [{userId, deviceId, ciphertext}] }` — a full re-fan: one new
ciphertext per recipient device AND per sender's other devices. The server verifies sender + window
 + device-list coverage (same staleness bounce as §5.2), then writes each device's edited
 ciphertext in one transaction — **UPSERT semantics** (round-3 termination finding 2): an existing
 `message_envelopes` row is replaced **content-only — `deliveredAt`/`readAt` stamps SURVIVE the
 replacement** (an edit is not an un-delivery; the §4 projection must never regress on edit); a
 recipient device that linked AFTER the original send (and therefore had no row,
 `none_for_device`) gets a row INSERTED and renders the edited message with its edited marker —
 the sender's client deliberately encrypted to the CURRENT device list, so the edit is delivered
 like any current send; the placeholder upgrades, never the reverse. Legacy
 `encryptedContent` is updated too while mixed-model rows exist. The server stamps `editedAt` and
 fans each device its own edited envelope via `messageEdited`. Reject paths
(`editMessageFailed`) unchanged. An edit never mints or consumes a `sendToken` (§5.4).

## 6. Registration lock and reset (Phase 0, ships before any device work)

### 6.0 Phase 0a — takeover alarm (days, no protocol change)
Promote the existing `[identity-churn]` branch (`key-bundles.service.ts:46-53`) to: durable
server-side audit row; WS + push notice to the account's other sessions/endpoints ("your security
identity was replaced from a new sign-in"); peer-visible flag corroborating the client's
`PEER_IDENTITY_CHANGED` state; **in-conversation timeline row on peer clients** (owner-ratified
2026-08-17, explicitly superseding the 2026-08-15 banner-removal ruling for this narrower
event-driven row). Wording follows the 08-16 consented-recovery framing.

### 6.1 Single-device registration lock (pre-multi-device)
`upsertKeyBundle` with a DIFFERENT `identityPublicKey` than stored requires
`sig_oldIK(newIdentityPublicKey ‖ userId ‖ serverNonce)`. Same-identity re-uploads (today's
every-connect re-upload) pass unchanged. Genuine loss → §6.2.
**Nonce spec:** CSPRNG-generated (unpredictable, never counter/timestamp), single-use, TTL ≤ 5 min,
bound to the issuing authenticated socket session. Scope honesty: defends against **P** under an
HONEST server; a colluding **S** can issue chosen nonces — that threat is handled by the peer-side
chain (I7), not by §6.1.

### 6.2 Reset ceremony (all devices / identity lost)
Credential login → `resetIdentityRequest` → server starts a **72 h** timer, immediately notifying
every live session AND every registered push endpoint (FCM + Web Push; this app has no email —
push is the only offline channel, which is WHY the delay is 72 h and not 24). Any session can
CANCEL with one tap (no key required). Peers' conversations are marked pending-reset.
Hardening:
- **Rate limit**: one pending request per account; a new request while one is pending is a no-op
  returning the existing deadline; after a cancel, cooldown 24 h before the next request.
- **Cancel/expiry serialization**: expiry-commit runs in one transaction that re-checks
  not-cancelled; states are terminal (`completed` / `cancelled`) — a late cancel after commit is a
  no-op, never an identity rollback; a cancel that wins the race aborts the commit.
On expiry the server accepts a fresh IK + fresh enrollment; peers get the loud identity-changed
surface.

#### 6.2.1 Recovery key (owner-ratified for 0b; spec per round-2 security finding 2)
Generated client-side on demand: **12-word BIP39-style phrase from ≥128 bits CSPRNG**, shown once,
never stored on-device or transmitted except as a verifier. Server stores an **Argon2id** hash
(memory-hard parameters pinned at implementation; NEVER a fast hash — a DB dump must not make the
phrase brute-forceable). Semantics:
- **Shortens, never silences:** presenting the phrase reduces the reset delay from 72 h to a
  **1 h cancel window** with the SAME notifications to every session and push endpoint (I4). There
  is no zero-delay path — a stolen phrase still rings every bell and leaves an hour to cancel.
- **Single-use:** invalidated on use AND on any completed reset; a new phrase must be generated
  afterward.
- **Online guessing bounded:** attempts rate-limited with lockout/cooldown per account.
- Users without a phrase: exactly the 72 h path, unchanged.

### 6.3 Primary migration (planned handover) — ROTATION, never copy
New primary candidate generates a fresh **DAK′** in its own Keystore; old primary signs the
replacement enrollment `E′ = sig_oldDAK(userId ‖ dakPub′ ‖ createdAt′)` after the same QR + SAS
ceremony as §5.1; server pins `E′`; peers re-pin on next fetch via the E→E′ chain (old DAK
authority dies at that instant); a DAK′-signed mutation flips `isPrimary`. The DAK private half
never leaves the device that minted it, ever. Old primary lost → reset §6.2 (the DAK is gone —
that is the designed outcome).

## 7. Wire-contract deltas (root `CLAUDE.md` §7 — every line re-ratified at Phase 2 review)

| Surface | Today | After |
|---|---|---|
| `sendMessage` | one `encryptedContent` | `envelopes[]` + `sendToken` (unique per sender) + two list-version stamps; reject path `deviceListStale` (listCanonical as base64) |
| `editMessage` | one new `encryptedContent` | `envelopes[]` full re-fan; per-device envelope-row replacement; window/sender checks unchanged (§5.7) |
| E2E plaintext envelope | `{content, messageType?, media…}` | + `senderListInfo {ownVersion, ownListHash, peerVersion, peerListHash}` (older clients ignore; escalation discipline §5.2) |
| `newMessage` / `messageEdited` | newest tab of user | device room, newest socket within device; payload + `originDeviceId` |
| `getMessages` history rows | `encryptedContent` echo | requesting device's envelope ciphertext → legacy fallback GATED to the session-owner device → `envelopeStatus: "none_for_device"` marker (§5.3); own rows + `originDeviceId`, `sendToken` |
| `uploadKeyBundle` / `fetchPreKeyBundle` / `uploadOneTimePreKeys` / `preKeysLow` / `checkOwnKeyBundle` | per user | per `(user, device)`; bundle mutation rules of §6.1; uploads for never-activated deviceIds rejected (§5.1) |
| `messageDelivered` / read events | per message | unchanged shape; server projects from RECIPIENT envelopes only, column-scoped UPDATE (§4) |
| `getServedMessageIds` | per user, row-existence | **UNCHANGED (I8)**; SILENCE to revoked devices (I6) |
| NEW | — | `openProvisioning`, `provisioningHello`, `provisionDevice`, `provisioningBlob`, `provisioningComplete` (session-bound), `deviceListChanged`, `getDeviceList`, `revokeDevice` (preempts stages), `resetIdentityRequest/Cancel` |
| `socketReady`, `getServerTime`, delete/clear/unfriend, reactions | per user | unchanged (delete fan-out cascades envelopes) |

## 8. Compatibility and rollout

- Existing accounts become `devices(userId, 1, isPrimary=true)` implicitly (migration backfill). No
  DAK until the user enables linking; until then the account is UN-ENROLLED and the §6.1 lock is
  NOT armed — a wiped device re-mints (amendment (lxxiii)). Enabling linking arms §6.1/§6.2.
- **Any platform may be primary** (rewritten by (lxxiv); the original "Keystore-capable only" rule
  never matched the code). The DAK's custody is the same as the IK's on that platform: Android
  Keystore, or the sealed `sig_` KV on web — I2's "Keystore" names the custody intent, not a
  platform gate. A web primary is asked to INSTALL the PWA before enabling linking (eviction, not
  theft, is its exposure); a browser tab sees the install instruction instead of the button.
  "QR as login without password" is out of scope by I3: the QR is a link step, never a credential.
- **Reconcile safety across the mixed model (I8):** "served" is row-existence based for every row
  shape — pre-migration rows, legacy-client sends (stored as a device-1 envelope), and new
  envelope-only rows reconcile identically. No first-launch mass-purge shape exists by
  construction; falsification 13 pins it.
- Legacy client → new server: single-ciphertext sends accepted, stored as a device-1 envelope.
  Window kept small by rollout ORDER: server first (accepts both), clients next (send envelopes),
  linking UI enabled LAST, gated on min-client-version per account.
- New client → old server: capability-probed (no `getDeviceList` answer = legacy server); client
  stays single-device, fail-closed.
- **Phase-1 migration transactionality (round-2 data-loss finding 5):** the schema+backfill
  migration runs as ONE Postgres transaction with PLAIN (non-CONCURRENTLY) index creation — the
  runner's abort-on-boot then guarantees clean rollback and idempotent re-run; table sizes here do
  not justify `CONCURRENTLY`'s non-transactional risk (an INVALID index blocking bundle upserts =
  key-delivery outage).
- e2e-wire harness grows the two-devices-one-account suite BEFORE Phase 1 merges (§10). Staging
  dress rehearsal for every schema phase (root §6).

## 9. Phase plan (each phase independently shippable, reviewed, and behind the previous)

| Phase | Content | Ships value alone? | Acceptance |
|---|---|---|---|
| **0a** | churn alarm: audit row + session/push notify + peer timeline row | YES — takeover detection | live-fire: bundle replace on a test account alerts second session + peer within 5 s |
| **0b** | registration lock §6.1 + reset ceremony §6.2 + recovery key §6.2.1 | YES — takeover prevention | red-first: password-only bundle replace rejected; reset honors 72 h/rate limit/serialization; recovery path slow-hashed, single-use, still-loud (falsification 21) |
| **1** | schema: `devices`, `(userId,deviceId)` bundles/OTPs, re-keyed 3-site epoch, JWT `deviceId`, refresh/push device columns, `originDeviceId`+`sendToken` (unique); single-transaction migration | invisible; unblocks all | full suites + wire harness green single-device; falsifications 1, 13 |
| **2** | provisioning §5.1, DAK + signed list + cross-check §5.2, envelopes + history reads §5.3, self-sync §5.4, revocation §5.5, edit re-fan §5.7 | the feature | two-device harness: link → both receive → self-sync → edit re-fan → revoke → stale bounce; ALL §10 falsifications green; own Phase-2 spec review first |
| **3** | device management UI (list, rename, revoke, last-seen), migration comms | usability | device-proven on owner's hardware |
| **4** | history-on-link via sealed-store archive (own design doc) | optional | — |

## 10. Falsification test plan (fail-before, then fix — repo tradition)

1. Two devices upload OTPs keyId 0..99 → OLD schema: device B overwrites device A's rows; peer
   draws A's slot → bad MAC (red). New schema: no collision (green).
2. Device-list mutation signed by **IK** (not DAK) → server rejects; peer client rejects.
3. Unsigned / wrong-version / replayed mutation → rejected; version rollback at a peer → loud flag.
4. `deviceListStale` answer with an INVALID signature chain → client refuses the list and fails the
   send (I7 — never the server's bare word).
5. Send addressed to a stale list → rejected atomically; zero envelopes written.
6. Self-sync: EVERY own-sender guard (`decrypt.dart:962, :975, :1290`, `history.dart:529`,
   `decrypt.dart:642`) switched to origin-device scoping — a self-sync row decrypts AND must not
   consume a pending-send record; red if any single guard is missed.
7. Concurrent send + revoke: revoked device receives no envelope for a message committed after the
   revocation transaction.
8. Provisioning blob replayed to a different ephemeral key → undecryptable; expired TTL → rejected;
   `provisioningComplete` one-shot AND rejected from any session other than the opener's.
9. Fail-closed inheritance: device-list fetch timeout on send → send FAILS; per-device
   `checkOwnKeyBundle` UNKNOWN → no key generation (0.1.10 invariant).
10. Reset: cancel halts; cancel racing expiry-commit serialized (terminal states); repeated
    requests rate-limited; peers never see identity-changed on a cancelled reset.
11. Expiry: at deadline row + ALL envelopes destroyed; a device that never fetched its envelope
    shows NO error artifact (row absent, §5.6); devices that decrypted destroy plaintext per
    existing clock rules.
12. Per-device epoch: post-reset, all three re-keyed sites purge/claim/count strictly within
    `(identity, deviceId)`.
13. **Reconcile mass-purge guard (I8):** origin device's own new-model sends, pre-migration rows,
    and legacy-client rows ALL reconcile as served; a revoked device's reconcile gets SILENCE and
    purges nothing; a `none_for_device` row is never a destruction trigger; **a linked non-owner
    device on a legacy row gets the marker, never the legacy ciphertext — it must NOT attempt (and
    terminally fail) a foreign-session decrypt; the session OWNER is positively served and
    decrypts its legacy row; after revoke/re-link leaves the account with no device 1, EVERY
    device gets the marker** (round-3 finding 1/4 + micro-check).
14. **Lost-ack via `sendToken`:** drop the ack → recovery by token match, read-back verified.
    COLLISION case: a duplicate token is rejected server-side; an artificially ambiguous match is
    a no-op that does NOT consume the pending record (round-2 data-loss finding 1).
15. **SAS grinding (rewritten):** an adversary substituting an ephemeral on the relayed leg cannot
    produce a COLLIDING SAS — the test derives both honest SAS values and asserts the adversary,
    holding only public transcript values plus its own private keys, cannot compute either target
    (DH-bound SAS; not the v3 naive-swap test).
16. **Split-view/freeze:** server serves peer A a frozen validly-signed old list (v3) after B
    revoked a device (v5) → first message from any of B's devices exposes v5 via `senderListInfo`;
    A re-fetches, independently confirms, alarms. Red without the E2E cross-check.
17. **DAK rotation:** after §6.3 handover, a mutation signed by the OLD DAK → rejected by server
    AND peers.
18. **Two-phase provisioning:** kill N between blob and `provisioningComplete` → no device row, no
    list mutation, blob re-fetchable until TTL; AND **N discards IK + minted keys + deviceId on
    abort** — post-abort N's keystore is empty and its bundle upload is rejected (I1).
19. **Projection safety:** delivery projection changes ONLY `deliveryStatus` via scoped UPDATE
    (incl. the converted `updateDeliveryStatus`); `expiresAt`/`disappearAfterSeconds`
    byte-identical; **self-sync envelopes never flip the projection** (a sender's second device
    reading its copy produces no DELIVERED/READ receipt); **read-TTL never starts from envelope
    stamps or self-sync reads (I9)**.
20. **Concurrent double-link:** two staged mutations at v+1 → second rejected; primary re-signs at
    v+2; exactly one device added per ceremony. Revoke PREEMPTS a pending stage.
21. **Recovery key:** verifier is Argon2id (fast-hash red test); phrase single-use; attempts
    rate-limited; the shortened path still notifies every session + push endpoint and honors the
    1 h cancel window.
22. **False-alarm discipline:** a malicious peer sending bogus `senderListInfo` (older AND newer
    claims) produces at most one rate-limited re-fetch and NO alarm when the server's signed list
    confirms the recipient is current; own-device bounded skew renders "syncing devices", never
    identity-changed.
23. **Canonical bytes:** `listCanonical` survives transport byte-exact (re-serialization must not
    change `listHash`); duplicate-key / ambiguous canonical bytes rejected at parse.
24. **Edit re-fan (§5.7):** an edit UPSERTs EVERY current device's envelope in one transaction; a
    device offline during the edit receives the edited ciphertext on next history read; **a device
    that linked AFTER the original send gets an INSERTED envelope and upgrades its placeholder to
    the edited message; replacing an already-delivered/read envelope preserves its
    `deliveredAt`/`readAt` stamps — the projection never regresses on edit** (round-3 finding 2/4
    + micro-check); edit from a non-origin own device succeeds;
    `editMessageFailed` paths unchanged; no `sendToken` minted.

## 11. Open questions (owner) — ALL RATIFIED 2026-08-17

1. In-conversation identity-changed timeline row — **YES** (supersedes the 2026-08-15
   banner-removal ruling for this narrower event-driven row; 0a ships it).
2. Recovery key — **YES, in 0b** (spec §6.2.1).
3. Device cap 3 — **CONFIRMED.**
4. Reset delay 72 h — **CONFIRMED.**
5. iOS-PWA users cannot be primaries until an iOS app exists — **CONFIRMED.**
6. Disappear-at-one-deadline (§5.6) — **CONFIRMED.**

## 12. Review record

- **Round 1 (2026-08-17, on v2):**
  - Data-loss review (reviewer subagent): REVISE — 6 findings folded into v3 (I8 origin, SILENCE
    rule, sendToken concept, column-scoped projection, §5.6 ruling, mixed-model reconcile).
  - Security review (reviewer subagent; first spawn refused by a content filter, re-dispatched
    defensively framed): SHIP-WITH-FIXES — 6 findings folded into v3 (SAS concept, E2E list
    cross-check, DAK rotation, two-phase commit, reset hardening, nonce spec).
- **Round 2 (2026-08-17, on v3 — three fresh reviewers + independent SAS literature check):**
  - Coherence + feasibility review: REVISE — 5 findings, all folded into v4: edit-under-envelopes
    was unspecified (§5.7 + falsification 24); per-device history read path missing (§5.3 +
    `none_for_device` marker); projection counted self-sync envelopes → false read receipts
    (recipient-only rule, §4); only 1 of 5 own-sender guards named (§5.4 enumeration +
    falsification 6); existing `updateDeliveryStatus` full-entity save named as conversion target.
    Also re-verified v3's code claims against source — all accurate.
  - Security review: SHIP-WITH-FIXES leaning REVISE — 6 findings, all folded: **v3's SAS was
    offline-grindable** (single-party public input; independently confirmed against
    Vaudenay/ZRTP literature) → two-round DH-bound SAS with secrets-last ordering (§5.1 +
    falsification 15 rewritten); recovery key was adopted but unspecified → §6.2.1 (Argon2id,
    single-use, still-loud, 1 h window; falsification 21); `senderListInfo` false-alarm/claims-
    newer discipline (§5.2 + falsification 22); `listCanonical` byte-exact transport + canonical
    constraints (§3 + falsification 23); self-sync listInfo skew (§5.2); revoke-preempts-stage +
    session-bound `provisioningComplete` (§5.1/§5.5 + falsifications 8, 20).
  - Data-loss review (first spawn failed before emitting; re-run): SHIP-WITH-FIXES — 5 findings,
    all folded: sendToken uniqueness/ambiguity law (P1 — sole-plaintext-copy misbinding; §4/§5.4 +
    falsification 14); abort-discard of IK on failed provisioning (I1/§5.1 + falsification 18);
    I9 read-TTL start conditions (§5.6 + falsification 19); `none_for_device` discriminator
    (§5.3); Phase-1 single-transaction migration, no `CONCURRENTLY` (§8). Verified clean: SILENCE
    fail-closed semantics; re-link of same physical device.
- **Round 3 (2026-08-17, on v4 — delta-scoped TERMINATION round: §5.1/§5.7/§6.2.1/I9/§5.3 marker
  only; stopping rule = zero mechanism findings ⇒ freeze):** DO-NOT-FREEZE — 2 MECHANISM + 1
  SPEC-WORDING + 1 TEST-GAP, all folded same day: (MECH) legacy `encryptedContent` fallback
  preceded `none_for_device` unconditionally, so a linked device would terminally
  `[Decryption failed]` its entire pre-link history → fallback now DEVICE-GATED to the session
  owner (§5.3, falsification 13 extended); (MECH) edit re-fan was ambiguous for a device linked
  after the send → UPSERT semantics, placeholder upgrades to the edited message (§5.7,
  falsification 24 extended); (WORDING) distinct HKDF info labels `fp-link-sas` / `fp-link-blob`
  for domain separation (§5.1); (TEST-GAP) both mechanism cases added to the falsification plan.
  Round 3 also verified: the two-round DH-bound SAS is sound incl. the blind-approve case (blob
  stays encrypted to the authentic ephPubN), and the 1 h recovery window is consistent with I4.
- **Micro-verification (2026-08-17, on the two round-3 folds only): FREEZE — zero MECHANISM
  findings.** Verified the device-gated fallback resolves every §8 mixed-model case (incl.
  reset/re-link with no device 1 → marker everywhere) and UPSERT edit is consistent with §5.2/§4/
  I8/I9. Four non-blocking items folded same day: deviceIds-never-reused invariant stated at the
  §5.3 gate; legacy-client sends pinned to device-1-envelope-at-ingest (dead branch removed,
  §4/§8 wording unified); edit UPSERT preserves delivery stamps (§5.7); falsifications 13/24
  extended (positive owner-serve, no-device-1 case, stamp preservation). **Doc frozen at v5.**
- **Owner ratification: §11 items 1–6 ALL CONFIRMED 2026-08-17.**
- **Amendment 2026-08-19 (owner-ratified decision record; doc remains frozen — this adds
  mechanism to an existing invariant, changes no protocol):** the §5.3 deviceIds-never-reused
  invariant is implemented by a **per-account allocator column `users.nextDeviceId`**
  (migration `0016`, `int`, default 2; allocation = one atomic
  `UPDATE users SET "nextDeviceId" = "nextDeviceId" + 1 WHERE id = $1 RETURNING …`).
  Deriving ids from `MAX(deviceId)+1` over `devices` is REJECTED: it silently converts a row-
  retention convention into a cryptographic invariant (any future purge of a `devices` row
  re-enables reuse). Grounded in prior-art research
  (`docs/plans/2026-08-19-multi-device-prior-art-research.md` §2): Signal's lowest-free reuse is
  survivable only via per-device registrationId disambiguation + total per-id purge on relink +
  a stale-session bounce, none of which exist here, and §5.3's device-gated legacy fallback makes
  a reused id actively dangerous; Matrix (Synapse #17375) documents reuse reattaching stale
  id-keyed attestations; WhatsApp/MLS allocate monotonically.
- **Amendment 2026-08-19 (§6.2 cooldown carve-out; owner-ratified):** the 24 h post-cancel
  cooldown is VOID if the account's password changed after the cancel: the cooldown predicate
  additionally requires `(u."passwordChangedAt" IS NULL OR r."cancelledAt" > u."passwordChangedAt")`.
  Rationale: the cooldown refusal's own copy directs a user whose ceremony was cancelled by an
  intruder to change their password; once they have (which revokes every refresh token and
  invalidates every prior JWT), the attacker-authored cancel must not keep the owner locked out
  of starting a legitimate ceremony. Deliberately narrow: a pending ceremony is NEVER cancelled
  by a password change (rows carry no requester attribution, so cancelling could discard the
  owner's own in-flight 72 h wait), and a cooldown armed AFTER the password change still binds.
  A cooldown refusal now logs a `warn` (previously the branch logged nothing).
- **Phase 2 Stage 0 review (2026-08-19, three independent reviewers: coherence + §7
  re-ratification / protection / data-durability): PASS-WITH-AMENDMENTS.** Every §7 delta
  re-ratified against the landed handlers; §8 compat re-verified under the landed OTP gate
  ordering; the DH-bound §5.1 SAS CONFIRMED to subsume an m.sas.v1-style commitment round
  (no /prototype needed for security — the argument rests on `ephPubN` being QR-only, see
  amendment c); the cooldown carve-out CONFIRMED to grant an attacker nothing new. Full
  finding-to-ticket map: `docs/plans/2026-08-19-phase2-stage0-decision-record.md`. The
  following NORMATIVE amendments bind Phase 2 (doc remains frozen; amendments complete
  mechanisms, none contradicts a frozen ruling):
  - **(a) §5.1 allocator ordering + idempotency.** The SERVER runs the `nextDeviceId`
    allocator exactly ONCE per `provisioningId` (memoized on the stage, allocated at
    `openProvisioning`) and delivers the assigned id to the primary BEFORE the primary signs
    `provisionDevice` — as drawn, the primary had no way to learn the id it must sign. The
    allocated id is the PRE-increment value (`RETURNING "nextDeviceId" - 1`). A duplicated or
    retried `provisionDevice` re-uses the memoized id, never re-allocates.
    `provisioningComplete` consumes the stage via an atomic compare-and-set inside the ONE
    commit transaction (two concurrent duplicates commit exactly one device row) and RETIRES
    the `provisioningId` (no blob refetch after commit). An aborted ceremony does NOT
    decrement the counter: gaps in the id space are expected and safe — the invariant is
    monotonic-never-reused, not dense.
  - **(b) §5.1 session rebind.** At `provisioningComplete` the server re-issues N's access +
    refresh tokens BOUND to the assigned deviceId (`refresh_tokens.device_id`,
    `createToken(userId, deviceId)` plumbing already landed in Phase 1); N MUST NOT upload key
    material until its socket is authenticated under that id (every per-device wire path keys
    off the JWT deviceId on the socket — a bundle uploaded before rebind would land on
    device 1 and overwrite the primary's). `uploadKeyBundle`/`uploadOneTimePreKeys` for a
    never-activated deviceId are rejected (§7 row already says so; this names it a T3
    deliverable — `DevicesService.ensureRow` creates only device 1's row and returns for any other id).
  - **(c) §5.1 ephPubN is QR-only.** `ephPubN` MUST NEVER transit the server: not echoed in
    the `openProvisioning` response, not in any relayed frame, not logged. The
    no-commitment-round SAS soundness argument rests on the QR channel giving BOTH
    authenticity AND confidentiality of `ephPubN`; a leak reopens the offline grind and would
    force an m.sas.v1-style commitment round. `provisioningHello` pins the FIRST `ephPubP`
    received (later hellos for the same stage rejected) and is accepted only from an
    authenticated session of the account.
  - **(d) Signature domain separation (§3/§6.1).** Every NEW signature construction carries an
    explicit ASCII context prefix whose first byte ≠ 0x05, keeping it provably disjoint from
    the FROZEN §6.1 registration-lock layout (`newIK(33, leading 0x05) ‖ utf8(userId) ‖ nonce`,
    which stays byte-exact as landed): enrollment `E` signs
    `"fp-enroll-v1\0" ‖ userId ‖ dakPub ‖ createdAt` under IK; the signed device list signs
    `"fp-list-v1\0" ‖ listCanonical` under DAK; DAK rotation signs
    `"fp-dak-rotate-v1\0" ‖ …` under the old DAK. Rationale: enrollment and §6.1 share sig_IK,
    list and rotation share sig_DAK — without contexts, a signature minted for one
    construction could reinterpret as another (the Matrix CVE-2022-39250 class). NEW
    falsification 25: a signature minted for any one construction is REJECTED by every other
    construction's verifier.
  - **(e) §5.5 accept-side revocation.** Revocation is bidirectional: at decrypt time a peer
    (and an own device, for self-sync envelopes) MUST verify the inbound envelope's
    `originDeviceId` is present-and-not-revoked in the CURRENT DAK-signed device list and
    FAIL CLOSED on absent/revoked; the revoked device's inbound pairwise session state is
    dropped on the next staleness bounce. Falsification 7 extended: a message SENT by a
    revoked device after revocation is refused at receive time, not just unrouted.
  - **(f) §6.2 reset × device roster.** A completed reset (i) allocates the recovering
    device's id from `users.nextDeviceId` — it NEVER re-mints device 1 (a fresh IK under a
    reused id 1 would be positively served the old device 1's legacy ciphertext by the §5.3
    fallback — the exact foreign-ratchet decrypt L269-272 forbids; post-reset pre-reset
    history is `none_for_device` markers everywhere, per falsification 13's no-device-1
    case); (ii) marks every surviving `devices` row revoked so the fresh device is the only
    live one; (iii) replaces `account_authorizations` with the fresh enrollment, the list
    version CONTINUING monotonically (never restarting at 1); (iv) leaves `users.nextDeviceId`
    untouched. The `purgeSupersededDevices` widening that implements (ii)/(iii) belongs to
    T6 (it is a device-list mutation), blocked on T1's columns — do NOT widen it inside T1.
  - **(g) Migration `0016` determinism.** `message_envelopes` starts EMPTY — NO backfill of
    pre-migration rows (they are served by the §5.3 device-gated legacy fallback; a backfilled
    device-1 envelope would change which device fallback order 1 serves).
    `account_authorizations` is NOT backfilled — rows appear lazily at enrollment,
    first-write-wins. `message_envelopes.messageId` FK is `ON DELETE CASCADE` — this cascade
    is the SOLE mechanism destroying never-fetched envelopes at the §5.6 deadline (every
    landed destruction path is a DB DELETE on `messages`); `(recipientUserId,
    recipientDeviceId)` carries NO FK to `devices` (envelopes outlive device-row lifecycle).
    Single transaction, plain indexes, no `CONCURRENTLY` (§8), like `0015`.
  - **(h) List freshness TTL: DEFERRED past Phase 2** (recorded so it is not silently
    forgotten). A WhatsApp-style signed-list TTL only bounds a silent server-freeze window
    while no honest message flows; §5.2's cross-check + I7 already collapse that window to
    the first honest message, and sustaining a freeze degrades to plain DoS. At the ratified
    cap-3 scale, version-stamp divergence detection suffices.
- **Amendment 2026-08-20 (T3 pre-implementation settlement, per the Stage-0 "settle before
  code" rule; doc remains frozen — these pin byte layouts and transport for mechanisms §5.1
  already mandates, changing no protocol):**
  - **(i) OOB payload + manual-code equivalence.** The §5.1 QR payload is the exact ASCII
    string `fp-link.v1.<provisioningId>.<base64url(ephPubN), no padding>.<platform>` (the
    trailing segment is N's self-reported platform label, ≤32 chars, informational metadata
    for the signed list entry). N renders it BOTH as a QR code and as a copyable text code;
    the primary MAY ingest it by camera scan or by manual paste — both are the same
    out-of-band channel (N's screen → human → primary), preserving amendment (c)'s
    authenticity AND confidentiality of `ephPubN`, which still never transits the server.
    T3 ships the manual path (required; it is also the only app-provable path on two web
    origins); camera scanning is Phase 3 UI. The new device's list entry is written with
    this platform label and NO `name` — user-chosen names arrive with the Phase 3 rename UI
    (which is where the client-side NFC-normalization rider lands, since T3 writes no name).
  - **(ii) SAS + blob derivations (byte-exact).** Ephemerals are Curve25519 pairs
    (`Curve.generateKeyPair()`); public keys travel in the 33-byte type-prefixed libsignal
    encoding everywhere (QR and `provisioningHello`). `S_dh =
    Curve.calculateAgreement(theirEphPub, ownEphPriv)` (32 B).
    `transcript = utf8(provisioningId) ‖ ephPubN(33) ‖ ephPubP(33)`.
    SAS bytes = `HKDF(ikm = S_dh, info = utf8("fp-link-sas") ‖ transcript, len = 32)`;
    the human code is the first 4 SAS bytes read as a big-endian uint32,
    mod 10^6, zero-padded to 6 decimal digits, displayed as two groups of three (`XXX XXX`
    — ~20-bit comparison, §5.1). Blob keys = `HKDF(ikm = S_dh, info =
    utf8("fp-link-blob") ‖ transcript, len = 64)`: bytes 0–31 = AES-256-CBC key, bytes
    32–63 = HMAC-SHA-256 key. Blob = `0x01 ‖ IV(16) ‖ AES-CBC ciphertext ‖
    HMAC(macKey, 0x01 ‖ IV ‖ ciphertext)(32)` — encrypt-then-MAC, MAC verified in constant
    time BEFORE any decrypt. Blob plaintext is UTF-8 JSON `{userId, deviceId, ikPub(b64),
    ikPriv(b64), dakPub(b64), enrollmentCreatedAt, enrollmentSig(b64)}`. The two HKDF info
    labels are distinct from each other (round-3 domain-separation ruling) and disjoint
    from every (d) signature context by construction (KDF inputs, not signature messages;
    first byte `f` ≠ 0x05 regardless).
    HKDF here is RFC-5869 HKDF-SHA256 with `salt = 32 zero bytes`, implemented locally
    over `package:crypto` (byte-identical to libsignal's HKDFv3 with null salt — that
    class is NOT exported from the `libsignal_protocol_dart` 0.8.2 barrel, and a `src/`
    implementation import is forbidden).
  - **(iii) Rebind delivery.** The (b) re-issued access + refresh tokens travel in the
    `provisioningCompleted` success answer on N's opener socket — TLS-protected and
    authenticated, the same trust surface as login's answer. N then disconnects, reconnects
    under the deviceId-bound access token, and only THEN uploads its per-device bundle/OTPs.
  - **(iv) Stage residency.** The provisioning stage (memoized deviceId, pinned `ephPubP`,
    staged blob + list mutation, 10-min TTL, consumed flag) lives in server-process memory
    keyed by `provisioningId` and bound to the opener socket — the durable §4 data model
    deliberately has NO stage table, because §5.1 already binds the stage to a socket
    session that cannot outlive the process. A backend restart drops every pending stage,
    indistinguishable from TTL expiry and handled by I1 abort hygiene; nothing durable
    leaks (counter gaps are safe per (a)).
- **Amendment 2026-08-20 (T4 pre-implementation settlement, per the Stage-0 "settle before
  code" rule; doc remains frozen — these pin wire shapes, ingest ordering and marker
  vocabulary for mechanisms §5.2/§5.3 already mandate, changing no protocol). Grounded in
  `docs/plans/2026-08-20-t4-envelope-fanout-research.md` (three codebase scouts + two
  primary-source librarians):**
  - **(v) Send DTO growth + legacy normalization AT INGEST.** `SendMessageDto` grows three
    OPTIONAL fields: `envelopes: [{userId, deviceId, ciphertext}]` (non-empty when present;
    each ciphertext individually bound by the existing 65536 limit), `senderListVersion`,
    `recipientListVersion`. A send is NEW-MODEL iff `envelopes` is present and non-empty,
    else LEGACY. Before any persistence a legacy send carrying `encryptedContent` is
    NORMALIZED into the one-element list `[{userId: recipientId, deviceId: 1, ciphertext:
    encryptedContent}]`, so exactly ONE downstream write path exists (Signal-Server keeps a
    single normalized `messagesByDeviceId` map regardless of count —
    `push/MessageSender.java`); a send carrying neither ciphertext (PING and today's
    ciphertext-less shapes) writes NO envelope and keeps today's behavior. NEW-MODEL rows
    NEVER write `messages.encryptedContent` — it stays NULL, retained per §4 for
    pre-migration rows only. Exactly one envelope per `(userId, deviceId)`: a duplicate pair
    is REFUSED (`duplicate_envelope_device`), mirroring Signal-Server's
    `IncomingMessageList.isNotDuplicateRecipients()` (last-wins would brick a device's
    ratchet). An envelope addressed to a recipient device that is not live
    (`DevicesService.isActive`) is REFUSED (`unknown_recipient_device`) — fail-closed; the
    full falsification-7 revocation case remains T6. A self-sync envelope addressed to the
    ORIGIN device itself is REFUSED (`self_envelope_for_origin_device`). Envelope COVERAGE is
    not otherwise server-enforced: the server cannot know which devices the client could
    build sessions to, so I5's never-silently-drop-a-device duty stays with the client.
    Version cross-check applies per party ONLY when that party has an
    `account_authorizations` row: an enrolled party's stamp MUST equal the stored
    `listVersion` (absent stamp counts as mismatch); a non-enrolled party is single-device by
    construction (rows ≥ 2 are minted solely by the provisioning commit) and carries no
    stamp. Legacy normalized sends carry no stamps and bypass the cross-check entirely — the
    §8 rollout window, whose cost is that a legacy client reaches device 1 only.
  - **(vi) `deviceListStale` refusal payload.** The stale-send refusal is a response-event in
    house style (`{success:false, error}` per `chat-device-list.service.ts`, NOT the send
    path's bare `error` emit), emitted to the CALLER socket only:
    `deviceListStale {success:false, error:"device_list_stale", tempId?, lists:[{userId,
    version, listCanonical(base64), listSignature, enrollment:{dakPub, enrollmentSig,
    enrollmentCreatedAt}}]}`. §5.2's singular payload becomes an ENTRY in `lists`, one per
    party whose stamp mismatched (recipient first when both are), so ONE round trip repairs
    both views — Signal-Server returns device IDs only
    (`MismatchedDevicesResponse`/`StaleDevicesResponse`) and forces a second `/keys` trip,
    while Sesame §3.3 explicitly permits returning the key material with the ids; ours is the
    Sesame shape and is self-verifying. `tempId` is REQUIRED for correlation when several
    sends are in flight. The check runs BEFORE any write: zero message rows, zero envelope
    rows (falsification 5; prior art is validate-then-insert,
    `MessageSender.validateIndividualMessageBundle` throwing before
    `messagesManager.insert`). The client MUST verify the I7 chain on a delivered list before
    adopting it and MUST fail the send on an invalid chain (falsification 4 — never the
    server's bare word), then retry at most 3 times before surfacing a hard send failure
    (Sesame §3.3/§4.1 mandate a finite cap without fixing the number).
  - **(vii) `senderListInfo` DEFERS to T5.** The §5.2 layer-2 field lives in E2E plaintext
    inside the ciphertext; the server never sees, stores, or validates it, so it is purely a
    client concern. Its falsifications (16 split-view, 22 false-alarm discipline) are both
    recipient-side escalation tests, and the receive-side guards they interact with are
    exactly the ones T5 flips to origin-device scoping. Landing the field alone in T4 would
    be dead weight; `E2eEnvelope.parse` ignores unknown keys, so adding it later costs
    nothing (the `linkPreview` precedent, root `CLAUDE.md` §7 envelope-compat).
  - **(viii) Per-device history reads + `envelopeStatus` vocabulary.** `getMessages` /
    `findByConversation` join `message_envelopes` on the REQUESTING `(recipientUserId,
    recipientDeviceId)` taken from the socket's JWT (legacy JWTs default to device 1, so
    addressing is uniform). The served ciphertext continues to ride the EXISTING
    `encryptedContent` wire field — no new ciphertext field, so older clients are untouched.
    Per-row fallback, device-gated: (1) this device's envelope → serve its ciphertext, NO
    `envelopeStatus`; (2) legacy `messages.encryptedContent` → served ONLY to the row's
    session owner, i.e. `deviceId == (originDeviceId ?? 1)` for the requester's OWN rows and
    `deviceId == 1` for rows it received; (3) otherwise the additive string marker. Two
    marker values, both carrying NO ciphertext: `"none_for_device"` (the row predates this
    device's link — the §5.3 honest placeholder) and `"own_origin"` (the requester's own row
    on its origin device: no envelope exists for the origin device BY DESIGN, since self-sync
    envelopes address the sender's OTHER devices). The second value is REQUIRED — without it
    the origin device would render "sent before this device was linked" over every message it
    ever sent. An extensible string code set is the industry-consistent shape (Matrix
    MSC2399's `m.room_key.withheld` `code`; `matrix-sdk-crypto`'s `UtdCause` keeps a dedicated
    `SentBeforeWeJoined` variant distinct from generic `Unknown`). Client rules: a marker row
    is EXCLUDED from the decrypt pass (it can never become `[Decryption failed]`), NEVER
    overwrites locally stored plaintext (it joins `placeholderContents`), and is NEVER a
    destruction trigger (I8, falsification 13); `own_origin` renders from the local plaintext
    store exactly as today and has no placeholder copy of its own.
  - **(ix) Lost-ack continuity under fan-out (forced by (v)+(viii); T5 keeps the rest).**
    Because a new-model row carries no ciphertext for its origin device, the landed
    exact-ciphertext pending-send reconcile (`frontend/CLAUDE.md` §5) would silently stop
    matching — a data-loss regression in the path that guards the ONLY plaintext copy.
    Therefore T4 lands the §5.4 key itself: the client MINTS `sendToken` for every new-model
    send and stores it IN the pending-send record; the server echoes `sendToken` on
    `messageSent` and on history rows served to that row's origin device; the reconcile
    matches `(senderId, originDeviceId, sendToken)` and MUST resolve to EXACTLY ONE row, an
    ambiguous match being a no-op that never consumes the record. Exact-ciphertext equality
    REMAINS the fallback for legacy and pre-existing records. The own-sender guard flip,
    self-sync consumption rules, and re-ack-without-re-fan under envelopes stay T5.
  - **(x) Legacy sends are refused once either party is enrolled; the client
    fans out only from a list it already holds (forced during T4 implementation;
    amends (v)'s "legacy normalized sends bypass the cross-check entirely").**
    Requiring the client to fetch a device list on EVERY send — to prove that a
    single-device account is single-device — taxes the overwhelmingly common
    path for nothing. So the client fans out only when it ALREADY holds a
    verified list for the RECIPIENT (seeded by an explicit `getDeviceList`, a
    `deviceListChanged`, or a `deviceListStale` refusal) and otherwise sends the
    legacy single-ciphertext shape, which (v) normalizes to a device-1 envelope
    at ingest. That is only safe because the SERVER now refuses a legacy
    ciphertext-bearing send whenever EITHER party has an `account_authorizations`
    row, answering `deviceListStale` with every enrolled party's signed list:
    a legacy send reaches device 1 alone, so accepting it for an enrolled peer
    would silently DROP that peer's other devices, exactly what invariant I5
    forbids. I5 therefore lands where it cannot be skipped — server-side — and
    the refusal is what upgrades a client to fan-out. Corollaries: a
    ciphertext-less send (PING) is never refused, since it has no envelope to
    fan out; a client MUST NOT fan out when the recipient's list is unknown
    (envelopes addressing own devices only would commit a row with a NULL legacy
    column whose recipient reads `none_for_device` forever — the message
    permanently invisible to the person it was sent to); and the refusal handler
    MUST explicitly resolve any party ABSENT from `lists[]` (an enrolled sender
    with a non-enrolled recipient yields a single entry, and without resolving
    the other party the resend would repeat the legacy shape until the retry cap).
    The server tells the client which device it is by echoing `deviceId` on
    `socketReady`: it cannot be derived client-side, and a fan-out must exclude
    its own origin device.
- **Amendment 2026-08-21 (T5 pre-implementation settlement, per the Stage-0 "settle before
  code" rule; grounded in `docs/plans/2026-08-21-t5-self-sync-lost-ack-research.md`, which
  cites libsignal, Signal-Server, Sesame, Matrix/Synapse, XEP-0198/0359, RFC 9420, CONIKS and
  Apple CKV from primary source). Items (xi)–(xviii) are NORMATIVE for T5. Two facts found by
  the research amend §5.4's own account of the work: the SEND half of self-sync already shipped
  in T4 on both tiers, and §5.4's list of own-sender guards is INCOMPLETE — the decisive gate is
  `MessageModel.needsDecryption`, and the receipt-emit guard must NEVER be device-scoped.**
  - **(xi) The own-row decision law — deny-decrypt unless PROVEN foreign-origin.** For a row
    with `senderId == me`, exactly one branch applies, evaluated in this order: (1)
    `envelopeStatus == 'own_origin'` → this device is the origin; NEVER decrypt (a Signal sender
    cannot decrypt its own output, and a failed attempt renders `[Decryption failed]` over the
    ONLY plaintext copy); reconcile via the pending-send record. (2) `(originDeviceId ?? 1) ==
    ownDeviceId` → the legacy shape of the same case (a legacy own row is served its own
    ciphertext with no marker); NEVER decrypt; reconcile. (3) `(originDeviceId ?? 1) !=
    ownDeviceId` → SELF-SYNC; decrypt as an ordinary inbound message against the session keyed
    `(myUserId, originDeviceId)`, and NEVER touch the pending-send record. The default is
    branch (1)/(2) behaviour: a row is decrypted only when its foreign origin is proven.
  - **(xii) The device-scoped branch requires an AUTHORITATIVE `ownDeviceId`.** `ownDeviceId`
    defaults to 1 and becomes authoritative only when `socketReady` echoes it, so a real device 2
    believes it is device 1 in that window. Until it is authoritative, an own row takes branch
    (1)/(2) — it stays `[encrypted]` and is retried once `socketReady` lands. Deferring the
    render is acceptable; guessing is not, because branch (3) on a wrongly-scoped row would
    attempt to decrypt this device's own ciphertext.
  - **(xiii) The five guards of §5.4 are eight, and one of them must NOT be flipped.** Flip to
    origin scoping: `MessageModel.needsDecryption` (**the master gate — omitted from §5.4; every
    other flip is dead code without it**), the history own-message branch, the live-path queue
    guard, the decrypt guard, and the terminal-duplicate guard (a foreign-origin own row IS a
    genuine inbound envelope and is eligible for that rule). The optimistic-replace branch keeps
    `tempId != null`, which already makes it origin-safe because a `tempId` exists only on the
    device that minted it. **The receipt-emit guard (`messageDelivered` + read-marking) stays
    ACCOUNT-scoped**: device-scoping it would make the sender's own second device emit a receipt
    for the account's own message, which §4 and falsification 19 forbid. The edit-echo reconcile
    and edit-eligibility checks likewise stay account-scoped — an edit is authored by the account.
  - **(xiv) `sendToken` uniqueness is enforced SENDER-scoped, which is strictly stronger than
    (ix)'s tuple.** The existing `UNIQUE (senderId, sendToken) WHERE sendToken IS NOT NULL`
    already makes "two candidate rows" structurally impossible; adding `originDeviceId` to that
    index would WIDEN the key and thereby PERMIT the same token from two devices, so it MUST NOT
    be added. (ix)'s `(senderId, originDeviceId, sendToken)` remains the CLIENT-side match law;
    the server contributes the uniqueness and the rule that the token is echoed ONLY to the row's
    origin device — so a non-origin device never holds the key that could consume another
    device's record. An ambiguous or absent match stays a no-op, asserted rather than assumed.
  - **(xv) `senderListInfo` shape and cadence (settles the (vii) deferral).** The field is
    `senderListInfo: {ownVersion, ownListHash, peerVersion, peerListHash}` inside the E2E
    plaintext; the server never sees, stores or validates it. Each hash is SHA-256 over the
    byte-exact DAK-signed `listCanonical` of that party's list as the SENDER knows it — never a
    re-serialization, since a non-canonical encoding yields phantom mismatches (Matrix signs
    canonical JSON for exactly this reason). Versions are the monotonic list versions. **Owner
    ruling 2026-08-21: it rides EVERY message**, not a sample: detection is immediate on the
    first message, and a sampled gossip (Apple CKV's approach) would make falsification 16 and
    the app-proof non-deterministic. A party the sender holds no verified list for is reported as
    absent, never as version 0.
  - **(xvi) Escalation discipline — a bare claim NEVER alarms (I7).** `senderListInfo` is
    untrusted peer-supplied data and may only be compared against the receiver's OWN verified,
    DAK-signed lists. A claim OLDER than what the receiver knows is a candidate freeze signal
    that renders only after the receiver independently confirms it against signed data. A claim
    NEWER than the receiver knows triggers AT MOST ONE re-fetch, rate-limited to one in flight
    per account with the rest queued (Matrix's rule — a parallel re-fetch lets a stale answer
    clobber a fresh one), and is then DISCARDED. Skew between the receiver's OWN devices is
    benign. First-contact TOFU stays unclosable in-band and MUST NOT be presented as if it were
    closed.
  - **(xvii) Own-device skew surfaces as a calm inline state (owner ruling 2026-08-21).** A small
    inline "syncing devices…" note in the conversation, en+pl, that clears itself once the lists
    agree. It MUST NOT reuse the identity-changed surface, and no security colour, icon or sound
    is permitted on this path — conflating a benign sync with an attack trains the user to ignore
    real warnings (Apple CKV: "warnings must be rare and accurate").
  - **(xviii) The reinstall gap is ACCEPTED, not repaired (owner ruling 2026-08-21).** A device
    that reinstalls holds no pending-send record and is echoed no `sendToken`, and the server
    never had the plaintext, so that device's own older rows render the honest
    `none_for_device`/own-origin placeholder permanently. This matches Signal's and Matrix's
    behaviour for messages predating the current install. A cross-device plaintext backfill would
    be a new plaintext-moving path and belongs to §9's Phase 4 if ever, NOT to T5.
  - **(xix) The device-list rollback pin covers the enrolled→not-enrolled transition.** An
    `authorization: null` answer for a party the client has already verified as enrolled at some
    version MUST be refused as a version rollback, not cached as "not enrolled". Enrollment is
    durable per §5.2, so the transition is never legitimate; caching it would silently narrow a
    fan-out to device 1 and, once (xi) lands, silently kill self-sync. This fix is T5's first
    stage because self-sync depends on the client's own device list being trustworthy.
  - **(xx) Three refinements forced by T5's post-build reviews (2026-08-21; three fresh
    reviewers, no P0). All NORMATIVE.**
    1. **The confirmed device id is SESSION state, never install state.** It MUST be reset to
       "device 1, unconfirmed" on logout/account switch, and a `socketReady` that carries NO
       `deviceId` MUST leave it unconfirmed rather than assert device 1. Both were latent
       violations of (xii) across sessions: this client is a process singleton, so a device id
       confirmed as N for one account survived into the next login, where an own row of a
       device-1 account looks foreign-origin — and the self-sync branch would then hand this
       device's OWN ciphertext to the ratchet. Unreachable while enrollment is unshipped
       (`ownDeviceId` is always 1), and fixed before it could ship.
    2. **The calm skew state of (xvii) is bounded to the re-fetch window.** The peer controls the
       version it claims about us, so raising the note on every mismatching claim let a hostile
       peer pin "syncing devices…" on permanently. It is now raised only when a re-fetch actually
       begins (same one-per-cooldown limiter) and cleared when that fetch settles.
    3. **The durable split-view record is DEDUPED per sender.** The claimed version and hash are
       peer-supplied and NOT DAK-signed, so a peer forging a mismatch on every message could
       append a durable row per message and FIFO-evict every other piece of forensic evidence
       (`CONTENT_KEY_LOST`, `OWN_IDENTITY_REPLACED`, …) from the 80-entry ring. One surviving row
       per peer is what an operator needs; per-message detail stays in the ring-only flow log.
- **Amendment 2026-08-21 (T6 pre-implementation settlement, per the Stage-0 "settle before
  code" rule; doc remains frozen — these pin the enforcement points and refusal codes for
  mechanisms §5.5, §5.1 and amendments (e)/(f) already mandate, changing no protocol law).
  Owner-ratified 2026-08-21. All NORMATIVE:**
  - **(xxi) Revocation refuses the primary and refuses self-revoke.** `revokeDevice` is
    accepted only for a device that is NOT the caller's own (`cannot_revoke_self`) and NOT the
    account's primary (`cannot_revoke_primary`); the caller's own row must be `isPrimary`
    (`not_primary`). The cryptographic gate remains the DAK signature on the list mutation —
    only the primary holds the DAK private key (§3), so the server-side `isPrimary` check is
    defence in depth, not the authority. Rationale for the two refusals: a primary that
    revoked itself would leave the account with NO device able to sign any future list
    version, which no in-band path can repair — the recovery for a lost primary is the §6.2
    reset, and a non-primary "sign me out" would need a server-signed list version, which §3
    forbids. A DAK-signed list whose canonical bytes revoke a different set than the request
    names is not reconciled: the request's `deviceId` MUST appear revoked in the submitted
    canonical list (`list_device_mismatch`), so the signed bytes and the teardown always agree.
  - **(xxii) The revoked-session predicate is "EXPLICITLY revoked", never "not active".** Both
    new gates — the socket connect gate and the HTTP gate — deny only when the `devices` row
    EXISTS and `revokedAt IS NOT NULL`. A MISSING row must never deny: every pre-Phase-1
    account has no row until its first connect writes one (§8), so denying on absence would
    lock out the entire legacy install base. This is deliberately the inverse polarity of
    `DevicesService.isActive`, which gates key-material UPLOADS and must fail closed on
    absence; a session gate that fails closed on absence is a mass lockout. Both predicates
    stay, each at its own call sites.
  - **(xxiii) I6 SILENCE is a separate rule from rejection, because silence is not an error.**
    A revoked device's still-valid access JWT is REJECTED by mutating handlers, but
    `getServedMessageIds` gets NO REPLY AT ALL — never an error answer, never an empty list.
    An empty `messageIds` is a legitimate "destroy all of them" instruction (I6), so a
    refusal shaped like an answer would remotely wipe the local history that §5.5 and §1
    guarantee stays. The revoked device therefore keeps every message it holds and its expiry
    sweep fails closed forever, which is the accepted over-retention I6 already records.
  - **(xxiv) The HTTP surface learns `deviceId`, and per-device push becomes real.**
    `JwtStrategy` now reads the `deviceId` claim (absent ⇒ device 1 per §8, exactly as the
    socket path already does), applies (xxii), and exposes it on the request principal. That
    unblocks the §5.5 clause that was unimplementable: the push-registration endpoints persist
    the caller's `deviceId`, so revocation can delete that device's rows. Rows registered
    BEFORE this ticket carry `deviceId IS NULL` and cannot be attributed to a device, so
    revocation deletes the revoked device's rows AND every NULL-`deviceId` row of the account:
    ambiguity resolves toward cutting the revoked device off, and a surviving device
    re-registers its endpoint on its next start (self-healing, at most one missed push
    window). Deleting nothing would keep pushing to the device the user just cut off.
  - **(xxv) Revocation preempts EVERY pending provisioning stage of the account**, not only a
    stage holding the revoked id (§5.1 "a security action never waits on a stuck link"). Every
    live stage carries a list mutation signed against the pre-revocation list, so revocation's
    version+1 makes all of them stale by construction; discarding them turns a guaranteed
    `stale_version` at commit into an immediate, honest `unknown_stage`. Stages are in-memory
    and keyed by `provisioningId` (amendment (iv)), so this is an iteration over the account's
    stages — nothing durable is touched.
  - **(xxvi) The kicked device is TOLD before it is dropped, and keeps its data.** The server
    emits `deviceRevoked { userId, deviceId }` to the revoked device's room and THEN
    disconnects its sockets. The client treats it as a logout with a stated reason (en+pl):
    session tokens cleared, local plaintext store and Signal key material UNTOUCHED — which is
    already what every existing logout path does, and is the §1 non-goal "no remote wipe" held
    intact. The event is best-effort (an offline device gets nothing); the (xxii) connect gate
    is the durable enforcement, so the UX must never depend on the event having arrived. A
    device that reconnects and is refused shows the same stated reason rather than the generic
    connection-lost banner.
  - **(xxvii) Accept-side (e) fails closed on VERIFIED data, and a cache miss is not a
    verdict.** At decrypt time, after the (xi) own-row branches have run, a genuine inbound
    row's `(senderId, originDeviceId ?? 1)` MUST be present-and-not-revoked in the receiver's
    verified list for that sender. The client's verified-list cache is memory-only, so a miss
    is the NORMAL state after every reload: a miss MUST trigger the ordinary rate-limited
    verified fetch and leave the row RETRYABLE (`[encrypted]`, no ledger consumption, no
    terminal failure), never refuse it permanently. Only a list that positively shows the
    origin device absent or revoked refuses the decrypt — and that refusal is silent (I7: it
    is a decrypt refusal, never an alarm surface). A sender that is not enrolled verifies as
    the synthesized single device 1, so an inbound `originDeviceId >= 2` from a non-enrolled
    account is refused, which is the correct fail-closed reading of §5.2.
    **Rider, forced by implementation (2026-08-21):** when the verified fetch itself FAILS
    (timeout, no pinned identity, broken chain), the withholding applies to
    `originDeviceId >= 2` only; a device-1 row keeps its pre-T6 behaviour and decrypts. A
    strict reading would let one withheld or broken `getDeviceList` answer silence EVERY
    conversation of a single-device account — a server-side off switch for reading mail — while
    buying almost nothing: §5.5 refuses to revoke a primary at all, and the one path that
    revokes device 1 is the §6.2 reset, which also replaces the account identity, so that
    device's ciphertext stops decrypting for every peer regardless of this check. A list the
    client DOES hold still refuses a revoked device 1, so the teardown case stays covered.
  - **(xxviii) The §6.2 reset roster teardown (amendment (f)) is ONE transaction at the
    authorized identity change**, which is the moment a reset actually completes (the
    ceremony's consumption point, not the request). In that transaction: the recovering device
    is ALLOCATED a fresh id from `users.nextDeviceId` and is re-issued its tokens with that
    claim (the shape `provisioningCompleted` already uses — a reset must never re-mint device
    1, per (f)(i)); every surviving `devices` row is stamped `revokedAt` (f)(ii); each revoked
    device's key bundle and OTPs are purged strictly inside its own `(userId, deviceId)`
    namespace; `users.nextDeviceId` is left untouched (f)(iv). Falsification 12 is precisely
    the assertion that this teardown cannot reach a surviving device's key material.
  - **(xxix) The `account_authorizations` row is REPLACED, never dropped, and its version
    never restarts** (f)(iii). Dropping it would destroy the `listVersion` that (f)(iii)
    requires be carried forward, contradict the entity's own law ("monotonic — never restarts,
    even across a §6.2 reset") and make the account read as not-enrolled, which (xix) correctly
    refuses as a rollback. So the reset transaction leaves the row ALONE: its DAK is now
    orphaned, because the enrollment record `E` was signed by the identity key the reset just
    replaced, so no peer can verify the chain and every peer FAILS CLOSED — the honest state
    for an account whose identity just changed, and one the takeover alarm already surfaces.
    Recovery is a REPLACEMENT enrollment, admitted by exactly one new rule: an enrollment whose
    STORED `enrollmentSig` no longer verifies under the account's CURRENT published identity
    MAY be replaced by a fresh IK-signed enrollment whose list version is strictly GREATER than
    the stored version (`enrollment_version_must_be_1` continues to govern a genuine first
    enrollment; first-write-wins is otherwise untouched). The predicate is self-verifying —
    only an identity change can orphan a stored enrollment, and the fresh `E` must verify under
    the identity the server currently serves — so no flag, no nullable state and no new
    trust input is introduced. The recovering device re-enrolls immediately as part of recovery
    (it holds the fresh IK, mints a fresh DAK, and signs a list naming only its newly allocated
    deviceId); it needs no new wire field to do so, because `getDeviceList` already serves the
    stored version it must exceed.
- **Amendment 2026-08-22 (T7 pre-implementation settlement, per the Stage-0 "settle before
  code" rule; ratified by the owner 2026-08-22).** §5.7 and falsification 24 leave five things
  open. Four are gaps; the first is a latent CORRECTNESS BUG in the frozen text, found by
  reading the receive path rather than the spec.
  - **(xxx) An edit UPDATES `messages.originDeviceId` to the EDITING device.** §5.7 permits an
    edit from any of the sender's devices, and that edit's ciphertext is bound to the EDITING
    device's ratchet — but the receiver selects its Signal session by
    `originDeviceId ?? 1` (`messaging_provider.decrypt.dart:1354-1355`, `:1372`, whose own
    comment already defines the field as "the device that PRODUCED this ciphertext"), and the
    accept-side (e)/(xxvii) gate keys on the same field. Since the edit receive path swaps in
    the new ciphertext while KEEPING the row's original `originDeviceId`
    (`messaging_provider.events.dart:472-476`), an edit from a non-origin device would make
    every receiver decrypt against the WRONG device and fail with a Bad-MAC on a row that
    decrypted fine before the edit. The field is therefore defined as **the device that
    produced the ciphertext currently stored**, not "the device that first sent the row": every
    envelope of one row is always produced by exactly ONE device (all of them at send, all of
    them at edit), so a single per-row field remains sufficient and no second device-id column
    is introduced. Consequences, all already legal under existing rules: the sender's ORIGINAL
    origin device now receives an edited envelope like any other device, which is the (R10)
    placeholder-upgrade path, and it loses its `own_origin` marker for that row because it is no
    longer the producer; edit ELIGIBILITY and the edit ECHO stay ACCOUNT-scoped per (xiii), so
    nothing about authorship depends on this field. Rejected alternatives: a separate
    `editorDeviceId` (two device-id fields that can disagree, and every decrypt site must learn
    which to prefer), and restricting edits to the original device (contradicts §5.7 outright
    and would silently remove the edit action on a second device).
    **Falsification 24 does not cover this** — it asserts a non-origin edit SUCCEEDS, never that
    a third device DECRYPTS it; T7 adds that assertion.
  - **(xxxi) The edit's staleness bounce reuses the `deviceListStale` event of (vi) verbatim**,
    emitted to the caller only and BEFORE any write, with the same ≤3 retry cap as §5.2. To feed
    the (v) per-enrolled-party version cross-check, `editMessage` additionally carries
    `senderListVersion` / `recipientListVersion` (present only for an ENROLLED party, an absent
    stamp counting as a mismatch exactly as in (v)) — fields §5.7's short example omits although
    its own "same staleness bounce as §5.2" requires them. `editMessageFailed` keeps its four
    existing bare codes untouched, so §5.7's "reject paths unchanged" holds: staleness is a
    DIFFERENT event, not a new code. The (v) envelope-shape refusals
    (`duplicate_envelope_device`, `unknown_envelope_user`, `unknown_recipient_device`,
    `self_envelope_for_origin_device`) are inherited by the edit path and answered on
    `editMessageFailed` as `reason`, since they are client-shape faults rather than a repairable
    staleness condition and carry no lists to repair with.
  - **(xxxii) The legacy `encryptedContent` column is updated on LEGACY rows ONLY, never on a
    new-model row.** §5.7's "legacy `encryptedContent` is updated too while mixed-model rows
    exist" is refined, because a new-model send deliberately stores NULL there
    (`chat-message.service.ts:380`) and the server's own new-model/legacy discriminator is
    `content === '[encrypted]' && encryptedContent == null` (`ackEnvelopeStatus`,
    `chat-message.service.ts:238-241`). Writing the column on a new-model row would silently
    reclassify that row as LEGACY after a single edit, changing the behaviour of every path
    keyed on the discriminator. The clause's intent — a mixed-model row stays readable to a
    client that only knows the column — is served exactly by writing it where the column is the
    row's only ciphertext.
  - **(xxxiii) Envelopes of devices dropped from the list between send and edit are LEFT in
    place.** They are unreachable: a revoked device cannot connect (xxii), is served silence by
    I6 (xxiii), and holds no valid session material after its teardown. Deleting them would
    introduce a SECOND envelope destruction path, whereas (g) names the message-delete CASCADE
    as the sole one, and would add a delete to the edit transaction for no observable benefit.
    Such a row keeps the pre-edit text and dies with its message.
  - **(xxxiv) An edited envelope carries `senderListInfo`**, per (xv)'s "rides EVERY message".
    An edit is a ciphertext-bearing message; omitting the block would leave exactly one message
    shape with no E2E cross-check of the device lists the server served, and the (xvi)/(xvii)
    escalation discipline governs the receive side unchanged. The builder already exists in the
    send path (`messaging_provider.send.dart:1300-1338`).
- **Amendment 2026-08-22 (T8 pre-implementation settlement, per the Stage-0 "settle before
  code" rule).** T8 is the harness sweep: every item is a proof an earlier ticket left owed, so
  the settlement fixes what an HONEST proof must show rather than changing any wire law. Three
  of the seven items need no amendment — the second harness account and the parameterized
  ceremony helpers are test-only; `list_device_mismatch` on the wire exercises a clause (xxi)
  already makes normative; and the calm-skew widget test proves a rule (xvii)/(xx) already
  states. The four below each pin something a future implementer would otherwise re-derive
  wrongly, and three of them exist because the obvious version of the proof CANNOT FAIL.
  - **(xxxv) A self-sync decrypt proof is VACUOUS unless it also asserts identity-key equality.**
    Falsification 6 proves ROUTING only: its self ciphertext is synthetic and the server treats
    every ciphertext as opaque, so nothing yet shows a sender's second device can decrypt its own
    copy. The proof T5 owes is: a real, ceremony-provisioned second device adopts the account's
    shared identity key (§5.1 ships `ikPriv` in the blob for exactly this), mints and uploads its
    OWN signed pre-key and one-time pre-keys under its `(userId, deviceId)` partition, and the
    origin device fetches THAT bundle, builds a session addressed to `(own userId, deviceId=N)`
    and encrypts a real ciphertext which the §5.2 fan-out routes to device N, which decrypts it
    as ORDINARY INBOUND against the ORIGIN device's session (xi)/(xii) and never touches a
    pending-send record. The anti-vacuity clause is binding and is the reason this amendment
    exists: **a Signal session decrypts whether or not the two parties' identity keys are equal**
    — `libsignal_protocol_dart` 0.8.2 carries no `self_session` concept and no IK-equality
    rejection branch, so X3DH admits the shared-account session by construction. A test that
    asserts only "device 2 decrypted" is therefore an ordinary two-party decrypt wearing a
    self-sync label; it MUST additionally assert that device 2's identity key IS the account's.
    **Measured correction, 2026-08-22, from running that experiment rather than reasoning about
    it:** when the adopt path was made to mint an unrelated identity, the run did NOT reach the
    equality assertion at all — it died two steps earlier, at the second device's
    `uploadKeyBundle`, with `identity_locked`. The §6.1 registration lock refuses a linked
    device that tries to publish an identity the account has not authorized, so the vacuity this
    clause guards is also fenced SERVER-side and is not reachable end-to-end today. The
    assertion stays REQUIRED regardless, for two reasons: it pins the property where the proof
    makes its claim instead of leaning on a control three subsystems away, and it is the only
    part of the test that would survive the lock being relaxed for a future recovery path. What
    changes is the justification — this is defence in depth, not the sole barrier — and the
    incidental finding is worth keeping: **the registration lock, not the harness, is what makes
    a foreign-identity second device impossible.**
  - **(xxxvi) §6.2 reset completion is a TWO-STAGE machine, and a proof AGES it rather than
    waiting it out.** The pending ceremony is flipped to `completed` by the per-minute
    `completeDueResets` sweep once `"deadlineAt" <= now()`; the (xxviii) roster teardown does NOT
    run then. It runs LAZILY at the next authorized bundle upload, which spends the completed row
    through `consumeCompletedReset` (conditional on `"consumedAt" IS NULL` and `"completedAt"`
    inside the 24 h grant TTL). Nothing completes "on the next request", which is the recurring
    misreading. A falsification-12 proof therefore runs request → age
    `identity_reset_requests."deadlineAt"` into the past by a direct SQL UPDATE (the owner's
    "delays in SECONDS, never wait out the window" rule; this is the ONLY sanctioned out-of-band
    write) → let the REAL sweep complete it → upload the recovering bundle to fire the REAL
    teardown. SQL-flipping `status` straight to `completed` skips the sweep and does NOT satisfy
    this item. Two further clauses, both anti-vacuity: falsification 12 claims the three re-keyed
    sites purge, claim and count **strictly within `(identityPublicKey, deviceId)`**, so a proof
    MUST establish at least TWO such partitions on one account BEFORE the reset — with a single
    partition the claim is trivially true and the test cannot fail; and the teardown leaves
    `account_authorizations` in place per (xxix), so a test expecting the reset to clear, drop or
    version-restart that row is asserting a spec violation and MUST fail.
  - **(xxxvii) A throttled `pinMessage` answers on its own `messagePinFailed` event, and the
    revert is CLIENT-driven from a pre-pin snapshot.** A throttled pin is the same divergence
    class (xxxi) and T7.5 closed for edits: the optimistic pin is applied locally, the refusal
    arrives as the bare `error` fallback which no pin code listens to, and the device keeps a pin
    the server and the peer never saw. Reusing `messagePinned` for the refusal is FORBIDDEN,
    because the guard refuses PRE-handler holding only the inbound `{conversationId, messageId}`
    and so cannot author the prior state: `pinnedMessageId: null` reverts a conversation that had
    a DIFFERENT message pinned to unpinned, and echoing the attempted id CONFIRMS a pin that
    never happened. The refusal is therefore `messagePinFailed {conversationId, reason, retryAfterMs}`,
    and the pinning device restores the pin it OVERWROTE from a snapshot captured at
    optimistic-apply time — the same discipline the edit path uses — cleared whenever an
    authoritative `messagePinned`/`messageUnpinned` settles it. `unpinMessage` writes no
    optimistic state, so it keeps the `error` fallback: an entry for it would be an answer with no
    client driver, the unreachable-code case the throttle table's own rule forbids. An older
    client that ignores `messagePinFailed` is left exactly where the `error` fallback leaves it
    today, so the change cannot regress it.
  - **(xxxviii) Envelope stamp survival is proven by the content-only conflict clause plus a
    recorded SQL check — the wire deliberately cannot observe it.** Per-device `deliveredAt` /
    `readAt` are bookkeeping behind the single §4 row projection (§5.3), are barred from feeding
    expiry or the read TTL (I9), and appear in no wire payload; exposing them would reveal WHICH
    recipient device received or read a message, a strictly finer delivery-metadata surface than
    the deliberately coarse projection. Falsification 24 therefore asserts the ROW projection
    only, and that assertion CANNOT detect a zeroed stamp because the row projection is
    maintained independently of the envelope. Survival is pinned instead by (1) the unit
    assertion that the envelope UPSERT's conflict clause names `ciphertext` and nothing else, and
    (2) the direct SQL evidence recorded in the T7 close. This is an accepted proof of record,
    not an owed wire test, and it stands only while the columns stay off the wire — if a future
    feature ever reads them onto it, this amendment is superseded and a real end-to-end survival
    test becomes owed. Corollary, stated so it cannot be silently relied upon: **`readAt` is never
    written by any code path** — `stampEnvelope`'s sole call site passes `'deliveredAt'`, and
    `markConversationRead` drives the ROW projection without touching the envelope — so any
    assertion that `readAt` "survives" is vacuous. The guard MUST target `deliveredAt` and MUST
    exercise a PRE-EXISTING non-null stamp rather than the insert-time null.
- **Amendment 2026-08-22 (T9 pre-implementation settlement, filed BEFORE code per the Stage-0
  "settle before you build" rule). Origin: the T1–T8 phase gate, three independent reviewers.**
  Two of the four defects below were mis-stated when first raised; the research round refuted
  those premises and they are recorded here corrected, not as first written.
  - **(xxxix) A peer device's bundle identity key MUST be checked against the account's verified
    identity key before a session is built, and the anchor MUST come from the verified device
    list — never from a fixed device slot.** §3 says every device of an account shares ONE
    identity key, and the I7 chain already verifies a peer's device list against that key. But
    nothing bound the PER-DEVICE bundle to it: `isTrustedIdentity` pins TOFU per Signal address
    `(peerId, deviceId)` and alarms only when a key CHANGES at an address already seen, so a
    peer's newly linked device is a fresh address and is trusted SILENTLY. A server that cannot
    forge the DAK-signed list can still serve any bundle it likes for a device the list
    legitimately names, which is precisely the capability the §2 matrix denies to S alone.
    Severity qualifier, established by the research and stated so it is not overclaimed: the
    §6.1 registration lock forces every STORED bundle of an account onto one identity key
    (verbatim in (xxxv)), so an HONEST server cannot serve a divergent one — this requires a
    COMPROMISED server. The check is therefore defence against server compromise, which §2
    already promises. Behaviour is FAIL CLOSED: a mismatch refuses the session and raises the
    identity alarm rather than encrypting to the key. Building-and-warning is rejected — a
    dismissible toast on a MITM is worse than a refusal the user can act on. The anchor MUST be
    read from the I7-verified list, NOT from `peerTofuIdentityBase64`'s hard-coded
    `(peerId, deviceId=1)` slot: ids are never reused and a post-§6.2 account has no device 1,
    so the fixed slot is empty exactly for the accounts that most recently survived a takeover.
    A first contact with a legitimately new device of a known peer is UNAFFECTED — the bundle
    carries the same account key, so the check passes silently.
  - **(xl) Binding the account identity key into the DAK-signed device list is the durable fix
    and is DEFERRED to its own ticket.** (xxxix) rests on a TOFU-acquired anchor; putting the
    account IK (or a commitment to it) inside the signed canonical bytes would make the binding
    verifiable offline from data the client already fetches, with no trust in the bundle at all.
    It is not folded into T9 because it changes the canonical bytes governed by (d) and needs a
    list-version migration on every enrolled account. (xxxix) is not a stopgap that (xl)
    discards — it stays as defence in depth.
  - **(xli) The §6.2 reset teardown MUST evict the superseded devices it revokes, and it runs
    where the socket server is already in scope.** `applyAfterReset` revokes the device rows and
    every refresh token in one transaction, but never emits `deviceRevoked` and never disconnects
    — while T6's `revokeDevice` does both. Both session gates are CONNECT-time only and
    `getServedMessageIds` is the sole per-event revocation re-check, so a superseded device
    holding ONE continuous socket keeps the whole remaining gateway surface after the ceremony
    whose purpose is to evict it. The eviction is a CALLER-side addition: `applyAfterReset` is
    invoked lazily from `handleUploadKeyBundle`, which already holds the socket.io `Server` and
    the revoked ids — the originally-alleged "runs from a cron with no server handle" is a FALSE
    PREMISE, refuted by (xxxii) and the call site. Eviction is best-effort POST-commit, matching
    T6: a failed kick must never roll back a committed teardown.
    **The companion claim that the teardown wrongly leaves the DAK-signed list alone is ALSO a
    FALSE PREMISE and is REJECTED.** Not touching `account_authorizations` is mandated by
    (f)(iii)/(xxix) — the recovering CLIENT republishes the list — and the reset probe already
    asserts that a test expecting the server to touch it would be asserting a spec violation.
  - **(xlii) A recovery phrase may only SHORTEN the reset delay once it has aged; enrolment is
    never silent; and replacing a phrase restarts its clock.** I4 says the recovery key shortens
    the delay but is never silent — yet the ENROLMENT that determines the delay was silent:
    `setRecoveryKey` needs only an authenticated socket, with no re-auth, no delay and no
    notification, and `requestReset` honours a brand-new phrase immediately with `shortened`.
    Framing correction from the research, because it decides the fix: the RESET itself is NOT
    silent (`identityResetPending` goes to the user room and to push on BOTH paths), so the
    defect is a silently SHRUNK window, not a missing alarm. And the actor is a password thief,
    who can already run the 72 h credentials-only reset — so password re-authentication does NOT
    defend this, and is rejected as the primary control. The load-bearing rule is a MINIMUM
    ENROLMENT AGE: a phrase minted after the compromise cannot buy the shortcut and is forced
    onto the full 72 h path, while a user who enrolled a key in advance — the case the feature
    exists for — still recovers fast. Enrolment MUST additionally notify every session and push
    endpoint, restoring I4's "never silent" to the step that actually sets the delay.
    Corollary, and a real trap the research caught: `setRecoveryKey` does NOT touch `createdAt`
    when REPLACING a phrase, so an age gate that reads it naively is bypassed by replacing onto
    an aged row. Replacement MUST reset the age clock.
  - **(xliii) A device roster is served only to a caller who may already message that account,
    with a narrow carve-out for decrypting history.** `getDeviceList` used the requester id only
    for an auth-presence check and then served any account's full signed roster — device count,
    platform, `addedAt`, `revokedAt`, plus enrolled-vs-not — to any authenticated caller, at 300
    requests / 15 min, on a repository public since 2026-08-18. That is a precise profiling
    oracle in an app whose premise is metadata minimisation. The predicate is the one the gateway
    already uses for "may A talk to B" (`validateCanMessage`: friends and not blocked either
    way); no new authorisation concept is introduced. The carve-out is REQUIRED, not a
    convenience: a client must still resolve the list of a peer who sent it a message and later
    unfriended or blocked it, or previously received history becomes permanently undecryptable —
    a fix that silently destroys readable history is worse than the leak it closes.
- **Amendment 2026-08-26 (T9 follow-up, settled with the fix and not before it — the gap was found
  by the T9 wire run, which is also what proved (xlii) was behaving correctly):**
  - **(xliv) A reset answer MUST say when a CORRECT phrase was too young to shorten the delay.**
    (xlii) is right to refuse the shortcut, but it refused it silently: `too_new` fell through to
    the same `{status:'pending', shortened:false}` an ordinary no-phrase reset returns, and the
    client reads only `shortened`. So the owner who did the responsible thing — enrolled a phrase,
    then lost the device two days later — types a phrase they know is correct and is shown the
    full 72 h with no explanation. The likely reading is "it was rejected", and the likely next
    action is to retype it, which walks a legitimate owner into the five-attempt lockout that
    (xlii)'s own gate left deliberately unspent. **This discloses nothing new.** Phrase
    correctness is ALREADY observable: a wrong phrase answers `invalid_phrase` while a correct one
    answers `pending`, so an attacker holding a candidate can distinguish them today without the
    flag. The verdict therefore buys the owner an explanation at no cost to the threat model
    (xlii) was written against. Scope is deliberately narrow: the verdict goes to the REQUESTER
    only, on `identityResetStatus`. The room-wide `identityResetPending` alarm keeps carrying the
    deadline and the cancel affordance and no phrase verdict — those sessions presented no phrase,
    and the alarm reaches devices the requester may not hold. It is transient by design and is
    NOT persisted on the ceremony row: it describes what just happened to a request, not the state
    of the ceremony, and a session that reconnects into a running ceremony needs the deadline and
    the cancel button, not a re-run of an explanation it already saw.
- **Amendment 2026-08-26 (T10, settled BEFORE the fix; the defect was found by auditing the
  residual list after (xliv) closed, and reproduced on the wire before a line was changed):**
  - **(xlv) A completed §6.2 reset MUST leave the account addressable — it does not today, in
    EITHER account shape, and the failure is permanent and bidirectional.** The teardown allocates
    a fresh device id ((a): ids are never reused) and revokes every other device, but nothing
    re-establishes the DAK-signed list that peers use to address the account. Two shapes, two
    failures, both reproduced against a real server:
    - **Previously enrolled.** The enrollment row survives by design ((xxix)), so peers are served
      a list that names the devices this teardown just REVOKED and omits the id it just allocated,
      signed by a DAK whose private half died with the lost devices. A peer that re-TOFUs the new
      identity cannot verify it at all — observed as `invalid_enrollment_signature` — and fails
      closed: it can never send to the account again.
    - **Never enrolled** (the majority shape — enrollment happens only when a second device is
      linked). No row exists, so the server answers `authorization: null`, which the client
      answers by SYNTHESIZING the single device 1 a non-enrolled account is supposed to have by
      construction. §6.2 breaks that construction. Peers then encrypt to a device that does not
      exist while refusing the one that does, and unlike the enrolled shape this is SILENT: the
      server accepts envelopes for any device id, so every message is lost in both directions with
      no error anywhere.
    Nine tickets missed this because the harness only ever reset accounts it had LINKED first —
    falsification 12 needs two partitions — so the never-enrolled reset, the common case, had
    never once been exercised.
    **Clause 1 — the recovering device MUST re-enroll.** This is the step (xxix) already reserved
    when it said the row is "REPLACED later, by a fresh IK-signed enrollment"; nothing implemented
    it, and `enrollDeviceAuthority` is emitted from exactly one place in the client, the link
    ceremony. The replacement mints a FRESH DAK, is signed by the new identity, and names only the
    freshly allocated id. The server already admits precisely this replacement and always has: an
    enrollment whose stored record no longer verifies under the account's current published
    identity is orphaned, and only an identity change can orphan it. The version it must carry
    rides the recovery ack as `nextListVersion`, because the client cannot read a row whose
    signature is orphaned and must not be made to guess — guessing 1 against a surviving row reads
    as a rollback attempt. Dictating that integer is ALMOST free of authority —
    the client still signs the list, and a server naming a STALE version merely
    gets the enrollment it wanted refused — but not entirely, and the first
    draft of this amendment overclaimed it. An INFLATED version is signed just
    as willingly, and because every later mutation must strictly exceed the
    stored version, a hostile server could freeze the account's device list for
    good by naming a number near the integer ceiling — a state that survives
    the server becoming honest again. The client cannot authenticate the number
    (the row it would check against is the orphaned one), so it applies a
    plausibility CEILING instead: versions advance once per device mutation, so
    no real account approaches it. It CANNOT live on the ceremony controller,
    which is registered by the devices screen: a recovery runs at login with no
    screen mounted.
    **The offer is REPEATED, not one-shot.** A re-enrollment that dies with a
    dropped socket or a killed app would otherwise leave the account
    un-addressable forever, since the teardown runs only on the upload that
    consumes the ceremony and nothing re-fires on a later launch — the exact
    "I lost my only device" user this amendment exists for. The server already
    detects that state (it is the same predicate clause 2 refuses on), so it
    re-offers the terms on EVERY authenticated key-bundle upload until the
    replacement lands. One predicate serves both clauses deliberately: a server
    that refused to serve a roster while telling nobody how to repair it would
    be a worse failure than the one being fixed.
    **Clause 2 — until it does, the server MUST NOT serve a roster that cannot
    receive.** When the answer would be `authorization: null` while the
    account's live devices exclude device 1, the roster is refused in silence,
    exactly as an entitlement refusal is — silence is fail-closed on the client
    (I5: "cannot verify", never "no devices"). This converts the dangerous
    silent shape into the survivable visible one for the window clause 1 cannot
    cover. An account with no live device at all keeps the historical answer, so
    the guard cannot invent a refusal for an unrelated empty roster.
- **Amendment 2026-08-26 (T11, ratified BEFORE the fix; the OTHER half of (xlv), found by
  re-reading the residual sweep once more after T10 shipped — the item had been marked closed):**
  - **(xlvi) The I7 anchor is a property of the peer ACCOUNT, not of their device 1.** (xlv)
    restored the LIST a §6.2 recovery leaves behind. It did not restore a peer's ability to CHECK
    that list. The chain is verified against "the identity key this device has accepted for that
    peer", and that value was read from a fixed `(peer, device 1)` address. §3 gives ONE identity
    key per account, shared to every linked device, so the device was never the right unit — the
    category error only became visible once §6.2 began producing accounts with **no device 1**,
    ids being never reused ((a)). For such a peer the lookup returned their PRE-reset key (if we
    had ever met device 1) or nothing, so the freshly re-enrolled list failed as
    `invalid_enrollment_signature` or `no_tofu_identity`. **Net effect before this amendment: (xlv)
    turned silent message loss into a fail-closed lockout, which is better and still broken.**
    **Clause 1 — pin the anchor per ACCOUNT.** One stored value per peer, written on the SAME
    acceptance path as the per-device row and never as a separate decision, so the anchor can only
    ever be a key this device already accepted. Last acceptance wins, which is exactly what lets it
    survive a peer replacing their entire device set. An install predating this keeps every anchor
    it had: a missing account pin falls back to the legacy `(peer, 1)` row and adopts it, because an
    upgrade that fail-closed every existing conversation at once would be far worse than the defect.
    **Clause 2 — first contact with an ADDRESS is not first contact with an ACCOUNT, and the gap
    used to swallow the alarm entirely.** A peer's reset arrives on a device id we have never seen,
    so the per-address TOFU rule read it as first contact and said NOTHING. That is precisely the
    event §6.2 promises to announce, and the same silence would cover a server introducing a device
    under an identity of its own choosing. The account pin makes it observable: a new address whose
    key differs from the accepted account key raises the existing identity-changed surface, while a
    new address carrying the SAME key stays quiet, because alarming on an ordinary link would train
    people to dismiss the one surface that detects a real takeover.
    Client-side only: no wire field, no migration, no change to DAK-signed bytes. **(xl) remains the
    durable end state** — binding the account identity into the signed list would make the anchor
    unguessable rather than merely account-scoped — but it changes (d)-governed canonical bytes and
    needs a list-version migration, and a recovery-breaking defect must not wait on that.
- **Amendment 2026-08-29 (D1/D2, ratified BEFORE the fix; found by following (xlvi)'s own
  acknowledgement path out the other side, and reproduced with real production objects in
  `frontend/test/providers/peer_reset_recovery_test.dart` before a line was changed):**
  - **(xlvii) An alarm the user cannot act on is not a warning, it is a dead end.** (xlv) restored
    the LIST a §6.2 recovery leaves behind and (xlvi) restored the ability to CHECK it, but the
    only action either one offers the user — acknowledging the identity change — **repaired nothing
    and destroyed the warning.** The three failures are independent and each is sufficient on its
    own, which is why this is one amendment and not three.
    **Clause 1 — acknowledgement MUST be atomic with adoption.** `acknowledgePeerIdentity` removed
    the peer from the alarm set FIRST and UNCONDITIONALLY, then discovered
    `promotePendingAccountIdentity` had nothing to promote and returned false. The anchor stayed
    stale, the warning was gone for good (it is the ONLY thing that clears it, and it is
    persisted), and the sole record was an `anchorAdvanced:false` diagnostic no user will ever
    read. The warning MUST survive an acknowledgement that did not advance the anchor.
    **Clause 2 — the user MUST be shown the key that adoption will pin.** The verify-security-keys
    dialog displayed the PINNED anchor while the confirm button promoted a DIFFERENT, never-displayed
    pending candidate: **the ceremony verified one number and adopted another.** For a legitimate
    rotation the displayed number cannot match what the peer reads out, so a careful user refuses a
    genuine change while a careless one accepts a key they never compared — the defence inverted.
    The offered key MUST be displayed, labelled, and beside the pinned one.
    **Clause 3 — recovery MUST NOT depend on a path that fail-closed.** For a peer who completed
    §6.2 the pending candidate is never written at all: the accept gate withholds their row before
    Signal runs, and the candidate's only writer is inside `isTrustedIdentity`. **(xlvi) clause 1
    SUCCEEDING is what makes this unreachable** — a peer who has NOT re-enrolled still sends a
    legacy row that takes the device-1 escape hatch, decrypts, and alarms correctly. The client MUST
    therefore be able to obtain the peer's currently-served account identity **on explicit user
    request**, show its fingerprint for out-of-band comparison, and pin it only on human
    confirmation. That served key is untrusted input and is never adopted implicitly; the human
    comparison is the entire defence, exactly as on first contact. Adoption MUST also drop the
    state the stale anchor poisoned — the cached device list and the peer's sessions — or the anchor
    advances while every send keeps failing.
    **Clause 4 — a per-device row lagging the human-accepted account anchor is not news.** Meeting
    a key that already EQUALS the accepted account anchor at some device address must not re-raise
    the alarm, or the adoption in clause 3 would re-alarm on the peer's very next message and train
    the user to dismiss the one surface that detects a real takeover.
    Client-side only: no wire field, no migration, no change to (d)-governed DAK-signed bytes.
    **(xl) remains the durable end state** and is untouched by this.
    **What clause 3 COSTS, stated plainly, because it is a real widening.** Before (xlvii) a server
    could raise the identity alarm but could NOT get a key adopted: with no candidate the
    acknowledgement was a no-op. Making recovery possible necessarily makes the ceremony
    server-summonable — `peerIdentityChanged` carries a userId the client does not contact-check,
    and "no candidate" is the default state for any peer who has not messaged recently, so a
    compromised server can put a key of its choosing in front of the user at a time of its
    choosing. **The defence is the out-of-band comparison and nothing else — exactly as on first
    contact, which has always been TOFU.** Three consequences are therefore load-bearing rather
    than cosmetic: the served key MUST be labelled as uncorroborated by any decrypted message; the
    copy MUST NOT invite a reflexive tap; and adoption MUST be restricted to a key this device
    actually recorded, so an invented key cannot reach the anchor even from a future caller.
    **Three residuals, recorded and NOT fixed here:** (a) the force-rebuild set is in memory only
    while the anchor advance is persisted, so adopting and then closing the app leaves the anchor
    advanced and the poisoned sessions intact until something else rebuilds them; (b) the persisted
    warning set keeps the 200 numerically HIGHEST peer ids rather than the most recent, and accepts
    warnings for non-contacts, so a server can evict a genuine warning across a restart — which
    matters more now that this warning is the sole door to recovery; (c) the device-list rollback
    pin is process-lifetime only. All three predate this amendment; (a) is newly load-bearing
    because of clause 3.
- **Amendment 2026-08-29 (D3, ratified BEFORE the fix; the owner asked whether the three residuals
  (xlvii) recorded needed attention, and reading them against source found all three real, none
  terminal, and the FIRST DRAFT OF THIS AMENDMENT OVERSTATED (a) — the correction is recorded below
  because a spec that exaggerates a risk trains the same dismissal a false alarm does):**
  - **(xlviii) A recovery the user has completed MUST survive a restart.** (xlvii) made a reset peer
    recoverable, but left the recovery's load-bearing state in memory while the part that CLOSES the
    door is persisted. Proven from source, not inferred: `_forceSessionRebuild` is a bare
    `Set<(int, int)>` (`encryption_provider.dart:52`), cleared on both disconnect (:1902) and login
    (:1936); adoption marks rebuild through it and nothing else (:2015 — deliberately NOT
    `deleteSession`, since that was removed for wiping archived ratchet states and turning in-flight
    messages into permanent Bad-MAC loss); `ensureSession` returns early on
    `hasSession && !needsRebuild` (:192); and the warning that is the SOLE door to the ceremony is
    removed and persisted the instant the anchor advances (`encryption_service.dart:334-335`).
    The composition is the defect, and no single line is wrong. **Confirm the ceremony, close the app
    before the next send to that peer, and the poisoned session is silently reused.** The blast
    radius is shape-dependent, and this is the part the first draft got wrong:
    - **Enrolled peer, post-§6.2 reset (the (xlv) shape): benign.** The teardown allocates a FRESH
      device id and ids are never reused ((a)), so after a restart the refetched list names a new
      address with no session at all; the poisoned record is orphaned and never addressed again.
    - **Non-enrolled peer (the common single-device shape): one lost message.** Such a peer is
      device 1 by construction (`VerifiedDeviceList.notEnrolled()`), so the address is stable and
      `hasSession(peer, 1)` is TRUE for the poisoned record. Our next send uses it, the peer cannot
      decrypt it, and they render `[Decryption failed]` on a plaintext that had one copy. Repair
      then arrives from THEM, not us: `messaging_provider.decrypt.dart:475-481` states the standing
      rule that "our own outbound session stays untouched — it either still works, or the peer sends
      US `sessionRebuildNeeded` (the one legitimate setter of the force-rebuild flag)", and their
      bad-MAC path (:1556) emits exactly that. **So the conversation self-heals after one destroyed
      message; it is not permanently broken, and the claim that it was is withdrawn.** What remains
      is a real cost paid by a user who did everything the ceremony asked, plus the fact that
      (xlvii)'s clause-4 suppression means they are never re-warned and never learn why.
    Three clauses:
    1. **The force-rebuild intent MUST be persisted per account**, written BEFORE the anchor
       advances and cleared only once a rebuild has actually happened. The ordering is the whole
       point: an ill-timed kill MUST leave a redundant rebuild, NEVER a cleared warning standing
       over a poisoned session. A redundant rebuild costs one pre-key fetch and one OTP; the other
       direction destroys a message that had exactly one copy, and hides the reason from both ends.
    2. **The persisted warning set MUST evict by INSERTION ORDER, not by numeric peer id**
       (`encryption_service.dart:501` sorts ints and keeps the tail — the 200 numerically HIGHEST
       ids), **and a server-sourced `peerIdentityChanged` MUST be ignored for a peer this device
       holds NO pinned account identity for** (the recorder added unconditionally, with no check on
       a userId the server chose freely). Otherwise ~200 forged events naming high userIds evict a
       genuine warning across a restart, and a malicious server both breaks a peer relationship AND
       deletes the repair path. Eviction is a quota, so it MUST drop the least recently warned peer —
       never the one with the smallest id, which is merely the OLDEST ACCOUNT and therefore the
       likeliest to be a real long-standing contact.
       **The anchor IS the contact check, and deliberately so:** no roster needs wiring into the
       crypto layer, because a peer this device holds no anchor for has no identity to have CHANGED —
       there is nothing for the ceremony to compare and nothing to repair — while every peer the
       alarm legitimately fires for is by construction one whose old key we pinned. Uncertainty
       (store not ready, storage error) MUST resolve to RECORDING the warning: losing a genuine
       safety notice is worse than keeping a spurious one, so this gate must never become a silent
       filter that fails closed against the user.
    3. **The device-list rollback pin MUST be persisted per account** (`device_list_cache.dart:111`
       is a bare `Map<int, int>`). Its own comment already argues rollback detection must survive
       cache invalidation; a process restart is a strictly stronger invalidation. After one, the
       client re-accepts any older validly-signed list — including one that re-admits a revoked
       device, or that downgrades a previously-enrolled peer to `authorization: null` in defiance of
       (xix).
    **Deliberately NOT fixed here:** persistence does not make recovery ATOMIC — the anchor advance
    and the poison drop remain separate writes, and clause 1 resolves that by choosing the redundant
    rebuild as the safe failure rather than by adding a transaction. And a contact check NARROWS the
    (xlvii) widening without closing it: a server can still summon the ceremony for any real contact,
    which remains governed by the out-of-band comparison and by (xl) as the durable end state.
- **Amendment 2026-08-29 (D4, ratified BEFORE the fix; found by a fresh security review of the
  (xlvii) ceremony, and it is the THIRD defect in this programme with one root cause — a slot that
  is read and then acted on while other writers can move it):**
  - **(xlix) Re-affirming the pinned key MUST NOT destroy a candidate that arrived after the
    fingerprint was displayed.** The compare-and-swap added for (xlvii) clause 2 closed the
    substitution path, but it has a bypass. `promotePendingAccountIdentity` returns false for two
    materially different reasons — NOTHING is staged, or a DIFFERENT key is staged — and
    `acknowledgePeerIdentity` conflates them: on any refusal it falls through to a re-affirmation
    branch (`encryption_service.dart:300-308`) which, when the confirmed key equals the current pin,
    calls `adoptAccountIdentity`. That method deletes the pending slot unconditionally
    (`signal_stores.dart:697`), and the caller then clears and persists the warning (:334-335).
    **The refusal the situation calls for already exists ten lines below (:314-321,
    `candidate_changed_since_display`) and is simply unreachable whenever the confirmed key happens
    to equal the pin.**
    The exploit needs a malicious server and no user error whatsoever. It summons the ceremony for
    contact P; the clause-3 probe the dialog itself emits tells the server the dialog is open right
    now; it answers with P's HONEST key, so `offerMatchesPin` holds and the out-of-band comparison
    SUCCEEDS; and while the user is reading the number aloud it delivers a ciphertext from a live
    device of P under a key of its own, which `isTrustedIdentity` writes into the candidate slot and
    the per-device row. The user's CORRECT confirmation then deletes the candidate, consumes the
    warning, and leaves the attacker's key in the `(P, device)` row — where (xlvii) clause 4
    guarantees it never alarms again, because the ACCOUNT anchor is honest. **A user who did
    everything right is the instrument that destroys the evidence.** Two clauses:
    1. **The re-affirmation branch MUST read the candidate slot BEFORE it decides.** A candidate
       that differs from the confirmed key means something wrote it after the display, which is
       exactly `candidate_changed_since_display` — refuse, leave the warning standing, and make the
       caller re-display. Re-affirmation is legitimate ONLY when the slot is empty or already holds
       the confirmed key.
    2. **`adoptAccountIdentity` MUST NOT drop a candidate it was not asked about.** The (xlvii)
       lesson was that "the pinned key is the key the human saw" has to be STRUCTURAL rather than a
       convention held by one call site; the same applies to destroying an alarm. It may clear the
       slot only when the slot holds the identity being adopted, so no unguarded mutator of that
       slot remains for a future caller to find.
    **Recorded, NOT fixed, and it needs a spec decision rather than a patch:** the human-verified
    account anchor is not passed to `buildSession` as the (xxxix) expected identity — the provider
    resolves that from the PER-DEVICE rows of the cached list and skips the device being built
    (`encryption_provider.dart:276-300`), so for a peer with ONE live device (every account that just
    completed §6.2) the candidate set is empty, the anchor is null, and the fail-closed gate at
    `encryption_service.dart:978-989` is vacuous on the first send after the ceremony. Passing the
    account anchor there would fail-close every legitimate account-wide rotation, which is the
    trade-off the comment at :293-296 deliberately took the other side of. **(xlvii) changes that
    calculus — a fail-closed peer now has a working door out — so the choice is reopened, but it is
    a spec call and it is NOT taken here.**
- **PRE-MERGE GATE ROUND (2026-08-29, three fresh reviewers on the full programme at `5c51bbd`).
  VERDICT: DO NOT MERGE. Six P1-class findings, four of them verified line-by-line by the lead
  against source. NONE of the six is fixed and NO amendment is ratified for them — each needs a
  spec ruling first, and several interact. Recorded here so they cannot be lost; numbering is
  deliberately the reviewers' ids, not amendment numerals, because they are not yet rulings.**
  - **RC-01 (P1, VERIFIED by the lead) — a peer who was OFFLINE during a §6.2 recovery is locked
    out permanently, silently, in both directions.** Four hops, each read in source: a device-list
    verification failure records a diagnostic and rethrows with no alarm
    (`encryption_provider.dart:423-428`); the accept gate withholds the recovering device's rows
    BEFORE Signal runs, because the escape hatch covers only `originDeviceId == 1`
    (`messaging_provider.decrypt.dart:146-162`), so `isTrustedIdentity` never records a candidate;
    `peerIdentityChanged` is a live room emit only (`chat-key-exchange.service.ts:439-441`), so an
    offline peer never learns; and BOTH (xlvii) doors are gated on the warning set that therefore
    stays empty (`encryption_service.dart:280`, `encryption_provider.dart:2041`). **This is the
    THIRD variant of the T10/T11 defect** — a completed reset leaving a conversation unreachable —
    differing only in which side was offline, and it contradicts I7 (:87-89). The comment at
    `decrypt.dart:142-145` reasons carefully about the OLD device 1 and never about the recovering
    device's NEW id >= 2.
    **Minimum fix, no wire change — and it MUST discriminate on `e.reason`, which the first draft of
    this entry did not say.** Raising the warning on EVERY `DeviceListVerificationException` would
    hand a malicious or merely broken server a way to permanently flag every contact as
    identity-changed by answering junk: that trades a silent lockout for a server-driven false alarm
    on the same I7 surface, and a surface that cries wolf is the one users learn to dismiss. The
    reasons are NOT interchangeable, so the gate is an ALLOW-LIST of exactly two — default-deny, so a
    reason code added later cannot silently start raising alarms:
    - `invalid_enrollment_signature` (`device_authority_engine.dart:365`) — the enrollment does not
      verify under the identity THIS device pinned. That is I7's "invalid chain" and it is precisely
      the post-§6.2 anchor mismatch RC-01 is about. **WARN.**
    - `version_rollback` (`device_authority_engine.dart:390`, `device_list_cache.dart:185`) — I7
      names rollback explicitly. **WARN.**
    - `invalid_list_signature` (:374) is NOT a warn: the enrollment verified under our pinned anchor,
      so the identity is RIGHT and only the inner DAK signature failed. Fail closed, as today.
    - `malformed_answer` (:354), `invalid_canonical` (:381), `user_mismatch` (:384),
      `version_mismatch` (:387) all mean "the server sent garbage", which is none of I7's three
      conditions and is not evidence about any peer's key. Fail closed, no alarm.
    - `no_tofu_identity` (`device_list_cache.dart:192`) is definitionally not an identity change: we
      hold no anchor, so there is no identity to have changed. It also subsumes the "only for a peer
      we hold a pinned anchor for" precondition.
    Note this is NOT in tension with (xlviii) clause 2's rule that uncertainty resolves toward
    WARNING. That rule governs OUR OWN uncertainty — a storage read we cannot complete — where the
    safe side is to warn. This governs the SERVER's assertion being unparseable, which is not
    evidence of an identity change at all. Different uncertainties, opposite safe sides.
  - **RC-02 (P1 adversarial / P2 as pure clock skew, VERIFIED) — dismissing the own-identity alarm
    arms a permanent suppressor from an UNVALIDATED server string.** `occurredAt` is accepted
    verbatim whenever it is a `String`; `dismissOwnIdentityReplaced` copies it into the persisted
    watermark (`encryption_service.dart:501`); `recordOwnIdentityReplacedFromServer` suppresses
    anything comparing `<=` it as a STRING (:460). The comment at :455-457 asserts "both sides are
    ISO-8601 UTC" and nothing enforces it. A server sends `occurredAt: '9999-...'`, the user taps
    the most natural button available, and the §6.0 offline-learn path is dead for that install
    while the alarm still looks healthy. Non-adversarial variant: `markOwnIdentityPublished` writes
    a DEVICE-clock watermark (+10 min) and compares it against SERVER stamps, so a fast clock
    suppresses genuine replacements for the skew. Fix: parse at the boundary, reject unparseable or
    far-future, compare instants not strings.
  - **F2 (P1, VERIFIED) — one server-chosen field destroys the primary's DAK private key.** ANY
    inbound `keyBundleUploaded` carrying integer `deviceId` + `nextListVersion` triggers
    `_reenrollAfterReset` with no latch and no proof a replacement is owed
    (`connection_provider.dart:934-944`). It mints a fresh DAK and `DakStore.persistArmed`
    OVERWRITES the existing record (`dak_store.dart:106`, keyed only by userId) and is awaited at
    `connection_provider.dart:877` — BEFORE `enrollDeviceAuthority` at :887. When the server then
    answers `already_enrolled`, nothing is restored: the real DAK private half is gone, every later
    `revokeDevice`/`provisionDevice` dies on `invalid_list_signature`, and the only exit is a 72 h
    §6.2 reset. `persistArmed`'s own docstring disciplines the write-before-emit ordering but never
    considers that the write destroys a still-valid key; `LinkCeremonyController` has the
    restore/clear discipline this path lacks.
  - **F3 (P1, VERIFIED) — after a §6.2 reset the orphaned roster is still SERVED, so a message is
    silently and permanently lost.** (xlv) clause 2's guard reads `!row && pendingReplacementVersion
    !== null` (`chat-device-list.service.ts:168`), so it covers only the NEVER-ENROLLED shape. For a
    previously-enrolled account the teardown leaves `account_authorizations` intact ((xxix)) and its
    stored `listCanonical` still names the pre-reset devices LIVE, so `row` exists, the guard is
    skipped, and a peer holding the pre-reset anchor verifies that dead roster successfully. Where
    the only live entry is device 1, `envelopeRefusal` exempts device 1 from the liveness check, the
    row commits with `encryptedContent = null`, and the recovering device reads `none_for_device`
    forever. Sender sees success; recipient never learns the message existed. `pendingReplacementVersion`
    ALREADY returns non-null for both shapes, so the fix is to drop the `!row &&` conjunct.
  - **F1 (P1, reviewer-reported, NOT independently verified by the lead) — a compromised LINKED
    device can seize the device-list authority and permanently disable revocation.** A linked device
    holds `ikPriv`; §6.1 accepts `sig_oldIK` as authorization for an identity replacement; the
    (xxix) replacement-enrollment branch then admits a fresh IK-signed enrollment whenever the
    stored one is ORPHANED, and a signature rotation orphans it exactly as a reset does. The primary
    is evicted from the signed roster with no `deviceRevoked` and can never revoke the intruder.
    Claimed to violate I2 and the §2 matrix row "Add/replace a device: L=no". Proposed fix: gate the
    replacement-enrollment admission on `authorizedBy === 'reset'`, which `upsertKeyBundle` already
    computes, rather than on mere orphaning.
  - **F4 — KA-02 CONFIRMED REAL, and BROADER than (xlix) recorded.** The (xxxix) expected-identity
    gate is vacuous not only on the first send after the ceremony but for EVERY cold cache (the list
    cache is memory-only) and EVERY single-live-device peer (`notEnrolled()` synthesises device 1
    alone), because `_accountIdentityAnchor` scans per-device rows excluding the device being built
    and `buildSession` no-ops on a null expected identity. So it is the DEFAULT state, not an edge
    case. Severity is below a silent MITM because `isTrustedIdentity` still alarms on the account
    anchor — but the plaintext is already encrypted to the attacker by then, which is the
    "build and warn" outcome (xxxix) rejected. The minimum safe fix has TWO halves and the second is
    load-bearing: fall back to the account anchor, AND make the refusal a first-class alarm (stage
    the offered key, add the peer to the warning set) so the (xlvii) door exists — otherwise the fix
    trades a MITM window for a lockout. **This is the spec call (xlix) deferred, and it is still not
    taken here.**
  - Also open, lower: **F5 (P2)** `AccountIdentityMismatch` — the one exception meaning "this is not
    this account's key" — is mapped to the catch-all "Recipient may not have encryption enabled",
    staging no candidate and raising no alarm, so the verify ceremony is unreachable (it is also the
    prerequisite for F4's fix). **F6 (P2)** the persisted rollback floor fails OPEN: a storage read
    error is indistinguishable from "never pinned", re-opening the rollback window, which is the
    opposite polarity to (xlviii) clause 2's own rule. **RC-03 (P2)** the (xlix) clause-1 candidate
    re-check is evaluated only against the PRE-await slot, and `adoptAccountIdentity` returns void so
    the caller cannot learn a candidate appeared during its storage write — the fourth instance of
    this programme's one root cause. **RC-04 (P2)** `ensureSession` consumes the in-memory rebuild
    flag on its first line and the durable intent is re-read ONLY at connect, so a rebuild that
    throws in-process leaves the poisoned session in use for the rest of the process. **F7/RC-06/
    RC-07 (P3)** `updateDeviceList` bypasses the §5.5 teardown; `regenerateIdentityAfterConfirmedLoss`
    clears peer warnings on inverted reasoning while leaving the anchors; `stagePendingAccountIdentity`
    remains an unguarded writer of the candidate slot (reviewer could construct no exploit).
  - **Fixed in this round (the only one):** RC-05 (P3) — `clearAll()` cleared nine fields and no
    ceremony state, so a pending countdown rendered over the NEXT account's session with a live
    cancel button, and the new 1-minute re-read kept running on a logged-out session because its
    stop condition IS that state. Fixed at `c405aaa`, falsified RED.
  - **Reviewer claim REJECTED by the lead:** that the wire harness does not run in CI. `ci.yml:207-252`
    boots `docker compose`, waits for backend health, and runs `flutter test test_e2e`; it was
    observed green this session. The reviewer inferred the risk without reading the workflow.
    **Reviewer claim UPHELD:** `RESET_PROBE` appears nowhere in `ci.yml`, so
    `identity_reset_teardown_test.dart` — the ONLY proof that a completed reset re-keys strictly
    within `(identity, deviceId)` (falsification 12) — is SKIPPED in CI. It is gated because
    `/auth/register` is 10/hr/IP shared by all of `test_e2e/` and the default run already spends it
    to the edge, so the fix is a SEPARATE job with its own compose stack (a fresh backend resets the
    in-memory bucket), never raising the production cap to fit a test.
- **Amendment 2026-08-29 (D5, ratified BEFORE the fix; from the pre-merge gate round, finding F3):**
  - **(l) A roster that CANNOT RECEIVE must be refused for every account shape, not only the
    never-enrolled one.** (xlv) clause 2 established the rule and its reasoning is unchanged: telling
    a peer to encrypt to a device that cannot receive is silent, permanent, bidirectional message
    loss, and silence is fail-closed on the client (I5), so refusing downgrades that loss to a
    visible send failure until the recovering device re-enrolls. The DEFECT is that the guard was
    written `!row && pendingReplacementVersion(userId) !== null`
    (`chat-device-list.service.ts:167-171`), and the `!row` conjunct silently restricts it to the
    account shape that has no enrollment row at all. A §6.2 teardown deliberately LEAVES the row
    ((xxix)) while stamping `devices.revokedAt`, so for every previously-enrolled account `row` is
    present, the guard is skipped, and the stored `listCanonical` — which still names the pre-reset
    devices as LIVE — is served. A peer holding the pre-reset TOFU anchor verifies that dead roster
    SUCCESSFULLY, because the enrollment was signed by exactly the key it pinned. Where the surviving
    list's only live entry is device 1, `envelopeRefusal` exempts device 1 from the liveness check,
    the row commits with `encryptedContent = null`, and the recovering device (a fresh id >= 2) reads
    `none_for_device` forever: the sender is shown a successful send and the recipient never learns
    the message existed.
    **The predicate already computes the right answer for both shapes** — `pendingReplacementVersion`
    returns `stored.listVersion + 1` whenever the stored enrollment no longer verifies under the
    account's currently published identity, and its own docstring (`device-list.service.ts:118-121`)
    names the "previously enrolled" case. So the ruling is simply: **drop the `!row &&` conjunct.**
    Refuse whenever a replacement is owed, for both shapes.
    **This also covers the §6.1 signature-authorized rotation, deliberately.** Such a rotation
    orphans the enrollment exactly as a reset does, and `purgeSupersededDevices` leaves the rotating
    device as the only published bundle — so the stored roster likewise names devices that can no
    longer receive, and refusing it is correct for the same reason. (Whether that rotation should be
    able to orphan an enrollment AT ALL is finding F1 and is NOT decided here.)

- **Amendment 2026-08-29 (D6, ratified BEFORE the fix; from the pre-merge gate round, finding RC-02):**
  - **(li) A server-supplied timestamp MUST NOT be able to arm a permanent alarm suppressor, and
    the self-publish suppression MUST NOT depend on the device clock.** Two defects share one field.
    1. **Validate and canonicalise at the boundary.** `occurredAt` was accepted verbatim whenever it
       was a `String`; `dismissOwnIdentityReplaced` copied it into the persisted watermark, and
       `recordOwnIdentityReplacedFromServer` suppresses anything comparing `<=` the watermark as a
       STRING. The comment asserted "both sides are ISO-8601 UTC" and nothing enforced it. So a
       server emits `occurredAt: '9999-01-01T…'`, the user taps the single most natural button on an
       alarm that reads like "you signed in on your laptop", and the §6.0 offline-learn path is dead
       for the life of that install while the alarm still looks healthy. Ruling: parse every
       server-supplied instant, reject what does not parse or sits absurdly far in the future, and
       store the CANONICAL UTC form so the ordering comparison is sound by construction rather than
       by assumption. On the LIVE event path an unparseable value must still raise the alarm — the
       event is the alarm and the timestamp is only metadata — using a locally generated instant, so
       garbage degrades to "we warn you, timed by our own clock" and never to silence. On the
       connect-time HYDRATION path an unparseable value is ignored, because that path exists purely
       to ORDER a past event against the watermark and an unorderable value cannot do that; a server
       withholding the field entirely already has that effect, so this grants it nothing.
    2. **Drop the device clock from the self-publish suppression.** `markOwnIdentityPublished` wrote
       a watermark of DEVICE-now + 10 min and that value was compared against SERVER-stamped
       instants, so a device whose clock runs fast suppresses every genuine replacement for the
       duration of the skew — the constant is named for skew but the comparison is what the skew
       breaks. The suppression exists for one narrow purpose: not alarming the user about the
       republish THEY just performed. That is a ONE-SHOT condition, not a time window. Ruling:
       record a persisted one-shot "our own publish is unacknowledged" flag, consumed by the first
       server report that would otherwise raise the alarm. It survives restart (a fresh install
       after a recovery is exactly when the false alarm fired), it involves no clock on either side,
       and it narrows the blind window from "ten minutes of reports" to "exactly one report" — which
       an unauthorized replacement still cannot reach, for the reason already recorded: the §6.1
       registration lock refuses a replacement that is neither signed nor spending a ceremony.

- **Amendment 2026-08-29 (D7, ratified BEFORE the fix; from the pre-merge gate round, finding RC-01
  — the THIRD variant of the T10/T11 defect):**
  - **(lii) A device list that fails to verify against the pinned anchor MUST raise the
    identity-changed surface, because I7 already says so and nothing implemented it.** The composed
    failure is recorded in full under RC-01 above; the short form is that after a §6.2 recovery the
    recovering device holds a FRESH id >= 2, a peer's list verification therefore fails against their
    stale anchor, and every path that could tell the peer is closed: the verification failure only
    records a diagnostic and rethrows, the accept gate withholds the recovering device's ciphertext
    BEFORE Signal runs (so `isTrustedIdentity` never stages a candidate), and `peerIdentityChanged`
    is a live room emit that an offline peer never receives. Both (xlvii) doors are gated on a
    warning set that consequently stays empty, so the conversation is dead in both directions with
    no explanation and no action available.
    **The ruling is to route that failure into the SAME recorder the server event uses**, which
    already carries the (xlviii) clause-2 anchor gate — a peer we hold no anchor for has no identity
    to have changed — and already dedupes and persists. No wire change, and it re-opens both doors.
    **It MUST discriminate on the reason, as an ALLOW-LIST of exactly two.** Raising on every failure
    would let a server permanently flag every contact as identity-changed by answering junk, trading
    a silent lockout for a server-driven false alarm on the same surface — and a surface that cries
    wolf is the one users learn to dismiss. The full classification of every reason code the
    exception can carry is recorded under RC-01; the two that qualify are
    `invalid_enrollment_signature` (the enrollment does not verify under the identity THIS device
    pinned — I7's "invalid chain", and precisely the post-recovery anchor mismatch) and
    `version_rollback` (I7 names rollback explicitly). An allow-list rather than a deny-list, so a
    reason code added later cannot silently begin raising alarms.
    **Only for a PEER's list.** Our own list failing to verify is not a statement about any peer's
    identity, and it has its own I7 own-skew path.
    The send still fails closed exactly as before — this adds the missing alarm, it does not make a
    broken list usable.
    **This SUPERSEDES an explicitly accepted residual, and the reversal needs stating.** The gate's
    silence was deliberate: `peer_reset_recovery_test.dart` argued that "this peer's list will not
    verify" is something a malicious or broken server can produce at will, so alarming on it would
    let the server manufacture identity warnings for any peer and train the user to dismiss the one
    surface that detects a real takeover. That reasoning is sound about alarm fatigue and it is
    still true that the two causes — a genuine rotation and a forged enrollment — CANNOT be told
    apart locally. Three things settle it the other way:
    1. RC-01 proves the alternative is not silence but a PERMANENT, unrecoverable lockout. Weighing
       a false alarm against an inconvenience was the wrong comparison; the real comparison is a
       false alarm against a conversation that is dead forever with no explanation.
    2. **In this state the send ALREADY fails.** The user is not being interrupted in a working
       conversation — they are already staring at "Could not verify this chat's devices", with no
       explanation and nothing to do. The alarm does not add noise; it names the condition and
       exposes the only exit. That materially changes the fatigue calculus the residual assumed.
    3. The widening is one the spec has ALREADY accepted. (xlviii) records that a contact check
       "NARROWS the (xlvii) widening without closing it: a server can still summon the ceremony for
       any real contact, which remains governed by the out-of-band comparison and by (xl) as the
       durable end state." A server forcing "verify keys with this contact" is exactly that
       already-accepted shape, and its resolution is the same: two humans comparing a number.
    What does NOT change: the local path still cannot STAGE a candidate, because the accept gate
    withholds the ciphertext before Signal runs. The repair therefore still goes through (xlvii)
    clause 3's served-key ceremony, which is why that mechanism remains load-bearing.

- **Amendment 2026-08-29 (D8, ratified BEFORE the fix; from the pre-merge gate round, finding F2):**
  - **(liii) Testing a replacement-enrollment offer MUST NOT destroy the authority the device
    already holds.** ANY inbound `keyBundleUploaded` carrying integer `deviceId` and
    `nextListVersion` triggered `_reenrollAfterReset` with no latch and no proof a replacement was
    owed. That path mints a fresh DAK and `DakStore.persistArmed` OVERWRITES the record in place —
    keyed only by userId — and is awaited BEFORE `enrollDeviceAuthority` is emitted. When the server
    then answers `already_enrolled`, nothing is restored: the account's real DAK private half is
    gone, every later `revokeDevice` and `provisionDevice` dies on `invalid_list_signature`, and the
    only exit is a 72 h §6.2 ceremony. `LinkCeremonyController` has exactly the clear-on-refusal
    discipline this path lacks, but clearing cannot help once the old record is already overwritten.
    **The client cannot authenticate the offer, and the fix must not pretend otherwise.** The row it
    would check the offer against is the orphaned one — the same reason the existing code defends the
    server-named `version` with a plausibility ceiling rather than a signature. So the ruling is not
    "prove the offer" but **"never spend a valid authority to test one"**:
    1. The new record is written to a SEPARATE PENDING slot, armed exactly as before, so the
       "callers MUST NOT emit until the write is proven" discipline is preserved and no accepted
       enrollment can be left unpersisted.
    2. It is PROMOTED to the live slot only after the server accepts.
    3. An explicit refusal CLEARS the pending slot, and the live record is untouched throughout.
    4. An ambiguous outcome — timeout, dropped socket — leaves the pending slot in place and the live
       record intact, which is the safe side: the worst case is a retry on the next offer, and the
       offer already rides every authenticated upload until it is taken.
    This also removes the need for a latch: an unlimited number of spurious offers now costs an
    unlimited number of refused enrollments and destroys nothing.
    **DELIBERATELY OUT OF SCOPE, and still unruled: whether an inbound `keyBundleUploaded` offer is
    GENUINE.** (liii) is an ordering ruling only — stage, emit, commit-or-restore — and it must not
    be read as having settled offer authenticity. The two questions were conflated in an earlier
    write-up of this finding, which described the fix as needing "a decision on how the client proves
    a re-enrollment offer is genuine"; that decision turned out to be unanswerable rather than
    pending, because the row the client would check the offer against is the orphaned one. So the
    ordering fix stands alone and needs no policy call.
    What remains, and is NOT decided here: an unauthenticated offer can still be replayed without
    limit. After (liii) that costs a mint plus a refused enrollment per offer and destroys nothing —
    which is why no latch was added — but it is unbounded work driven by a server-controlled field,
    and it is the same shape as the (a)-sanctioned allocator burn recorded under F8. If it is ever
    ruled on, the candidate mechanisms are a per-`(deviceId, version)` one-shot, or requiring the
    offer to arrive as the ANSWER to an upload this device actually made rather than as an unsolicited
    push. Both are cheap; neither is needed for correctness now.

- **Amendment 2026-08-30 (D9, ratified BEFORE the fix; from the pre-merge gate round, finding F1):**
  - **(liv) The §6.1 old-IK signature is NOT sufficient authorization for an identity change on an
    ENROLLED account.** §6.1 admits an identity replacement on either a signature by the PREVIOUS
    identity key or a completed §6.2 ceremony. That was sound in Phase 0b and multi-device
    DELIBERATELY FALSIFIED ITS PREMISE: the §5.1 link blob ships `ikPriv` to every linked device
    (`link_ceremony_controller.dart:460`), because a device must sign its own X3DH signed prekey
    under the account identity. So "holds `ikPriv`" no longer means "is the account's primary", and
    the signature path silently became available to every linked device.
    A compromised LINKED device therefore reaches, with no ceremony and no 72 h delay: mint a new
    IK → `authorizeIdentityChange` returns `'signature'` (`key-bundles.service.ts:311-319`) →
    `purgeSupersededDevices` wipes the primary's bundle (`:171`) → the primary can never republish,
    because it does not hold the new `ikPriv` and cannot sign a prekey under it → the stored
    enrollment no longer verifies (`device-list.service.ts:139-146`) → the replacement-enrollment
    branch admits the laptop's OWN DAK (`:243-290`) → every later list update from the primary dies
    on `invalid_list_signature` (`:351-360`). This violates the §2 matrix row "Add/replace a device:
    L=no" and invariant I2, and it is strictly worse than losing list authority: the ACCOUNT IDENTITY
    is now the attacker's, so peers encrypt to it and the primary cannot read its own mail. It is
    neither silent (the §6.0 takeover alarm fires on the primary) nor permanent (the 72 h ceremony
    remains an exit), which is why it ranks below a silent MITM.
    **The fix is at ADMISSION, not at the enrollment.** An earlier draft of this ruling constrained
    the replacement enrollment to the SAME `dakPub`, so that list authority stayed with the holder of
    `dakPriv`. That was rejected during review as protecting the wrong asset: it leaves the attacker
    holding the account identity, which is the actual prize, and revoking the laptop does not undo
    it. Gating the identity change instead makes every downstream hop unreachable.
    So: when an `account_authorizations` row EXISTS, the signature path is not consulted at all and
    ONLY `consumeCompletedReset` can authorize an identity change.
    1. A NON-enrolled account keeps §6.1 exactly as specified. There, the Phase 0b premise still
       holds — one device, one holder of `ikPriv` — so the path is still sound, and every Phase 0b
       wire test (`registration_lock_test`, `takeover_alarm_test`, `stale_otp_epoch_test`,
       `e2e_incident_regression_test`) exercises single-device accounts and is unaffected.
    2. No new column and no migration: enrollment is already a single row keyed by `userId`, and it
       is exactly the state the decision needs. Persisting `authorizedBy` was considered and is
       unnecessary once the gate moves to admission.
    3. Cost to a legitimate primary: an enrolled account must use the ceremony to rotate its IK.
       This is not a regression in practice — a primary that needs a NEW identity has lost its key
       material, which is precisely what §6.2 exists for, and the production client never used the
       signature path at all (no client code requests `getRegistrationLockNonce`; only the e2e
       harness does).
    4. The `IdentityChangeAuthorization` docstring's claim that "a signed rotation deliberately does
       NOT tear the roster down — the account still holds its other devices" stands for the
       non-enrolled case and is now unreachable for the enrolled one.
    5. **PROVEN BEHAVIOURALLY, not only by a mock** (`frontend/test_e2e/enrolled_identity_lock_test.dart`,
       added after the second gate round raised that the gate's only coverage was a mocked
       `authorizationRepo.findOne`). A mocked predicate proves the BRANCH but not the QUERY: it stays
       green if the gate is wired to the wrong table, if the partial `select` misbehaves against real
       TypeORM, or if the entity is missing from the DataSource — the last of which shipped in Phase
       0a and only the live harness caught it. The probe enrolls an account through the real engine
       and wire, then attempts a validly signed identity change and asserts `identity_locked` plus an
       unchanged `key_bundles` row, `dakPub`, `listVersion`, zero `identity_change_audit` rows, and a
       served bundle still carrying the original identity. FALSIFIED against a live Postgres:
       reopening the gate makes the server answer
       `{success: true, identityChanged: true, deviceId: 1, nextListVersion: 2}` — the attack landing
       AND the replacement-enrollment slot being offered, i.e. hops 2 through 6 of the F1 chain
       observed end to end rather than reasoned about. The non-enrolled positive control stayed green
       through the reversion, so the probe discriminates on enrollment and not on upload health.

- **Amendment 2026-08-30 (D10, ratified BEFORE the fix; from the pre-merge gate round, finding F5):**
  - **(lv) A refused session MUST leave the ceremony that repairs it REACHABLE.** The (xxxix) gate
    fails closed on an account-identity mismatch — correctly, and (lii) has since widened the same
    reasoning — but `_buildSessionSerialized` throws `AccountIdentityMismatch`
    (`encryption_service.dart:1261`) after staging NO candidate and raising NO alarm. The peer never
    enters `_peersWithChangedIdentity`, so no banner appears; `promotePendingAccountIdentity` has
    nothing to promote; and `_userFriendlySendError` maps the exception to the catch-all "Recipient
    may not have encryption enabled – ask them to open the app."
    (`messaging_provider.send.dart:1695-1720`). The user is told to ask the recipient to open an app
    they already have open, and the ONE door out — the out-of-band fingerprint comparison — is
    unreachable. This is the same defect class as (xlvii) clause 3 and RC-01: fail-closed is right,
    but a refusal with no surfaced alarm is indistinguishable from a permanent unexplained outage.
    So a refusal MUST, before it throws:
    1. STAGE the offered key as the pending account-identity candidate, so the adoption the ceremony
       performs promotes a candidate THIS DEVICE recorded — the structural property (xlvii) clause 3
       and `stagePendingAccountIdentity`'s own contract already require.
    2. Add the peer to `_peersWithChangedIdentity`, fire `onPeerIdentityChanged` and persist, so the
       banner and the verify action exist.
    3. Then throw, unchanged. Staging grants no trust: the pending slot is read only by the display
       and by an explicit human confirmation.
    **It MUST NOT route through `recordPeerIdentityChangedFromServer`.** That method's (xlviii)
    clause 2 guard drops any peer for which `getAccountIdentity` is null — which is exactly the state
    F4 is about — so reusing it would silently discard the alarm on the very path this amendment
    exists to light up, restoring the lockout under a different mechanism. The guard is there to
    filter ids a SERVER asserted with no local anchor; here the anchor is the thing that produced
    the refusal, so the condition it tests is already known true.
    `_userFriendlySendError` additionally gains a branch naming the security condition and pointing
    at the verify action, because a message the user cannot act on is why this went unnoticed.

- **Amendment 2026-08-30 (D11, ratified BEFORE the fix; from the pre-merge gate round, finding F4 /
  KA-02, and taking the spec call (xlix) explicitly deferred):**
  - **(lvi) The (xxxix) expected-identity gate MUST fall back to the ACCOUNT anchor, and a peer whose
    offered key cannot be matched to it is REFUSED.** (xlix) recorded this as narrower than it is.
    `_accountIdentityAnchor` (`encryption_provider.dart:283-299`) resolves the anchor by scanning
    per-device rows of the CACHED verified list, EXCLUDING the device being built, and `buildSession`
    no-ops on a null expected identity (`encryption_service.dart:1253-1254`). The candidate list is
    therefore empty — and the gate vacuous — in two states that are the DEFAULT, not the edge:
    1. **Any cold cache.** The verified-list cache is memory-only, so every first send after launch
       resolves no anchor at all.
    2. **Any single-live-device peer.** `VerifiedDeviceList.notEnrolled()` synthesises device 1
       alone, so the only candidate IS the device being built and is skipped. That is every
       non-enrolled account, i.e. most users.
    So the §3 account-wide identity binding — the whole defence against a server serving its own key
    for a device the DAK-signed list legitimately names — was unenforced for almost every send.
    **THE RULING IS FAIL CLOSED**, consistent with (xxxix), (xlvii) clause 3, (lii) and every other
    disposition in this programme: the per-device scan runs first, and when it yields nothing the
    anchor comes from `peerTofuIdentityBase64` (already ACCOUNT-scoped per (xlvi)). A mismatch is
    refused, exactly as it is today for a resolved anchor.
    **This is a real behaviour change and it is intended.** Before: a peer who reinstalled or rotated
    keys was reported by libsignal's same-address `onIdentityChanged` and the session BUILT anyway.
    After: the send is REFUSED until the human compares fingerprints out of band. That is the
    industry-standard shape (a changed safety number blocks sending until accepted) and it is the
    only disposition consistent with (xxxix)'s own argument that a dismissible banner over a live
    MITM is worse than a refusal, because the plaintext is already encrypted to the attacker by the
    time the banner is read.
    **(lv) IS A HARD PREREQUISITE, not a companion.** Without it this ruling trades a MITM window for
    a permanent lockout on the most common path in the app: the refusal would raise no banner, stage
    no candidate, and report "Recipient may not have encryption enabled". (lv) is what makes the
    refusal a first-class, recoverable alarm, and it MUST land first.
    The `skipDeviceId` exclusion is kept for the per-device scan, where its reasoning still holds — a
    rebuild must not compare an address to itself. It does NOT extend to the account anchor: on a
    legitimate account-wide rotation the account anchor holds the old key, so the offer is refused
    and surfaced rather than reported-and-built. That is the same trade as above, deliberately taken,
    and (xlvii) clause 3's served-key ceremony is the exit.

- **Amendment 2026-08-30 (D12, ratified BEFORE the fix; from the pre-merge gate round, finding F6):**
  - **(lvii) The persisted rollback floor MUST NOT fail OPEN.** `_loadDeviceListPins`
    (`encryption_service.dart:784-798`) wrapped its whole body in `catch (_) {}`, so a storage or
    decode failure was indistinguishable from "this device has never pinned anything". An empty floor
    is not a neutral state: `DeviceListCache.adopt` refuses a `not enrolled` answer for a peer ONLY
    when a pin exists (`device_list_cache.dart:183-186`), and shifts the rollback comparison off the
    pin (`:194-202`). With the floor silently empty, a server may re-serve an older validly-signed
    list — including one that re-admits a device the peer revoked — or collapse a previously enrolled
    peer to the synthesised single device. That is exactly the window (xix) refuses and (xlviii)
    clause 3 persisted the floor to close, reopened by the failure path.
    It also contradicts the SAME FILE's stated rule twelve lines below the call site: "A THROWING read
    propagates: a storage error must never be read as 'no keys'" (`:849-851`), which `initialize` is
    already built to honour — it throws `E2eIdentityIncompleteException` on the analogous condition.
    So a failed pin READ propagates out of `initialize`. A storage failure is not server-triggerable,
    which is why this ranks P2 rather than P1, but the disposition must still be fail-closed: a
    LOUD, retryable init failure is strictly better than a permanent, undetectable downgrade of the
    rollback defence. `raw == null` remains a genuine absence and stays silent — a device that never
    pinned anything has no floor to lose.
    The WRITE side stays non-throwing, and the reason is specific rather than tolerance:
    `recordDeviceListPin` serialises the ENTIRE map on every advance, so a transient write failure is
    repaired by the next successful advance, and `onPinAdvanced` is a `void` callback reached from
    inside verification — throwing there would convert a storage hiccup into a failed verification.
    It gains a diagnostic instead, because the failure was previously invisible.

- **Amendment 2026-08-30 (D13, ratified BEFORE the fix; from the pre-merge gate round, finding
  RC-03):**
  - **(lviii) A guarded write MUST REPORT whether its guard held.** (xlix) clause 1 reads the pending
    slot before considering a re-affirmation (`encryption_service.dart:313-317`) and (xlix) clause 2
    makes `adoptAccountIdentity` clear the candidate only when the slot still holds exactly what the
    caller was told (`signal_stores.dart:704-717`). Both are right, and together they still lose: the
    re-check is evaluated against the PRE-AWAIT slot, `adoptAccountIdentity` returns `void`, and its
    guard `return`s SILENTLY — so a candidate that appears during the storage write is correctly
    LEFT IN PLACE while the caller, learning nothing, sets `advanced = true`, drops the peer from
    `_peersWithChangedIdentity` and clears the persisted warning (`:357-360`). The evidence survives
    and the only door back to the ceremony does not, which is precisely the outcome (xlix) clause 2
    exists to prevent, reached through the gap between its own two clauses.
    **This is the FOURTH instance of this programme's single root cause** — a decision taken on state
    re-read after an `await` (T10, T11, RC-01, and this) — and it is the one where the check and the
    act were split across a file boundary, which is why three reviewers and two prior amendments
    passed over it.
    So `adoptAccountIdentity` returns whether the pending slot was EXACTLY as the caller expected,
    and the caller treats "not as expected" as `candidate_changed_since_display`: it returns false and
    leaves the warning standing. The anchor write itself is unaffected and needs no rollback — the
    re-affirmation path passes the ALREADY-PINNED key, so that write is idempotent.
    The `expectedPendingBase64 == null` case MUST also consult the slot. It previously returned before
    reading, and null means "the caller observed no candidate" — the exact state in which a candidate
    appearing under the dialog is invisible. Reporting it is the whole point; it still MUST NOT delete
    a candidate it was never told about ((xlix) clause 2).

- **Amendment 2026-08-30 (D14, ratified BEFORE the fix; from the pre-merge gate round, finding
  RC-04):**
  - **(lix) A consumed rebuild intent MUST be RESTORED when the rebuild fails.** `ensureSession`
    removes the address from the in-memory `_forceSessionRebuild` on its first line
    (`encryption_provider.dart:181`) so concurrent callers do not each rebuild — correct — and
    (xlviii) clause 1 keeps the DURABLE intent until a session really exists (`:260`). But the
    durable copy is re-read only at connect, so within one process a rebuild that THROWS between
    those points leaves `needsRebuild` false for every later call, `hasSession` true, and the early
    return at `:192` hands back the POISONED session for the rest of the process.
    A malicious server reaches it deterministically by never answering `fetchPreKeyBundle`: the fetch
    times out, the intent is gone, and the session the rebuild existed to replace is reused. It is
    also reached by the (lvi) refusal, which now throws on this path by design.
    The same file already names this exact hazard for a different map — "would leave the joiner with
    no session AND with its force-rebuild flag already consumed" (`:42-45`) — so the shape was known
    and only the failure branch was missed.
    So the consumption is scoped to the ATTEMPT: on any failure the in-memory intent is restored
    before the error propagates. Dedup is preserved, because the flag is absent exactly while an
    attempt is in flight. The durable intent needs no change — it was already correct, and it is
    what makes the NEXT process safe; (lix) is only about this one.

- **Amendment 2026-08-30 (D15, ratified BEFORE the fixes; from the SECOND pre-merge gate round, which
  reviewed (l)–(lix) themselves and found three P1s in them):**
  - **(lx) The replacement-owed refusal MUST live on the SEND path, not only on `getDeviceList`.**
    (l) is correct where it sits and sits on the door the send path never opens. `_resolveFanOut`
    deliberately does NOT fetch (`messaging_provider.send.dart:36-61`) — the memory-only cache is
    empty after every reload — so the first send of every session goes out in the LEGACY shape and is
    answered by the server's bounce, not by the guarded read. That bounce, `deviceListStale`, ships
    the account's FULL signed record — `dakPub`, `enrollmentSig`, `enrollmentCreatedAt`,
    `listCanonical`, `listSignature` — with no guard at all (`chat-message.service.ts:211-245`,
    emitted at `:362-378` and again on the edit path at `:1062-1078`). `pendingReplacementVersion` has
    exactly two production call sites, `chat-device-list.service.ts:168` and
    `chat-key-exchange.service.ts:328`; it is never consulted on the send path. So F3's loss is NOT
    closed: the peer verifies the orphaned roster under its PRE-RESET anchor — successfully, because
    that enrollment was signed by the very key it pinned, which is (l)'s own premise — adopts the dead
    roster, and re-sends into it. Where the surviving roster's only live entry is device 1 the
    envelope passes the liveness check (device 1 is exempt, `:183-191`), the row commits with a null
    ciphertext, and the recovering device reads `none_for_device` forever while the sender sees
    success.
    A SECOND, quieter variant needs no bounce at all: for a NEVER-enrolled account post-reset,
    `envelopeRefusal` is skipped entirely for a legacy send (`if (isNewModel)`, `:341`) and
    `staleLists` returns EMPTY because neither party has a row (`if (!auth) continue`, `:227`), so the
    send commits straight to the revoked device 1. That is the exact shape (xlv) clause 2 was written
    for, and the protection is never consulted.
    So the refusal moves to the write path: **before any persistence, and for BOTH send shapes, a send
    is REFUSED when either party owes a replacement enrollment.** Refusing both directions is
    deliberate — a recipient that owes one cannot receive, and a sender that owes one cannot be
    verified by the peer's accept gate, so both are silent loss. The window is short: the offer rides
    `keyBundleUploaded` on every authenticated upload and the client re-uploads on every connect.
  - **(lxi) The ACCOUNT anchor MUST WIN over a per-device row, reversing (lvi)'s scan order.** (lvi)
    kept the per-device scan first and used the account anchor only as a fallback. That is backwards,
    and the reason it was ordered that way is OBSOLETE rather than merely debatable: (xxxix) preferred
    the scan because `peerTofuIdentityBase64` was then a hardcoded `(peer, device 1)` slot, and
    (xlvi) has since made it ACCOUNT-scoped. Meanwhile the two sources have opposite trust
    properties. The account anchor moves ONLY on human acknowledgement
    (`promotePendingAccountIdentity`). A per-device row is overwritten unconditionally by
    `saveIdentity` from inside `isTrustedIdentity` (`signal_stores.dart:582`), which is TOFU and
    accepts any key an admitted inbound ciphertext presents. So the scan let a server-delivered
    ciphertext CHOOSE the expectation that the (lvi) gate then compares the served bundle against: the
    server poisons `(P, device 2)`'s row, triggers a rebuild of `(P, device 1)`, and the gate compares
    the served key to the attacker's own key and BUILDS. A banner stands, but the send is not refused
    — the precise disposition (xxxix) and (lvi) both reject in writing. It also contradicts
    `isTrustedIdentity`'s own stated principle three lines above the write: "a forged key can raise a
    VISIBLE alarm but can never quietly become the thing the I7 chain trusts."
    So: consult the account anchor FIRST; the per-device scan answers only when no account anchor
    exists. `skipDeviceId` continues to apply to the scan alone. A legitimate account-wide rotation
    now refuses and surfaces instead of silently building, which is (lvi)'s ruling applied
    consistently rather than a new trade.
  - **(lxii) A failed anchor READ is not "no anchor".** `peerTofuIdentityBase64` returns null both
    when nothing is stored and when the read THREW, and a null expectation is treated as genuine first
    contact and stays trusting. So one transient storage error silently restores the vacuous gate for
    that send. Its own comment says "fail closed at the caller", which is true for
    `DeviceListCache.adopt` (it raises `no_tofu_identity`) and false for this caller. This is the same
    polarity error (lvii) just ruled on for the persisted pin, and the same file already answers the
    analogous question the other way in `_hasPinnedAccountIdentity` ("uncertainty answers YES on
    purpose"). The anchor read used by the gate MUST distinguish the two and let a read failure
    propagate out of `ensureSession`, where (lix) already restores the rebuild intent and (lv) makes
    the failure visible.
  - **(lxiii) The (lv) staging MUST NOT clobber a genuine candidate.** (xlvii) clause 3 stages a
    served key only when the slot is empty, and says why: the slot is the evidence a human will
    compare. (lv)'s refusal path stages UNCONDITIONALLY, so a candidate recorded from a real inbound
    ciphertext is overwritten by a key the server just served — the "candidate moves under the open
    dialog" shape (xlix) clause 2 and (lviii) spent two amendments preserving, reached from the writer
    side. It also hands a hostile server a durable ceremony DoS: vary the served key on every
    `fetchPreKeyBundle` and every confirmation loses its compare-and-swap, so the warning never
    clears and the only door out of the (lvi) refusal stays shut. Fail-closed, so P2, but it defeats
    the mechanism (lv) exists to guarantee. The staging takes the same guard as (xlvii) clause 3:
    write only when the slot is EMPTY or already holds exactly this key.
    **RESIDUALS from the second gate round, ACCEPTED and NOT fixed here.** All P3 except the last,
    all recorded so a later reader does not have to rediscover them:
    1. **A read→delete window survives inside the pending slot.** (lviii) moved the race from
       (write + read) to (read + delete): `adoptAccountIdentity` reads the slot and then deletes
       unconditionally, and `promotePendingAccountIdentity` has the same shape. A candidate staged
       between those two awaits — by `isTrustedIdentity` on a concurrent decrypt, or by the (lv)
       refusal on a concurrent send — is destroyed while success is reported. Two awaits wide and not
       attacker-timeable. The real fix is a compare-and-delete primitive on the slot; it is the FIFTH
       instance of this programme's one root cause and the honest statement is that the pattern needs
       a primitive, not a fifth hand-rolled guard.
    2. **(li)'s plausibility ceiling is one day, not zero.** `occurredAt = now + 23 h` parses and is
       stored canonically, so one crafted event plus the user's natural dismissal buys ~24 h of
       suppressed CONNECT-TIME (offline-learn) reports. The live event path is unaffected. Bounded
       rather than permanent, which is what (li) required, but the amendment's text does not quantify
       it.
    3. **(li) clause 2's one-shot can be HELD by a server.** It is armed only by our own publish ack,
       so a server cannot arm it — but by withholding `identityReplacedAt` a server leaves it armed
       and spends it on a later, genuine report. Materially bounded by (liv): an enrolled account's
       identity can now only move through a ceremony that broadcasts 1–72 h earlier.
    4. **`invalid_list_signature` has no user-visible surface.** (lii) correctly excludes it from the
       I7 alarm, but the plain send path never fetches the list, so the condition lands on the
       catch-all "Recipient may not have encryption enabled". Wrong copy for a chain failure.
    5. **(l) also withholds the account's OWN roster**, and `refreshDeviceList` has no timeout, so the
       devices screen spins indefinitely while a replacement is owed. Recovery is unaffected — the
       offer rides `keyBundleUploaded`, never the list read — so this is cosmetic, but it is a mute
       fail-closed state.
    6. **(liv) leaves an enrolled account no fast rotation after a linked-device compromise.** §5.5
       revocation is logout semantics and does not rotate the account IK, so a compromised linked
       device keeps a copy of `ikPriv`, and any session may cancel a ceremony (keyless by §6.2
       design) and arm a 24 h cooldown. Mitigation is immediate and adequate: REVOKE the device
       first, then start the ceremony. Worth one line of operator guidance in §6.2.
    7. **P2, PRE-EXISTING, and the one to fix first after merge:** the reset cooldown, the
       password-change carve-out and the completed-grant TTL are asserted only by inspecting a MOCKED
       query builder's `innerJoin`/`andWhere` calls
       (`backend/src/key-bundles/identity-reset.service.spec.ts:249-274`, `:621-649`), and the author
       disclaims behavioural proof in-line. An inverted WHERE carrying the same parameter stays
       green. The §6.2 ceremony is now the ONLY authorization for an enrolled account's identity
       change ((liv)), so it carries more weight than when those tests were written.

- **Amendment 2026-08-30 (D16, ratified by the owner BEFORE the fix; from the bounded merge-gate
  review — one question, "can a normal user with an honest server lose a message, lose access, or
  get permanently stuck", three fresh reviewers, one BLOCKING finding):**
  - **(lxiv) A key-bundle namespace belongs to the INSTALL that minted its material, and both tiers
    MUST enforce it.** The finding (GATE2-REVOKED-DEVICE-RELOGIN-CLOBBER): a revoked linked device
    that signs back in with the password — which `deviceRevokedNotice` explicitly invites — is
    resolved by `resolveLoginDeviceId` onto the LIVE PRIMARY's device id ((xxii) built that door
    while fixing the post-reset login lockout). The revoked device still holds the shared account
    `ikPriv` (§5.1) plus its OWN locally minted signedPreKey/registrationId/OTPs, its Signal
    material deliberately survives logout, its own device id is memory-only, and the client
    re-uploads its bundle on EVERY connect. So the upload passes both §5.5 session gates (session
    device id = live primary), carries the unchanged account identity (`identityChanged=false` — no
    registration lock, no audit row, no alarm, no OTP purge) and silently UPSERTS the revoked
    install's signedPreKey over the primary's row, while the served one-time-pre-key pool remains
    the primary's. A peer's X3DH then needs private halves held by two different installs; no
    device holds both, so every first message built on the mixed bundle is permanently
    undecryptable while the sender sees it delivered. Normal taps, honest server — exactly the
    merge-gate class. Ruling, two clauses:
    1. **Server: a bundle row's `registrationId` MUST NOT change while its `identityPublicKey` is
       unchanged.** Identity and registrationId are minted together, once, in every mint path
       (initial generation, §5.1 adoption, consented regeneration), so "same identity, different
       registrationId, same `(userId, deviceId)` row" is by construction a DIFFERENT physical
       install writing into a namespace it does not own. `upsertKeyBundle` refuses it before any
       write; the WS answer is `keyBundleUploaded { success:false, error:'device_material_conflict' }`.
       A same-install re-upload (same registrationId) and every identity-changing path (which the
       (liv)/§6.1 machinery already adjudicates) are untouched. The bundle guard alone does NOT
       close the loss (caught in review of this very amendment's first draft): the OTP
       replenishment path bypasses `upsertKeyBundle` and a foreign install sharing the account
       identity could still deposit ITS one-time pre-keys into the owner's pool, mixing the halves
       from the other side. So `uploadOneTimePreKeys` takes an OPTIONAL `registrationId` install
       proof — refused on mismatch with the caller's own row, accepted when absent (a pre-(lxiv)
       client predates device linking, so the foreign-install shape cannot exist for it; new
       clients always send it). Together the two guards close the loss server-side for every
       client shape. **Scope, recorded so nobody overstates it later: the served bundle exposes
       `registrationId` to any authenticated fetcher, so clause 1 is a CORRECTNESS gate against the
       honest-but-displaced install (the real client always quotes its OWN minted value), not an
       authorization control — a MODIFIED client already holding the account password could quote
       the primary's value, but that adversary can already run the §6.2 reset outright and is
       outside this gate's threat model.**
    2. **Client: the install stamps which device id its material was provisioned for, and refuses
       E2E duty when the session disagrees.** One durable stamp per account
       (`e2e_<uid>_material_device_v1`), moved by a single uniform rule: **every authorized
       re-homing of the material clears the stamp, and the next server-confirmed own-device id
       TOFU-stamps it.** The clearers are the two mint paths (fresh generation and consented
       regeneration), the §5.1 adoption (inline with the mint it performs), and the §6.2 rebind
       adoption (cleared BEFORE the reconnect, so the recovering device re-stamps its freshly
       allocated id instead of tripping the gate). The TOFU write covers fresh accounts and every
       pre-Phase-1 install. A contradiction is therefore only reachable by material that survived
       a session-identity change it was never re-homed for — the revoked device signing back in.
       On contradiction the client does not publish keys, does not join E2E flows
       (`isE2EReady` stays false, which every send/decrypt path already consults), records
       `E2E_DEVICE_MISMATCH`, and surfaces "this device was removed — link it again" routing to
       the §5.1 ceremony — replacing the standing invitation to keep chatting. A storage READ
       failure fails OPEN (a flaky read must not take a healthy device out of duty; clause 1
       still refuses a genuinely foreign write). **The `rebind_failed` shape (§5.1 adoption
       committed, session still bound to the primary id) is NOT caught by this clause** — the
       adoption cleared the stamp, so the next confirm TOFU-stamps the primary id under the
       adopted material; there the server-side clause 1 is the guard that refuses the clobbering
       write, and the failure state already has its own error surface.
    8. *(appended to the (lxiii) residual list, RECORDED and NOT fixed — **the latch half is CLOSED
       by (lxxxv), 2026-09-17, which also corrects the price below: the two passes destroy each
       other's ack channel, so NEITHER promotes**)* **`_reenrollAfterReset` has
       no in-flight latch** — the rebind path and the every-upload owed-offer listener can run it
       concurrently; both share one `_resetEnrollAck` completer and one pending-DAK slot, and
       `promotePending` promotes whatever the slot holds, unbound to the enrollment the server
       accepted. Worst case (narrow, not attacker-timeable under an honest server): the server pins
       DAK A while the client arms DAK B — device authority stranded until another §6.2 ceremony,
       no message or access loss. The SIXTH instance of the programme's one root cause, this time
       on the DAK slot; the honest fix remains the compare-and-delete/compare-and-promote primitive
       residual 1 already calls for.

- **Amendment 2026-08-31 (D17, ratified by the owner BEFORE the fix; from the live two-device QA
  session — Android emulator primary + real-browser web install driving §5.1, §5.5 and the (lxiv)
  relogin end-to-end):**
  - **(lxv) The (lxiv) recovery MUST be COMPLETABLE: a mismatched install re-entering the §5.1
    ceremony disposes its stale Signal material inline with the adoption.** Live QA proved the
    promised recovery dead-ended twice on the same hidden assumption — that only a KEYLESS install
    ever runs the device-side flow. A revoked install that signs back in is not keyless: its dead
    identity survived logout by design. First dead end: `devices_screen.dart` gated the
    device-side CTA on `identityIncomplete` alone, so exactly the install the (lxiv) banner routes
    here was offered the PRIMARY-side flow it can never complete (it holds no DAK; fail-closed
    `no_dak`). The gate is now `identityIncomplete OR deviceMaterialMismatch`. Second dead end,
    one step deeper: `adoptProvisionedIdentity`'s T3 invariant lock ("refuse when the device
    already holds ANY identity") aborted the SAS-confirmed re-link with `adopt_failed`. The lock
    stays — its carve-out is exactly ONE shape: the ceremony passes `disposeStaleMaterial: true`
    only when the provider is in the (lxiv) mismatch state, read live at blob time; the service
    then wipes the stale Signal material (identity, sessions, pre-keys, signed pre-keys, peer
    trust — the same suffix family the consented-loss regeneration wipes, now one shared
    primitive) and adopts atomically after. Ordering law: the wipe runs AFTER the blob is
    MAC-verified, decrypted, user-matched and fully parsed — a malformed blob must fail before
    the wipe, or it would strand the install keyless without the adopt that justified the
    disposal. Consent law: the SAS confirmation plus authenticated blob IS the user's consent to
    dispose material that provably cannot serve this session (stamped for a revoked device id);
    the content store is untouched — sealed history lives under independent content keys, so the
    §5.5 revoke dialog's "messages stay" promise holds. Non-goals, recorded: the disposal is NOT
    reachable outside a ceremony (the flag defaults false everywhere, including the historical
    controller constructor shape), and `rebind_failed` after a (lxv) disposal is no worse than
    after a keyless link — the adopted identity is committed and clause 1 of (lxiv) still guards
    the server rows.

- **Amendment 2026-09-02 (D18, ratified by the owner BEFORE the fix; from the second live
  two-device QA — Android emulator primary (device 1) + real-browser web install, which proved
  (lxv) end to end (mismatch banner → device-side CTA → re-link → `LINK_STALE_MATERIAL_DISPOSED`
  → `LINK_IDENTITY_ADOPTED` → device 3, device 1's bundle byte-untouched) and then found two
  defects on the same path that no amendment covered):**
  - **(lxvi) clause 1 — a remote session end MUST leave the auth surface on top.** §5.5's
    `deviceRevoked` arrives while the user may be anywhere; the client's `AuthGate` swaps its OWN
    subtree to the sign-in screen, but any route pushed above it on the root navigator (the open
    chat, the devices screen) survives the swap and keeps rendering over it against providers that
    were just cleared — observed twice as a blank grey page with an EMPTY semantics tree and no
    thrown error. The (lxiv) notice ("sign in and link this device again") was therefore invisible
    at the only moment it is shown; a reload reaches the sign-in screen but the notice is in-memory
    and lost. Rule: on the logged-in → logged-out transition `AuthGate` pops the root navigator to
    its first route, in the same post-frame step that disconnects the socket. Pre-existing
    mechanism (any provider-driven logout — `refresh_invalid`, expiry — had the same shape), new
    reachability: `deviceRevoked` is the first logout the SERVER initiates at an arbitrary moment.
  - **(lxvi) clause 2 — local plaintext outranks the `none_for_device` marker.** The (lxv) text
    claimed the §5.5 "messages stay" promise holds because the content store is untouched. In
    STORAGE it holds; in DISPLAY it did not: after a (lxv) re-link the install is a NEW device id,
    the history read answers `none_for_device` for every row that predates it, and the client
    stamped the "sent before this device was linked" placeholder at ingestion — over rows THIS
    install had already decrypted and sealed under its previous id. The stamped row carries no
    ciphertext, `needsDecryption` is false, and `_hasUsableDecryptedContent` counted the sentinel
    as usable, so the hydration pass never consulted the persisted copy. Rule: the sentinel is a
    placeholder, never usable content; the snapshot hydration consults the local sealed plaintext
    for such rows and upgrades them, and the placeholder is what remains ONLY when nothing local
    exists — which is the honest (viii) meaning. No decrypt is attempted (there is no ciphertext),
    no retry path is armed (every retry predicate is gated on `needsDecryption`), and a genuinely
    pre-link row is unchanged. The (lxv) "messages stay" sentence now holds in both senses.
  - **(lxvi) clause 3 — every way off a ceremony screen cancels the ceremony.** Both §5.1 screens
    cancelled only from their own app-bar arrow (`cancelPrimary` / `abortNewDevice`); the
    system back — Android gesture or hardware back, browser back — popped the route and left the
    ceremony running. Observed as the primary's screen reopening in the previous ceremony's `done`
    state (a second link in one sitting was impossible); the worse shape follows from the same
    code: a new device that backs out mid-SAS leaves a live stage the primary can still approve,
    and the identity is adopted behind a screen nobody is looking at — the I1 abort hygiene that
    falsification 18 pins for every FAILURE path, skipped for the one path the user takes on
    purpose. Rule: the cancel/abort hangs off the route's pop (`PopScope`), so the arrow, the
    gesture and the browser all take the same exit. Idempotent by construction: a `done` primary
    only resets local state (no `cancelProvisioning` for a consumed stage), and the new-device
    abort is skipped in `done`/`aborted`/`idle` exactly as the arrow already did.

- **Amendment 2026-09-02 (D19, owner's blanket "achieve perfection" authorization; from the
  keyless-second-install probe the (lxvi) session left as its open question — does "start fresh"
  on an unlinked install clobber the primary's `key_bundles` row?):** it does NOT (the (0b) lock
  refused: `KEY_BUNDLE_IDENTITY_LOCKED`, `OTP_UPLOAD_DROPPED`, device 1's row and pool
  byte-untouched, zero audit rows). What it does instead is close every non-destructive exit on
  the CLIENT. Observed on a fresh browser context signed in as an enrolled account: the only
  offered door was "start fresh"; one tap and a confirm later the install held a fresh identity
  the account will never publish, the devices screen's link CTA was gone (its gate was
  `identityIncomplete`, which the regeneration clears), the devices screen showed only the red
  chain-invalid line, and the sole remaining action was a 72 h reset that REVOKES the phone. A
  second-device user — the population §1 exists for — is routed at the destructive door first and
  then locked out of the safe one by taking it.
  - **(lxvii) clause 1 — the keyless banner leads with the link.** A keyless install of an
    account whose server bundle exists (`IDENTITY_GUARD_SERVER_BUNDLE_EXISTS`) is, first, a
    second device; "the usual device lost its keys" is the rarer shape and its remedy is
    destructive. Rule: the banner's always-visible action routes to the devices screen (the
    §5.1 device-side flow, exactly as the (lxiv) mismatch banner does), and "start fresh" moves
    into the banner's disclosure as a secondary action — still reachable in two taps, still
    behind its confirm dialog, no longer the thing a thumb lands on. The body copy names both
    shapes in that order. For an account that never enabled linking the link door still tells
    the truth: the ceremony is opened from the device that holds the keys, and that screen
    offers "enable linking" first.
  - **(lxvii) clause 2 — an identity the lock refused is stale material.** The (lxv) carve-out
    admitted exactly one shape of existing identity to the ceremony's disposal: material stamped
    for a revoked device id. A refused regeneration is the same fact reached from the other side
    — the server has said, durably, that this identity will never serve this session — so it is
    admitted as the second and last shape. Rule: the devices screen offers the device-side CTA
    while `identityIncomplete || deviceMaterialMismatch || identityUploadLocked`, the ceremony's
    `disposeStaleMaterial` is authorized while `deviceMaterialMismatch || identityUploadLocked`
    (both read live at blob time, both predicates owned by the provider so a third caller cannot
    drift), and the locked banner gains the same link door as clause 1, with "start reset"
    demoted to its disclosure. The (lxv) ordering and consent laws apply unchanged: wipe only
    after the blob is verified, decrypted, user-matched and parsed; the SAS plus authenticated
    blob is the consent; the content store is untouched. The lock flag clears where it always
    did — on the successful same-identity re-upload the post-rebind reconnect performs.
  - Non-goal, recorded: a locked install can still SEND with its unpublished identity (nothing
    gates the send path on `identityUploadLocked`); peers see a TOFU identity-change pill and the
    message decrypts. Pre-programme behaviour, unchanged here.

- **Amendment 2026-09-02 (D20, same authorization; the (lxvii) live re-verification — locked web
  install → link door → ceremony → `LINK_STALE_MATERIAL_DISPOSED` → `LINK_IDENTITY_ADOPTED` →
  device 6, device 1 untouched — then walked the devices screen and confirmed three of the
  residuals the (lxvi) session had only noted):**
  - **(lxviii) clause 1 — the devices screen re-reads the list when its own ceremony completes.**
    `refreshDeviceList()` ran only in the screen's `initState`. After a device-side ceremony the
    screen underneath the ceremony route still showed the pre-ceremony `chainInvalid` line and
    the keyless CTA — for an install that had JUST been told "linked and ready" — and only a
    re-entry showed the verified list with this device on it. The `deviceListChanged` broadcast
    cannot be relied on here: it lands while the install is between sockets (rebind →
    disconnect → reconnect). Rule: the controller re-requests the list itself once the rebind
    reaches `done`, after the reconnect. **Second half, found when the first was re-verified
    live:** the list refresh alone left the screen keyless for ~20 s, because the provider's
    init success path flips `identityIncomplete` and `isE2EReady` and NEVER notifies — every
    watcher (the shell banner, the devices screen) repainted only on the next unrelated notify.
    Rule: a successful init notifies. Pinned by a test in the exact live shape (keyless init →
    adopt → reconnect init → a notification observed with both flags healthy).
  - **(lxviii) clause 2 — only the DAK holder is offered the primary flow.** The enrolled branch
    offered "link a device" on every enrolled install, so a linked device was invited into a
    flow that fails closed with `linkNoDak` only after the user typed a code from a third device.
    "Primary" is read from the one fact that defines it (§5.5: the primary is the only DAK
    holder), not from `deviceId == 1` — the revoke gate's own note admits device 1 stops being
    true after a §6.2 reset. Rule: the controller resolves DAK presence on every list refresh;
    the screen offers the primary CTA only when it is present, and a linked device gets one
    line saying new devices are added from the primary. The explainer no longer says "this"
    device is the primary.
  - **(lxviii) clause 3 — a keyless install is not shown a chain failure.** The list verifies
    against this install's own identity; with none (or with an identity the lock refused) the
    chain cannot verify, and the screen rendered that as the red `devicesChainInvalid` line
    directly above "this device holds no keys yet — link it". Two explanations for one state,
    one of them alarming and neither actionable beyond the CTA. Rule: while the device-side
    flow is what the screen offers, the list section is empty; the keyless text and the CTA are
    the whole message. The verification result itself is unchanged (still `chainInvalid`, still
    `no_local_identity`) — this is presentation, and the fresh-identity re-verification of
    clause 1 is what turns it into a list.
- **Amendment 2026-09-02 (D21, owner-directed on the (lxviii) screenshot; client-only):**
  - **(lxix) — the devices screen collapses revoked tombstones.** §3 makes revoked rows permanent
    in the DAK-signed bytes (`revokedAt?` on the entry) and (a) never reuses an id, so a device
    that is revoked and re-linked leaves a struck-through row behind forever: twenty revokes are
    twenty tombstones ordered by id ABOVE the newest live device. The tombstone earns its place
    only briefly — it is the user's confirmation that the revoke took. Rule (presentation only;
    the canonical bytes, the version discipline and the peer-side "absent OR revoked fails
    closed" check of (e)/(xxvii) are untouched, and the signed list is NOT pruned — pruning changes
    (d)-governed bytes and needs a list-version migration for no security gain): live rows lead
    in id order; revoked rows collapse behind a single counted disclosure
    (`devicesRevokedSection`, "Cofnięte urządzenia (N)") rendered after the last live row,
    absent when there are none, collapsed on every visit. Falsified two-way: flat rendering →
    `Found 1 widget with key device-row-2`; tombstones-first ordering → `Expected: less than
    <196.0> / Actual: <316.0>`.
    Two refinements from review: (1) a revoke that LEFT the device (no `no_dak`/`sign_failed`)
    OPENS the section once `revokeDevice` returns, because the tombstone is the user's
    confirmation that the revoke took and a collapsed section would make the row simply vanish;
    the server's answer lands later and is not gated (falsified both ways: `Found 0 widgets with
    key device-row-2` on success, `Found 1 widget` on a refused revoke); (2) the ARB `one` branch
    is grammatical ("Cofnięte urządzenie (1)" / "Revoked device (1)"). Live on the primary, on the
    shipped gated code: re-linked web `#4`, revoked it → the section opened itself, `#4` struck
    under `#2`/`#3`, "Cofnięte urządzenia (3)".

- **Amendment 2026-09-02 (D22, owner-directed from the FIRST REAL LINK on prod 0.2.0 — the owner's
  PWA primary + a desktop browser; the ceremony worked, and two things around it did not):**
  - **(lxx) clause 1 — the QR is a deep link.** The QR encoded the bare `fp-link.v1.…` string, and the
    primary has no in-app scanner, so a phone camera offered a web search. Rule: the QR carries
    `<app origin>/link#<code>` — the code in the URL FRAGMENT, which a browser never includes in any
    request, so amendment (c) ("ephPubN never transits the server") holds byte for byte and nginx
    logs see `/link` alone. `/link` is served by the SPA fallback; it collides with no API prefix and
    needs no server route. The web boot reads the fragment ONCE, parks the code
    (`PendingLinkCode`), scrubs the URL from the address bar and history, and the shell routes to the
    devices screen, which starts the primary-side ceremony PREFILLED — but only once `holdsDak` is
    resolved true ((lxviii) clause 2): a linked device that scanned a QR is shown its note, and the
    parked code is left for a primary. `LinkOobCode.tryParse` accepts the URL form back and ignores
    the host — the fragment is the payload. The text code and paste path are unchanged (item (i)).
    Falsified: gate dropped → `Found 1 widget with type LinkDeviceScreen` on a no-DAK install; QR
    back to the bare code → the semantics label no longer ends with `/link#<code>`.
  - **(lxx) clause 2 — a finished ceremony returns to the devices screen.** Both sides ended on a
    checkmark the user had to back out of. Rule: `done` pops the ceremony route and the confirmation
    is a toast on the screen underneath; the devices screen re-reads the list on the rebound socket
    ((lxviii) clause 1), so the new row is there on arrival. The pop's cancel/abort hooks are inert
    for `done`, which is where this touches (lxvi) clause 3: its "system back after done is a plain
    exit" pin becomes "done exits by itself, as a plain exit" — the exit is now automatic, and the
    contract it defends (flow reset, no `cancelProvisioning` for a consumed stage) is asserted on
    the auto-pop instead. Falsified: pop removed → `Found 0 widgets with text "marker-page"`.
  - **(lxx) clause 3 — staging waits for the verified list; it does not fail on its absence.** Found
    by the first live deep-link run, not by review: on a cold boot the Keystore read that resolves
    `holdsDak` beat the list fetch, the parked code started the ceremony at once, both sides showed a
    matching SAS, and Approve failed with `list_unavailable` — the stage was valid, only the list had
    not arrived. The manual path has the same latent race (`startPrimaryFlow` never fetched a list).
    First fix tried and REJECTED: gating the deep link on `listState == enrolled` — that converts the
    race into a silent dead end whenever the list does not verify, worse than the search page.
    Rule: `_stageProvisionDevice` with no list in hand fetches it and re-stages on the same
    `_resignPending` mechanism and retry cap the (falsification 20) stale-version path uses; a list
    that arrives `chainInvalid` or `not enrolled` while a stage waits FAILS the ceremony with
    `list_unavailable` — never leaves it in `staging`. The screen gate is the DAK alone. Also added:
    `OWN_DEVICE_LIST_UNVERIFIED {reason}` persisted diag, because the screen's one generic line hid
    the reason (`malformed_answer` / `invalid_enrollment_signature` / …) a field report needs.
    Falsified: wait removed → `Expected: staging / Actual: failed` at Approve without a list.
    Review riders, same day: (i) a FOURTH non-verified exit (`authorization is! Map`) also hung the
    stage — all four exits now call one `_failWaitingStage()`; (ii) `toDeepLink` builds the URL from
    scheme/host/port only, because `Uri.replace` kept the origin's query and a QR minted while
    `?notify_conv=` was still in the bar would have carried it; (iii) every navigation the ceremony
    triggers from a controller notification runs post-frame — the mid-build `setState` the first
    test run surfaced was a real defect. (iv) A persisted `OWN_DEVICE_LIST_UNVERIFIED {reason}` diag
    was added WITHOUT the owner's prior ask (the standing instrumentation rule) — disclosed in the
    session summary; the owner may strike it.
  - **Not in this amendment:** an in-app camera scanner on the primary (`getUserMedia` +
    `BarcodeDetector`/jsQR on web, `mobile_scanner` on native). The OS camera + deep link covers the
    "scan and done" ask on every phone; the in-app scanner is a convenience for desktops with webcams.

- **Amendment 2026-09-03 (D23, owner-directed from the post-launch review; client-only):**
  - **(lxxi) — "Start fresh" is removed; a never-published identity is discarded without asking.**
    Proven from source: a keyless install of an enrolled account cannot send (`_e2eInitialized`
    stays false, `ensureSession` throws), and the ONLY path that manufactured an install able to
    encrypt under an identity no peer trusts was `IdentityDamagedBanner` → "Zacznij od nowa" →
    `recoverFromIncompleteIdentity`, which set `_e2eInitialized = true` and fired `onE2EReady` BEFORE
    the `uploadKeyBundle` the registration lock then refused. Owner ruling: the button is useless —
    "a fresh user gets new keys anyway" — and a device that lost its keys re-enters through the §5.1
    link or the §6.2 reset, never by minting on its own.
    Rule: `identityIncomplete` has no consented remedy. The banner offers the link (and, per the
    next amendment, the reset door); the provider method, the service's `regenerateIdentityAfterConfirmedLoss`,
    the confirm dialog, its five strings and the `RECOVERED_USER_ID` e2e probe are deleted.
    `identityIncomplete` is raised ONLY when the server says the login's device already published a bundle.
    Second half, which keeps the never-enrolled user's plain start WITHOUT the button: `initialize`
    consults `checkServerBundleExists` on EVERY non-`loaded` outcome — `absent`, `absent` with
    Signal residue (`session_`/`pre_key_`/`signed_pre_key_`/`next_pre_key_id`), and `partial` from
    the store alike. An explicit `true` → `E2eIdentityIncompleteException` (enrolled; link or reset).
    UNKNOWN → `E2eIdentityCheckUnavailableException` (deferred to the next connect, as before).
    An explicit `false` → the residue is discarded by the same `_wipeSignalMaterial` the (lxv)
    disposal uses, peer-identity warnings and rebuild intents are cleared, and a new identity is
    minted exactly as on an empty store. Persisted diag `IDENTITY_RESIDUE_DISCARDED {userId}`
    replaces `IDENTITY_REGEN_CONSENTED`.
    Why `false` is safe to act on: `handleCheckOwnKeyBundle` answers for the session's device id, and
    a password login resolves to the LIVE PRIMARY (`resolveLoginDeviceId`, amendment (xxii)). The
    primary's bundle is absent in exactly two states: the account never published one, or a §6.2
    reset completed and its freshly allocated id awaits the upload that spends it — in both, minting
    is the designed outcome. A revoked device's purged bundle cannot produce `false` because a login
    never resolves to a revoked id: `revokeDevice` refuses `cannot_revoke_primary`
    (`chat-device-revocation.service.ts`) and a reset teardown keeps exactly one live id, so the
    zero-live-devices fallback to device 1 is unreachable for an enrolled account. Cost: a
    damaged-identity install now needs one server round trip (≤ 6 s, the shared-completer timeout)
    before the banner appears, instead of raising it offline — the banner's only action needs the
    server anyway.
    Rider (review of the first cut): the discard is PROVEN, never attempted blind. `_wipeSignalMaterial`
    reports whether the wipe is PROVEN complete (listed AND every row deleted); otherwise the (lxxi) branch records
    `IDENTITY_RESIDUE_DISCARD_DEFERRED` and throws `E2eIdentityCheckUnavailableException` — minting
    over rows it could not see is the stranded-ratchet state the discard exists to prevent (§5.11 R1
    doctrine: inconclusive reads as present). The (lxv) disposal keeps its best-effort semantics.
    Falsification: the discard removed → residue test fails on `e2e_9_session_49_1` still present;
    the server check removed from the residue branch → "residue + bundle exists" mints a key over
    the enrolled identity; enumeration failing + `false` → `E2eIdentityCheckUnavailableException`,
    zero writes.
  - **(lxxii) — the keyless banner carries the reset door.** Before (lxxi) the ONLY route from a plain
    keyless install of an enrolled account to the §6.2 reset was accidental: tap "start fresh", have the
    registration lock refuse the upload, and only THEN did `IdentityResetPendingBanner` render with
    "Rozpocznij reset" (`identityUploadLocked`). (lxxi) removed that button and with it the doorway —
    shipped as 0.2.1 with the gap open (owner's words, the day before: "I don't see any reset button").
    Rule: `IdentityDamagedBanner` keeps the §5.1 link as its always-visible action and gains, in the
    disclosure, the SAME secondary action the lock-refused banner has — `identityResetStartAction`
    through `startIdentityResetFlow` (phrase asked first, every entry point in one order) — and its
    body closes with the honest cost: no working primary → reset; 72 h, or 1 h with the recovery
    phrase; every other device is signed out; ciphertext this device never decrypted is gone. The door
    HIDES while a reset is already pending (`identityResetDeadline != null`) — the pending banner owns
    that state and offers cancel, and two "start" buttons for one ceremony would answer `existing`.
    Reset itself is unchanged: server, delay, notifications, spend-by-upload.
    Falsification: door removed → `Found 0 widgets with key identity-damaged-start-reset`; pending
    gate removed → the door renders beside a running countdown.

- **Amendment 2026-09-04 (D24, owner-ratified in three yes/no answers: opt-in lock YES, web-primary
  install rule YES, "QR as login" DROPPED; cross-tier — backend rule + client gate):**
  - **(lxxiii) clause 1 — the registration lock is OPT-IN; enabling linking is what arms it.** Owner's
    words: "when primary device is not linked then app works normally." Today §6.1 refuses every
    identity replacement, so a routine PWA storage wipe on an account that never linked anything
    costs the full §6.2 delay — the same price as a stolen password. Rule: the server refuses an
    unauthorized identity replacement ONLY when the account is ENROLLED, i.e. an `account_authorizations`
    row exists for `userId` (the DAK pin, one row per account, already read on every list mutation —
    `device-list.service.ts` `getAuthorization`). Both refusal sites take the same predicate:
    `upsertKeyBundle` (`key-bundles.service.ts:162-176`) and `uploadOneTimePreKeys` (`:464-486`) —
    the OTP site MUST be exempted too, because the client emits bundle + OTPs back to back and the
    keys can land first; a refused OTP batch on an un-enrolled account would be the (lxiv) pool-loss
    shape for no gain. An un-enrolled replacement is logged `[identity-churn] via=unlocked` and
    written to the same audit row as a `signature`/`reset` churn, so §6.0's alarm (push + WS +
    peer timeline row) fires unchanged — the posture is Signal-without-PIN: password-only takeover
    is POSSIBLE on an un-enrolled account, and it is LOUD. Once a DAK is enrolled the lock is exactly
    §6.1/§6.2 as before; disenrollment does not exist (a reset re-enrolls or leaves the account
    un-enrolled, per the (xlv)/(xlvi) teardown), so the lock never silently disarms.
    Threat honesty for §2: **P** against an un-enrolled account gains the account identity (as
    pre-programme), never a device list (there is none) and never silence. Owner accepts this; the
    cure is one tap ("Włącz łączenie"), and clause 3 says so at the moment of choice.
  - **(lxxiii) clause 2 — the client learns the lock state with the bundle answer, and a wipe on an
    un-enrolled account mints without asking.** `ownKeyBundleStatus` gains the additive field
    `linkingEnabled: boolean` (row exists). The (lxxi) guard's tri-state becomes a pair
    `{exists, linkingEnabled}` (or UNKNOWN as before): `exists && linkingEnabled` →
    `E2eIdentityIncompleteException` (gate); `exists && !linkingEnabled` → the residue is discarded by
    the PROVEN `_wipeSignalMaterial` (rider of (lxxi), deferred if unproven), a new identity is
    minted and uploaded, diag `IDENTITY_GUARD_UNLOCKED_REMINT {userId}`; `!exists` → mint as today;
    field ABSENT (older server) → treated as `linkingEnabled: true` — fail-closed to the current
    behaviour, never to a mint the server would refuse. Old history on the wiped device is
    unreadable (no key exists to read it) and the previous identity's peers see §6.0's
    "identity changed" row — exactly the pre-programme outcome, minus the silence.
  - **(lxxiii) clause 3 — an enrolled account that lost its keys meets a GATE, not a banner.** Rule:
    while `needsDeviceLink` (`identityIncomplete || deviceMaterialMismatch || identityUploadLocked`)
    or the new `identityCheckUnavailable` (the UNKNOWN outcome of the guard, today flagless) is set,
    `AuthGate`'s logged-in branch renders `DeviceLinkGateScreen` ABOVE `MainShell`, which stays
    mounted but `Offstage` (the socket, the guard's own round trip and the reset hydration all live
    under the shell — unmounting it would starve the gate of the very state that opens it). No
    shell, no banners, no composer. The gate is ONE screen with four states, chosen by provider state,
    never by navigation: (a) **link** — the device-side §5.1 ceremony inline (the `LinkThisDeviceScreen`
    body: QR + text code, "Czekam na urządzenie główne…"), the always-visible action; (b) **reset
    pending** (`identityResetDeadline != null`) — countdown (1 h when `shortened`, else 72 h; a
    `phrase_too_new` answer is shown as the reason the wait is 72 h) + "Anuluj", the link stays
    offered because the primary may reappear — and the copy says to cancel FIRST, because linking
    does not cancel a ceremony (server `cancelReset` is reachable only via `resetIdentityCancel`);
    (c) **unknown** (`identityCheckUnavailable`) — spinner
    + "Spróbuj ponownie" that re-runs the E2E init, never a keyless shell; (d) **mismatch/locked**
    (`linkDisposesStaleMaterial`) — state (a) with the (lxv)/(lxvii) disposal notice. Footer on every
    state: "Nie masz już urządzenia głównego? → Rozpocznij reset" (`startIdentityResetFlow`, hidden in
    (b) — (lxxii)'s two-buttons rule) and "Wyloguj" (`AuthProvider.logout`, keys and history untouched).
    `IdentityDamagedBanner`, `DeviceMismatchBanner` and the lock-refused branch of
    `IdentityResetPendingBanner` are DELETED from `main_shell.dart` — the gate owns those states and
    a banner behind an `Offstage` shell is dead code; the pending-countdown branch of
    `IdentityResetPendingBanner` stays for the OTHER sessions of the account (a healthy device
    watching a reset it may want to cancel) and `OwnIdentityReplacedBanner` is untouched. The
    devices screen's keyless branch ((lxvii) clause 1) becomes unreachable behind the gate and is
    removed with it. Deep-link parking (`PendingLinkCode`) is a PRIMARY-side concern and is unchanged.
    Cost, stated: the gate mounts when the verdict lands (one guard round trip, ≤ 6 s), so a keyless
    install sees the shell's skeletons for that window; a healthy install (`loaded`) never touches the
    server for this and never sees the gate.
  - **(lxxiii) clause 4 — link approval on a `partial` install wipes the residue before adopting.**
    `E2eIdentityIncompleteException` has two origins (`encryption_service.dart` `initialize`): a clean
    store with a server bundle, and `partial`/residue (prekeys, sessions, `next_pre_key_id` survive,
    identity gone). Both land on the gate. `adoptProvisionedIdentity` runs `_wipeSignalMaterial` only
    when it HOLDS an identity (the (lxiv) stale shape); a residue install holds none, so today the
    received identity is installed OVER foreign prekeys and a stale prekey counter — the stranded-
    ratchet shape (lxxi)'s rider exists to prevent. Rule: the adopt path wipes whenever residue is
    present (`_hasPriorInstallResidue` OR a stored identity), PROVEN, before the first store write;
    unproven → the ceremony fails `rebind_failed`-style with `LINK_RESIDUE_DISPOSAL_DEFERRED` and the
    gate stays. Consent is the SAS + authenticated blob, as in (lxv).
    Falsification (each mutant printed, substitution count asserted, restored in `finally`):
    (F1) backend exemption removed at the bundle site → un-enrolled replacement answers
    `identity_locked`; (F2) exemption removed at the OTP site only → the OTP batch after an
    un-enrolled remint is refused; (F3) exemption applied to an ENROLLED account → the §6.1 spec's
    "different IK without signature is refused" case goes green-for-the-wrong-reason (asserted red);
    (F4) client treats an absent `linkingEnabled` as `false` → the guard mints against an old server;
    (F5) gate route removed → `Found 1 widget with type MainShell` visible on a keyless enrolled
    install; (F6) reset-pending state removed → no countdown/`Anuluj` while `identityResetDeadline`
    is set; (F7) UNKNOWN state removed → keyless shell on a null guard answer; (F8) residue wipe
    skipped on adopt → `e2e_<uid>_pre_key_…` survives `LINK_IDENTITY_ADOPTED`.
  - **(lxxiv) clause 1 — a web PRIMARY is asked to be INSTALLED first.** §8 said only a
    Keystore-capable device may be primary; code disagreed since (li) — `enableLinking(platform:'web')`
    mints and persists a DAK on web in the same sealed `sig_` KV as the IK
    (`link_ceremony_controller.dart:352-372`, `dak_store.dart`), and every web primary in the field is
    real. Code wins; §8 is rewritten below. The exposure is EVICTION, not theft: a browser-tab origin
    is the first thing a storage-pressure sweep or a "clear browsing data" takes, and a wiped primary
    is the one shape whose only exit is the §6.2 delay (I2 — the DAK exists nowhere else). Rule: on
    web the not-enrolled branch of the devices screen offers "Włącz łączenie" ONLY when the app runs
    installed — `matchMedia('(display-mode: standalone)')` OR `navigator.standalone` (new
    `utils/web_display_mode.dart`, web + stub; `navigator.storage.persisted()` is NOT the signal:
    WebKit ≤ 16 has no API and 17+ answers heuristically). A browser tab sees the same row with an
    install instruction instead of the button. Enabling shows a plain one-paragraph warning (this
    browser becomes the account's main device; if its storage is cleared, linking must be reset —
    72 h, or 1 h with a recovery phrase) with "Włącz" / "Anuluj", and on success routes to
    `RecoveryKeyScreen` (the phrase offer; skippable). Android and desktop native are unchanged.
  - **(lxxiv) clause 2 — an already-enrolled web primary that is not installed is nudged.** The
    enrolled + `holdsDak == true` branch on web, when not standalone, renders one line above the
    "Połącz urządzenie" action: install this app so its keys are not evicted with the browser cache.
    Informational only — no gate, no modal (the owner's local 697 is this shape).
  - **(lxxiv) clause 3 — §8 rewritten.** Replace the "only Keystore-capable" bullet with: any
    platform may be primary; the DAK lives in platform Keystore on Android and in the sealed `sig_`
    KV on web (same custody as the IK — I2's "Keystore" is the custody INTENT, not a platform gate);
    web primaries are asked to install first (clause 1). "QR as login without password" is
    permanently out of scope: I3 requires a password login on the new device; the QR is a LINK step.
    Falsification: (F9) standalone check inverted → the button renders in a plain tab; (F10) nudge
    removed → no install line for an enrolled non-standalone web primary.

- **Amendment 2026-09-05 (D25, agent ruling on the owner's delegation — "I've not enough knowledge
  to take that decision, please make it for me"; backend rule + client copy):**
  - **(lxxv) — the §6.2 ceremony is REFUSED for an UN-ENROLLED account.** (lxxiii) clause 1 made
    never-enrolled the DEFAULT population (every user who never linked a second device), and for
    such an account §6.1 never refuses: a fresh install re-mints on credentials alone under
    device 1, and a peer synthesizing device 1 for a non-enrolled account ((xlv) clause 2's
    `authorization: null`) addresses the device that EXISTS. Nothing checked enrolment in
    `identity-reset.service.ts`, and `DeviceLinkGateScreen` shows the reset door in its
    `checkingOnly` state, so an un-enrolled owner could still start the 72 h ceremony — whose
    completion teardown revokes device 1 and allocates id ≥ 2 while the account stays un-enrolled:
    the (xlv) silence then holds forever and the only live device is unaddressable until it
    re-enrols. A ceremony can therefore only HARM an un-enrolled account. Rule: `requestReset`
    answers the new status `not_enrolled` (`identityResetStatus { status: 'not_enrolled' }`) when no
    `account_authorizations` row exists, BEFORE the phrase is examined — a fact about the account,
    not an attempt: no row written, the phrase neither spent nor counted toward the five-attempt
    lockout. Ordered AFTER the pending check so a row created before this rule keeps answering
    `existing` and stays cancellable. Enrolment is monotonic ((xxix): the row is never dropped), so
    the refusal can never trap an account that later needs the ceremony. Client copy points at the
    recovery that works — sign in on the new device (`identityResetNotEnrolled`, EN+PL); older
    clients see an unknown status and say nothing (`identityResetAnswerMessage` default).
    Alternatives rejected: skipping roster reallocation for un-enrolled completions (keeps a 72 h
    wait that buys nothing and leaves the door's copy lying), and rewriting the probe around the
    stranding (documents the gap instead of closing it). Probe: `identity_reset_teardown_test`'s
    never-enrolled group now proves the unlocked remint under device 1, the `not_enrolled` answer
    with phrase intact, `authorization: null`, `liveDeviceIds == [1]` and `isLiveDevice(1)` — the
    addressability assertions that never executed while the group died on its stale
    `identity_locked` premise.

- **Amendment 2026-09-08 (D26, owner-ratified in one sentence — "agree on everything, green light";
  brainstorm recorded in `.planning/multi-device/OPEN-QUESTIONS.md`; prod facts that drove it: 114
  users, 2 enrolled, 0 linked devices, 3 identity replacements ever — all `via=unlocked` wipes):**
  - **(lxxvi) — the passcode lock and the ceremony.** Clause 1: `passcodeEraseWarning` is
    enrolment-aware. The lock screen cannot read E2E state (on web the store is wrapped), so the
    client persists a CLEARTEXT hint `account_enrolled_hint_<uid>` (prefs) from every
    `ownKeyBundleStatus.linkingEnabled == false` / enrolment observation, and the erase panel renders
    `passcodeEraseWarningEnrolled` when the hint is true — it names the three doors (phrase, other
    device, 72 h) instead of "log in again". Clause 2: a link ceremony or an enrolment in progress
    is a departure exemption exactly like the attach picker: `linkCeremonyActive`
    (`composer_keyboard_signals.dart`, same shape as `composerNativePickerActive`) is raised by
    `LinkCeremonyController` from the first emit until terminal state, and `PasscodeProvider`
    treats it as the picker for the immediate lock, the foreground verdict and the DOM curtain
    — a background during `adoptProvisionedIdentity`'s writes must not relaunch the page. Clause 3:
    after `adoptProvisionedIdentity` / `adoptRestoredIdentity` land raw keys while wrapping is ON,
    the service calls `PasscodeProvider.wrapRawKeysNow()` (idempotent `wrapRawKeys`) so a crash in
    that window does not leave key material raw on a "protected" device.
    Falsification: (F1) hint never written → enrolled copy absent; (F2) exemption removed → a
    0 s auto-lock during `adopt` calls `_lock()`; (F3) wrap hook removed → `fpwk1:` absent after adopt.
  - **(lxxvii) — the QR is real: either side may scan, no in-app copy of a 96-char code.** Clause 1
    (server): `openProvisioning { role?: 'new' | 'primary' }`, default `'new'` (byte-compatible).
    With `role: 'primary'` the OPENER is the primary; the stage records `primarySocketId` and
    `newDeviceSocketId` explicitly (today both are implied by `openerSocketId`). `provisioningHello`
    from the OTHER party pins its ephemeral, answers `provisioningHelloAck { success, deviceId }` to
    the caller and relays `provisioningHello { provisioningId, ephPubP, deviceId }` to the opener
    (the field name stays `ephPubP` from v1 even though it now means "the hello party's ephemeral",
    and `deviceId` is new in the relay: the primary must build the blob for it). `provisionDevice` is
    accepted from `primarySocketId` only and relays the blob to `newDeviceSocketId`;
    `provisioningBlob` fetch, `provisioningComplete` and the cancel relay use the same explicit
    roles. The SAS derivation is unchanged (DH-bound, both ephemerals) — which socket said hello is
    not a crypto input. Clause 2 (code): `fp-link.v2.<provisioningId>.<base64url ephPub>.<platform>.<p|n>`
    — the last segment names the ROLE of the device that displays it; v1 codes (no role segment)
    parse as `n`. Clause 3 (client): both screens show a QR AND a "Zeskanuj kod" button
    (`link_qr_scanner.dart`: `mobile_scanner` on Android/iOS, `BarcodeDetector` → vendored jsQR
    fallback on web, never a runtime CDN; camera denied/unsupported falls back to the typed field,
    which stays). The gate (`LinkThisDeviceBody`) still auto-opens as `new` and shows its v1/v2-n
    code; scanning a `p` code there cancels its own stage and runs the hello-side flow. The primary's
    `LinkDeviceScreen` opens as `primary`, shows its `p` code, and its scanner accepts an `n` code
    (classic flow). Clause 4: `AndroidManifest.xml` gains an `https://fireplace.ignorelist.com/link`
    `VIEW` intent-filter (auto-verify), and the native build consumes the fragment via a platform
    channel replacing `link_fragment_stub.dart`'s null. I3 unchanged: password login on N, SAS
    compare, approve on P. Falsification: (F4) role ignored server-side → blob relayed to the
    primary; (F5) v2 `p` code parsed as `n` → SAS mismatch; (F6) scanner result not fed to the
    controller → field stays empty.
  - **(lxxviii) — the recovery phrase is a KEY BACKUP; restore is instant and identity-preserving.**
    I1 is amended: the server may hold `IK`, `registrationId` and `DAK` ONLY as an AES-256-GCM blob
    sealed under a key derived from the 12-word phrase (128-bit CSPRNG entropy, BIP39 checksum;
    PBKDF2-HMAC-SHA256 600k over the NFKD-normalized phrase with a 16-byte random salt — the KDF is
    belt-and-braces, the entropy is the guarantee). Signed/one-time prekeys are NOT in the blob:
    they are regenerated on restore and peers re-key. Clause 1 (wire): `setRecoveryKey { phrase,
    backup: { blob, salt, iterations, version: 1 } }` writes the Argon2id verifier AND the blob in
    one transaction (columns on `recovery_keys`, migration 0017); `getIdentityBackup {}` →
    `identityBackup { exists, blob?, salt?, iterations?, version? }`, and `{ exists: false, error }`
    on a read failure so an unknown never reads as "you have no backup" (JWT socket, 10/15 min — the blob is
    useless without the phrase). `ownKeyBundleStatus` gains additive `hasIdentityBackup`. Clause 2
    (restore): `uploadKeyBundle` additionally accepts `restoreSignature` + `nonce` (from
    `getRegistrationLockNonce`): XEdDSA by the account's CURRENT published IK over
    `identityPublicKey ‖ userId ‖ nonce`, valid only when the uploaded identity EQUALS the stored one.
    `upsertKeyBundle` answers `authorizedBy: 'restore'`; the gateway then purges the one-time
    pre-keys of the login-resolved device (their private halves died with the wipe), runs the
    (xxviii) roster teardown (`applyAfterReset`: fresh deviceId, `isPrimary`, every other device
    revoked with reason `restored`, sessions dropped, one reissued), and acks
    `keyBundleUploaded { success, deviceId, access_token, refresh_token, restored: true,
    nextListVersion }`. No `identity_change_audit` row, no §6.0 alarm (the identity did not change);
    a content-free `{ type: 'identity_restored' }` push goes to every endpoint BEFORE the push rows
    are dropped, and revoked sockets receive `deviceRevoked { reason: 'restored' }`
    (`deviceRevokedRestoredNotice`). Clause 3 (client): the gate gains a third door
    `linkGateRestoreAction` → 12-word prompt → `getIdentityBackup` → unseal (GCM failure =
    `linkGateRestoreWrongPhrase`, no server attempt spent) → `adoptRestoredIdentity` (residue wipe
    as (lxxiii) clause 3, installs IK + registrationId + DAK, mints signed prekey + OTPs) →
    upload with proof → rebind (existing `onSessionRebound`) → OTP upload → DAK-signed list
    `nextListVersion` (old devices revoked, new device added; `updateDeviceList`, NOT a
    re-enrolment — E still verifies) → `requestSessionRebuild` to every conversation peer (so the
    first message after restore is not lost) → shell. **Placement (2026-09-22, Run C on a Pixel 7):
    the restore door renders ABOVE the reset section on every state** — it was the LAST item, below
    the fold and under "Rozpocznij reset", so a wiped user read "new keys after 6 h, old history
    lost" before finding the door that keeps the same identity; the option that preserves the keys
    now comes before the one that destroys them (`device_link_gate_screen_test.dart` pins the order).
    Clause 4 (enrolment order): "Włącz łączenie"
    = warning (web) → phrase generated → `RecoveryKeyScreen` MANDATORY with a random-word
    confirmation (`recoveryKeyConfirmPrompt`) → DAK minted → `setRecoveryKey` with the blob → ONLY
    THEN `enrollDeviceAuthority`; a failed backup upload aborts before enrolment
    (`recoveryKeyBackupFailed`). Every later phrase (re)generation re-uploads the blob — invariant:
    the blob is always sealed under the latest phrase. An enrolled `holdsDak` primary with
    `hasIdentityBackup == false` sees `devicesBackupMissing` + `devicesCreateBackupAction`. Threat
    posture accepted by the owner: phrase possession = instant account takeover (Signal PIN/SVR
    posture); the 72 h reset remains for accounts without a phrase. Falsification: (F7) restore
    proof verified with the wrong key → accepted; (F8) OTP purge skipped → old keyIds served;
    (F9) enrolment before backup upload → enrolled with `hasIdentityBackup == false`; (F10) wrong
    phrase → `restoreSignature` emitted.
  - **(lxxix) — the peer key-change surface is DEMOTED by default.** `SettingsProvider.keyChangeWarnings`
    (prefs `key_change_warnings`, default false; Settings → Privacy row `settingsKeyChangeWarnings`).
    With it OFF, a peer identity change (either detection path) auto-acknowledges: the I7 anchor
    advances to the new key at once and the timeline renders ONE muted system line
    (`peerIdentityChangedSystemLine`, `DevicesSyncingNote` styling, no error palette, no required
    tap; tapping still opens the fingerprint dialog). With it ON, today's `PeerIdentityChangedRow`
    + manual confirm is unchanged. The OWN-account banner (`ownIdentityReplaced`) is NOT demoted.
    Falsification: (F11) toggle ignored → red pill with the setting off; (F12) auto-ack removed → the
    muted line persists across reload.

- **Amendment 2026-09-08b (D27, owner-ratified: "let user rename linked devices"; the three riders
  are defects D26 shipped or exposed, folded into the same release):**
  - **(lxxx) clause 1 — DEVICE RENAME.** The primary may give any LIVE device row a human name.
    **No new wire and no server change:** `DeviceListEntry.name` has been in the canonical encoding
    since §3 (sorted key `name`, `kDeviceNameMaxLength` = 64 UTF-16 units, `_validString` rejects
    control characters, and the server re-checks it at the storage gate), and `updateDeviceList`
    already accepts ANY DAK-signed list at a higher version — `applySignedListUpdate` constrains
    only `userId`, the signature and version monotonicity. So a rename is exactly the
    `revokeDevice` shape with `name` set instead of `revokedAtMs`, emitted on the EXISTING
    `updateDeviceList` (mutating tier, 60/900000) and answered by `deviceListUpdated
    { success, listVersion }`; the server's own `deviceListChanged` broadcast to the user room is
    what refreshes the other installs. Rules: only a DAK holder may rename (the engine is armed
    from the Keystore FIRST, as `revokeDevice` learned to — the app-proof caught that path missing
    it); a REVOKED row may not be renamed (it is a tombstone, and mutating it would spend a list
    version to no effect); an empty/whitespace-only name CLEARS the field rather than storing `""`
    (the encoder omits an absent name, so clearing must reach the same canonical bytes as never
    naming it); the name is trimmed and length-capped client-side before signing. Names are
    INFORMATIONAL: nothing in I1–I7, the SAS or any envelope reads them, and a peer that dislikes a
    name simply displays it. Falsification: (F13) rename emitted without arming the DAK → signature
    absent, nothing leaves the device; (F14) a cleared name that still writes `""` → canonical bytes
    differ from the never-named list.
    **NFC.** The storage gate refuses a `name` that is not NFC-normalized, and the encoder's own
    header has promised since §3 that "when the rename UI lands, the client-side NFC normalization
    lands with it". It lands as a REFUSAL, not a normalization: Dart core ships no Unicode
    normalizer, and the alternative was hundreds of KB of Unicode tables in a PWA bundle to tidy a
    device label. `isSignableDeviceName` rejects the combining-diacritic blocks (U+0300–U+036F,
    U+1AB0–U+1AFF, U+1DC0–U+1DFF, U+FE20–U+FE2F) that decompose Latin, Greek and Cyrillic — the
    only way this app's users produce non-NFC text (a paste from macOS/iOS) — and deliberately
    leaves alone the marks that are NORMAL in NFC for other scripts (Arabic, Hebrew, Indic vowel
    signs live in different blocks). The refusal happens BEFORE signing, so no list version is
    spent, and it gets its own copy (`devicesRenameNotStorable`, "type it instead of pasting"):
    "could not rename, try again" would be a dead end, since retyping the same paste fails
    identically. Accepted false positive: a Latin base + mark with no precomposed form (`z` +
    U+0308) is refused despite being valid NFC. Falsification: (F19) with the check removed, the
    decomposed name is signed and emitted; the precomposed spelling of the SAME name and an Arabic
    fatha both stay accepted, so the refusal is not simply "no diacritics allowed".
  - **(lxxx) clause 2 — the "primary" badge was keyed on `deviceId == 1`.** `devices_screen.dart`
    labelled the row whose id is 1. Every §6.2 reset and every (lxxviii) restore RE-HOMES the
    surviving install onto a FRESH id and revokes the old one, so after any of them the live primary
    loses the badge and the REVOKED device 1 keeps it — actively misleading, and (lxxviii) turns
    that from a 72-h-rare event into an ordinary one (observed live on the 0.2.23 drive: the
    restored primary rendered `web · #3` with no badge). The signed list carries no `isPrimary`
    field and must not grow one (it would be a second source of truth the DAK signs but the server
    also believes). The badge is therefore derived: **the LOWEST non-revoked `deviceId`**, which is
    exactly the row `DevicesService.resolveLoginDeviceId` resolves for login. Falsification: (F15)
    a list whose device 1 is revoked and 3 is live badges 3, never 1.
  - **(lxxx) clause 3 — the flipped ceremony recorded `platform: 'unknown'`.** (lxxvii) let the
    PRIMARY open the ceremony, and in that direction the new device's platform label reaches the
    primary only through `provisioningHello` — which carried `provisioningId` + `ephPubP` and
    nothing else, so every device linked through the path (lxxvii) makes primary landed in the
    roster as `unknown`. `ProvisioningHelloDto` gains an OPTIONAL `platform` (same
    `^[A-Za-z0-9_-]{1,32}$` bound the OOB code already enforces), relayed to the opener beside
    `deviceId`; the primary uses it for the list entry and falls back to `unknown` when absent, so
    an older client is unchanged. Informational metadata only (spec item (i)) — it is not a crypto
    input and a lying label costs its own owner a wrong icon. Falsification: (F16) hello without
    `platform` → entry still `unknown`, never a crash or a rejected DTO.
  - **(lxxx) clause 4 — copy that understates (lxxviii).** Two LIVE strings still promised the
    pre-(lxxviii) recovery terms: `devicesEnableLinkingWebWarningBody` ("a reset: 72 hours, or 1
    hour with a recovery key" — said in the very dialog that is about to DEMAND a phrase whose whole
    point is that it restores immediately) and `linkGateResetHint` (the same "1 hour with a recovery
    key", rendered on the gate next to the instant restore door). Both now describe the reset
    as the LAST resort and point at the phrase door. Three (lxxiii)-era keys carrying the same stale
    promise are DELETED, not reworded: `identityDamagedBody`, `identityUploadLockedBody` and
    `recoveryKeyExplainer` have had no reader since `DeviceLinkGateScreen` replaced the banners and
    `recoveryKeyBackupExplainer` replaced the phrase explainer. `recoveryPhrasePromptBody` KEEPS its
    "72 → 1" wording: it belongs to the reset ceremony, where a phrase genuinely only shortens the
    wait.
  - **(lxxx) clause 5 — the restored install alarmed itself.** Observed live on the 0.2.23 drive:
    seconds after a successful restore the shell raised the RED own-account banner "Nowe klucze
    szyfrowania na Twoim koncie". The restore was innocent — the audit row it reported predated the
    restore and was written by that same install's earlier login — but the wipe destroyed the
    install's dismissal watermark (`e2e_<uid>_own_identity_replaced_seen_v1`), so connect-time
    hydration from `ownKeyBundleStatus.identityReplacedAt` re-raised a change the user had already
    lived through, in the one flow whose entire promise is "nothing happened to your account".
    **The fix is CONTENT-BASED, never a suppression flag.** `latestIdentityChangeAt` is replaced by
    `latestIdentityChange` returning `{ at, to }` where `to` is the audit row's
    `newIdentityPublicKey`, and `ownKeyBundleStatus` carries the additive `identityReplacedTo`
    beside `identityReplacedAt`. `recordOwnIdentityReplacedFromServer` then IGNORES a row whose
    `to` equals this device's own published identity: such a row describes a change that ENDED at
    the key this device holds, so nothing is pending — while a row ending at any OTHER key still
    alarms, unchanged. This is exactly as strong as the existing threat model: an attacker cannot
    republish this identity without its private half, and a §6.2 ceremony or a §6.1 rotation by
    anyone else lands on a DIFFERENT key and is still reported. **The one-shot
    `markOwnIdentityPublished` flag was deliberately NOT reused here** — a restore reports
    `identityChanged: false` and an account with no audit row sends no instant at all, so
    `normalizeServerInstant` returns null and bails BEFORE the flag is consumed; the flag would
    persist in prefs and silently eat the first genuine replacement that ever arrived. A rule that
    can only ever suppress a row already ending at our own key cannot do that. Absent
    `identityReplacedTo` (older server) changes nothing: the row is reported as today.
    Falsification: (F17) a hydrated row whose `to` is a FOREIGN key still raises the banner; (F18)
    with the comparison removed, the restore drive's own row raises it again.
  - **(lxxx) clause 6 — a half-finished restore stranded the install (found by the D27 code
    review, present in the shipped 0.2.23).** `restoreFromPhrase` cleared `_identityIncomplete`
    the moment `adoptRestoredIdentity` returned, four stages before the machine was done. That flag
    feeds `needsDeviceLink`, which mounts the gate that HOSTS this machine's progress and errors —
    so the shell appeared as soon as the identity landed, and a failure in any remaining stage (the
    20 s nonce wait, the 45 s upload ack, the roster re-sign) reported itself to an unmounted
    widget. Invisible, and worse, PERMANENT: on re-entry `adoptRestoredIdentity` saw a held
    identity, and a keyless install has neither `deviceMaterialMismatch` nor
    `identityUploadLocked`, so `disposeStaleMaterial` was false and it threw
    `already holds an identity` on every retry. The install kept a locally adopted identity whose
    fresh signed prekey and one-time prekeys were never published — peers went on fetching the
    stale server bundle, so first-message decryption broke — with no route back.
    Two changes, both narrow: the flag is cleared only at `done` (and the release is recorded as
    `RESTORE_GATE_RELEASED`, the one restore step a field report could not otherwise place), and a
    re-adopt of the IDENTICAL identity is now idempotent instead of fatal — a DIFFERENT held
    identity is still refused, because disposing that one needs the (lxv)/(lxvii) authorization the
    caller passes explicitly. Falsification: (F20) re-add the early clear → the regression fails on
    a still-gated retry; (F21) refuse every re-adopt → the retry cannot complete. The regression
    starts from the REAL gated state (no local identity + a server that says a bundle exists);
    an earlier version asserted on the diag marker instead and the (F20) mutant SURVIVED it, which
    is why the assertion is on `needsDeviceLink` itself.
    **A THIRD change was needed, and the first two were not enough.** Clearing the flag late only
    covers failures BEFORE the rebind. The rebind's reconnect re-runs E2E init, and the init success
    path clears `identityIncomplete` itself — so a failure at `listing` or in the session-rebuild
    sweep, both of which run after the rebind, dismissed the gate again. `needsDeviceLink` therefore
    gains `restoreUnfinished` (`_restoreStage` neither `idle` nor `done`) as an INDEPENDENT reason
    to hold the gate, which also covers a `failed` restore — precisely the state the user must be
    able to see and retry. Falsification (F22): drop the `restoreUnfinished` term and a provider
    whose init SUCCEEDED (so `identityIncomplete` is false) stops being gated by an unfinished
    restore. A first attempt to test this by modelling the rebind inside the upload branch
    DEADLOCKED the harness (the machine awaits the upload ack, which awaited an init that awaited
    its own `checkOwnKeyBundle` answer from the same callback) — the kept test drives the predicate
    directly instead, which is both faster and non-vacuous.
  - **(lxxx) clause 7 — clause 6's third change over-held the gate (found by the final pre-ship
    review of 0.2.25, present in the shipped 0.2.25).** `restoreUnfinished` was `_restoreStage`
    neither `idle` nor `done`, and NOTHING ever returned the stage to `idle`: not `clearAll()`
    (logout / account switch), not `onConnect(false)`, not another door succeeding. So a restore
    that failed BEFORE adopting anything — wrong phrase, `exists:false`, a fetch that never
    answered — left `restoreUnfinished` true for the life of the process. That held the gate
    against the OTHER two doors: a user who mistyped the phrase and then linked by QR (or completed
    a 72 h reset) had `identityIncomplete` cleared by the post-rebind init and stayed gated
    anyway, with nothing left to retry — the (lxxx) clause-6 stuck state on a different door. And
    it outlived the account: a failed attempt under user A gated user B's next login on the same
    install. Two changes. (1) `restoreUnfinished` holds ONLY once the backup identity has been
    ADOPTED and the machine has not reached `done` (`_restoreAdopted`, set after
    `adoptRestoredIdentity` returns, cleared at `done`): before adopt nothing is half-done, the
    gate is held by whatever brought the user to it, and the failure is shown by the same
    section; after adopt the install holds an identity whose prekeys are unpublished and the
    idempotent retry (clause 6) is the way out. (2) `clearAll()` and `onConnect(false)` return the
    machine to `idle` with the failure and the adopted flag cleared — the restore belongs to the
    account, like the §6.2 ceremony state two lines above it. The §6.2 rebind is `connect()` with
    the SAME user id, so it is a reconnect and touches neither. Falsification: (F23) hold on
    `failed` regardless of adopt → a wrong phrase followed by a healthy init stays gated; (F24)
    drop the teardown → the failed machine survives `clearAll()` into the next account.

- **Amendment 2026-09-08c (owner-ratified after the D27 ship: "5 go" on the gap list, and the two
  security answers below given in the same exchange):**
  - **(lxxxi) — pre-link history collapses to ONE line instead of a wall of placeholders.** §5.3
    and (viii) made `none_for_device` an HONEST marker, never a destruction trigger and never
    `[Decryption failed]`; the client then rendered every such row as its own bubble reading
    "Wysłana przed połączeniem tego urządzenia." — which on a freshly linked device is the FIRST
    thing the user sees, dozens of times, before any real message. Owner ruling (2026-09-08,
    "nobody reads a wall of text"): hide the rows. Storage, ingestion, the (lxvi) clause-2
    plaintext-outranks-marker rule, the decrypt pass and `getServedMessageIds` reconcile are ALL
    UNCHANGED — the row still exists locally, still carries the sentinel, is still never destroyed
    on the marker. The change is confined to the DISPLAY boundary: `MessagingProvider.messages`
    (the only list the UI reads) omits rows whose content is the pre-link sentinel, and exposes
    `hiddenPreLinkCount`; `ChatDetailScreen` renders ONE muted divider at the oldest end while that
    count is non-zero ("Wcześniejsze wiadomości nie są dostępne na tym urządzeniu", key
    `historyNotOnThisDevice` since (lxxxviii) A3), so the user still learns
    WHY the thread starts where it does. Rows are contiguous at the oldest end (a row predates the
    link or it does not), so a page of hidden rows adds nothing visible and the scroll-anchored
    pagination simply asks for the next page on the next nudge — no auto-continue, because an
    account with a long pre-link history would otherwise be walked page by page unprompted.
    An EDITED pre-link row (§5.7: the edit re-fan upserts real ciphertext for a later-linked
    device) is not hidden — it carries ciphertext, decrypts, and renders as a normal message.
    A reply whose parent is hidden still previews from the server-enriched reply snapshot; the
    lookup through `messages` simply misses. Falsification: (F28) drop the filter → the envelope
    test that asserts the row is absent from `messages` and counted turns RED; (F29) count
    without filtering → the divider renders while the placeholders are also rendered, the
    widget test finds both.
  - **(lxxxi) clause 2 — clause 5 of (lxxx) failed its first live proof; the restored install
    still alarmed itself.** Reproduced 2026-09-08 on the local stack: account 204, identity
    K1 → second browser mints K2 (un-enrolled, audit row K1→K2) → that browser enrols with a phrase
    (backup of K2) → third, EMPTY browser logs in, restores from the phrase (server:
    `[identity-restore] proof verified`, device 1→3, identity byte-identical, no new audit row)
    → the shell raises "Nowe klucze szyfrowania na Twoim koncie". The (lxxx) comparison is
    correct and DID run — on the SECOND hydration. The FIRST `ownKeyBundleStatus` arrives at the
    connect that precedes the gate, when the wiped install holds NO identity at all;
    `_ownPublishedIdentityBase64()` returns null and the documented "unknown own key falls
    through to reporting" rule raises the alarm and persists it. The restore then rebinds,
    re-initializes, hydrates again, finds `to == own`, and takes the early return — which SKIPS
    the row but never RETRACTS the alarm that same row raised a minute earlier. The
    fail-through was designed for a foreign row and is right for one; it was never asked what
    happens when the row later turns out to be ours. Fix, content-based like clause 5 itself:
    in the `own == replacedTo` branch, an alarm currently showing for THIS row — the same
    normalized instant, because the server reports only the latest audit row — is dismissed
    (`_ownIdentityReplacedAt == normalized` → the ordinary dismissal path, watermark written).
    Any alarm for a DIFFERENT instant is left alone: a device that minted K3 over a foreign K2
    still shows the K1→K2 alarm it was raised on, exactly as today. Falsification: (F31)
    remove the retraction → the test that raises the alarm with no identity, then hydrates the
    same row with the identity loaded, stays alarmed; the control asserts a row with a
    different instant is NOT retracted.
  - **(lxxxii) — THE SEED IS THE ACCOUNT (owner-ratified 2026-09-08, "confirm all", after the lead
    stated the combined effect once: every single stolen secret now suffices for takeover — a
    stolen phrase walks in with no alarm and nothing to cancel; a stolen password waits 6 h,
    shorter than a night's sleep. Owner's posture: "seed phrase > password", the crypto-wallet
    model. Recorded here as an explicit owner decision; the two-factor shape it replaces was
    (lxxviii)'s.)**
    **Clause 1 — the §6.2 delay is 6 h.** `RESET_DELAY_MS` 72 h → 6 h. `RESET_DELAY_RECOVERY_MS`
    stays 1 h, `CANCEL_COOLDOWN_MS` stays 24 h, `COMPLETED_GRANT_TTL_MS` stays 24 h.
    `RECOVERY_MIN_AGE_MS` is DEFINED as `RESET_DELAY_MS` and therefore follows to 6 h — the (xlii)
    argument is relational ("a phrase old enough to shorten the window predates a same-session
    compromise by at least the window it removes") and survives the change unchanged. Copy: every
    "72 h" becomes "6 h" and "3 days" becomes "6 h" (`linkGateResetHint`, `linkGateResetPhraseTooNew`,
    `recoveryPhrasePromptBody`, `identityResetPhraseTooNew`; root `CLAUDE.md` §7 and
    `frontend/CLAUDE.md` §5 follow). The push on `identityResetPending` is unchanged and is now
    the ONLY thing standing between a password thief and the account for those 6 h.
    **Clause 2 — the phrase alone resets the password.** New REST door `POST /auth/recover
    { identifier, phrase, newPassword }`, UNAUTHENTICATED, throttled 5 / 15 min per IP (an
    Argon2id verify costs 19 MiB; the throttle is the whole DoS control). An unknown identifier
    pays a DUMMY Argon2id verify (`TIMING_SAFE_DUMMY_VERIFIER`, same parameters) and touches no
    counter — login's bcrypt twin — so the door is not a timing oracle for which usernames exist;
    a KNOWN account with no phrase enrolled pays the same dummy inside `verifyRecoveryPhrase`, so
    it is not an oracle for who enrolled either (F38).
    (The first cut skipped the dummy "for the memory cost"; that argument did not hold, since an
    attacker who wants to burn Argon2 simply names a real account. Fixed in the same release.)
    Accepted residual (owner, 2026-09-09): the dummy paths do not perform the failure-counter
    UPDATE the wrong-phrase-on-an-enrolled-account path pays (~1 ms, one indexed row) — a
    difference below network jitter, not worth a dummy write. Recorded, not fixed.
    Identifier
    resolves exactly as `login` does (`username#tag`, or a bare username that matches exactly one
    account; an ambiguous bare name resolves to nobody). The phrase is verified against the
    (lxxviii) `recovery_keys.verifierHash` through the SAME failure counter and lockout the §6.2
    shortcut uses (`RECOVERY_MAX_FAILED_ATTEMPTS` 5 → `RECOVERY_LOCKOUT_MS` 1 h, counted in SQL),
    so guessing at either door spends the same budget. `usedAt` is IGNORED and the phrase is NOT
    spent: `usedAt` marks the (§6.2.1) SHORTCUT as consumed, and the (lxxviii) restore door already
    ignores it for the same reason — the phrase is the seed, not a ticket. `RECOVERY_MIN_AGE_MS`
    does NOT apply: the age rule defends the shortcut against a phrase the thief minted himself,
    and minting a phrase already requires holding the identity (the primary), i.e. owning the
    account. On success, in this order: revoke every refresh session, then store the bcrypt hash
    and stamp `passwordChangedAt` (the (existing) `resetPassword` ordering, for the same stolen-
    refresh-token reason), audit-log `recoverPassword success` (no account id in any log line since metadata privacy step 0), and answer with the
    ordinary login tokens for the live primary device — the door proved ownership, so a second
    round-trip to sign in would be ceremony. Refusals: unknown identifier, wrong phrase, no
    phrase enrolled → 401 `Invalid credentials` (one wording, no enumeration); lockout → 423
    `recovery_locked`; DTO shape (password rules) → 400. No push and no room broadcast on the
    door itself: the owner's other devices learn on their next refresh (`refresh_invalid`) —
    accepted as the "no alarm" the posture implies. Client: a "Nie pamiętam hasła" link under the
    sign-in form opens the recover form (identifier prefilled, 12 words, new password with the
    same rules the register tab shows); success adopts the returned session like a login and
    lands wherever a login lands — the gate on an enrolled account, where the same 12 words then
    restore the keys. `AuthStatusCode.phraseRejected` is the one new status ("Nazwa lub fraza
    nie pasuje."); a 423 maps to the existing `tooManyAttempts`. Falsification (backend):
    (F32) skip the counter on a wrong phrase → the lockout test at this door stays unlocked after
    five failures; (F33) drop `revokeAllForUser` → a pre-recovery refresh token still refreshes;
    (F34) skip the dummy verify → an unknown identifier answers without paying the Argon2 cost
    (asserted by the verify spy); (F37) same, on the ambiguous-bare-name path. Frontend: (F35) map 401 on the recover attempt to `invalidCredentials` → the
    screen names a password field the form does not have.
  - **(lxxxiii) — THE PHRASE IS OFFERED AT THE DOOR AND NUDGED ON THE LIST (owner "go" 2026-09-09,
    closing the multi-device programme's last open ask: "PWA users never need to link").** The
    12 words do not lock the account — only "Włącz łączenie" enrols (an `account_authorizations`
    row, (lxxiii)); `setRecoveryKey` has no enrolment precondition (`handleSetRecoveryKey`), so
    for a plain single-browser user the phrase buys exactly one thing: forgot password → still
    get in ((lxxxii) clause 2). No gate, no QR, no devices screen. Losing the browser on an
    un-enrolled account still means new keys (the phrase restores the identity at the gate ONLY
    when the account is enrolled — (lxxviii) clause 3 is reached through `needsDeviceLink`, which
    an un-enrolled account never raises); contacts still see the muted note. Password recovery,
    not history.
    **Clause 1 — at registration.** `AuthProvider.register` stamps `freshRegistration` on the two
    paths that end SIGNED IN with an account these credentials just created (the clean 201 and
    the lost-answer → probe-sign-in path); the "taken → the typed credentials opened it" path is
    an EXISTING account and is not stamped. `clearStatus()` (the start of every attempt) clears
    it. The Chats screen CONSUMES the stamp once, and pushes the existing `RecoveryKeyScreen`
    (12 words, Zapisałem, confirm one word — the §6.2.1/(lxxviii) screen, unchanged in substance)
    the moment `ownKeyBundleStatus` reports `hasIdentityBackup: false` for this account — never
    on unknown, never on true (a pre-existing account reached through the probe path keeps its
    backup). The screen gains `deferrable: true` → a "Później" action (`recovery-key-later`)
    under the generate button; any exit other than a saved backup counts as "later" (clause 3).
    Forcing the screen on someone who came to chat loses more users than it protects.
    **Clause 2 — the generate button waits for E2E.** `RecoveryKeyScreen` enables "Wygeneruj"
    only while `EncryptionProvider.isE2EReady` — `exportIdentityForBackup` throws before
    `initialize()` has finished, and at the door the identity is minted seconds after the shell
    appears. Applies to every door (Settings, Devices, the nudge, the offer): a disabled button
    for two seconds beats a phrase-shaped failure snackbar. The failure snackbar itself becomes
    context-neutral (`recoveryKeySaveFailed`, a dead key until now: "Nie zapisano klucza. Te słowa
    nie działają — spróbuj ponownie."); `recoveryKeyBackupFailed` ("łączenie nie zostało
    włączone") is DELETED — it was wrong on two of the four doors, and the linking flow's abort
    is visible on the toggle itself.
    **Clause 3 — the legacy nudge.** No migration: `ownKeyBundleStatus.hasIdentityBackup`
    ((lxxviii)) already says whether an account has a backup. Any account with an EXPLICIT
    `false` gets ONE muted line at the top of Czaty — `backup-nudge`, "Zabezpiecz konto — utwórz
    12 słów", tap → the same screen; an X (`backup-nudge-dismiss`) snoozes it. Snooze is
    `SettingsProvider.snoozeBackupNudge(userId)`: prefs key `backup_nudge_dismissed_at_<uid>`,
    epoch ms, per account per install, hides the line for 7 days
    (`kBackupNudgeSnooze`); the pure predicate is `shouldShowBackupNudge(hasIdentityBackup,
    dismissedAt, now)` in `utils/backup_nudge.dart`. Done removes it: `onRecoveryKeySet` success
    already flips `_hasIdentityBackup = true`. "Później" at the door writes the same snooze — the
    user just declined, and a line under the very screen they closed is a nag, not a reminder.
    The line is rendered ABOVE the list in the Chats column (mobile: the list stops scrolling
    behind the header while the line is up; desktop: between the header and the list) so it
    exists in the skeleton, empty and populated states alike. Unknown (`null`, older server)
    renders nothing, as the devices-screen nudge already does.
    Falsification: (F39) drop the `hasIdentityBackup == false` condition on the offer → the offer
    fires on an account the status reported `true` for; (F40) predicate ignores `dismissedAt` →
    the line is back the moment it is dismissed; (F41) generate button ignores `isE2EReady` → it
    is enabled with E2E down; (F42) stamp `freshRegistration` on the taken-but-mine path → an
    existing account is offered a phrase it may already hold. Live: register → shell → offer →
    Później → line on Czaty → X → line gone → Settings → phrase → line stays gone after relogin.
    **Clause 4 — the line and the offer ask for a PHRASE, not a BLOB (field defect, 2026-09-09,
    hours after 0.2.34 went live).** User `goonboy` (id 48) enrolled a phrase on 2026-09-02 —
    before (lxxviii) — so his `recovery_keys` row has a verifier and NO `backupBlob`;
    `hasIdentityBackup` is `false` for him, the Czaty line told him to "secure the account", and
    the screen showed twelve NEW words with no hint that confirming them would replace the ones
    on his paper. He backed out (row `createdAt` unchanged — `setRecoveryKey` rewrites it), so
    nothing was lost; prod had exactly 2 verifier-only rows and 0 blobs, i.e. the line nagged the
    only two people who had already done the right thing. The owner's framing decides the fix:
    for a PWA user the phrase means password recovery, and a verifier-only phrase already does
    that ((lxxxii) clause 2 verifies against `verifierHash`); the blob matters only at the gate,
    which an un-enrolled account never meets, and enabling linking already re-enrols the phrase
    through the same screen. So: `ownKeyBundleStatus` additionally carries `hasRecoveryPhrase`
    (a `recovery_keys` row exists, blob or not; additive, explicit bool, absent = UNKNOWN); the
    clause-1 offer and the clause-3 line key off `hasRecoveryPhrase == false` — never on
    `hasIdentityBackup`. The devices screen's "create your backup" nudge on an ENROLLED primary
    keeps `hasIdentityBackup` (there the blob IS the point). `onRecoveryKeySet` success flips
    both flags. And `RecoveryKeyScreen` says, above the generate button whenever
    `hasRecoveryPhrase == true`, that the new words REPLACE the current phrase
    (`recoveryKeyReplacesExisting`) — true on every door, load-bearing on this one.
    Falsification: (F44) key the line off `hasIdentityBackup` again → a verifier-only account
    (`hasRecoveryPhrase: true, hasIdentityBackup: false`) gets the line; (F45) drop the
    `hasRecoveryPhrase` field from the status payload → the same account gets the line because
    the client reads absent as false (it must read absent as UNKNOWN, and the server must send
    it). Deploy order: backend FIRST — a 0.2.35 client against a 0.2.33 server sees no field and
    shows nothing, which is the safe direction.
  - **(lxxxiv) — THE MUTED KEY-CHANGE LINE LIVES UNTIL THE NEXT MESSAGE (owner pick "a",
    2026-09-12, asked "how long is the strip visible" — answer from source: forever).** (lxxix)
    said "persisted", meaning survives a reload; the implementation made it permanent: the note
    (`peerKeyChangeNotes[peerId]` = ISO instant, `e2e_<uid>_peer_key_change_notes_v1`) was
    written on the change, re-inserted on a repeat, evicted only past the 200-peer cap, and
    consulted by `ChatDetailScreen` with a bare `containsKey`. Rule now: the line renders while
    it is the NEWEST thing in the conversation — i.e. while no message (sent or received, any
    sender) has `createdAt` strictly after the note's instant. The first message after the
    change pushes it out for good; a later change writes a fresh instant and the line returns
    at the top. Two sources answer "is anything newer": the loaded timeline
    (`messages.last.createdAt`, ascending — and ONLY when `messages.last.conversationId` is this
    conversation: the build right after an embedded-pane switch still holds the previous chat's
    rows, `didUpdateWidget` reloads post-frame, and a newer foreign row would durably delete a
    note that was never superseded) and the conversations list's `lastMessages[convId]`,
    which is populated before the chat's history arrives — without it the first render after a
    reload sees an EMPTY timeline, which cannot out-date anything, and the evicted line flashes
    (seen live, `fp-l1-A-reloaded-chat2.png`). And the eviction is DURABLE: the first build that
    finds the note superseded calls `EncryptionService.dismissPeerKeyChangeNote(peerId,
    occurredAt:)` — a COMPARE-AND-REMOVE on the instant (review finding, 0.2.39: the screen
    decides in `build` and calls after the frame, and `_demoteKeyChangeIfMuted` can write a fresh
    instant in between; a peer-keyed remove deleted that never-superseded note and the latch hid
    it) — plus persist + `onPeerIdentityChanged`, once per note instant (`_dismissedNoteAt`
    latch, reset on pane switch), so a cleared or expired history cannot bring a superseded line
    back. An unparseable instant (corrupt storage — the writer is `toIso8601String()`) is dropped
    by `_loadKeyChangeNotes` at the boundary, so the screen's question stays "is anything newer?"
    and never gains a second meaning. Accepted residuals: the instant is device-local and `createdAt` is
    server time, so a device clock behind the server by more than the delivery latency lets the
    TRIGGERING message hide the line at once, a clock ahead lets one extra message through; and
    `messages.last` is the newest by position, not by `createdAt` — an optimistic own row
    (local `now`) followed by a server-stamped peer row can keep the line one message longer
    until the next history merge re-sorts. A muted, informational line; the warnings-ON red pill
    is untouched by this amendment.
    **Rider — per-account peer state leaked across logins.** `EncryptionService` is a process
    singleton; `EncryptionProvider.clearAll` (logout) never cleared the service's
    `_peerKeyChangeNotes` / `_peersWithChangedIdentity` / `_peersRefusedIdentity` /
    `_pendingSessionRebuilds` / `_deviceListPins`, and `initialize(userId)` only ADDED the new
    account's stored entries on top of the previous account's — so after A logs out and B logs
    in (same tab, no reload) B's chats showed A's notes and pills, A's rebuild intents
    (`peerId:deviceId` — A's sessions, not B's) drove B's sends, and A's device-list pins were
    re-persisted under B's storage key. The pins are a scoping/hygiene matter, not a false
    refusal: a list version is peer P's property, so a floor A saw is true for B too — but B's
    floor must come from B's own storage (`e2e_<B>_devicelist_pins_v1`), which the loader
    restores right after the clear. `initialize` now
    clears the five when the user id DIFFERS from the one it last initialised; a same-user
    re-run (passcode re-lock → `revokeForPasscodeLock` → unlock) keeps them, because a refusal
    is session-scoped and unpersisted and must survive a re-lock.
    **Rider 2 — the muted line fired ONCE PER PEER, EVER (found by the live drive: a second
    remint by the same peer produced no line).** `recordPeerIdentityChangedFromServer` returned
    early when the peer was already in `_peersWithChangedIdentity`; with warnings OFF the muted
    demotion acknowledges with nothing staged, the anchor does not advance, and the peer stays
    in that set for good — so every later `peerIdentityChanged` for that peer was dropped as a
    duplicate. Invisible while the line was permanent; silent data loss once it is evicted. Now
    a repeat event with warnings OFF still runs the demotion (fresh note instant, persist,
    notify; the `PEER_IDENTITY_CHANGED` breadcrumb carries `repeat: true`, so the diag ring shows
    remints 2..n); with warnings ON the repeat stays a no-op (the standing pill already says it).
    The local libsignal path is unchanged: its demotion promotes a staged candidate, the anchor
    advances, and the set is cleared, so a second change there is already "fresh".
    Falsification: (F46) drop the timestamp comparison → the note still renders over a message
    newer than it; (F46b) ignore the list's `lastMessages` → the note renders on an empty
    timeline whose list preview is newer; (F46c) drop the `dismissPeerKeyChangeNote` call → the
    superseded note is still in the map; (F46d) trust rows of another conversation → a note
    older than the previous chat's rows is evicted and dismissed; (F47) drop the user-id guard in `initialize` → a note
    recorded for account 1 is present after `initialize(2)`; (F47b) clear unconditionally → a
    refusal recorded before a same-user re-initialise is gone after it; (F48) restore the early
    return → a second server event after an evicted note writes nothing; (F49) make the dismiss
    peer-keyed → a dismissal carrying a stale instant removes a fresher note; (F50) let the loader
    accept any string → an unparseable instant reaches the screen.

- **Amendment 2026-09-17 ((lxxxv), no owner call needed — it closes a residual this document
  already carried as RECORDED and NOT fixed):**
  - **(lxxxv) — THE §6.2 RE-ENROLLMENT IS SINGLE-FLIGHT, AND THE LATCH IS TAKEN BEFORE THE
    MINT.** (lxiv) residual 8 described the overlap and priced it as "device authority stranded
    until another §6.2 ceremony". Re-reading the source puts the price higher: the two passes do
    not merely disagree about which DAK is armed, they **destroy each other's ack channel**.
    `_reenrollAfterReset` is fired unawaited from the owed-offer listener, and the offer rides
    EVERY authenticated `keyBundleUploaded` — so a second upload inside the 20 s ack window
    started a whole second pass, which overwrote `_resetEnrollAck` (orphaning the first waiter)
    and the pending DAK slot; the first pass then timed out and its `finally` cleared the
    SURVIVOR's completer, so `deviceAuthorityEnrolled` had nowhere to land and the second pass
    timed out too. Neither promoted. Fixed with a `_reenrollInFlight` latch taken **before the
    mint** — not at the ack — so a duplicate offer allocates no DAK and arms no record; it is
    recorded as `RESET_REENROLL_INFLIGHT` and returns. Cleared when the pass settles, exactly
    like `_reboundInFlight`, because a later offer is a legitimate retry and the server re-offers
    the terms on every upload anyway. This does NOT supersede residual 1's
    compare-and-promote primitive: the latch closes the concurrent case, while a
    compare-and-promote would also bind the promote to the enrollment the server accepted across
    a process restart.
    Falsification, and this is the shape the regression test drives: (F51) remove the latch → two
    offers inside the ack window emit TWO enrollments (measured: red at `hasLength(1)`, actual 2);
    (F52) take the latch at the ack instead of before the mint → the second pass still mints a DAK
    and arms a pending record before it is turned away; (F53) clear the latch unconditionally in
    `finally` without the single-flight guard → the surviving pass's ack is dropped and the third
    offer is swallowed, which the test's second assertion catches (a still-held latch leaves the
    enrollment count at 1).

- **Amendment 2026-09-22 ((lxxxvi) owner pick "(b) first" in the metadata-privacy session;
  (lxxxvii) no owner call needed — it closes a defect found while building (lxxxvi)):**
  - **(lxxxvi) — ROWS SEALED BEFORE THIS INSTALL'S IDENTITY JOIN THE (lxxxi) DIVIDER.** A storage
    loss on an account with linking OFF re-mints (`IDENTITY_MINTED {reason:
    server-bundle-unlocked-remint}`, (lxxiii) clause 2), and every row the server still serves from
    before was sealed to an identity this install never held: the thread opened on a wall of "Nie
    można odczytać tej wiadomości… Klucze zniknęły". The owner's storage-loss requirement is that
    neither side sees such placeholders. The boundary is the SERVER's audit instant for the change
    that ENDED at this install's key — `ownKeyBundleStatus.identityReplacedAt` when
    `identityReplacedTo` is our published key ((lxxx) clause 5) — never a device clock ((li)).
    `EncryptionService.ownIdentitySince` advances forward-only on such a row and persists as
    `e2e_<uid>_own_identity_since_v1` (a cold start renders history before any connect re-reports
    it); an upload ack carrying `identityChanged: true` re-asks `checkOwnKeyBundle` at once, because
    the connect-time answer predates the row that upload just wrote and the minting session is the
    one the user reads first. `MessagingProvider.messages` then omits, besides the pre-link
    sentinel, every row stamped before that instant whose content is `[Decryption failed]`, or
    `[encrypted]` with no usable decrypted content — a keyed image restored from a history file IS
    usable and stays — and `hiddenPreLinkCount` counts both kinds, so the same ONE divider stands in
    for them. Display boundary only, exactly like (lxxxi): storage, the decrypt pass (so the
    identity-reset `requestSessionRebuild` still fires) and reconcile are unchanged, and a readable
    row is never hidden whatever its age. The view is keyed on the boundary as well as the list, and
    `EncryptionProvider.onOwnIdentitySinceChanged` (set by `ConnectionProvider.setProviders`)
    re-filters an open thread when the audit row lands after its history. **Keys still do not match for such an
    account** — this closes the placeholder half of the requirement only; the key half needs
    linking ON (the (lxxviii) phrase door). Residual: a row a peer seals to the OLD identity AFTER
    the instant (a peer that was offline at the change) still renders as unreadable. The chat-list
    preview never passes through this filter, and the history load and its decrypt pass never
    write it: the server's `conversationsList` sets it, with the neutral `encryptedMessage` label
    for an unreadable row. Only a live event writes it from the thread's own rows — a live receive
    (normally stamped after the instant, so a failure there shows in the thread too), a live edit
    of the previewed row whose decrypt fails, or a delete of the previewed row, which re-points the
    preview to the newest LOADED row. Residual: the last two can surface a hidden pre-boundary row
    in the list as "can't be read on this device" (none of these paths reads the boundary) until
    the next `conversationsList` restores the neutral label.
    Falsification: (F54) drop the pre-identity term → the failed peer row and the own row render and
    the count stays 0; (F55) drop the usable-content exemption → a history-imported image is
    hidden; (F56) drop the callback wiring → the open thread is never notified; (F57) drop the
    launch-time load → a relaunched service forgets the boundary; (F58) drop the post-upload re-ask
    → no `checkOwnKeyBundle` follows an identity-changing ack; (F59) drop the boundary from the
    view's cache key → a boundary that moved without a notification leaves the rows showing;
    (F61) drop the `[Decryption failed]` term → a pre-boundary row the minting session failed
    renders; (F62) drop the `[encrypted]`-without-usable-content term → the same row after a
    restart, which comes back `[encrypted]` (the reset verdict is never persisted), renders.
  - **(lxxxvii) — THE OWN-KEY BRANCH SPENDS THE (li) ONE-SHOT.** An upload ack carrying
    `identityChanged: true` arms `markOwnIdentityPublished` so the report of our own publish does
    not alarm ((li) clause 2). Since (lxxx) clause 5 the server names the key a change ENDED at, and
    a row ending at ours returned early — BEFORE the one-shot was consumed. So after every re-mint
    and every §6.2 ceremony the flag stayed armed in prefs and silently ate the next FOREIGN
    replacement report: the connect-time hydration, which is the only path an OFFLINE device has
    (the live `ownIdentityReplaced` reaches connected sessions only) — i.e. the device a takeover
    targets while its owner is away. Fix: the own-key branch spends an armed flag, because the
    report it was armed for is this one, recognised by content. Falsification: (F60) remove the
    spend → arming the flag, reporting our own row and then a foreign one raises no alarm
    (measured red: `ownIdentityReplacedAt` null).
  - **(lxxxviii) — STORAGE LOSS WITHOUT PLACEHOLDERS: DISPLAY (2026-09-23, owner priority; design
    `.planning/metadata-privacy/storage-loss-design.md` Part A).** The owner's requirement: a PWA user whose
    browser storage is cleared must never see a `[Decryption failed]` or `[encrypted]` placeholder, and old
    history is not needed. Boundary T = `EncryptionService.ownIdentitySince` (SERVER time, persisted,
    forward-only): the (lxxxvi) re-mint audit instant, or the restore instant of lever (d) ((lxxxix)).
    - **A1 — chat list.** The server's `conversationsList` serves every E2E last message as `[encrypted]` and
      only a live event replaces it, so after ANY restart the list resolves each row through
      `MessagingProvider.listPreviewFor(lastMessage, unreadCount)`, wired in `ConversationsScreen`:
      (1) plaintext this install holds for that id (RAM decrypt cache, else the persisted copy, read lazily
      once per id after E2E is up, skipped when edit-stale) → the real text or media label; (2) otherwise a
      PEER row with `unreadCount > 0` this install can read → "Nowa wiadomość" (`newMessagePreview`, list
      only; reply quotes keep `encryptedMessage`); (3) otherwise NO preview text — a read row, an OWN row, a
      row this install can never read (predates T with no usable content, or a hidden post-T row per A2), or
      a stored copy still being read. `ConversationsProvider` no longer relabels the server row to
      'Encrypted message' (the relabel made a dead row look readable).
    - **A2 — thread.** With T set, `MessagingProvider.messages` omits a PEER row stamped at or after T whose
      LAST decrypt attempt failed under the `noSession` rule or the `identityReset` rule (recorded per row at
      the decrypt catch, `_deadSessionFailedIds`) and that has no usable content — `[Decryption failed]` or
      the restart shape `[encrypted]`. It is NOT counted in `hiddenPreLinkCount`: it awaits re-delivery
      (reseal), it is not history. Every other failure class after T renders as before: Bad MAC (a session
      this install holds; `hadSessionAtDecrypt` cannot attribute it to the dead install), duplicate, unknown —
      T is permanent, so a blanket hide would mask genuine faults forever. A row merely queued for its first
      decrypt keeps "Odszyfrowywanie…"; an edit's new ciphertext drops the old verdict; the set lives with the
      conversation cache and is never persisted. T null: unchanged.
    - **A3 — divider copy.** `historyBeforeDeviceLinked` → `historyNotOnThisDevice`: "Wcześniejsze wiadomości
      nie są dostępne na tym urządzeniu" / "Earlier messages aren't available on this device" — one neutral
      text for pre-link and pre-T rows (owner pick).
    Falsification (`messaging_provider_envelope_status_test.dart` group (lxxxviii),
    `conversations_list_preview_test.dart`): (A-F1) drop the unreadable term → a pre-T unread row claims
    "Nowa wiadomość" / a pre-T failed row says "can't be read"; (A-F2) drop the post-T hide → the failed live
    row renders; (A-F3) apply it with T null → a genuine failure on a normal install is hidden; (A-F4) count
    post-T rows in the divider → the count is wrong; (A-F5) widen past the dead-session classes → a post-T
    Bad-MAC/unknown failure disappears; (A-F6) drop the plaintext lookup → a read or own chat loses its text;
    (A-F7) drop `unreadCount > 0` → a read row claims to be new. Residual: a contact's in-flight message sealed
    to the dead session that arrives AFTER this install built a fresh session to that contact fails as Bad
    MAC, stays visible, and is not re-delivered.

- **Next gate:** T11 implementation review, then the T1–T11 merge decision. The T1–T8 phase
  gate itself is CLOSED 2026-08-22: three reviewers, verdicts SHIP / SHIP WITH FIXES ×2; the
  test-integrity findings are folded at `4c0e0bf`; the four security findings were T9. **T10 (xlv)
  and T11 (xlvi) are the two halves of one defect: a completed §6.2 reset left the account
  unreachable, first silently and then fail-closed. Neither was found by a suite** — both came from
  re-reading residual notes against source, and the second was hiding behind a note the first had
  already marked closed.
