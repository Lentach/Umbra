# Web at-rest Signal-key sealing (B2b) — design

**Status:** IMPLEMENTED, DEPLOY HELD — design review REVISE (`SigSealDesignReview`, R1-R8 all
folded in, incl. two CRITICALs: R1 swallowed-throw regeneration, R2 drain lock); post-review
lock-order advisory fixed (ABBA deadlock — drain now takes exactly ONE lock per row, §3.3);
implementation reviews: data-loss **SHIP** (`SigSealDataLossReview`: no regeneration / ratchet
reset / prekey reuse / rollback / re-exposure / deadlock path; two LOW self-healing residuals —
trusted-pin drain race fixed at source, prekey resurrection accepted §3.3), spec
**SHIP-WITH-FIXES** (`SigSealSpecReview`: diag payload aligned, §5.2/§5.3/§5.7 dedicated tests
added and red-proven, kid-sort claim softened). 12+3 falsification mutations run RED.
**Deploy gated on: a dump proving canary survival past the 7-day iOS horizon + fresh owner OK.**
**Queue:** `2026-08-03-HANDOFF-signal-grade-queue.md` addendum (new item after B2a shipped).
**Prereqs read:** root `CLAUDE.md`, `frontend/CLAUDE.md` §5, `docs/design/web-content-sealing.md`
(B2a — the proven template this deliberately mirrors and deliberately diverges from),
`signal_stores.dart`, `encryption_service.dart` init/clear paths.
**Governing rule:** over-retention is recoverable, over-destruction is not; destructive rules
fail closed. For THIS design the sharper form is: **over-unavailability is recoverable
(next boot retries), identity destruction is not.**

## 1. Problem

On web every piece of Signal key material is base64/JSON **cleartext in localStorage** under
`sig_e2e_<uid>_*` (DualStorage web branch → `WebSignalKvStore` over `SharedPreferencesAsync`):

| Family | Content | Blast radius if leaked |
|---|---|---|
| `identity_record_v1` (+ legacy mirrors `identity_key_pair`, `registration_id`) | the identity private key | permanent impersonation + decrypt of all future traffic |
| `session_<peer>_<dev>` | live double-ratchet state per peer | decrypt/forge future messages in that session until rekey |
| `pre_key_<id>`, `signed_pre_key_<id>` | one-time/signed prekey private halves | decrypt PreKey messages addressed to us |
| `trusted_identity_<peer>_<dev>` | peers' PUBLIC keys (TOFU pins) | not secret; integrity-relevant (see §3.6) |
| `next_pre_key_id`, `setup_complete` | counter + flag | none (control records) |

A browser-profile copy, device backup, or disk image yields the identity. The attacker cannot
read PAST messages (B2a sealed those, and consumed ratchet keys are gone), but can impersonate
the owner and decrypt future traffic until noticed. B2a closed the content half; this closes
the key half.

### Threat model (honest scope)

Protects: at-rest disk forensics, profile copies, backups, localStorage dumps — values become
AES-256-GCM ciphertext whose keys live in the origin's IndexedDB+WebCrypto secure store.
Does NOT protect: JS running in the origin (XSS), a compromised device at runtime, the server.
Same posture as B2a and the Android store.

### The availability tradeoff (owner must sign off explicitly)

Today the identity survives iff **localStorage** survives. After B2b it survives iff
**localStorage AND the IndexedDB+WebCrypto key store** survive. That is a real new exposure:
a partial eviction that kills IndexedDB but keeps localStorage would today lose only content
keys (recoverable: rows retire, resend fixes); after B2b it loses the identity (unrecoverable
by design — that is what sealing means). Mitigating evidence and posture:

- `CANARY_OK {ageDays: 5}` on the production device — positive multi-day survival of exactly
  this store. **Honesty corrections (design review):** (1) 5 days is BELOW the ~7-day iOS
  script-writable-storage horizon the fear centers on — the §6 owner sign-off is therefore
  CONDITIONED on canary survival demonstrated past 7 days (it crosses that line within days
  of this writing; a fresh dump proves it). (2) The canary lives in the SAME store as the
  sealing keys, so it is a SIMULTANEOUS loss indicator, not an early warning — it tells us
  loss happened, it cannot tell us before.
- B2a's content keys already live there; since 0.1.5 a silent IndexedDB death surfaces
  loudly (`CONTENT_KEY_LOST`). Any such event before B2b ships is the STOP signal for this
  design.
- Browser eviction (`Clear site data`, ITP, storage pressure) is origin-scoped and USUALLY
  takes localStorage with it — but that is not guaranteed on iOS partitioned PWAs; the
  IndexedDB-dies-localStorage-lives case is precisely the new exposure and is not walked
  back here. What bounds it: transients are survivable (next bullet), and only genuine
  destruction of the key material is fatal.
- `navigator.storage.persist()` is requested at boot (`main.dart`).
- **Key loss is never destruction here**: keys unavailable → E2E is DOWN this session and
  retries next boot (§3.5). Only genuinely destroyed key material is fatal, and every
  transient is survivable by construction.

## 2. Governing rules (acceptance criteria)

1. **An unseal failure on a VALUE READ never becomes absent — it THROWS; an enumeration never
   drops or garbles PRESENCE.** This is the whole design. Absence answers drive catastrophic
   transitions:
   - `loadFromStorage` null → `IdentityLoadResult.absent` → `_generateKeys()` mints a NEW
     identity — every peer's history permanently undecryptable, silently (the exact class the
     atomic identity record was built against, `frontend/CLAUDE.md` §5);
   - `loadSession` null → fresh `SessionRecord()` → ratchet reset → permanent bad-MAC for the
     peer (`signal_stores.dart:553-556`);
   - `containsPreKey` false → prekey id reuse → overwritten private half → bad MAC for whoever
     drew the public half.
   A value that exists but cannot be unsealed surfaces from `read()` as a distinct
   `SigStoreUnreadable(family, stage)` throw that PROPAGATES: the decrypt/encrypt fails
   transiently (retryable), identity load surfaces as `partial`-equivalent refusal — never
   `absent`, never a fresh record, never id reuse.
   **Design-review correction (R1/R3 — CRITICAL/HIGH): throwing is NOT sufficient for
   `readAll`, because two real callers CATCH-AND-SWALLOW an enumeration throw into the
   absent-equivalent default:** `_hasPriorInstallResidue`
   (`encryption_service.dart:260-280`, `catch (_) → return false` → the residue guard that
   blocks regeneration is DISABLED exactly when the key store is flaky) and
   `_highestStoredPreKeyId` (`:700-710`, `catch (_)` → fresh-install default 19 → prekey id
   reuse when the cleartext counter is also lost). A throwing `readAll` therefore re-arms
   both catastrophes through the existing catches. Resolution in §3.1 (presence-preserving
   enumeration) plus two companion hardenings in §3.1a.
2. **Control records stay CLEARTEXT**: `next_pre_key_id` (an origin-shared RMW counter under
   the existing `fireplace-e2e-prekeys-<uid>` Web Lock) and `setup_complete`. Ids/counters
   only; they must stay readable when keys are not.
3. **Migration is resumable and never destructive**: seal-on-write + read-both; a legacy
   plaintext value is replaced ONLY after its envelope round-trips in RAM and a compare-and-set
   re-read confirms no concurrent write (B2a §3.4 steps, same lock discipline). Nothing is
   ever deleted by migration. Correctness never depends on the drain finishing.
4. **Fallback is legal ONLY while no sealed row exists.** First-ever armed session failing to
   mint → plaintext session, loudly (`SIG_STORE_FALLBACK`). But once ANY `fpsig1:` row exists,
   a session that cannot arm its keys must throw (`SIG_KEY_UNAVAILABLE` durable; E2E
   unavailable this session, retried next boot) — it must NEVER fall back to a store that
   would read envelopes as absent/garbage, and above all it must NEVER let an
   absent-looking identity trigger regeneration over sealed rows.
5. **No retirement concept exists for sig rows.** Content rows retire (recoverable by resend);
   key material never does. An unknown kid mid-inventory means THROW on that read, not fold,
   not delete — the key may come back next boot.
6. **New wrapper, not a mutation of `WebSignalKvStore`** — that class is the historical
   behavior; mobile (`flutter_secure_storage`, hardware-backed) is untouched by construction.

## 3. Design

### 3.1 Seam: wrap the DualStorage web branch

Everything reaches web storage through FOUR async methods — `DualStorage.write/read/delete/
readAll` → `WebSignalKvStore`. All callers are already async (libsignal store interfaces are
`Future`-based), so **there is no sync-read problem and therefore NO RAM plaintext view**:
seal/unseal happens inline per operation, stateless. This is the major structural divergence
from B2a and removes B2a's hardest machinery (view coherence, memo pruning, snapshot totality).

New `frontend/lib/services/encryption/sealed_web_signal_kv.dart`:
`SealedWebSignalKv` composes the untouched `WebSignalKvStore` (read-both/legacy-drain behavior
preserved beneath it) plus an injected `ContentSealer` (same interface as B2a; VM tests use the
deterministic fake) and a key manager handle. `DualStorage._webStore` returns it behind a
memoized async opener (rule: a session never flips backend mid-flight). Non-web platforms:
byte-identical by construction.

- `write(key, value)`: sealed family → seal → sealer null = THROW `SigStoreUnreadable(family,
  'seal')` (a refused key write must fail the caller — libsignal store writes are awaited and
  their failure is survivable/retryable; silently persisting plaintext instead would be a
  store that pretends to be sealed). Control family → verbatim.
- `read(key)`: value absent → null (genuine absence keeps meaning absence — new-peer session
  creation, fresh-install detection, and prekey consumption all depend on it). Value present
  with `fpsig1:` prefix → unseal; failure (unknown kid, tamper, WebCrypto error) → THROW.
  Value present without prefix → legacy plaintext, served as-is (read-both).
- `delete(key)`: verbatim (content-agnostic; deletion semantics unchanged — prekey
  consumption, session deletion, `clearEncryptionKeys`).
- `readAll()`: **presence-preserving, never value-throwing** (design review R4 — this is a
  correctness lever, not a perf one). Every real caller consumes KEY NAMES only
  (`inventoryPeerIds` parses names; `clearAllKeys` enumerates-then-deletes;
  `_highestStoredPreKeyId` parses ids from names; `_hasPriorInstallResidue` and
  `_wipeSignalMaterial` classify by suffix). An unsealable value is
  returned AS ITS RAW `fpsig1:` STRING — the key stays present, so residue/highest-id/
  inventory answers stay CORRECT under any crypto transient, and sealing adds ZERO new throw
  surface to enumeration (the underlying `getAll` can still fail exactly as it can today —
  a pre-existing hazard §3.1a hardens). B2a's total-or-throw snapshot doctrine protected a
  VALUE-reading gate; no sig enumeration caller reads values, so presence is the contract
  here. A future value-reading enumeration caller MUST go through `read()` per key (which
  throws properly) — pinned by a doc-comment on the method.

#### Envelope

`fpsig1:<kid>:<base64(12-byte IV || AES-256-GCM ct+tag)>`. Distinct magic from B2a's `fps1:`
so the two families can never cross-decode; no `cid` slot (sig rows are not conversation-
erasure targets; the peer id is already in the cleartext key name for `session_`/`trusted_`
rows — no new metadata leaked, none hidden that a rule needs). A legacy value can never
collide with the magic (values are base64/JSON/ints). Guard test: the parser refuses
non-`fpsig1:` strings; the store never double-seals an already-sealed value.

#### Sealed vs cleartext families

SEALED: `identity_record_v1`, `identity_key_pair`, `registration_id`, `pre_key_<id>`,
`signed_pre_key_<id>`, `session_<peer>_<dev>`, `trusted_identity_<peer>_<dev>` (§3.6).
CLEARTEXT: `next_pre_key_id`, `setup_complete`, anything unrecognized (pass-through verbatim —
forward compatibility; an unknown future key is not silently sealed into a format an older
build can't read).
### 3.1a Companion hardenings (design review R1/R3 — two pre-existing catch sites)

The presence-preserving `readAll` removes the sealing-INDUCED path into these catches, but
the review exposed that both are one underlying-`getAll` failure away from catastrophe even
today. Both are hardened in this change, each with its own red test:

- `_hasPriorInstallResidue` (`encryption_service.dart:260-280`): a failed enumeration must
  read as INCONCLUSIVE → residue-present → regeneration BLOCKED (surface as
  `E2eIdentityIncompleteException`-class refusal, retry next boot). The current
  `catch (_) → false` biases toward regeneration on a storage transient — written for a
  world where `getAll` practically never failed; the bias is inverted now that the guard
  protects sealed material.
- `_highestStoredPreKeyId` (`:700-710`): a failed enumeration must ABORT the mint (return
  null → caller skips replenishment this session), never default to the fresh-install
  floor — the default is exactly the id-reuse hazard the method exists to prevent, reachable
  when the cleartext counter was also lost.

### 3.2 Key custody

- Kids/keys: `fp_sig_key_<kid>`, active-kid marker `fp_sig_active_kid_v1` — a SEPARATE family
  from `fp_content_key_<kid>`, same `FlutterSecureStorage(webOptions: WebOptions(dbName:
  'FireplaceE2E'))` instance (failure modes deliberately correlated with the canary and the
  content keys; if that store dies, everything it guards dies together and the diags say so).
  Separate family because content-key ROTATION/SHREDDING (B2a §6, deferred) must never be able
  to destroy a key sig rows still need — different lifecycle, different namespace.
  `ContentKeyManager` is reused with the prefix/marker parameterized (mechanical; it is
  already platform-agnostic over `SecureKv`) — not a second custody implementation.
- Armed before use: mint = write → FRESH read-back → only then seal anything (unchanged
  doctrine).
- Open (first DualStorage web op of the session, memoized):
  under Web Lock **`fireplace-e2e-sig-keys`** (its own name — touches no SessionRecord, no
  ledger, no content keys): inventory keys → if inventory FAILS (null): sealed rows unknown →
  probe backing store for any `fpsig1:` row; probe SUCCEEDS with zero envelopes → fallback
  (plaintext, loud); probe finds any envelope → THROW `SIG_KEY_UNAVAILABLE` (rule 4);
  **probe itself FAILS → fail closed: THROW `SIG_KEY_UNAVAILABLE`** (design review R5 —
  "no sealed row exists" is only decidable by a SUCCESSFUL zero-envelope probe; folding a
  probe failure into the "none" arm would open the rule-4 forbidden state). If inventory
  succeeds and is empty AND a successful probe shows no sealed rows → mint + arm; mint
  fails → fallback (loud). If inventory has keys → active kid = the marker if present and
  known, else a DETERMINISTIC shared tiebreak (length-then-lex — approximately newest; the
  unpadded rng tail makes strict mint-order impossible and irrelevant: every inventoried
  key decrypts by embedded kid regardless, the tiebreak only makes sibling engines agree);
  proceed sealed. **No row scan, no retire fold — nothing destructive happens at open, ever**
  (rule 5). The lock exists for the cold-store mint race (B2a finding C1's shape): without it
  two engines could both see "no kid + no sealed rows", both mint, and both proceed — harmless
  for uniqueness (kids are unique, both persist) but the lock also serializes non-session
  drain rows against a future rotation, so it is taken from day one, same as B2a. **The
  sig-keys lock is NEVER held while acquiring any other lock** (lock-order advisory, drain
  step 3 below).
- Steady-state ops take NO lock (per-op seal/unseal is stateless; cross-engine session-record
  coherence is already owned by the per-peer `fireplace-e2e-session-<uid>-<peer>` locks and
  `SharedPreferencesAsync`'s cache-free reads — sealing changes neither).

### 3.3 Migration

State lives in the data, resumable by construction (B2a §3.4 verbatim, adapted):

1. **Seal-on-write from the first armed session.** Session records rewrite on every
   encrypt/decrypt, so the hot material seals itself within hours of normal use.
2. **Read-both forever.** Legacy plaintext values serve as-is.
3. **Background drain**, small batches (16 — rows are few: 1 identity + ~25 sessions + ~100
   prekeys), **exactly ONE lock per row, NEVER nested** (post-review lock-order advisory —
   supersedes this doc's earlier "batch lock plus per-peer lock" shape, which was an ABBA
   deadlock: the ratchet path acquires per-peer → (lazy store open) sig-keys, so a drain
   holding sig-keys while WAITING on a per-peer lock hangs both engines forever — Web Locks
   are origin-wide with no timeout):
   - `session_<peer>_<dev>` AND `trusted_identity_<peer>_<dev>` rows drain under ONLY
     `fireplace-e2e-session-<uid>-<peer>` — the SAME lock their writers take (design review
     R2 — CRITICAL for sessions: the sig-keys lock does not mutually exclude the writer
     that matters; a same-engine CAS with "no await between re-read and write" only
     excludes microtasks of the SAME isolate, while a sibling engine can land a ratchet
     advance between the drain's re-read and write — a stale envelope would ROLL BACK the
     double ratchet, permanent bad-MAC. B2a's CAS was sufficient because content rows are
     over-write-recoverable; session rows are not. Trusted pins added by the data-loss
     review: `saveIdentity` rewrites them under the per-peer lock too — a clobbered re-pin
     would only cost one spurious banner + TOFU re-pin, but excluding it at source is
     cheap);
   - every other row drains under ONLY `fireplace-e2e-sig-keys` (no concurrent rewriter by
     construction: identity records are written only at init/migration; prekey rows are
     written once at generation — serialized by the existing `fireplace-e2e-prekeys-<uid>`
     lock — and only ever DELETED afterward, so a CAS re-read finding the row gone aborts
     that row, the correct outcome. Two engines draining the same non-session row
     concurrently is harmless: both envelopes round-trip to the same plaintext.
     **Accepted residual (data-loss review, LOW):** a cross-engine `removePreKey` landing
     between the drain's re-read and write can resurrect a consumed prekey's private half
     as a sealed row — dead weight, never reuse: `next_pre_key_id` has already advanced,
     the server never re-issues that id, and the stale half is never drawn again).
   Per row: seal in RAM → unseal-verify round-trip in RAM BEFORE any write (H1 class:
   in-place replacement means one value under the key at all times; a post-write verify
   would detect failure only after the sole copy of the IDENTITY was overwritten) → re-read
   the key and compare-and-set against the value the envelope was built from, no await
   between re-read and write (D1 class, same-engine half; the row's single lock covers the
   cross-engine half) → write, commit true required → post-write read-back as byte-equality
   durability proof. Abort the drain on any failure; partial progress kept; retry next
   session.
4. **Nothing deleted, ever.** In-place replacement under the same key.

The pre-existing `WebSignalKvStore` legacy-namespace migration (cached SharedPreferences →
async store) is UNDERNEATH this wrapper and untouched: a value it drains arrives as legacy
plaintext and is picked up by read-both/seal-on-write like any other.

**Rollback (owner-gated rarity, accepted with eyes open — harsher than B2a's):** a build
rolled back to raw `WebSignalKvStore` reads `fpsig1:` strings where base64/JSON is expected.
Characterized consequences (to be pinned by tests BEFORE ship): `loadFromStorage` →
`jsonDecode` THROWS → init fails loudly — **not** `absent`, so no regeneration;
`loadSession` → `base64Decode` throws → decrypt fails; `containsPreKey` → non-null → true
(safe). Net: E2E is DOWN under rollback but nothing is destroyed; roll-forward fully
recovers. This asymmetry (down-but-intact) is the acceptable direction.

### 3.4 What "keys unavailable" does to the session (rule 4)

`SIG_KEY_UNAVAILABLE` session: `EncryptionService.initialize` surfaces it like
`E2eIdentityIncompleteException` — E2E does not come up, UI shows the existing init-failure
surface, nothing is written, nothing regenerates, next boot retries. This is deliberately
more conservative than B2a's fallback-and-serve: content could serve envelopes as
present-but-unreadable; Signal CANNOT run without plaintext keys, and any softer failure
invites an absent-read. The one legal fallback (pre-first-seal) is memoized for the session
and never flips TO sealed mid-session.

**Fallback coexistence guard (design review R6):** memoization alone re-opens rule 4 across
engines — engine A legally falls back (mint failed, zero sealed rows), engine B opens minutes
later with the key store recovered, mints, and seals; A would then keep WRITING PLAINTEXT
beside B's sealed rows for the rest of its session (last-write-wins re-exposes at rest
exactly what this design seals). Therefore a fallback session re-probes for `fpsig1:` rows
BEFORE EVERY WRITE (fallback is a rare degraded mode; the scan cost is irrelevant): any
envelope found → the write THROWS `SigStoreUnreadable('fallback-superseded')` and the
session records `SIG_KEY_UNAVAILABLE` — reads may continue (legacy plaintext still serves),
but no new plaintext is persisted beside sealed rows. The fallback never flips to sealed
mid-session; it only loses write permission.

### 3.5 Diagnostics

| Event | Channel | Meaning |
|---|---|---|
| `SIG_SEAL_OPEN {sealed, legacy, ms}` | ring | per-boot open outcome + counts |
| `SIG_SEAL_DRAIN_DONE {sealed}` | durable, one-shot | migration finished |
| `SIG_STORE_FALLBACK {stage}` | durable | pre-first-seal session running plaintext (legal, loud) |
| `SIG_KEY_UNAVAILABLE {stage}` | durable | sealed rows exist, keys unreachable → E2E down this session; `locked` (passcode vault shut) is the exception: it is not memoized, so the first op after the unlock re-opens (0.2.75 fix: 0.2.74 read the store before the passcode screen and kept E2E down for every passcode user on web) |
| `SIG_ROWS_UNREADABLE {stage}` | durable, deduped once per session | first unsealable value encountered (`parse` = malformed envelope, `kid` = key material unreachable for that kid, `unseal` = present-kid tamper/corruption) |
| drain batches | ring | progress |

Watch items post-deploy: any `SIG_KEY_UNAVAILABLE` or `SIG_ROWS_UNREADABLE` = escalate
immediately; `SIG_SEAL_OPEN` should show `legacy` monotonically → 0.
`ContentKeyCanary` unchanged and REQUIRED: a canary loss after B2b ships is now an
identity-threatening event and must page the owner (it already records durable + banner).

### 3.6 `trusted_identity_*`: sealed, and why

Peers' public keys are not confidential, but sealing them buys GCM integrity: a localStorage
writer who swaps a pinned peer key for their own would silently pre-trust a MITM key
(`isTrustedIdentity` compares against the stored pin; a forged pin = no
`PEER_IDENTITY_CHANGED` banner when the MITM begins). Honest limit, stated in the doc so
nobody oversells it: the same attacker can DELETE the pin instead, and first-use TOFU
re-accepts silently — sealing raises the bar from "silent substitution" to "detectable-in-
principle reset", it does not close TOFU. **Cost is small, not zero** (design review): a
present-but-unsealable pin now throws out of `isTrustedIdentity` — the hottest path, every
encrypt/decrypt — taking that peer's messaging down even with a healthy ratchet. Bounded
because: a corrupt plaintext pin already throws today (`base64Decode`/`fromBytes`), the
`_trustedMemo` amortizes the unseal to once per peer per session, and in the key-store-
transient case the sessions are unsealable anyway (E2E down regardless). Marginal both
ways; included for uniformity, not sold as a win. The `_trustedMemo`
write-skip-when-unchanged optimization compares parsed keys ABOVE the seam and is unaffected.

## 4. Non-goals

- Mobile: untouched (hardware-backed already).
- Rotation/shredding of sig keys: envelope carries `kid` from day one; rotation is code-only
  later, same as B2a §6. No shred obligation exists for sig rows (nothing is ever deleted).
- Sealed sender, encrypted backups, app lock: parked by owner decision.
- XSS/runtime hardening: out of scope, stated in the threat model.
- Closing TOFU (§3.6 honest limit): out of scope; fingerprint verification remains the answer.

## 5. Falsification plan (each must run RED first)

1. **Absent-read catastrophe (the class this design exists for):** map unseal failure to null
   in `read` → `loadFromStorage` returns `absent` → assert the test catches that a fresh
   identity WOULD be minted (fake at the regeneration seam); with the throw in place, init
   fails with `SigStoreUnreadable` and storage is untouched.
2. **Session reset on unsealable row:** unsealable `session_` row must throw out of
   `loadSession`; mutation returning `SessionRecord()` must go red (ratchet reset).
3. **Prekey id reuse:** unsealable `pre_key_` row + `containsPreKey` mapped to false → red
   test proving id reuse would overwrite a live private half.
4. **Fallback-over-sealed-rows blocked:** store with `fpsig1:` rows + key inventory failing →
   opener must THROW (`SIG_KEY_UNAVAILABLE`), never return the plaintext store; mutation
   allowing fallback must go red on "fresh plaintext identity written while sealed rows
   exist".
5. **Drain verify order (H1 class):** sealer producing a non-round-tripping envelope must
   abort BEFORE the write; post-write-verify mutation destroys the only identity copy → red.
6. **Drain CAS (D1 class):** concurrent session-record write mid-drain must not be clobbered
   by the stale envelope (ratchet rollback); CAS removal → red.
7. **Cold-store mint race:** two simulated engines, passthrough lock → both mint and proceed;
   real lock serializes (pin the mechanism, B2a-style).
8. **Control records cleartext:** `next_pre_key_id` RMW must remain readable/writable with
   the sealer completely broken.
9. **Rollback characterization:** every family's old-code behavior on an `fpsig1:` value
   pinned exactly as §3.3 states (no `absent`, no regeneration, no id reuse).
10. **No double-seal / no cross-decode:** `fpsig1:` value is never re-sealed; a `fps1:`
    (content) envelope fed to the sig parser is refused and vice versa.
11. **Swallowed-throw regeneration (review R1 — the CRITICAL):** identity rows absent +
    sealed `session_`/`pre_key_` rows present + underlying `getAll` failing →
    `_hasPriorInstallResidue` must report residue/inconclusive and `_generateKeys` must NOT
    run; the current `catch (_) → false` mutation must go red on "new identity minted over
    surviving sealed rows".
12. **Swallowed-throw prekey reuse (review R3):** `next_pre_key_id` absent + `getAll`
    failing → `_highestStoredPreKeyId` must abort the mint; the fresh-install-default
    mutation must go red on id reuse.
13. **Cross-isolate drain CAS (review R2):** the interfering writer holds the PER-PEER
    session lock (not the sig-keys lock) and lands a ratchet advance between the drain's
    re-read and write — with the drain also taking the per-peer lock the write is excluded;
    without it (mutation) the stale envelope clobbers → red. Item 6's same-isolate version
    is necessary but NOT sufficient — this one pins the lock NAME.
14. **Probe-failure fail-closed (review R5):** key inventory null + backing-store probe
    THROWING → opener must throw `SIG_KEY_UNAVAILABLE`; the probe-failure-as-none mutation
    must go red on "plaintext store returned while envelopes exist".
15. **Fallback coexistence (review R6):** a memoized fallback engine + envelopes appearing
    (sibling engine sealed) → next write throws and records `SIG_KEY_UNAVAILABLE`; the
    unguarded-write mutation must go red on "plaintext written beside sealed rows".
16. **Presence-preserving readAll:** an unsealable value must appear in `readAll` as its raw
    envelope (key present); a value-throwing mutation must go red on BOTH the residue guard
    (item 11 shape) and `inventoryPeerIds` bricking on one corrupt row.
17. **Lock-order pin (deadlock advisory):** the drain must NEVER request a per-peer session
    lock while holding `fireplace-e2e-sig-keys` (the ABBA half against the ratchet path's
    per-peer → lazy-open → sig-keys order). The recording test lock flags any acquisition
    requested while sig-keys is held; restoring the nested batch-lock shape must go red.

## 6. Rollout

- Own release, frontend only, after B2a's watch items stay clean; full gauntlet (this doc →
  independent design review DONE (REVISE, folded) → falsified tests →
  parallel data-loss + spec reviews → owner OK).
- Owner sign-off REQUIRED on the §1 availability tradeoff specifically, not just the deploy —
  and CONDITIONED on a dump showing canary survival past the 7-day iOS horizon (§1).
- First boot: `SIG_SEAL_OPEN {legacy: ~126}`; hot rows seal via use, drain finishes the rest;
  one `SIG_SEAL_DRAIN_DONE`. Then `legacy: 0` forever.
- Field instrument unchanged: hacker-mode dump; escalation table in §3.5.
