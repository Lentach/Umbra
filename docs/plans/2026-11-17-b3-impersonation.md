# B3: can a malicious server impersonate a friend?

Status: investigation + red test; no fix implemented. Date 2026-11-17.
Red test: `frontend/test/security/b3_impersonation_test.dart` (skipped).

## Verdict

**The decrypt half of the chain holds; the wrap-key half is bounded by one
extra precondition.** A party that holds (a) the user's login password and
(b) the server-side contact-backup row can read the friends' queue addresses
and seal frames to them. The friend's device then accepts a first ("PreKey")
message from an identity key the attacker invented, as the user, with no
identity check, and moves the pinned identity to the attacker's key.

The "server" that does this is the identity service operator (or anyone who
can read the plaintext password at `/auth/login` and the backup row). It
does NOT need to break any cipher.

## The chain, link by link

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | Login sends the raw password | TRUE | `frontend/lib/services/api_service.dart:104-110` (`jsonEncode({'identifier', 'password'})` to `/auth/login`); backend hashes it only after receipt (`backend/src/auth/auth.service.ts:58`, `bcrypt.compare`). The server sees the plaintext on every login. |
| 2 | The password unwraps the contact backup | TRUE | `contact_backup.dart:275-303` `deriveWrapKey`: `passcode: secret` for `ContactWrapKind.password`, PBKDF2-style KDF (`kContactBackupKdfIterations`) over the password and a per-account `salt` the server stores and serves. `contact_backup_service.dart:655-665` tries `(ContactWrapKind.password, password)` at login. The server holds the wrapped row AND the salt, so it can run the same KDF offline with the password it just saw. No second secret is involved (the phrase wrap is a *separate* door, not a requirement). |
| 3 | The backup holds friends' queue addresses | TRUE, with a limit | `contact_record.dart:674-691` `toBackupJson` keeps `outbound` (`peerDeviceId`, `sid`, `sealPub`: `contact_record.dart:156-185`) and drops `queues` (own private halves) and `relays`. `outbound` is exactly what a sender needs to write into the friend's normal queue. |
| 4 | Normal-queue frames skip the identity check | TRUE | `_readBox` (`messaging_provider.box.dart:1086-1111`) goes: live-device check (1066) → `preKeyFromNewIdentity` (only a *decision-88 handoff* trigger, for a not-enrolled friend; it does not refuse anything) → `enc.decrypt`. The request/sibling paths call `enc.carriesOwnIdentity(signal)` first (`messaging_provider.box.dart:633-640`, `prekey_identity.dart` `ciphertextMatchesIdentity`); the normal path has no equivalent against the pinned friend identity. |
| 5 | Signal's own store does not catch it | TRUE | `SecureIdentityKeyStore.isTrustedIdentity` (`signal_stores.dart:615-660`) returns `true` for ANY key ("TOFU always wins"), saves it, and for a changed key only stages a candidate + `onIdentityChanged`. It never refuses. |
| 6 | The acknowledgement moves the pin | TRUE by default | `encryption_service.dart:372-393`: with key-change warnings off (the default since (lxxix), `settings_provider.dart:167` is `false`) `_demoteKeyChangeIfMuted` calls `acknowledgePeerIdentity` at once; the test log shows `PEER_IDENTITY_ACKNOWLEDGED anchorAdvanced: true source: pending_candidate`. The anchor is attacker-owned within the same decrypt. With warnings ON the text is still decrypted and returned; only the pin stays on the real key until a human acts. |

### Extra links (what else the server needs)

1. **The backup row's plaintext requires the password at login time or a
   later offline guess.** A server that only stores bcrypt'd passwords but
   logs/observes plaintext at `/auth/login` has it; a database-only leak does
   not (bcrypt'd password, and the KDF salt alone does not open the wrap).
   So B3 is an *active/malicious operator* attack, not a data-at-rest one.
   (Offline guessing of weak passwords against the stored wrap is a separate
   KDF-cost question.)
2. **The user must have a backup row at all** (`ContactBackup` ready).
   Accounts without one are not exposed through this path.
3. **A live origin device.** `_originDeviceIsLive`
   (`messaging_provider.decrypt.dart:72-100`) refuses a revoked/unlisted
   device. The attacker simply names a live id from the user's public signed
   device list (normally device 1): no bar.
4. **The friend's bundle.** Served by the same server to anyone; the red test
   builds the PreKey message from the real public bundle fields.
5. **Sealing to the queue.** The box is anonymous by design: `/box` takes
   unauthenticated sends to a sid (`box_client`, D1). `QueueSeal` (`queue_seal.dart`)
   is ECIES to `sealPub`, which the backup row supplies; no sender
   authentication exists in the outer layer. So **yes, it can seal**.
   `_ownerOf` (`box_inbox.dart:355-375`) then attributes the frame to the
   record's `userId`, and `frame.senderUserId != null` is refused only for
   normal queues (`box_inbox.dart:171`), which the attacker avoids.
6. **A PreKey message to an established session.** libsignal accepts a new
   PreKey message even when a session exists (it archives the old one); this is
   what lets the attacker supersede the real session rather than needing a
   fresh friend.

### What breaks the chain (none fully)

* The friend's OWN device pins `(peer, device)` identity, but only as an
  alarm, never as a gate (`signal_stores.dart:640-656`).
* `preKeyWouldReplaceSession` guards only the sibling path.
* An enrolled friend (`cachedDeviceList.enrolled == true`) does not take the
  decision-88 re-mint path, but the decrypt still runs.

### What the victim sees

* Default settings (warnings off): **nothing in the timeline of the message
  itself.** `PEER_IDENTITY_CHANGED` + `PEER_IDENTITY_ACKNOWLEDGED` fire and a
  muted key-change note is stored (`_peerKeyChangeNotes`) that
  `chat_detail_screen` shows only "for a change that actually was absorbed";
  it is a quiet note, not a block. The forged text is displayed in the
  user's chat. Safety number changes silently (the anchor moved).
* Warnings on: the actionable key-change pill shows, and sends to the user
  fail closed (anchor not advanced), but the forged message is already
  shown.
* The real user is not informed at all: their own device never sees the
  attacker's frames, only later the friend's replies encrypted to the
  attacker's session (they fail to decrypt, appearing as lost messages).

### Evidence run

`flutter test test/security/b3_impersonation_test.dart` with the skip removed:
both tests fail today.

* `victim.decrypt(user, forgedPreKey)` returns `'new number, send the code here'`.
* After it, `peerTofuIdentityBase64(user)` equals the attacker's identity key,
  not the real one (`PEER_IDENTITY_CHANGED` then `PEER_IDENTITY_ACKNOWLEDGED
  anchorAdvanced: true`).

Not covered by the test (stated, not hidden): the seal/inbox attribution and
the backup unwrap are shown by code reading, not by execution; a full
end-to-end run needs the box server. The test stands at the `EncryptionService`
layer `_readBox` calls; the missing check lives at or above that layer.

## Fix options

### Option A: friend-identity check on normal queues (recommended first)

In `_readBox`, before `enc.decrypt`: for a PreKey frame, compare its identity
key with the account anchor pinned for the friend (`getAccountIdentity`,
`signal_stores.dart:~570`), exactly as `carriesOwnIdentity` does for
siblings. A mismatch is not decrypted; the frame is held aside and the friend
gets the actionable key-change pill.

Legitimate identity changes this must keep working:

* **Decision 88 re-mint** (friend lost storage, single-device): the new
  identity arrives in a PreKey frame by design. Today's `preKeyFromNewIdentity`
  path already detects it; for a not-enrolled friend we cannot tell a re-mint
  from the attack by the frame alone: this is the honest residue. Required
  change: do NOT auto-accept; stage the candidate, show the key-change
  pill (safety-number change) and decrypt only after acknowledgement, OR
  accept when the frame carries a proof from the old identity (new
  versioned field in the handoff envelope: old-identity signature over the
  new key + new queue).
* **§6.2 reset ceremony / new enrolled device:** the account identity is
  shared by linked devices (`signal_stores.dart:518-520`); a reset changes the
  signed device list, so the verified list (not the frame) is the authority:
  accept a new identity iff the verified, signature-chained list the client
  already holds (I7) names it.
* **Wire/migration:** none for the check itself (client-only). Old peers
  (≤0.2.88) keep sending exactly as today; their legitimate frames carry the
  pinned identity and pass. Old *receivers* remain vulnerable until they
  update (the check is receiver-side), so the fix only protects updated
  recipients. A signed re-mint proof would be a new optional envelope field,
  ignorable by old clients, but then re-minting old senders cannot supply it:
  they fall to "ask the human" (acknowledge), an acceptable degradation.
* **Effort:** M (about 2-3 days): check, hold/ack flow for re-mint, tests for
  reset/new-device/re-mint.
* **Risk:** medium. A bug here locks friends out after a legitimate
  reinstall; mitigated by the acknowledge path. Must run the wire/E2E
  invariants (`frontend/docs/e2e-invariants.md`).
* **Owner decisions (S8, OWNER-class):** what the user sees on a re-mint
  (blocking pill vs. quiet note: changes "what users see") and whether the
  muted-by-default setting (lxxix) may absorb a key change on a *PreKey frame
  from a normal queue*. Conservative engineering default: never auto-absorb
  on that path. Asked, not assumed.

### Option B: stop deriving the backup wrap from the login password

Keep the backup, but wrap the content key under a secret the server never
sees, so the password stops being a key to the friends' queues.

* **B1: recovery-phrase-only wrap** (drop `ContactWrapKind.password` at
  `contact_backup.dart:298`, `contact_backup_service.dart:411,664`). The
  phrase door already exists (`ContactWrapKind.phrase`). A normal login on a
  new device would no longer restore contacts unless the user types the
  phrase. Product regression for restore UX: OWNER decision.
* **B2: separate backup secret** held in the device keystore plus the
  phrase; a password-only login cannot open it.
* **B3: password-blind login (OPAQUE / client-side stretching).** The server
  never sees the plaintext; the wrap key comes from the OPAQUE export key.
  Biggest change: new auth protocol, new backend endpoints, migration of
  every account (needs the plaintext once, or a re-registration on next
  login).
* **Wire/migration (≤0.2.88):** the row format has a `wraps[]` list with a
  `kind` (the password wrap is one entry), so adding a new kind is additive;
  old clients ignore unknown kinds only if they tolerate them, which must be
  verified in `contact_backup_service.dart` (`_tryWraps`) before shipping. Removing the
  password wrap breaks ≤0.2.88 restore on a fresh login (they look for it).
  Needs a dual-wrap period.
* **Effort:** B1 S-M, B2 M, B3 L (a protocol change; weeks, plus a security review).
* **Risk:** B1 high UX risk; B2 key-loss risk (lose keystore AND phrase →
  contacts gone, which the product already accepts for a lost phone); B3
  high.
* **Owner decisions:** B1 and B2 change recovery UX; B3 changes the auth
  design (the design approved 2026-09-20 §: "changes approved design").
  All OWNER.
* **Does not fix** a server that is *actively* malicious *and* already
  holds a live session token: after login the server can still push a
  bundle. It removes the cheap path (the plaintext password), not the lack
  of sender authentication on the box. A is the only option that closes the
  forging itself.

### Option C: both, staged (A now; B1/B2 as hardening)

## Recommendation

1. **Ship Option A**, with the conservative owner-default (re-mint never
   auto-absorbed from a normal-queue PreKey). It is client-only, closes the
   attack for every updated recipient regardless of how the attacker got the
   addresses (password, backup leak, or a former friend's device), and the
   red test flips green.
2. **Then B2 (or B1)** as defence in depth, only after the owner decides the
   recovery UX; B3/OPAQUE is a separate roadmap item.
3. Until A ships, the exposure is: any server operator that sees the
   plaintext password at login can speak as that user to friends on updated
   and old clients alike.

Owner questions (not decided here): (1) is a PreKey frame under a changed
identity from a normal queue blocked until acknowledged even with key-change
warnings off? (2) should a not-enrolled friend's re-mint require a proof
from the old identity, accepting that old senders then fall back to a human
acknowledge? (3) B1/B2: is requiring the recovery phrase to restore contacts
acceptable?
