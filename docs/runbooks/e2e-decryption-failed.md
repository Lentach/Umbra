# Runbook: "[Decryption failed]" reappears (post-0.0.126)

Written 2026-07-07 after the in-process encrypt/decrypt cross-race fix;
updated 2026-07-23 after the cross-PWA-engine incident and 0.0.126 fix.
Use this when users report broken messages again and you need to decide fast:
**stale build, in-process lock failure, cross-context lock failure, replay
window, or identity/session churn** — without re-deriving prior incidents.

## Step 0 — rule out the stale-build trap (2 min, do this FIRST)

The 2026-07-07 incident investigation was nearly derailed twice by builds that
were not what they claimed to be.

1. Affected device → Settings footer → `gitCommit` MUST match
   `git rev-parse --short origin/master`. A bumped semver proves nothing.
2. `curl https://fireplace.ignorelist.com/version.json` (frontend) and
   `/version` (backend). If either is stale, deploy first, re-test, stop here.
3. PWA must be fully closed + reopened after deploy. NEVER uninstall / clear
   site data on a real account (wipes Signal keys, manufactures the exact
   symptom you are debugging).

## Step 1 — pull evidence BEFORE theorizing

- Affected device: Privacy & Safety → hacker mode → **Durable failures
  (survives restart)** → Copy. This is `E2ePersistentDiag` — it survives
  restart precisely so you can do this after the fact.
- Backend (VM): `cd ~/fireplace && docker compose -f docker-compose.prod.yml logs --since 24h backend | grep -iE "one.?time|prekey"`
  — OTP uploads = identity regenerations (reconnect re-upload does NOT upload
  OTPs). Same-minute repeated uploads from one user = clear-data/incognito
  churn, not a code bug.

## Step 2 — classify by signature

| Signature (from diag/UX) | Meaning | Action |
|---|---|---|
| `DECRYPT_DECISION kind:duplicate` on NEW messages from a confirmed 0.0.126+ build | A session writer escaped the process queue/origin lock, or raw replay persistence failed | Step 3A |
| `DECRYPT_RAW_REPLAY` | This engine received a message another engine already decrypted, or resumed after the ratchet advanced but before normal content persistence. Exact-ciphertext replay restored plaintext without touching Signal twice | Expected recovery after 0.0.126; investigate only if followed by failures |
| Messages stuck `SENDING` forever, chats stop decrypting, NO new failure events in diag, app otherwise alive | **The new lock deadlocked** — a guarded method awaits another guarded method for the same peer (non-reentrant tail queue chains behind itself, silently) | Step 3B |
| `kind:duplicate` only on OLD rows | Pre-fix consumed ciphertext. Hydrate any surviving structured plaintext cache; if no engine ever cached plaintext, cryptographic recovery is impossible | Resend only the unrecoverable rows |
| `DECRYPT_IDENTITY_RESET` / `idReset:true`, peer's OTP uploads in backend log | Peer regenerated identity (storage loss / clear-data / incognito). Separate problem — the still-unbuilt regeneration guard | Run the 2-min persistence test (below), then build the guard |
| `kind:badMac` | Peer encrypting from a stale sender ratchet or session mismatch | Existing rebuild-request machinery handles it; investigate only if looping |
| `ENCRYPT_OVERLAP` events | INFO only: proves sends were concurrent. Expected and safe under the lock | Ignore |
| Own SENT message shows `[encrypted]` on the SENDER's device only; recipient reads it fine; NO `DECRYPT_DECISION` for it; log shows `SEND_EMIT` followed by `SOCKET_DISCONNECT` within seconds and no `RECV_MSG` echo. CAVEAT: those events live only in the in-memory ring (wiped on restart) — capture in-session, or add a durable `SEND_UNACKED` event first | **Lost `messageSent` ack** (07-08 field case, msg 14667): socket died inside the ack window, so the tempId→realId mapping never happened and the plaintext was never persisted under the real id. NOT an E2E failure — the wire was fine, the recipient got it; a Signal sender cannot decrypt its own ciphertext, so the sender's copy stays `[encrypted]`. Message content is recoverable only by resending | **FIXED (0.0.102, `fix/lost-ack-pending-send-reconcile`)**: durable pending-send records — ONE SharedPreferences key per EXACT emitted ciphertext (`e2e_${uid}_pendsend_v1_<ciphertext>`, NOT a shared JSON blob: concurrent-save RMW on one blob is the `_sessionTails` lost-update shape), written at `SEND_EMIT`, consumed on ack, TTL 72h + cap 40; history merge reconciles an own `[encrypted]` row via peek → persist under real id → VERIFY by read-back (`saveDecryptedContent` swallows failures) → take, emitting durable `SEND_ACK_RECONCILED`. Wiped by `clearAllKeys`/`clearDecryptedContentCache` (plaintext at rest); deliberately NOT cleared on reconnect. NEVER replace the exact-ciphertext matcher with heuristics: review rejected timestamp proximity because a wrong match persists the WRONG plaintext under a real id — permanent, worse than `[encrypted]` |
| `kind:noSession` + `hadSession:false` on messages sent AFTER this device wiped/reinstalled and re-minted (`rule` is `identityReset` in the process that minted, `noSession`/`badMac` in a later one) | Expected post-wipe damage, NOT a receiver bug: the pre-wipe backlog is unrecoverable, the peer IS asked to re-key, and new messages decrypt once the peer confirms your new safety number | **Step 3G** — settled, do not re-derive |

**Dating rule (learned twice — msg 14149, then msgs 14389/14423):** a
`DECRYPT_DECISION` timestamp is when the receiver ATTEMPTED the decrypt, not
when the message was sent. Wires are poisoned at ENCRYPT time on the sender's
device. Before classifying any duplicate as new-vs-pre-fix, date the row and
identify the sender. The server keeps no message rows any more (the `messages`
table was dropped in Phase 4 step 5): date it from the diag/log timestamps of
the sending device, or from the offline archive for a pre-step-5 id.

Then check the SENDER's footer version at that time — a peer PWA keeps running
its cached old bundle until fully closed + reopened (can be days after a
deploy), and a stale sender mints poisoned wires that an up-to-date receiver
correctly rejects. Stale-sender decay is expected after a fix ships; only a
duplicate from a **confirmed-updated** sender reopens Step 3A.

## Step 3A — duplicate counters on new messages (the race is back)

The invariant has two layers: **every** peer-session load→mutate→store must go
through the process-local `_runSessionSerialized`, and every web acquisition
must also hold the origin-wide `runSessionCrossContextLocked` lock keyed by
local user + peer. Suspects, in order:

1. Enumerate every `SessionCipher` / `SessionBuilder` construction and
   `storeSession` / `deleteSession` caller. All production writers must remain
   inside serialized `EncryptionService` bodies.
2. Check the cross-context runner. On web it must reach `navigator.locks`;
   native/stub intentionally uses only the process queue. A caught Web Locks
   error must propagate — silently running unlocked reopens the bug.
3. Run
   `frontend/test/services/encryption_encrypt_decrypt_race_probe_test.dart`.
   Its two-engine gated case uses separate `_sessionTails` maps plus a shared
   origin-lock model. Removing the cross-context lock must reproduce
   `DuplicateMessageException old counter: 1, 0`.
4. Run the source-controlled browser probe:
   ```bash
   cd frontend
   dart compile js tool/session_cross_context_lock_probe.dart \
     -o build/session_lock_probe/probe.js
   python -m http.server 8765
   ```
   Open `http://127.0.0.1:8765/tool/session_cross_context_lock_probe.html`;
   the title must become `SESSION_LOCK_PASS`. It asserts same-name queuing and
   fail-closed behavior when `navigator.locks` is absent. Also run
   `session_cross_context_lock_web_test.dart` when the Flutter Chrome harness
   is healthy.
5. Never add another ad-hoc session lock. Extend the existing two-layer
   contract and keep guarded bodies leaf-level/non-reentrant.

## Step 3B — hang: the lock deadlocked (bug IN the race fix)

Mechanism: `_sessionTails` is a tail-chained future queue, NOT a reentrant
mutex. If a guarded method (`encrypt`, `decrypt`, `buildSession`,
`deleteSession`) ever awaits another guarded method for the SAME peer while
queued, it waits behind itself forever. No exception, no diag event — sends
hang, decrypts stop, per one peer or all peers.

1. Confirm: `git log -p` the four guarded bodies (`_encryptSerialized`,
   `_decryptSerialized`, `_buildSessionSerialized`, the `deleteSession`
   closure) — any call to `encrypt(`, `decrypt(`, `buildSession(`,
   `deleteSession(` inside them is the bug.
2. Fix = hoist the nested call OUT: cross-operation sequencing (e.g.
   `ensureSession` → `buildSession` then `encrypt`) lives at the provider
   layer as separate sequential acquisitions. Guarded bodies stay leaf-level.
3. Emergency mitigation while fixing: `git revert` the offending commit and
   `.\deploy-web.ps1`. Reverting the lock itself is SAFE data-wise (no storage
   format change; keys/ratchets untouched) — you trade back to the rare race,
   which beats a hung app.

## Step 3C — duplicate replay/crash window (fixed in 0.0.126)

A Signal decrypt consumes and persists a one-shot ratchet key before provider
code can persist the parsed envelope. Another PWA engine can receive the same
socket broadcast after that advance; app suspension can also kill the first
engine in the post-decrypt window. Re-decrypting the ciphertext then correctly
throws `DuplicateMessageException`.

0.0.126 writes a bounded raw plaintext replay record while still holding the
cross-context session lock. The record is keyed by local user + message id and
accepted only when the ciphertext matches exactly. The second engine therefore
returns plaintext without consuming Signal twice; edited ciphertext with the
same message id cannot replay stale content. Normal structured content
persistence does not delete this short replay record. Account/cache privacy
clears remove both stores.

If a post-0.0.126 duplicate reaches the UI instead of logging
`DECRYPT_RAW_REPLAY`, check the served commit first, then inspect whether the
raw preference write failed (`DECRYPT_RAW_PERSIST_FAILED`) or whether the
message id/ciphertext changed.

## Step 3D — chat entry is slow and briefly shows "[encrypted]"

NOT a decryption failure. Rows resolve correctly, just late. Symptom: opening a
chat with real history janks for a fraction of a second and the message text
visibly flips from `[encrypted]` to plaintext.

Two independent causes, both fixed after 0.0.132:

1. **Paint before hydrate.** The server ships `content: "[encrypted]"` for
   every E2E row, and `onMessageHistory` merged + notified BEFORE any local
   plaintext was applied, so the first painted frame was all placeholders.
   Fixed by hydrating the parsed snapshot from the RAM/persisted caches while
   it is still a caller-local list
   (`_hydrateSnapshotFromCaches`, `messaging_provider.decrypt.dart`).
2. **One full `SharedPreferences.reload()` PER ROW.** `getDecryptedContent`
   reloads before every read (added by `fd89e7e` for cross-engine coherence),
   and the history pass called it once per message. On web `reload()` is
   `getAll()`: enumerate EVERY localStorage key, then `getItem` + `jsonDecode`
   each `flutter.`-prefixed one — and the plaintext cache holds up to 2000
   records. Fixed by `getDecryptedContentMany` (one reload per pass).

Measured with `frontend/tool/prefs_reload_cost_probe.dart` (compile + serve +
headless Chrome, same pattern as the session-lock probe; title becomes
`PREFS_PROBE_DONE`). At the 2000-record cap, desktop i7, real localStorage:
one reload 1.6-2.0 ms; a 50-row page cost 65-77 ms of blocked main thread,
200 rows ~300 ms, 400 rows ~590 ms. One reload for the whole pass is ~1.5 ms
flat. Phones run this 4-6x slower.

**Do NOT "fix" this by deleting the reload.** The plaintext cache is itself a
cross-engine coherence surface: a stale snapshot means a cache miss, a live
decrypt of a ciphertext another engine already consumed, and a real
`DuplicateMessage`. Hoisting is safe only because one reload still opens the
pass and the raw replay cache (which keeps its own reload, written before the
session lock releases, capped at 40 records) still covers writes landing
mid-pass. Same reason a batch MISS is not an answer — callers must fall
through to `getDecryptedContent`, never treat an absent id as "no plaintext".

Regressions: `frontend/test/providers/messaging_provider_chat_entry_hydration_test.dart`.
Both behaviours are separately falsifiable (disable the pre-paint hydration →
the placeholder-frame test goes red; ignore the prefetched batch → the
pass-level read-count test goes red at 30 reads instead of 0).

## Step 3E — "Encryption keys missing on this device" banner / E2E never comes up

`E2eIdentityIncompleteException`. This install holds no usable Signal identity
(absent, or present but INCOMPLETE) while the server already has a bundle for
the login's device, and initialization refused to mint over it. This is
deliberate: regenerating silently is what destroys a user's history without
telling them. Diag shows `IDENTITY_INCOMPLETE` (local residue was found) or
`IDENTITY_GUARD_SERVER_BUNDLE_EXISTS` (empty store, second-device shape).

1. Do NOT tell the user to clear site data or reinstall — that converts
   recoverable damage into certain loss.
2. Dump `E2ePersistentDiag`. `IDENTITY_RESIDUE_UNKNOWN` means the residue probe
   itself failed twice and was treated as RESIDUE-PRESENT (fail closed); with
   the server saying a bundle exists that changes nothing, and with the server
   saying none exists the residue is discarded (`IDENTITY_RESIDUE_DISCARDED`)
   and a fresh identity minted — there is nothing to recover on a
   never-enrolled account.
3. There is no "start fresh" (amendment (lxxi)). The way forward is the §5.1
   link from a device that still holds the keys (the banner's only action), or
   the §6.2 reset (72 h; 1 h with the recovery phrase) when no such device
   exists. Set expectations precisely: after a reset, every message this device
   has NOT already decrypted is gone for good and peers re-key; history already
   in the plaintext cache stays readable.

## Step 3F — "security keys changed" warning in a chat

`PEER_IDENTITY_CHANGED`. The peer presented an identity key different from the
one we had trusted. Fireplace remains trust-on-first-use, so the message still
decrypts — the change is now surfaced instead of swallowed.

Almost always a reinstall or storage wipe on their side (cross-check: their OTP
uploads in the backend log, per Step 1). It is also indistinguishable from a
server handing us a substituted bundle, which is why the user is told rather
than the client deciding for them. There is no action to take in the app; the
resolution is the two humans confirming over another channel.

## Step 3G — everything from a peer fails after THIS device was wiped/reinstalled

**SETTLED 2026-09-13 — the receiver side is not the defect, and this does not kill the channel.**
Device-proven on the 0.2.42 APK (`7818786…`, Pixel_7 AVD, prod backend) across four
`pm clear` → re-login cycles. Read the verdict before re-deriving anything.

Signature: `peer <id> · noSession · N messages` on messages the peer sent AFTER this device
re-minted. `kind:noSession` with `hadSession:false` means the RECEIVER has no session to open the
message with; it is NOT `badMac`, so "the peer encrypted to a stale identity" is ruled out. The
peer sent a whisper, not a PreKey — **confirmed, no longer inference**:
`DECRYPT_START {msgId: …, ctype: 2, hasSession: true}`.

### Verdict: the peer IS told, every time, and the channel comes back

`notifyPeer: true` in every failing row observed, and the request reaches the peer at the wire
level. Two independent emit paths cover the two process shapes:

| Process that decrypts | rule | emit path |
|---|---|---|
| the one that MINTED (reinstall → log in → open chat) | `identityReset` | immediate `requestSessionRebuild` (`messaging_provider.decrypt.dart:1546-1557`) |
| a LATER one (FCM-woken, cold start) | `noSession` / `badMac` | `_retryDecryptForPeers` → `_requestSessionRebuildForPeer` → durable `SESSION_RESET` (`:1149-1168`, `:467-491`) |

Backend relays it as `sessionRebuildNeeded {fromUserId}` **and remembers it**, replaying to a
recipient that connects later (`chat-key-exchange.service.ts:1090-1103`, `:1021`) — so an offline
peer still gets it. Observed rows:

```
05:06:00 IDENTITY_MINTED {userId: 123, reason: server-bundle-unlocked-remint}
05:07:10 DECRYPT_DECISION {msgId: 24332, kind: noSession, rule: identityReset, isHistory: true,
         idReset: true, hadSession: false, persist: false, markFailed: true, retry: none,
         notifyPeer: true}
05:14:30 DECRYPT_DECISION {msgId: 24332, kind: badMac, rule: badMac, idReset: false,
         hadSession: true, notifyPeer: true}        <- later process, session now exists
05:14:30 SESSION_RESET {peerId: 124, trigger: badMac}
```

plus, on a socket joined to the PEER's own user room: `<- sessionRebuildNeeded {"fromUserId":123}`.

**`idReset` correction (the 2026-07/09 write-ups had this wrong).** `hadIdentityReset` is
`_encryptionService.needsKeyUpload` (`encryption_provider.dart:119`), an in-memory field
(`encryption_service.dart:234`) set on mint/adopt (`:1223`, `:1434`, `:1666`) and **never
persisted**. The bundle upload does NOT clear it — `encryption_provider.dart:1469` only READS it;
the only clear sites are `:1473` (link-identity discard), `:4296` and `:4336` (clearAllKeys /
reset). So it stays TRUE for the whole lifetime of the minting process, and the ordinary
reinstall sequence takes the `identityReset` branch. `idReset:false` appears only in a process
that did not itself mint (`E2E_INIT_DONE {needsKeyUpload: false}`) — which is what the first
2026-09-13 observation caught, via FCM.

**Do NOT build the proposed durable "identity replaced; peer N not yet re-keyed" marker.**
`OWN_IDENTITY_REPLACED` is already recorded durably, both emit paths already fire, and the missed
classification costs nothing observable. There is no receiver-side fix to make here.

**One real defect DOES fall out of the corrected fact, and it is the best red-first test
candidate here.** `needsKeyUpload` is process-wide and peer-AGNOSTIC, so for the whole lifetime
of a minting process `hadIdentityReset` is true for EVERY peer — not just the ones affected by
the identity change. `decideDecryptionFailure` therefore routes an UNRELATED peer's transient
`noSession`/`unknown` down the `identityReset` branch: `markContentFailed: true` with
`retryAction: none`, plus a `requestSessionRebuild` that peer never needed (their OTP burns).
Bounded — `persistTerminalFailure` is false, so a later launch re-attempts and can still recover
the row — but during that first post-reinstall session a one-off hiccup is shown as
`[Decryption failed]` with no retry at all. Not observed in the field yet; not fixed here
(out of scope for the wipe question). A fix would scope the flag per peer, or gate the branch on
the peer actually having been affected.

### What actually blocks the conversation: the SENDER's account-identity anchor

The peer's first send after your re-mint FAILS locally, before the wire:
`SEND_FAIL {error: AccountIdentityMismatch: the bundle served for userId=… deviceId=1 carries an
identity key that is not the account's}` (`encryption_service.dart:1864-1872`).

**Since 0.2.43 the peer is told BEFORE they compose, not after the bounce.** The red
`PeerIdentityChangedRow` pill ("Klucze … się zmieniły. Dotknij, aby sprawdzić") now renders for
any peer whose anchor has not advanced, regardless of the key-change warnings setting — that
state is knowable the moment the change arrives, and it is exactly the state in which every send
fails. Before that fix the default (warnings OFF) demoted it to a calm "klucze zaktualizowane"
note and the pill appeared only AFTER a refused send had set `peersRefusedIdentity`, so the first
symptom a user ever saw was a message bouncing with "Ponów" and no explanation. The bounced
bubble now names the cause too: a row whose OWN last attempt threw `AccountIdentityMismatch`
carries "Nie wysłano: klucze bezpieczeństwa tego kontaktu się zmieniły…" above the retry button
while the ceremony is outstanding, because until the anchor advances every retry fails
identically. Two conditions, not one: a timeout or an "Image too large" bounce in the SAME chat
keeps showing "Ponów" alone — there, retrying IS the remedy — and the sentence disappears once
fingerprints are compared, leaving the plain retry.

This is DESIGN, not a bug. The anchor moves only through a human confirmation (amendment (xlvi));
the demoted auto-acknowledge can only promote a candidate this device RECORDED, and a plain
server event stages none — `_demoteKeyChangeIfMuted` says so explicitly
(`encryption_service.dart:306-319`), producing
`PEER_IDENTITY_ACKNOWLEDGED {anchorAdvanced: false, source: pending_candidate}`. Auto-advancing
there would let the server swap a peer's identity key with nobody ever comparing a number.

After the peer taps the pill → "Odciski się zgadzają"
(`PEER_IDENTITY_ACKNOWLEDGED {anchorAdvanced: true, source: displayed_candidate}`) → "Ponów",
the message is delivered and **decrypts LIVE on the wiped device** (verified twice: 05:10 and
05:23 rows, phone in the foreground in that chat).

Two things that look like fixes and are not:

- **Having the wiped device send first does NOT spare the peer.** Tested: the phone's PreKey
  message decrypted on the peer, and the peer's reply STILL bounced with
  `AccountIdentityMismatch`. The outbound path validates the anchor regardless of an existing
  session.
- **A recovery phrase only helps an ENROLLED account.** With linking OFF (the default) a keyless
  login re-mints silently and never asks for the phrase, even when the account has one
  (device-proven: `Generating new keys (fresh install)` with a phrase on file). With linking ON
  the reinstall meets the device-link gate, which offers "Mam frazę odzyskiwania" → same identity
  restored (`Loaded existing keys from storage`, no own-identity banner) → no peer sees a key
  change and no confirmation is needed.

### Live (socket) path

No longer "not verified", but note what was actually observed: after the re-mint, **both** live
post-heal messages DECRYPTED, so the live path never produced a failure row to mis-flag. Every
failing row in every cycle was `isHistory: true`. `decideDecryptionFailure` differs only in the
retry action for the live case (`scheduleLiveRetry` → `_runLiveDecryptRetries` →
`_retryDecryptForPeers`, same `_requestSessionRebuildForPeer`), so the notify is covered there too.

### Known rough edge after a phrase restore (separate, unfixed)

The restore REBINDS the device id. A peer client already open keeps sending to the old one —
`SEND_FAIL {error: Bad state: Recipient has no key bundle (userId=…, deviceId=1)}` for ~90 s of
retries — and the restored device's first message sits as `[encrypted]` on their side (accept-side
gate withholding an unverified origin). ONE reload/restart of the peer app clears both. Owner call
pending on whether the inbound envelope should refresh the verified device list sooner.

Repro (~15 min, prod): two throwaway accounts, exchange a message each way, then on the phone
`adb shell pm clear com.fireplace.app`, relaunch and log back in — on an UN-ENROLLED account any
keyless login re-mints (`encryption_service.dart:1201-1208`); an ENROLLED one gates instead
(`:1166`), so use an un-enrolled account here. Then send peer → phone. Delete the accounts after.
**`pm clear` wipes the durable ring: read it with the hacker-mode panel's Copy button, which
lands on the Windows clipboard through the emulator's clipboard sync, BEFORE clearing.**

## The 2-min persistence test (still not run as of 2026-07-07)

Gates the regeneration guard. Normal (non-incognito) browser profile: register
fresh account → send/receive once → fully close browser → reopen → open app.
Backend log must show NO new OTP upload for that user. If it does, key
persistence is broken on normal profiles and that is the fleet-wide story —
prioritize over everything else.

## Hard rules (learned the expensive way)

- Never conclude "not a regression" from "the files I checked didn't change".
  The 07-07 incident verdict missed a live race because the audit stopped at
  key-storage code. Enumerate WRITERS of the shared state, not diffs of files.
- Never advise users to clear site data / reinstall / test in incognito.
- `[Decryption failed]` rows that are persisted-terminal do not come back.
  Ever. Set expectations before deploying a fix.

## Incident record — 2026-07-23 Sender A → Receiver B

- User report: several messages showed `[Decryption failed]`, then recovered
  without a resend over a short period.
- Production evidence covered three affected type-2 whisper rows in one
  conversation across two consecutive days. Exact account/message identifiers
  and timestamps remain only in the gitignored incident findings.
- Receiver diagnostics classified all three rows as `kind:duplicate`, not bad
  MAC, no-session, or identity reset. The later diagnostic times date history
  attempts, not message creation.
- Sender key-bundle evidence showed no identity rotation: registration and
  identity remained stable, with unused OTPs available. A bundle
  reconnect/update preceded the two newest rows by about four minutes.
- The served frontend was commit `c15d770`, version `0.0.125`; backend was
  `4609af2`. The frontend delta since the prior build contained Contacts UI
  only. The latest E2E commit only repaired next-OTP id selection. Neither
  introduced the failure.
- Attribution (high confidence, not direct client telemetry): 0.0.94 serialized
  Signal writes only inside one Dart engine. Multiple same-origin PWA engines
  share Signal storage but owned independent `_sessionTails`; they could race
  the same record or process one broadcast twice. Legacy `SharedPreferences`
  caching could then hide plaintext written by the other engine. A later cache
  hydration/restart exposed that plaintext, producing the visible
  “self-repair.” No production snapshot recorded which windows were open, but
  the deterministic harness reproduces the complete signature.
- Why it was intermittent: it requires overlapping engines/resume traffic and
  a narrow ratchet/cache ordering. A quiet month does not disprove it.
- Fix: origin-wide Web Locks around every peer-session mutation; exact-
  ciphertext raw replay written before lock release; web-only preference
  reload before cross-context reads; provider call sites now bind `messageId`
  into decrypt.
- Proof before release: deterministic two-engine probe failed pre-fix with
  `DuplicateMessageException old counter: 1, 0` and passes post-fix; the
  compiled browser helper queued same-name Web Locks; all focused tests,
  the full Flutter suite, production web build, and local full-stack Signal
  wire harness passed.
- Scope: prevents future races/replay gaps. It cannot recover plaintext for a
  message that was consumed before 0.0.126 and never cached anywhere. Do not
  clear users' site data; that destroys the keys needed for unaffected traffic.

## Known accepted edges (independent review, 2026-07-09 — none blocking)

- `buildSession`/`deleteSession` are lock-guarded but NOT probe-pinned: the
  gated test would stay green if their `_runSessionSerialized` wrapper were
  silently removed. Follow-up gated case if touching this code: hold an
  encrypt's storeSession, run buildSession to completion, release, assert the
  next wire decrypts.
- `EncryptionService` is app-lifetime; `_sessionTails` are never cleared and
  `initialize()` swaps stores without draining the queue. A cross-user write
  is ~unreachable today (tails drain in ms, prekey fetches cancel on
  disconnect) but nothing ENFORCES quiescence across `initialize()`. Clean fix
  if it ever bites: fresh service per login, or key tails by (userId, peerId).
- `clearAllKeys()` (account deletion) deletes session records outside the
  queue — an in-flight op past its loadSession can resurrect session bytes at
  rest after the wipe. Privacy hygiene only; route the deletes through the
  queue if hardening.
